# Exercises the actual Windows/WSL path boundary and export-process environment.
Test 'process environment overrides remove originally absent variables after tool success or failure' {
    Import-Module (Join-Path $root 'skills/ba-release/scripts/ProcessTools.psm1') -Force
    $key='BA_RELEASE_ABSENT_ENVIRONMENT_TEST'
    Remove-Item -LiteralPath ('Env:'+$key) -ErrorAction SilentlyContinue
    $probe=Join-Path $sandbox 'environment-probe.ps1'
    "if (`$env:BA_RELEASE_ABSENT_ENVIRONMENT_TEST -cne 'temporary') {exit 9}; exit 0" | Set-Content -LiteralPath $probe
    $result=Invoke-ReleaseTool $probe @() $sandbox -Environment @{$key='temporary'}
    Assert ($result.exitCode -eq 0 -and -not (Test-Path -LiteralPath ('Env:'+$key))) 'Successful tool left an originally absent variable behind.'
    Expect-Error {Invoke-ReleaseTool (Join-Path $sandbox 'missing-executable') @() $sandbox -Environment @{$key='temporary'}} 'did not run as a process'
    Assert (-not (Test-Path -LiteralPath ('Env:'+$key))) 'Failed tool left an originally absent variable behind.'
}
Test 'tool runners close stdin even when the caller holds an input pipe open' {
    $tool=Join-Path $sandbox 'stdin-gcloud.ps1'
    @'
if ($MyInvocation.ExpectingInput) {
    [Console]::Error.WriteLine('waiting-for-eof')
    $input | Out-Null
}
'eof received'
exit 7
'@ | Set-Content -LiteralPath $tool
    $runner=Join-Path $sandbox 'open-stdin-runner.ps1'
    @'
# Like the SDK wrapper, omit a param block so pwsh does not bind stdin before the body.
$Module,$Tool,$Directory,$Kind=$args
$ErrorActionPreference='Stop'
Import-Module $Module -Force
$result=switch ($Kind) {
    'probe' {Invoke-ReleaseProbe $Tool @('--version') $Directory 5}
    'tool' {Invoke-ReleaseTool $Tool @('--version') $Directory}
    'native' {Invoke-ReleaseTool (Join-Path $PSHOME $(if ($IsWindows) {'pwsh.exe'} else {'pwsh'})) @('-NoProfile','-File',$Tool,'--version') $Directory}
}
$result | ConvertTo-Json -Compress
exit 0
'@ | Set-Content -LiteralPath $runner
    foreach ($kind in @('control','probe','tool','native')) {
        $start=[Diagnostics.ProcessStartInfo]::new()
        $start.FileName=Join-Path $PSHOME $(if ($IsWindows) {'pwsh.exe'} else {'pwsh'})
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true
        $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        $arguments=if ($kind -eq 'control') {@('-NoProfile','-File',$tool)} else {@('-NoProfile','-File',$runner,(Join-Path $root 'skills/ba-release/scripts/ProcessTools.psm1'),$tool,$sandbox,$kind)}
        foreach ($argument in $arguments) {$start.ArgumentList.Add($argument)}
        $process=[Diagnostics.Process]::new();$process.StartInfo=$start
        try {
            $null=$process.Start()
            # Deliberately leave StandardInput open: closing the outer pipe would hide the bug.
            if ($kind -eq 'control') {
                $ready=$process.StandardError.ReadLineAsync()
                Assert ($ready.Wait(10000) -and $ready.Result -eq 'waiting-for-eof') 'Control wrapper did not enter its input-reading branch.'
                Assert (-not $process.WaitForExit(250)) 'Control wrapper did not block on inherited stdin.'
                continue
            }
            $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
            Assert ($process.WaitForExit(15000)) "$kind runner waited on the caller's open input pipe."
            Assert ([Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout,$stderr),5000)) "$kind output did not close."
            Assert ($process.ExitCode -eq 0) "$kind runner failed: $($stderr.Result)"
            $result=$stdout.Result | ConvertFrom-Json -AsHashtable
            Assert ($result.exitCode -eq 7 -and $result.text -match 'eof received') "$kind did not return the wrapper output and exit code: $($stdout.Result)"
        } finally {
            if (-not $process.HasExited) {$process.Kill($true);$null=$process.WaitForExit(5000)}
            $process.Dispose()
        }
    }
}
Test 'tool lookup requires PATH or an explicit directory and never implicitly runs a local file' {
    Import-Module (Join-Path $root 'skills/ba-release/scripts/ProcessTools.psm1') -Force
    $directory=Join-Path $sandbox 'local-tool-lookup'
    New-Item -ItemType Directory $directory | Out-Null
    $name='local-only-'+[guid]::NewGuid().ToString('N')+'.ps1'
    $path=Join-Path $directory $name
    "'explicit local tool';exit 0" | Set-Content -LiteralPath $path
    Push-Location $directory
    try {
        Assert (-not (Find-ReleaseDoctorTool $name)) 'A bare command name resolved from the working directory.'
        Expect-Error {Invoke-ReleaseTool $name @() $directory} 'executable missing or not runnable'
        Assert ((Find-ReleaseDoctorTool ("./"+$name)) -eq $path) 'Explicit relative tool path was rejected.'
        $result=Invoke-ReleaseTool ("./"+$name) @() $directory
        Assert ($result.exitCode -eq 0 -and $result.text -eq 'explicit local tool') 'Explicit local tool did not run.'
        $priorPath=$env:PATH
        try {
            $env:PATH=$directory+[IO.Path]::PathSeparator+$priorPath
            Assert ((Find-ReleaseDoctorTool $name) -eq $path) 'A command on PATH was rejected.'
        } finally {$env:PATH=$priorPath}
    } finally {Pop-Location}
}
if ($IsWindows) {
    Test 'Windows tool lookup rejects association-only PATHEXT entries before invocation' {
        Import-Module (Join-Path $root 'skills/ba-release/scripts/ProcessTools.psm1') -Force
        $directory=Join-Path $sandbox 'association-tools'
        $fallback=Join-Path $sandbox 'waited-tools'
        New-Item -ItemType Directory $directory,$fallback | Out-Null
        $priorPath=$env:PATH;$priorExtensions=$env:PATHEXT
        try {
            $env:PATHEXT='.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.CPL;.PY;.PYW;'+$priorExtensions
            $env:PATH=$directory+';'+$fallback+';'+$priorPath
            foreach ($extension in @('.vbs','.vbe','.js','.jse','.wsf','.wsh','.msc','.cpl','.py','.pyw')) {
                $name='association-'+$extension.Substring(1)
                $path=Join-Path $directory ($name+$extension)
                'Association-only fixture; must never be invoked.' | Set-Content -LiteralPath $path
                "'waited fallback';exit 0" | Set-Content (Join-Path $fallback ($name+'.ps1'))
                Assert (@(Get-Command $name -All -CommandType Application,ExternalScript).Source -contains $path) "Fixture $extension was not discoverable."
                Assert ((Find-ReleaseDoctorTool $name) -eq (Join-Path $fallback ($name+'.ps1'))) "Lookup accepted $extension."
                Assert (-not (Find-ReleaseDoctorTool $path)) "An explicit $extension path was accepted."
                Expect-Error {Invoke-ReleaseTool $path @() $sandbox} 'executable missing or not runnable'
                $result=Invoke-ReleaseTool $name @() $sandbox
                Assert ($result.exitCode -eq 0 -and $result.text -eq 'waited fallback') "The fallback for $extension did not run synchronously."
            }
            foreach ($extension in @('.bat','.cmd')) {
                $path=Join-Path $fallback ('waited'+$extension)
                "@echo off`r`necho waited batch`r`nexit /b 7" | Set-Content -LiteralPath $path
                $result=Invoke-ReleaseTool $path @() $sandbox
                Assert ($result.exitCode -eq 7 -and $result.text -eq 'waited batch') "$extension did not return its output and exit code."
            }
        } finally {$env:PATH=$priorPath;$env:PATHEXT=$priorExtensions}
    }
}
Test 'release CLI binds relative executable paths to the caller across doctor prepare and publish' {
    $fixture=New-DoctorFixture 'relative-cli-tools'
    $caller=Join-Path $sandbox 'relative-cli-caller'
    $tools=Join-Path $caller 'tool kit'
    New-Item -ItemType Directory $tools | Out-Null
    $engineText=[IO.File]::ReadAllText($engine).Replace('$index =', 'if ($Rest -contains ''--version'') {''4.7.1.stable.fixture'';exit 0}'+"`n"+'$index =')
    $engineText | Set-Content -LiteralPath (Join-Path $tools 'godot.ps1')
    Copy-Item $butler (Join-Path $tools 'butler.ps1')
    Copy-Item $steam (Join-Path $tools 'steamcmd.ps1')
    Copy-Item $gh (Join-Path $tools 'gh.ps1')
    $cli=Join-Path $root 'skills/ba-release/scripts/release.ps1'
    $executables=@{ButlerExecutable='tool kit/butler.ps1';SteamCmdExecutable='tool kit/steamcmd.ps1';GhExecutable='tool kit/gh.ps1'}
    $priorSteam=$env:BA_STEAM_USERNAME;$priorStore=$env:BA_FIXTURE_NOTE_STORE
    $env:BA_STEAM_USERNAME='fixture';$env:BA_FIXTURE_NOTE_STORE=Join-Path $sandbox 'relative-cli-remote-note.md'
    Push-Location $caller
    try {
        $json=& pwsh -NoProfile -File $cli -Mode doctor -Repository $fixture.repo -Destination 'itch-windows,steam,notes' -GodotExecutable 'tool kit/godot.ps1' -TemplateRoot $fixture.templates @executables
        Assert ($LASTEXITCODE -eq 0) "Doctor failed with caller-relative tools: $json"
        $doctor=($json -join "`n") | ConvertFrom-Json -AsHashtable
        foreach ($tool in @('butler','steamcmd','gh')) {
            $check=@($doctor.checks | Where-Object {$_.id -eq $tool})[0]
            Assert ($check.status -eq 'passed' -and $check.message -eq "Executable found: $(Join-Path $tools ($tool+'.ps1'))") "Doctor resolved $tool from the wrong directory."
        }
        $json=& pwsh -NoProfile -File $cli -Mode prepare -Repository $fixture.repo -Destination 'itch-windows,steam,notes' -StateRoot (Join-Path $sandbox 'relative-cli-state') -GodotExecutable 'tool kit/godot.ps1' -ButlerExecutable $executables.ButlerExecutable
        Assert ($LASTEXITCODE -eq 0) "Preparation failed with caller-relative tools: $json"
        $prepared=($json -join "`n") | ConvertFrom-Json -AsHashtable
        $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        $json=& pwsh -NoProfile -File $cli -Mode publish -StatePath $prepared.statePath -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan) @executables
        Assert ($LASTEXITCODE -eq 3) "Publish failed before recording store progress: $json"
        $published=($json -join "`n") | ConvertFrom-Json -AsHashtable
        Assert ($published.destinations['itch-windows'].status -eq 'succeeded' -and $published.destinations.steam.status -eq 'awaiting-store-action' -and $published.destinations.notes.status -eq 'succeeded') "Publish did not use the caller-relative tools: $json"
    } finally {
        Pop-Location
        $env:BA_STEAM_USERNAME=$priorSteam;$env:BA_FIXTURE_NOTE_STORE=$priorStore
    }
}
if ($IsWindows) {
    Test 'release CLI reports a missing-drive executable as blocked without rejecting other modes' {
        $repo=New-Fixture 'missing-drive-cli'
        $drive=@(90..68 | ForEach-Object {[string][char]$_} | Where-Object {-not (Get-PSDrive -Name $_ -ErrorAction SilentlyContinue)})[0]
        Assert ($null -ne $drive) 'Fixture requires an unused drive letter.'
        $missing=$drive+':\private-runtime-path\missing.exe'
        $cli=Join-Path $root 'skills/ba-release/scripts/release.ps1'
        $executables=@{GodotExecutable=$missing;ButlerExecutable=$missing;SteamCmdExecutable=$missing;GhExecutable=$missing}
        $json=& pwsh -NoProfile -File $cli -Mode doctor -Repository $repo -Destination notes @executables
        Assert ($LASTEXITCODE -eq 2) "Missing drive aborted doctor instead of blocking one tool: $json"
        $report=($json -join "`n") | ConvertFrom-Json -AsHashtable
        Assert (-not $report.ready -and @($report.checks | Where-Object {$_.id -eq 'gh' -and $_.status -eq 'blocked'}).Count -eq 1) 'Missing-drive GitHub CLI was not blocked.'
        Assert (@($report.checks | Where-Object {$_.id -eq 'godot' -and $_.status -eq 'skipped'}).Count -eq 1) 'Unselected missing-drive tool affected the doctor report.'
        $json=& pwsh -NoProfile -File $cli -Mode doctor -Repository $repo -Destination itch-windows @executables
        Assert ($LASTEXITCODE -eq 2) "Missing-drive engine aborted doctor: $json"
        $report=($json -join "`n") | ConvertFrom-Json -AsHashtable
        Assert (@($report.checks | Where-Object {$_.id -eq 'godot' -and $_.status -eq 'blocked'}).Count -eq 1) 'Missing-drive engine was not blocked.'
        $json=& pwsh -NoProfile -File $cli -Mode plan -Repository $repo -Destination notes @executables
        Assert ($LASTEXITCODE -eq 0) "An unused missing-drive override blocked read-only planning: $json"
    }
}
Test 'Steam and Butler failures retain safe reasons without persisting private tool output' {
    $repo=New-StoreFixture 'store-safe-diagnostics'
    $prepared=Invoke-ReleasePrepare $repo @('itch-windows','steam') (Join-Path $sandbox 'store-safe-diagnostics-state') $engine
    $stateFile=Join-Path $prepared.statePath 'state.json'
    $state=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    $missing=Join-Path $sandbox 'private-runtime-path/missing-tool'
    $priorSteam=$env:BA_STEAM_USERNAME
    try {
        $env:BA_STEAM_USERNAME=$null
        $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $missing -SteamCmdExecutable $missing -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan)
        Assert ($result.destinations.steam.error -like '*Set BA_STEAM_USERNAME*') 'Steam failure hid the missing authentication input.'
        $env:BA_STEAM_USERNAME='private_fixture_account'
        $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $missing -SteamCmdExecutable $missing
        Assert ($result.destinations['itch-windows'].error -like '*Butler executable is unavailable before upload.*') 'Butler failure hid the missing executable.'
        Assert ($result.destinations.steam.error -like '*SteamCMD executable is unavailable before upload.*') 'Steam failure hid the missing executable.'
        Assert (-not $result.destinations['itch-windows'].remote.Contains('phase') -and -not $result.destinations.steam.remote.Contains('phase')) 'Missing tools claimed an upload had started.'
        $failedButler=Join-Path $sandbox 'private-butler.ps1'
        $failedSteam=Join-Path $sandbox 'private-steam.ps1'
        "'password=private-tool-output';[Console]::Error.WriteLine('Bearer private-tool-stderr');exit 23" | Set-Content $failedButler
        "'password=private-tool-output';[Console]::Error.WriteLine('Bearer private-tool-stderr');exit 24" | Set-Content $failedSteam
        $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $failedButler -SteamCmdExecutable $failedSteam
        Assert ($result.destinations['itch-windows'].status -eq 'failed' -and $result.destinations['itch-windows'].error -like '*Butler upload failed (exit 23).*') 'Butler failure lost its exit code.'
        Assert ($result.destinations.steam.status -eq 'failed' -and $result.destinations.steam.error -like '*SteamCMD upload failed (exit 24); no verifiable build-completion record.*') 'Steam failure lost its exit code or completion check.'
        $json=($result | ConvertTo-Json -Depth 30)+(Get-Content $stateFile -Raw)
        Assert ($json -notmatch 'private-tool-output|private-tool-stderr|private-runtime-path|private_fixture_account') 'Store failure exposed private output, a runtime path or an account.'
    } finally {$env:BA_STEAM_USERNAME=$priorSteam}
}
if ($IsWindows -and (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    Test 'Windows state paths remain readable from WSL through Store app redirection' {
        $folder=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('ba-release-path-test-'+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        try {
            $physical=& (Get-Module Release) {param($path) Get-ReleaseStateRoot $path} $folder
            $marker=Join-Path $physical 'marker.txt'
            [IO.File]::WriteAllText($marker,'shared release state')
            $linux=(& wsl.exe --exec wslpath -a -u $marker) -join ''
            Assert ($LASTEXITCODE -eq 0) 'WSL could not translate the state path.'
            $content=(& wsl.exe --exec cat $linux 2>&1) -join ''
            Assert ($LASTEXITCODE -eq 0 -and $content -ceq 'shared release state') 'State path is visible only inside the Windows Store app.'
        } finally {
            Remove-Item -LiteralPath (Join-Path $folder 'marker.txt') -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $folder
        }
    }
}
Test 'Gradle exports disable persistent daemons without changing other exports or caller options' {
    $repo=New-StoreFixture 'gradle-process-environment'
    Add-FixtureApk $repo
    Change-Config $repo {param($config) $config.androidVersionCodePolicy='existing'}
    Invoke-FixtureGit $repo @('add','release.json') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Use existing counters for runtime fixture') | Out-Null
    $exportLog=Join-Path $sandbox 'export-environment.jsonl'
    $runtimeEngine=Join-Path $sandbox 'environment-engine.ps1'
    @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
$index=[Array]::IndexOf($Rest,'--export-release')
@{preset=$Rest[$index+1];options=$env:GRADLE_OPTS} | ConvertTo-Json -Compress | Add-Content $env:BA_FIXTURE_ENVIRONMENT_LOG
'exported game' | Set-Content -LiteralPath $Rest[$index+2]
exit 0
'@ | Set-Content -LiteralPath $runtimeEngine
    $priorOptions=$env:GRADLE_OPTS;$priorLog=$env:BA_FIXTURE_ENVIRONMENT_LOG
    try {
        $env:GRADLE_OPTS='-Dfixture.retained=true -Dorg.gradle.daemon=true';$env:BA_FIXTURE_ENVIRONMENT_LOG=$exportLog
        $prepared=Invoke-ReleasePrepare $repo @('steam','google-play','itch-android') (Join-Path $sandbox 'runtime-state') $runtimeEngine -ButlerExecutable $butler
        Assert ($prepared.status -eq 'prepared') 'Runtime fixture did not prepare.'
        $records=@(Get-Content -LiteralPath $exportLog | ForEach-Object {$_ | ConvertFrom-Json})
        foreach ($record in $records) {
            $expected='-Dfixture.retained=true -Dorg.gradle.daemon=true'
            if ($record.preset -ceq 'Android existing AAB') {$expected+=' -Dorg.gradle.daemon=false'}
            Assert ($record.options -ceq $expected) "Wrong process options for $($record.preset)."
        }
        Assert ($records.Count -eq 4 -and $env:GRADLE_OPTS -ceq '-Dfixture.retained=true -Dorg.gradle.daemon=true') 'Export selection or caller options changed.'
    } finally {$env:GRADLE_OPTS=$priorOptions;$env:BA_FIXTURE_ENVIRONMENT_LOG=$priorLog}
}
Test 'itch Android dry-run and publication select the signed APK without its optional signature sidecar' {
    $repo=New-StoreFixture 'itch-single-apk'
    Add-FixtureApk $repo
    Change-Config $repo {param($config) $config.androidVersionCodePolicy='existing'}
    Invoke-FixtureGit $repo @('add','release.json') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Use existing counters for APK selection fixture') | Out-Null
    $apkEngine=Join-Path $sandbox 'apk-engine.ps1'
    @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
$index=[Array]::IndexOf($Rest,'--export-release');$output=$Rest[$index+2]
'signed APK fixture' | Set-Content -LiteralPath $output
'optional signature fixture' | Set-Content -LiteralPath ($output+'.idsig')
'@ | Set-Content -LiteralPath $apkEngine
    $apkButler=Join-Path $sandbox 'apk-butler.ps1'
    @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
if (-not (Test-Path -LiteralPath $Rest[1] -PathType Leaf) -or -not $Rest[1].EndsWith('.apk')) {exit 8}
if ($Rest -contains '--dry-run') {[IO.Path]::GetFileName($Rest[1])}
exit 0
'@ | Set-Content -LiteralPath $apkButler
    $prepared=Invoke-ReleasePrepare $repo @('itch-android') (Join-Path $sandbox 'apk-file-state') $apkEngine -ButlerExecutable $apkButler
    Assert ($prepared.status -eq 'prepared') 'APK dry-run received a directory instead of the signed APK.'
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($state.artifacts[0].files.Count -eq 2 -and $state.checks['itch-android'].included.Count -eq 1 -and $state.checks['itch-android'].included[0] -ceq 'Game.apk') 'APK selection changed sealed artifacts or included the sidecar.'
    $published=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $apkButler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan)
    Assert ($published.status -eq 'needs-store-action' -and $published.destinations['itch-android'].status -eq 'awaiting-store-action') 'Approved APK publication did not use the same input as its dry-run.'
}

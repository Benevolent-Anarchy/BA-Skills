# Specifies read-only, destination-scoped runtime readiness without real service requests.
function New-DoctorFixture([string]$Name) {
    $repo=New-StoreFixture $Name
    $tool=Join-Path $sandbox ($Name+'-godot.ps1')
    @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
if ($Rest.Count -ne 1 -or $Rest[0] -ne '--version') {exit 91}
'4.7.1.stable.fixture'
'@ | Set-Content $tool
    $templates=Join-Path $sandbox ($Name+'-templates/4.7.1.stable')
    New-Item -ItemType Directory $templates -Force | Out-Null
    foreach ($file in @('windows_release_x86_64.exe','linux_release.x86_64','android_release.apk','android_source.zip')) {'template' | Set-Content (Join-Path $templates $file)}
    Add-Content (Join-Path $repo 'project.godot') 'config/features=PackedStringArray("4.7", "GL Compatibility")'
    Invoke-FixtureGit $repo @('add','project.godot') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Record engine requirement') | Out-Null
    return @{repo=$repo;tool=$tool;templates=(Split-Path $templates -Parent)}
}

Test 'doctor scopes prerequisites to selected stores and never exposes runtime secrets' {
    $fixture=New-DoctorFixture 'doctor-scoped'
    $priorSteam=$env:BA_STEAM_USERNAME;$priorPlay=$env:BA_GOOGLE_PLAY_ACCESS_TOKEN
    try {
        $env:BA_STEAM_USERNAME='private_fixture_account';$env:BA_GOOGLE_PLAY_ACCESS_TOKEN='private_fixture_token'
        $report=Get-ReleaseDoctor -Repository $fixture.repo -Destination @('steam') -GodotExecutable $fixture.tool -TemplateRoot $fixture.templates -SteamCmdExecutable $steam -ButlerExecutable 'missing-butler-fixture' -GhExecutable 'missing-gh-fixture'
        Assert $report.ready 'Selected Steam local prerequisites should be ready.'
        Assert (@($report.checks | Where-Object {$_.id -eq 'butler' -and $_.status -eq 'skipped'}).Count -eq 1) 'Held itch requested Butler.'
        Assert (@($report.checks | Where-Object {$_.id -eq 'play-auth' -and $_.status -eq 'skipped'}).Count -eq 1) 'Held Play requested Google credentials.'
        $json=$report | ConvertTo-Json -Depth 20
        Assert ($json -notmatch 'private_fixture') 'Doctor exposed an account or token.'
        Assert (-not $report.remoteAccessVerified) 'Presence checks claimed remote authentication.'
    } finally {$env:BA_STEAM_USERNAME=$priorSteam;$env:BA_GOOGLE_PLAY_ACCESS_TOKEN=$priorPlay}
}
Test 'doctor reports missing tools and exact engine templates without changing source or index' {
    $fixture=New-DoctorFixture 'doctor-missing'
    $before=@(Get-ChildItem $fixture.repo -Recurse -File -Force | ForEach-Object {"$($_.FullName):$((Get-FileHash $_.FullName).Hash)"}) -join "`n"
    Remove-Item -LiteralPath (Join-Path $fixture.templates '4.7.1.stable/linux_release.x86_64')
    $report=Get-ReleaseDoctor -Repository $fixture.repo -Destination @('itch-linux') -GodotExecutable $fixture.tool -TemplateRoot $fixture.templates -ButlerExecutable 'missing-butler-fixture'
    Assert (-not $report.ready) 'Missing Butler/template was accepted.'
    Assert (@($report.checks | Where-Object {$_.id -eq 'butler' -and $_.status -eq 'blocked'}).Count -eq 1) 'Missing Butler was not actionable.'
    Assert (@($report.checks | Where-Object {$_.id -eq 'template:Linux existing' -and $_.status -eq 'blocked'}).Count -eq 1) 'Exact selected template was not checked.'
    $after=@(Get-ChildItem $fixture.repo -Recurse -File -Force | ForEach-Object {"$($_.FullName):$((Get-FileHash $_.FullName).Hash)"}) -join "`n"
    Assert ($before -ceq $after) 'Doctor changed source or Git data.'
}
Test 'doctor skips exports for notes-only selection and rejects mismatched engine versions' {
    $fixture=New-DoctorFixture 'doctor-engine'
    $notes=Get-ReleaseDoctor -Repository $fixture.repo -Destination @('notes') -GodotExecutable 'missing-godot-fixture' -GhExecutable $gh
    Assert $notes.ready 'Notes-only release required export tools.'
    '"4.8.stable.fixture"' | Set-Content $fixture.tool
    $report=Get-ReleaseDoctor -Repository $fixture.repo -Destination @('itch-windows') -GodotExecutable $fixture.tool -TemplateRoot $fixture.templates -ButlerExecutable $butler
    Assert (@($report.checks | Where-Object {$_.id -eq 'godot-version' -and $_.status -eq 'blocked'}).Count -eq 1) 'Wrong engine minor version was accepted.'
}
Test 'doctor checks Android signing presence without serializing credentials' {
    $fixture=New-DoctorFixture 'doctor-android'
    $prior=@{}
    foreach ($key in @('GODOT_ANDROID_KEYSTORE_RELEASE_PATH','GODOT_ANDROID_KEYSTORE_RELEASE_USER','GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD')) {$prior[$key]=[Environment]::GetEnvironmentVariable($key)}
    try {
        $keyfile=Join-Path $sandbox 'doctor-private.keystore';'key fixture' | Set-Content $keyfile
        $env:GODOT_ANDROID_KEYSTORE_RELEASE_PATH=$keyfile;$env:GODOT_ANDROID_KEYSTORE_RELEASE_USER='private_fixture_alias';$env:GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD='private_fixture_password'
        Change-Config $fixture.repo {param($c) $c.distributions['google-play'].retainVersionCodes=@()}
        $report=Get-ReleaseDoctor -Repository $fixture.repo -Destination @('google-play') -GodotExecutable $fixture.tool -TemplateRoot $fixture.templates -AndroidSdkPath (Join-Path $sandbox 'missing-sdk') -JavaSdkPath (Join-Path $sandbox 'missing-jdk')
        Assert (@($report.checks | Where-Object {$_.id -eq 'signing:Android existing AAB' -and $_.status -eq 'passed'}).Count -eq 1) 'Runtime release signing was not recognized.'
        Assert (($report | ConvertTo-Json -Depth 20) -notmatch 'private_fixture|doctor-private') 'Doctor leaked signing material.'
        Assert (@($report.checks | Where-Object {$_.id -eq 'android-sdk' -and $_.status -eq 'blocked'}).Count -eq 1) 'Missing SDK was not reported.'
    } finally {foreach ($key in $prior.Keys) {[Environment]::SetEnvironmentVariable($key,$prior[$key])}}
}
Test 'doctor version probes have a bounded timeout' {
    $fixture=New-DoctorFixture 'doctor-timeout'
    'Start-Sleep -Seconds 30' | Set-Content $fixture.tool
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $report=Get-ReleaseDoctor -Repository $fixture.repo -Destination @('itch-windows') -GodotExecutable $fixture.tool -TemplateRoot $fixture.templates -ButlerExecutable $butler -ProbeTimeoutSeconds 1
    Assert ($watch.Elapsed.TotalSeconds -lt 10 -and @($report.checks | Where-Object {$_.id -eq 'godot-version' -and $_.status -eq 'blocked'}).Count -eq 1) 'Hung version probe was not bounded.'
}
if ($IsWindows) {
    Test 'doctor Godot discovery skips extensionless shims for explicit and default engine names' {
        $fixture=New-DoctorFixture 'doctor-engine-shims'
        $shims=Join-Path $sandbox 'godot-shims';$tools=Join-Path $sandbox 'godot-tools'
        New-Item -ItemType Directory $shims,$tools | Out-Null
        foreach ($name in @('godot_console','godot4_console','godot','godot4')) {
            '#!/bin/sh' | Set-Content (Join-Path $shims $name)
            Copy-Item $fixture.tool (Join-Path $tools ($name+'.ps1'))
        }
        $priorPath=$env:PATH
        $env:PATH=$shims+';'+$tools+';'+$priorPath
        try {
            foreach ($name in @('godot_console','godot4_console','godot','godot4')) {
                $found=& (Get-Module Release) {param($name) Get-ReleaseEngine $name} $name
                Assert ($found -eq (Join-Path $tools ($name+'.ps1'))) "Engine lookup accepted the $name shim."
            }
            $default=& (Get-Module Release) {Get-ReleaseEngine}
            Assert ($default -eq (Join-Path $tools 'godot_console.ps1')) 'Default engine lookup changed preference or accepted a shim.'
            foreach ($name in @('godot',$null)) {
                $report=Get-ReleaseDoctor -Repository $fixture.repo -Destination @('itch-windows') -GodotExecutable $name -TemplateRoot $fixture.templates -ButlerExecutable $butler
                Assert $report.ready 'Doctor could not probe the runnable Godot candidate.'
                Assert (@($report.checks | Where-Object {$_.id -eq 'godot-version' -and $_.status -eq 'passed'}).Count -eq 1) 'Doctor did not verify the resolved engine.'
            }
            Expect-Error {& (Get-Module Release) {param($path) Get-ReleaseEngine $path} (Join-Path $shims 'godot')} 'Requested Godot executable was not found'
        } finally {$env:PATH=$priorPath}
    }
}
Test 'doctor keeps its complete blocked report when the engine process cannot start' {
    $fixture=New-DoctorFixture 'doctor-engine-start-failure'
    $invalid=Join-Path $sandbox 'invalid-engine.exe'
    'not an executable image' | Set-Content -LiteralPath $invalid
    $cli=Join-Path $root 'skills/ba-release/scripts/release.ps1'
    $json=& pwsh -NoProfile -File $cli -Mode doctor -Repository $fixture.repo -Destination itch-windows -GodotExecutable $invalid -ButlerExecutable $butler -TemplateRoot $fixture.templates
    Assert ($LASTEXITCODE -eq 2) "Doctor aborted instead of reporting a blocked probe: $json"
    $report=($json -join "`n") | ConvertFrom-Json -AsHashtable
    Assert (-not $report.ready -and -not $report.Contains('error')) 'Doctor returned only a top-level exception.'
    Assert (@($report.checks | Where-Object {$_.id -eq 'godot-version' -and $_.status -eq 'blocked' -and $_.message -like '*could not start*'}).Count -eq 1) 'Probe launch failure was not explained.'
    Assert (@($report.checks | Where-Object {$_.id -eq 'butler' -and $_.status -eq 'passed'}).Count -eq 1 -and @($report.checks | Where-Object {$_.id -eq 'template:Windows existing'}).Count -eq 1) 'Engine probe failure discarded the other checks.'
}
Test 'doctor respects Gradle APKs and their configured build directory' {
    $fixture=New-DoctorFixture 'doctor-gradle-apk'
    Add-FixtureApk $fixture.repo
    $presets=Join-Path $fixture.repo 'export_presets.cfg'
    [IO.File]::WriteAllText($presets,([IO.File]::ReadAllText($presets).Replace('gradle_build/use_gradle_build=false','gradle_build/use_gradle_build=true')+"`ngradle_build/gradle_build_directory=`"res://android/custom_build`"`n"))
    $build=Join-Path $fixture.repo 'android/custom_build/build';New-Item -ItemType Directory $build -Force | Out-Null
    'Gradle project fixture' | Set-Content (Join-Path $build 'build.gradle')
    Remove-Item -LiteralPath (Join-Path $fixture.templates '4.7.1.stable/android_release.apk')
    $report=Get-ReleaseDoctor -Repository $fixture.repo -Destination @('itch-android') -GodotExecutable $fixture.tool -TemplateRoot $fixture.templates -ButlerExecutable $butler
    Assert (@($report.checks | Where-Object {$_.id -eq 'template:Android existing APK' -and $_.status -eq 'passed'}).Count -eq 1) 'Gradle APK incorrectly required the standard APK template.'
    Assert (@($report.checks | Where-Object {$_.id -eq 'gradle:Android existing APK' -and $_.status -eq 'passed'}).Count -eq 1) 'Configured Gradle APK build directory was ignored.'
    Move-Item -LiteralPath (Join-Path $build 'build.gradle') -Destination (Join-Path (Split-Path $build -Parent) 'build.gradle')
    $missing=Get-ReleaseDoctor -Repository $fixture.repo -Destination @('itch-android') -GodotExecutable $fixture.tool -TemplateRoot $fixture.templates -ButlerExecutable $butler
    Assert (@($missing.checks | Where-Object {$_.id -eq 'gradle:Android existing APK' -and $_.status -eq 'blocked'}).Count -eq 1) 'A Gradle file outside Godot''s build subdirectory was accepted.'
}

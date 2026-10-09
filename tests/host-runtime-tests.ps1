# Exercises the actual Windows/WSL path boundary and export-process environment.
Test 'process environment overrides remove originally absent variables after tool success or failure' {
    Import-Module (Join-Path $root 'skills/ba-release/scripts/ProcessTools.psm1') -Force
    $key='BA_RELEASE_ABSENT_ENVIRONMENT_TEST'
    Remove-Item -LiteralPath ('Env:'+$key) -ErrorAction SilentlyContinue
    $probe=Join-Path $sandbox 'environment-probe.ps1'
    "if (`$env:BA_RELEASE_ABSENT_ENVIRONMENT_TEST -cne 'temporary') {exit 9}; exit 0" | Set-Content -LiteralPath $probe
    $result=Invoke-ReleaseTool $probe @() $sandbox -Environment @{$key='temporary'}
    Assert ($result.exitCode -eq 0 -and -not (Test-Path -LiteralPath ('Env:'+$key))) 'Successful tool left an originally absent variable behind.'
    Expect-Error {Invoke-ReleaseTool (Join-Path $sandbox 'missing-executable') @() $sandbox -Environment @{$key='temporary'}} 'not recognized|cannot find|not found'
    Assert (-not (Test-Path -LiteralPath ('Env:'+$key))) 'Failed tool left an originally absent variable behind.'
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

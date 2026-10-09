. "$PSScriptRoot/PresetFixture.ps1"
Import-Module "$assetRoot/tools/Verification.psm1" -Force
if (Test-Path "$skillRoot/scripts/TauriPreset.psm1") {Import-Module "$skillRoot/scripts/TauriPreset.psm1" -Force}
if (Test-Path "$skillRoot/assets/presets/tauri/tools/TauriVerification.psm1") {Import-Module "$skillRoot/assets/presets/tauri/tools/TauriVerification.psm1" -Force}
Import-Module "$skillRoot/scripts/Presets.psm1" -Force
Import-Module "$skillRoot/scripts/Project.psm1" -Force
function New-TauriPreparationFixture {
    $f=New-TauriProcessFixture
    $f.root=New-BootstrapFixture 'Tauri starter path with spaces'
    $f.identity=New-BootstrapIdentity -Name 'Starter' -Description 'Purpose' -Parent $sandbox
    $f.identity.projectPath=$f.root
    $f.selection=Resolve-BootstrapPreset $f.identity -Preset tauri
    $f.resolution=@{preset='tauri';selections=@{tauri='3.0.0';generator='4.0.0'};artifacts=@(@{name='generator';version='4.0.0';uri='https://example.invalid/generator.tgz';proof='published-integrity';integrity=('sha512-'+[Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData([byte[]]@(1,2,3))))})}
    $f.download={param($uri,$path) [IO.File]::WriteAllBytes($path,[byte[]]@(1,2,3))}
    Write-ProjectFoundation $f.identity | Out-Null
    return $f
}
Test 'Tauri selected-release check inspects the application direct dependency' {
    $f=New-TauriProcessFixture;$resolution=@{selections=@{tauri='3.0.0'}}
    Assert-TauriSelectedRelease $resolution (& $f.metadata)
    $f.version='2.99.0';$metadata=& $f.metadata
    $metadata.packages+=@{id='unrelated3';name='tauri';version='3.0.0'}
    Expect-Error {Assert-TauriSelectedRelease $resolution $metadata} 'selected|release|major'
}
Test 'Tauri preparation retains official source locks binary icons and effective ignores' {
    $f=New-TauriPreparationFixture
    $result=Initialize-TauriPreset $f.identity $f.selection $f.resolution $f.root $f.process $f.download
    $generator=@($f.calls | Where-Object {$_.arguments -contains 'create-tauri-app' -and $_.arguments -contains '.'})
    Assert ($generator.Count -eq 1 -and 'vanilla-ts' -in $generator[0].arguments -and '3' -in $generator[0].arguments) 'Moving or incorrect generator recipe.'
    foreach ($path in @('package-lock.json','src-tauri/Cargo.lock','src-tauri/icons/icon.ico','src-tauri/capabilities/default.json','src/main.test.ts','src/vite-env.d.ts')) {Assert ($path -in $result.trackedPaths) "Source missing: $path"}
    Assert (@($result.trackedPaths | Where-Object {$_ -match '(^|/)(node_modules|target|dist)/'}).Count -eq 0) 'Generated output included.'
    Assert ([IO.File]::ReadAllBytes("$($f.root)/src-tauri/icons/icon.ico")[1] -eq 255) 'Binary icon corrupted.'
    Assert ([IO.File]::ReadAllText("$($f.root)/src/main.ts").Contains('textContent')) 'Title not set safely.'
    Invoke-FixtureGit $f.root @('init','-b','main') | Out-Null
    foreach ($path in @('node_modules/module.js','src-tauri/target/cache','src-tauri/gen/schemas/test.json','dist/export','nested/dist/export','.env.local','coverage/index.html')) {Write-FixtureText "$($f.root)/$path" 'output';Invoke-FixtureGit $f.root @('check-ignore','--no-index','--',$path) | Out-Null}
    foreach ($path in @('.env.example','src-tauri/icons/icon.ico','src-tauri/Cargo.lock','src-tauri/capabilities/default.json','src/main.ts')) {Write-FixtureText "$($f.root)/$path" 'source';Invoke-FixtureGit $f.root @('add','--',$path) | Out-Null}
}
Test 'Tauri preparation blocks changed layouts and missing or failed dependencies' {
    foreach ($mode in @('layout','locks','install')) {
        $f=New-TauriPreparationFixture;$f.mode=$mode
        Expect-Error {Initialize-TauriPreset $f.identity $f.selection $f.resolution $f.root $f.process $f.download} 'layout|missing|lock|install|failed'
    }
}
Test 'Tauri preparation resumes retained generator and lock checkpoints' {
    foreach ($boundary in @('generator','locks')) {
        $f=New-TauriPreparationFixture;$checkpoints=@{}
        $interrupt={param($phase,$value) if ($phase -ceq $boundary) {throw 'fixture interruption'}}.GetNewClosure()
        Expect-Error {Initialize-TauriPreset $f.identity $f.selection $f.resolution $f.root $f.process $f.download -Checkpoints $checkpoints -Checkpoint $interrupt} 'interruption'
        Initialize-TauriPreset $f.identity $f.selection $f.resolution $f.root $f.process $f.download -Checkpoints $checkpoints | Out-Null
        Assert (@($f.calls | Where-Object {$_.arguments -contains 'create-tauri-app' -and $_.arguments -contains '.'}).Count -eq 1) 'Generator reran after durable output.'
        Assert (@($f.calls | Where-Object {$_.arguments -contains 'generate-lockfile'}).Count -eq 1) 'Cargo re-resolved completed locks.'
        Assert (@($f.calls | Where-Object {$_.arguments -contains '--package-lock-only'}).Count -eq 1) 'npm re-resolved completed locks.'
    }
    $f=New-TauriPreparationFixture;$checkpoints=@{}
    $interrupt={param($phase,$value) if ($phase -ceq 'locks-started') {throw 'fixture interruption'}}
    Expect-Error {Initialize-TauriPreset $f.identity $f.selection $f.resolution $f.root $f.process $f.download -Checkpoints $checkpoints -Checkpoint $interrupt} 'interruption'
    Expect-Error {Initialize-TauriPreset $f.identity $f.selection $f.resolution $f.root $f.process $f.download -Checkpoints $checkpoints} 'unresolved|lock receipt'
    Assert (@($f.calls | Where-Object {$_.arguments -contains '--package-lock-only'}).Count -eq 0) 'Unresolved interruption silently selected fresh dependencies.'
}
Test 'Tauri gate fails each required stage and incomplete frontend reports' {
    $f=New-TauriPreparationFixture
    Initialize-TauriPreset $f.identity $f.selection $f.resolution $f.root $f.process $f.download | Out-Null
    $config=Read-ProjectVerificationConfig $f.root
    foreach ($stage in @('typescript','frontend-tests','frontend-build','rust-format','rust-lint','rust-tests','tauri-build','report')) {
        $f.mode=$stage
        $r=Invoke-TauriVerification $f.root $config $f.process
        Assert (-not $r.Passed -and $r.Diagnostics.Count -gt 0) "Gate accepted failed $stage."
    }
    $f.mode='pass';$r=Invoke-TauriVerification $f.root $config $f.process
    Assert ($r.Passed -and $r.Stages.Count -eq 7 -and $r.BinaryPath.EndsWith('starter.exe')) 'Complete native gate did not report binary.'
    Write-FixtureText "$($f.root)/package-lock.json" '{"lockfileVersion":3,"packages":{}}'
    Assert (-not (Invoke-TauriVerification $f.root $config $f.process).Passed) 'Stale lock accepted.'
}

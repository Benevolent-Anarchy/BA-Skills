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
Test 'Tauri preparation records stable frontend ranges and matching locks' {
    $f=New-TauriPreparationFixture
    $result=Initialize-TauriPreset $f.identity $f.selection $f.resolution $f.root $f.process $f.download
    $package=[IO.File]::ReadAllText("$($f.root)/package.json") | ConvertFrom-Json -AsHashtable
    Assert ($package.devDependencies.vitest -ceq '^4.2.0' -and $package.devDependencies.jsdom -ceq '^29.0.0') 'Resolved frontend test versions were not retained as tested ranges.'
    foreach ($kind in @('dependencies','devDependencies')) {
        foreach ($spec in $package[$kind].Values) {Assert ($spec -notmatch '^[A-Za-z][A-Za-z0-9-]*$') "Committed dependency uses a moving dist-tag: $spec"}
    }
    Assert-TauriNpmLock $f.root
    Assert (@($result.checkpoints.locks.manifest | Where-Object path -CEQ 'package.json').Count -eq 1) 'Manifest mutations are missing from the completed lock receipt.'
}
Test 'Tauri preparation rejects unproved frontend versions and safely retries a definite lock failure' {
    foreach ($version in @('next','4.3.0-beta.1','')) {
        $f=New-TauriPreparationFixture;$f.testVersions.vitest=$version;$checkpoints=@{}
        Expect-Error {Initialize-TauriPreset $f.identity $f.selection $f.resolution $f.root $f.process $f.download -Checkpoints $checkpoints} 'vitest|stable|version'
        Assert (-not $checkpoints.ContainsKey('locks-started') -and -not $checkpoints.ContainsKey('locks') -and $checkpoints.ContainsKey('locks-failed')) 'Definite failure retained an unresolved lock marker.'
        Assert (-not (Test-Path "$($f.root)/package-lock.json") -and -not (Test-Path "$($f.root)/src-tauri/Cargo.lock")) 'Definite failure retained unproved locks.'
        $f.testVersions.vitest='4.2.0'
        Initialize-TauriPreset $f.identity $f.selection $f.resolution $f.root $f.process $f.download -Checkpoints $checkpoints | Out-Null
        Assert (@($f.calls | Where-Object {$_.arguments -contains 'create-tauri-app' -and $_.arguments -contains '.'}).Count -eq 1) 'Definite lock failure reran the completed generator.'
    }
}
Test 'Tauri definite synchronization failure restores the overlay before retry' {
    $f=New-TauriPreparationFixture;$checkpoints=@{};$inner=$f.process
    $failure=@{locks=0;pending=$true}
    $process={param($exe,$arguments,$cwd,$environment)
        $result=& $inner $exe $arguments $cwd $environment
        if ($arguments -contains '--package-lock-only') {
            $failure.locks++
            if ($failure.pending -and $failure.locks -eq 2) {$failure.pending=$false;return @{ExitCode=1;Output='definite npm synchronization failure';Executable=$exe}}
        }
        return $result
    }.GetNewClosure()
    Expect-Error {Initialize-TauriPreset $f.identity $f.selection $f.resolution $f.root $process $f.download -Checkpoints $checkpoints} 'synchronization'
    $actual=(Get-FileHash "$($f.root)/package.json" -Algorithm SHA256).Hash.ToLowerInvariant()
    $recorded=@($checkpoints.overlay.manifest | Where-Object path -CEQ 'package.json')[0].sha256
    Assert ($actual -ceq $recorded -and -not (Test-Path "$($f.root)/package-lock.json")) 'Failed lock attempt did not restore the retained overlay.'
    Initialize-TauriPreset $f.identity $f.selection $f.resolution $f.root $process $f.download -Checkpoints $checkpoints | Out-Null
    Assert-TauriNpmLock $f.root
    Assert (@($f.calls | Where-Object {$_.arguments -contains 'create-tauri-app' -and $_.arguments -contains '.'}).Count -eq 1) 'Retry discarded completed generator output.'
}
Test 'Tauri initial lock retains the recorded release when a newer release is available' {
    $f=New-TauriPreparationFixture;$f.version='3.0.1';$inner=$f.process
    $process={param($exe,$arguments,$cwd,$environment)
        if ($arguments -contains 'update' -and $arguments -contains '--precise' -and $arguments -contains '-p' -and $arguments -contains 'tauri') {
            $precise=[Array]::IndexOf($arguments,'--precise')
            $f.version=$arguments[$precise+1]
        }
        & $inner $exe $arguments $cwd $environment
    }.GetNewClosure()
    $prepared=Initialize-TauriPreset $f.identity $f.selection $f.resolution $f.root $process $f.download
    Assert (@($prepared.receipts[0].rustPackages | Where-Object {$_.name -ceq 'tauri' -and $_.version -ceq '3.0.0'}).Count -eq 1) 'Preparation selected a newer release than its recorded resolution.'
}
Test 'Tauri generated Rust targets use identity names and escaped package metadata' {
    $f=New-TauriPreparationFixture
    $f.identity=New-BootstrapIdentity -Name 'Foo Bar' -Description "An `"app`" at C:\tools`nSecond line" -Parent $sandbox -Owner cicely-f
    $f.identity.projectPath=$f.root;$f.selection=Resolve-BootstrapPreset $f.identity -Preset tauri
    Initialize-TauriPreset $f.identity $f.selection $f.resolution $f.root $f.process $f.download | Out-Null
    $cargo=Get-TauriTool 'cargo';$rustc=Get-TauriTool 'rustc'
    $metadata=Invoke-VerificationProcess $cargo @('read-manifest','--manifest-path','src-tauri/Cargo.toml') $f.root (Get-TauriProcessEnvironment $f.root)
    Assert ($metadata.ExitCode -eq 0) "Generated Cargo manifest is invalid: $($metadata.Output)"
    $package=$metadata.Output | ConvertFrom-Json -AsHashtable
    Assert ($package.description -ceq $f.identity.description -and $package.authors -contains 'cicely-f') 'Generated package metadata retained placeholders or invalid TOML escaping.'
    $library=@($package.targets | Where-Object {$_.kind -contains 'lib'})
    Assert ($library.Count -eq 1 -and $library[0].name -ceq 'foo_bar_lib') 'Generated library name did not derive from the crate.'
    $tauri=@($package.dependencies | Where-Object name -CEQ tauri)
    Assert ($tauri.Count -eq 1 -and $tauri[0].req -ceq '^3.0.0') 'Cargo manifest does not allow deliberate compatible upgrades.'
    $lib=Join-Path $f.root 'libfoo_bar_lib.rlib';$binary=Join-Path $f.root 'fixture-main.exe'
    $compile=Invoke-VerificationProcess $rustc @('--edition','2021','--crate-name','foo_bar_lib','--crate-type','lib','src-tauri/src/lib.rs','-o',$lib) $f.root (Get-TauriProcessEnvironment $f.root)
    Assert ($compile.ExitCode -eq 0) "Generated library cannot compile: $($compile.Output)"
    $compile=Invoke-VerificationProcess $rustc @('--edition','2021','src-tauri/src/main.rs','--extern',"foo_bar_lib=$lib",'-o',$binary) $f.root (Get-TauriProcessEnvironment $f.root)
    Assert ($compile.ExitCode -eq 0 -and (Test-Path $binary -PathType Leaf)) "Generated main does not call the renamed library: $($compile.Output)"
}
Test 'Tauri project gate accepts deliberate stable upgrades and bootstrap remains exact' {
    $f=New-TauriPreparationFixture
    Initialize-TauriPreset $f.identity $f.selection $f.resolution $f.root $f.process $f.download | Out-Null
    $config=Read-ProjectVerificationConfig $f.root
    foreach ($version in @('3.0.1','3.2.0')) {
        $f.version=$version
        Assert ((Invoke-TauriVerification $f.root $config $f.process).Passed) "Project gate rejected deliberate compatible upgrade: $version"
        $exact=Invoke-TauriVerification $f.root $config $f.process -RequireExactPreparedVersions
        Assert (-not $exact.Passed -and ($exact.Diagnostics -join ' ') -match 'selected|prepared') 'Bootstrap gate accepted an unselected release.'
    }
    foreach ($version in @('2.99.0','4.0.0','3.1.0-beta.1','not-a-version')) {
        $f.version=$version
        $result=Invoke-TauriVerification $f.root $config $f.process
        Assert (-not $result.Passed -and ($result.Diagnostics -join ' ') -match 'upgrade|verify\.json') "Project gate did not reject or explain incompatible version: $version"
    }
}
Test 'Tauri preparation rejects a stable release newer than its recorded selection' {
    $f=New-TauriPreparationFixture;$f.version='3.0.1'
    Expect-Error {Initialize-TauriPreset $f.identity $f.selection $f.resolution $f.root $f.process $f.download} 'selected|prepared|release'
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
        Assert (@($f.calls | Where-Object {$_.arguments -contains '--package-lock-only'}).Count -eq 2) 'npm re-resolved completed locks.'
    }
    $f=New-TauriPreparationFixture;$checkpoints=@{}
    $interrupt={param($phase,$value) if ($phase -ceq 'locks-started') {throw 'fixture interruption'}}
    Expect-Error {Initialize-TauriPreset $f.identity $f.selection $f.resolution $f.root $f.process $f.download -Checkpoints $checkpoints -Checkpoint $interrupt} 'interruption'
    Expect-Error {Initialize-TauriPreset $f.identity $f.selection $f.resolution $f.root $f.process $f.download -Checkpoints $checkpoints} 'unresolved|lock receipt'
    Assert (@($f.calls | Where-Object {$_.arguments -contains '--package-lock-only'}).Count -eq 0) 'Unresolved interruption silently selected fresh dependencies.'
}
Test 'Tauri marker-only generator interruption preserves unknown execution state' {
    $f=New-TauriPreparationFixture;$checkpoints=@{}
    $interrupt={param($phase,$value) if ($phase -ceq 'generator-started') {throw 'fixture interruption before generator directory'}}
    Expect-Error {Initialize-TauriPreset $f.identity $f.selection $f.resolution $f.root $f.process $f.download -Checkpoints $checkpoints -Checkpoint $interrupt} 'interruption'
    Assert (-not (Test-Path ($f.root+'.generator'))) 'Fixture did not interrupt before creating generator output.'
    Expect-Error {Initialize-TauriPreset $f.identity $f.selection $f.resolution $f.root $f.process $f.download -Checkpoints $checkpoints} 'completion receipt|unresolved|unknown'
    Assert (@($f.calls | Where-Object {$_.arguments -contains 'create-tauri-app'}).Count -eq 0) 'Marker-only interruption silently reran the generator.'
}
Test 'Tauri legacy completed lock receipt keeps package overlay validation' {
    $f=New-TauriPreparationFixture;$checkpoints=@{}
    Initialize-TauriPreset $f.identity $f.selection $f.resolution $f.root $f.process $f.download -Checkpoints $checkpoints | Out-Null
    $checkpoints.locks.manifest=@($checkpoints.locks.manifest | Where-Object path -CNE 'package.json')
    $entry=@($checkpoints.overlay.manifest | Where-Object path -CEQ 'package.json')[0]
    $entry.sha256=(Get-FileHash "$($f.root)/package.json" -Algorithm SHA256).Hash.ToLowerInvariant()
    $package=[IO.File]::ReadAllText("$($f.root)/package.json") | ConvertFrom-Json -AsHashtable
    $package.description='corrupted legacy overlay'
    Write-FixtureText "$($f.root)/package.json" ($package | ConvertTo-Json -Depth 10)
    Expect-Error {Initialize-TauriPreset $f.identity $f.selection $f.resolution $f.root $f.process $f.download -Checkpoints $checkpoints} 'Retained Tauri preparation differs: package\.json'
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

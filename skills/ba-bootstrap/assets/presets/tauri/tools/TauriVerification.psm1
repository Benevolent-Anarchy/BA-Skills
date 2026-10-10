#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Get-TauriTool([string]$Name) {
    $command=Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {return $command.Source}
    if ($Name -in @('cargo','rustfmt','rustc','rustup')) {
        $candidate=Join-Path $env:USERPROFILE ".cargo/bin/$Name.exe"
        if (Test-Path $candidate -PathType Leaf) {return $candidate}
    }
    throw "Required Tauri tool missing: $Name. Install the prerequisite separately; verification does not install SDKs."
}
function Get-TauriNpm {
    $npm=Get-TauriTool 'npm';$node=Get-TauriTool 'node'
    if ($npm.EndsWith('.cmd',[StringComparison]::OrdinalIgnoreCase)) {
        $cli=Join-Path (Split-Path $npm -Parent) 'node_modules/npm/bin/npm-cli.js'
        if (-not (Test-Path $cli -PathType Leaf)) {throw 'npm CLI source missing beside npm.cmd.'}
        return @{exe=$node;prefix=@($cli)}
    }
    return @{exe=$npm;prefix=@()}
}
function Get-TauriProcessEnvironment([string]$Repository) {
    $cargo=Get-TauriTool 'cargo';$node=Get-TauriTool 'node'
    return @{PATH=((Split-Path $cargo -Parent)+[IO.Path]::PathSeparator+(Split-Path $node -Parent)+[IO.Path]::PathSeparator+$env:PATH);CARGO_TARGET_DIR=(Join-Path $Repository 'src-tauri/target')}
}
function Assert-TauriSelectedRelease([hashtable]$Resolution,[hashtable]$CargoMetadata) {
    $root=$CargoMetadata.resolve.root
    $node=@($CargoMetadata.resolve.nodes | Where-Object id -CEQ $root)
    if (-not $root -or $node.Count -ne 1) {throw 'Cargo metadata does not identify one application root.'}
    $dep=@($node[0].deps | Where-Object name -CEQ 'tauri')
    if ($dep.Count -ne 1) {throw 'Application does not have exactly one direct Tauri dependency.'}
    $package=@($CargoMetadata.packages | Where-Object id -CEQ $dep[0].pkg)
    if ($package.Count -ne 1 -or $package[0].name -cne 'tauri' -or $package[0].version -cne $Resolution.selections.tauri) {throw "Application does not use selected Tauri release $($Resolution.selections.tauri); preserve the failed preparation rather than selecting an older release."}
}
function Assert-TauriNpmLock([string]$Repository) {
    $package=[IO.File]::ReadAllText("$Repository/package.json") | ConvertFrom-Json -AsHashtable
    $lock=[IO.File]::ReadAllText("$Repository/package-lock.json") | ConvertFrom-Json -AsHashtable
    if ($lock.lockfileVersion -lt 2 -or -not $lock.packages.ContainsKey('')) {throw 'npm lockfile missing its application package.'}
    $root=$lock.packages['']
    if ($root.name -cne $package.name -or $root.version -cne $package.version) {throw 'npm lockfile is stale for the application.'}
    foreach ($kind in @('dependencies','devDependencies')) {
        $expected=if($package.ContainsKey($kind)){$package[$kind]}else{@{}}
        $actual=if($root.ContainsKey($kind)){$root[$kind]}else{@{}}
        if ($expected.Count -ne $actual.Count) {throw "npm lockfile $kind is stale."}
        foreach ($key in $expected.Keys) {if (-not $actual.ContainsKey($key) -or $actual[$key] -cne $expected[$key]) {throw "npm lockfile is stale for $key."}}
    }
}
function Invoke-TauriVerification([string]$Repository,[hashtable]$Config,[scriptblock]$Process) {
    $stages=[Collections.Generic.List[object]]::new();$diagnostics=[Collections.Generic.List[string]]::new();$stage='typescript';$binary=$null
    try {
        if (-not $Config.ContainsKey('tauri') -or $Config.tauri.selectedRelease -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or $Config.tauri.crateName -cnotmatch '^[a-z][a-z0-9-]*$') {throw 'Tauri verification configuration requires a selected stable release and legal crate name.'}
        foreach ($path in @('package.json','package-lock.json','src-tauri/Cargo.toml','src-tauri/Cargo.lock')) {if (-not (Test-Path "$Repository/$path" -PathType Leaf)) {throw "Required locked Tauri source missing: $path"}}
        if (-not (Test-Path "$Repository/node_modules" -PathType Container)) {throw 'Installed frontend dependencies missing. Run npm ci with the recorded lockfile.'}
        Assert-TauriNpmLock $Repository
        $before=@{};foreach ($path in @('package-lock.json','src-tauri/Cargo.lock')) {$before[$path]=(Get-FileHash "$Repository/$path" -Algorithm SHA256).Hash}
        $npm=Get-TauriNpm;$cargo=Get-TauriTool 'cargo';$environment=Get-TauriProcessEnvironment $Repository
        $metadata=& $Process $cargo @('metadata','--manifest-path','src-tauri/Cargo.toml','--locked','--format-version','1','--quiet') $Repository $environment
        if ($metadata.ExitCode -ne 0) {throw "Locked Cargo metadata failed: $($metadata.Output)"}
        Assert-TauriSelectedRelease @{selections=@{tauri=$Config.tauri.selectedRelease}} ($metadata.Output | ConvertFrom-Json -AsHashtable)
        $lockCheck=& $Process $npm.exe ($npm.prefix+@('ci','--dry-run','--ignore-scripts','--no-audit','--no-fund')) $Repository $environment
        if ($lockCheck.ExitCode -ne 0) {throw "Locked npm dependency check failed: $($lockCheck.Output)"}
        $run=Join-Path $Repository ('.test-results/tauri-'+[guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($run) | Out-Null
        $commands=@(
            @{name='typescript';exe=$npm.exe;arguments=$npm.prefix+@('run','typecheck')},
            @{name='frontend-tests';exe=$npm.exe;arguments=$npm.prefix+@('run','test','--','--run','--reporter=junit',"--outputFile=$run/frontend.xml")},
            @{name='frontend-build';exe=$npm.exe;arguments=$npm.prefix+@('run','build')},
            @{name='rust-format';exe=$cargo;arguments=@('fmt','--manifest-path','src-tauri/Cargo.toml','--all','--','--check')},
            @{name='rust-lint';exe=$cargo;arguments=@('clippy','--manifest-path','src-tauri/Cargo.toml','--locked','--all-targets','--','-D','warnings')},
            @{name='rust-tests';exe=$cargo;arguments=@('test','--manifest-path','src-tauri/Cargo.toml','--locked')},
            @{name='tauri-build';exe=$npm.exe;arguments=$npm.prefix+@('run','tauri','--','build','--no-bundle','--ci','--','--locked')}
        )
        foreach ($command in $commands) {
            $stage=$command.name;$child=$environment.Clone();$child.BA_TAURI_STAGE=$stage
            if ($stage -ceq 'frontend-tests') {$child.BA_TAURI_RESULTS="$run/frontend.xml"}
            $result=& $Process $command.exe $command.arguments $Repository $child
            if ($result.ExitCode -ne 0) {throw "$stage failed: $($result.Output)"}
            if ($stage -ceq 'frontend-tests') {
                if (-not (Test-Path "$run/frontend.xml" -PathType Leaf)) {throw 'Frontend tests wrote no results XML.'}
                [xml]$xml=[IO.File]::ReadAllText("$run/frontend.xml");$root=$xml.DocumentElement
                if ($root.LocalName -cne 'testsuites' -or $root.GetAttribute('tests') -cnotmatch '^[0-9]+$' -or [int]$root.GetAttribute('tests') -lt 1) {throw 'Frontend test results are malformed or contain zero tests.'}
                foreach ($field in @('failures','errors')) {if ($root.GetAttribute($field) -cnotmatch '^[0-9]+$' -or [int]$root.GetAttribute($field) -ne 0) {throw "Frontend test results reported $field."}}
                if ($xml.SelectNodes('//failure|//error').Count -gt 0) {throw 'Frontend test results contain failures.'}
                $cases=@($xml.SelectNodes('//testcase'))
                if ($cases.Count -ne [int]$root.GetAttribute('tests')) {throw 'Frontend test report counts do not match actual testcase records.'}
                $skipped=@($cases | Where-Object {$null -ne $_.SelectSingleNode('skipped')}).Count
                if ($root.HasAttribute('skipped') -and ($root.GetAttribute('skipped') -cnotmatch '^[0-9]+$' -or [int]$root.GetAttribute('skipped') -ne $skipped)) {throw 'Frontend test report skipped count is inconsistent.'}
                if ($cases.Count - $skipped -lt 1) {throw 'Frontend test results contain zero executed non-skipped tests.'}
            }
            if ($stage -ceq 'tauri-build') {
                $extension=if($IsWindows){'.exe'}else{''}
                $binary=Join-Path $Repository "src-tauri/target/release/$($Config.tauri.crateName)$extension"
                if (-not (Test-Path $binary -PathType Leaf) -or (Get-Item $binary).Length -eq 0) {throw "Native build did not produce the application binary: $binary"}
            }
            $stages.Add(@{Name=$stage;Passed=$true;ExitCode=0;Diagnostics=@();Output=$result.Output})
        }
        foreach ($path in $before.Keys) {if ((Get-FileHash "$Repository/$path" -Algorithm SHA256).Hash -cne $before[$path]) {throw "Verification mutated recorded lockfile: $path"}}
    } catch {$diagnostics.Add($_.Exception.Message);$stages.Add(@{Name=$stage;Passed=$false;ExitCode=1;Diagnostics=@()})}
    return @{Passed=(@($stages | Where-Object {-not $_.Passed}).Count -eq 0);Stages=$stages.ToArray();Diagnostics=$diagnostics.ToArray();BinaryPath=$binary}
}
Export-ModuleMember -Function Invoke-TauriVerification,Assert-TauriSelectedRelease,Assert-TauriNpmLock,Get-TauriTool,Get-TauriNpm,Get-TauriProcessEnvironment

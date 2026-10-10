Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Project.psm1')
Import-Module (Join-Path $PSScriptRoot 'Dependencies.psm1')
Import-Module (Join-Path $PSScriptRoot 'Preparation.psm1')
Import-Module (Join-Path $PSScriptRoot '../assets/project/tools/Verification.psm1')
Import-Module (Join-Path $PSScriptRoot '../assets/presets/tauri/tools/TauriVerification.psm1')
function Get-TauriSourcePaths([string]$Repository,[string]$Directory=$Repository) {
    foreach ($item in Get-ChildItem $Directory -Force) {
        $relative=[IO.Path]::GetRelativePath($Repository,$item.FullName).Replace('\','/')
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {throw "Tauri source contains a link: $relative"}
        if ($item.PSIsContainer) {
            if ($item.Name -in @('.git','node_modules','dist','.test-results','.vite','.vitest','coverage') -or $relative -in @('src-tauri/target','src-tauri/gen/schemas')) {continue}
            Get-TauriSourcePaths $Repository $item.FullName
        } else {$relative}
    }
}
function Set-TauriText([string]$Path,[string]$Text) {[IO.File]::WriteAllText($Path,$Text.Replace("`r`n","`n"),[Text.UTF8Encoding]::new($false))}
function Save-TauriCheckpoint([string]$Phase,[hashtable]$Value,[hashtable]$Checkpoints,[scriptblock]$Checkpoint) {
    $Checkpoints[$Phase]=$Value
    & $Checkpoint $Phase $Value | Out-Null
}
function Assert-TauriRetainedFiles([string]$Repository,[object[]]$Manifest) {
    $actual=@(Get-BootstrapPreparedManifest $Repository @($Manifest.path))
    foreach ($entry in $Manifest) {if (@($actual | Where-Object {$_.path -ceq $entry.path -and $_.sha256 -ceq $entry.sha256}).Count -ne 1) {throw "Retained Tauri preparation differs: $($entry.path). Preserve evidence rather than rerun the generator."}}
}
function Initialize-TauriPreset {
    param([hashtable]$Identity,[hashtable]$Selection,[hashtable]$Resolution,[string]$Repository,
        [scriptblock]$Process={param($exe,$arguments,$cwd,$environment) Invoke-VerificationProcess $exe $arguments $cwd $environment},
        [scriptblock]$Download={param($uri,$path) Invoke-WebRequest -Uri $uri -OutFile $path | Out-Null},
        [hashtable]$Checkpoints=@{},[scriptblock]$Checkpoint={param($phase,$value)})
    if ($Selection.name -cne 'tauri' -or $Resolution.preset -cne 'tauri') {throw 'Tauri preparation requires a recorded Tauri selection and resolution.'}
    $root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../assets/presets/tauri'))
    $npm=Get-TauriNpm;$cargo=Get-TauriTool 'cargo';$environment=Get-TauriProcessEnvironment $Repository
    $dependencies=$Repository+'.dependencies';$generator=$Repository+'.generator'
    Assert-BootstrapOwnedPath (Split-Path $Repository -Parent) $dependencies
    Assert-BootstrapOwnedPath (Split-Path $Repository -Parent) $generator
    [IO.Directory]::CreateDirectory($dependencies) | Out-Null
    $artifact=$Resolution.artifacts[0].Clone()
    if ($Checkpoints.ContainsKey('generator-acquired')) {$artifact.sha256=$Checkpoints['generator-acquired'].sha256}
    $receipt=Receive-BootstrapArtifact $artifact "$dependencies/create-tauri-app.tgz" $Download
    if (-not $Checkpoints.ContainsKey('generator-acquired')) {Save-TauriCheckpoint 'generator-acquired' $receipt $Checkpoints $Checkpoint}
    # Execute the already verified archive; npm still verifies its native optional dependencies.
    $prefix=$npm.prefix+@('exec','--yes',"--package=$dependencies/create-tauri-app.tgz",'--','create-tauri-app')
    if (-not $Checkpoints.ContainsKey('generator')) {
        if ($Checkpoints.ContainsKey('generator-started') -or (Test-Path $generator)) {throw 'Generator execution has no completion receipt. Preserve unresolved preparation; do not run it again.'}
        Save-TauriCheckpoint 'generator-started' @{startedAt=[DateTime]::UtcNow.ToString('o')} $Checkpoints $Checkpoint
        try {
            [IO.Directory]::CreateDirectory($generator) | Out-Null
            $help=& $Process $npm.exe ($prefix+@('--help')) $generator $environment
            $plain=$help.Output -replace "$([char]27)\[[0-9;]*m",''
            $major=($Resolution.selections.tauri -split '\.')[0]
            if ($help.ExitCode -ne 0 -or $plain -notmatch '--tauri-version\s+\[([^\]]+)\]' -or $major -notin @($Matches[1] -split '\|' | ForEach-Object {$_.Trim()})) {throw "Recorded generator $($Resolution.selections.generator) cannot provide selected Tauri major $major. Update the preparation adapter; no older release is substituted."}
            foreach ($flag in @('--template','vanilla-ts','--manager','--identifier','--yes')) {if (-not $plain.Contains($flag)) {throw "Recorded generator help lacks required option $flag."}}
            $generated=& $Process $npm.exe ($prefix+@('.','--template','vanilla-ts','--manager','npm','--identifier',$Selection.appIdentifier,'--yes','--tauri-version',$major)) $generator $environment
            if ($generated.ExitCode -ne 0) {throw "Official generator failed: $($generated.Output)"}
            foreach ($path in @('package.json','tsconfig.json','vite.config.ts','index.html','src/main.ts','src/styles.css','src-tauri/Cargo.toml','src-tauri/tauri.conf.json','src-tauri/src/main.rs','src-tauri/src/lib.rs','src-tauri/build.rs','src-tauri/capabilities/default.json')) {if (-not (Test-Path "$generator/$path" -PathType Leaf)) {throw "Unsupported generator layout; required source missing: $path"}}
            $manifest=@(Get-BootstrapPreparedManifest $generator @(Get-TauriSourcePaths $generator))
        } catch {
            $failure=$_.Exception.Message
            Remove-BootstrapOwnedItems (Split-Path $Repository -Parent) @($generator)
            $Checkpoints.Remove('generator-started')
            Save-TauriCheckpoint 'generator-failed' @{failedAt=[DateTime]::UtcNow.ToString('o');message=$failure;retryable=$true} $Checkpoints $Checkpoint
            throw
        }
        Save-TauriCheckpoint 'generator' @{version=$Resolution.selections.generator;help=$help.Output;output=$generated.Output;manifest=@($manifest | ForEach-Object {@{path=$_.path;sha256=$_.sha256}})} $Checkpoints $Checkpoint
    }
    Assert-TauriRetainedFiles $generator $Checkpoints.generator.manifest
    if (-not $Checkpoints.ContainsKey('overlay')) {
        $manifest=@(foreach ($path in Get-TauriSourcePaths $generator | Where-Object {$_ -notin @('README.md','.gitignore') -and $_ -notmatch '^(src/assets|public)/.*\.(svg|png)$'}) {
            $bytes=[IO.File]::ReadAllBytes("$generator/$path")
            if ([IO.Path]::GetExtension($path) -in @('.rs','.toml','.json','.lock','.ts','.tsx','.js','.jsx','.mjs','.cjs','.css','.html','.md','.txt','.svg','.yaml','.yml') -or [IO.Path]::GetFileName($path) -in @('.gitignore','.gitkeep','.npmrc','LICENSE','LICENCE')) {$bytes=ConvertTo-BootstrapTextBytes $bytes}
            @{path=$path;bytes=$bytes;sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()}
        })
        Write-BootstrapManifest $Repository $manifest | Out-Null
        $config=[IO.File]::ReadAllText("$Repository/src-tauri/tauri.conf.json") | ConvertFrom-Json -AsHashtable
        if (-not $config.ContainsKey('build') -or -not $config.build.ContainsKey('frontendDist') -or -not $config.ContainsKey('app') -or $config.app.windows -isnot [array] -or -not $config.app.windows.Count) {throw 'Unsupported Tauri configuration layout; preserve upstream source and update the adapter.'}
        foreach ($icon in $config.bundle.icon) {if (-not (Test-Path "$Repository/src-tauri/$icon" -PathType Leaf)) {throw "Required app icon missing: $icon"}}
        $config.productName=$Identity.title;$config.version='0.0.1';$config.identifier=$Selection.appIdentifier
        foreach ($window in $config.app.windows) {$window.title=$Identity.title}
        $config.build.frontendDist='../dist';$config.build.devUrl='http://localhost:1420';$config.build.beforeDevCommand='npm run dev';$config.build.beforeBuildCommand='npm run build'
        Set-TauriText "$Repository/src-tauri/tauri.conf.json" (($config | ConvertTo-Json -Depth 20)+"`n")
        $toml=[IO.File]::ReadAllText("$Repository/src-tauri/Cargo.toml")
        if ($toml -notmatch '(?m)^tauri\s*=\s*\{[^\r\n]*version\s*=\s*"[\^~= ]*([0-9]+)[^"]*"' -or $Matches[1] -cne ($Resolution.selections.tauri -split '\.')[0]) {throw 'Generator Rust dependency does not match the selected Tauri family or known manifest layout.'}
        $toml=[regex]::Replace($toml,'(?m)^(tauri\s*=\s*\{[^\r\n]*?version\s*=\s*)"[^"]*"',('${1}"^'+$Resolution.selections.tauri+'"'))
        $packageBlock=[regex]::Match($toml,'(?ms)^\[package\]\s*\n(.*?)(?=^\[|\z)')
        if (-not $packageBlock.Success) {throw 'Cargo package manifest layout missing.'}
        $block=[regex]::Replace($packageBlock.Value,'(?m)^name\s*=\s*"[^"]*"',('name = "'+$Selection.crateName+'"'))
        $block=[regex]::Replace($block,'(?m)^version\s*=\s*"[^"]*"','version = "0.0.1"')
        # JSON string escapes are also valid TOML basic-string escapes.
        $fields=@{description=($Identity.description | ConvertTo-Json -Compress);authors=('['+($Identity.owner | ConvertTo-Json -Compress)+']')}
        foreach ($field in $fields.Keys) {
            $pattern='(?m)^'+$field+'\s*=.*$';$line=$field+' = '+$fields[$field]
            if ([regex]::IsMatch($block,$pattern)) {$block=[regex]::Replace($block,$pattern,[Text.RegularExpressions.MatchEvaluator]{param($match) $line})}
            else {$block=$block.TrimEnd()+"`n$line`n"}
        }
        $toml=$toml.Replace($packageBlock.Value,$block)
        $libraryBlock=[regex]::Match($toml,'(?ms)^\[lib\]\s*\n(.*?)(?=^\[|\z)')
        $libraryName=[regex]::Match($libraryBlock.Value,'(?m)^name\s*=\s*"([a-zA-Z_][a-zA-Z0-9_]*)"')
        if (-not $libraryBlock.Success -or -not $libraryName.Success) {throw 'Unsupported Cargo library manifest layout.'}
        $oldLibrary=$libraryName.Groups[1].Value;$newLibrary=$Selection.crateName.Replace('-','_')+'_lib'
        $block=[regex]::Replace($libraryBlock.Value,'(?m)^name\s*=\s*"[^"]*"',('name = "'+$newLibrary+'"'))
        $toml=$toml.Replace($libraryBlock.Value,$block)
        Set-TauriText "$Repository/src-tauri/Cargo.toml" $toml
        $main=[IO.File]::ReadAllText("$Repository/src-tauri/src/main.rs")
        $call=[regex]::Escape($oldLibrary)+'\s*::\s*run\s*\(\s*\)'
        if ([regex]::Matches($main,$call).Count -ne 1) {throw 'Unsupported Rust main entry point: expected one generated library run call.'}
        Set-TauriText "$Repository/src-tauri/src/main.rs" ([regex]::Replace($main,$call,($newLibrary+'::run()')))
        $package=[IO.File]::ReadAllText("$Repository/package.json") | ConvertFrom-Json -AsHashtable
        $package.name=$Selection.packageName;$package.version='0.0.1';$package.scripts.typecheck='tsc --noEmit';$package.scripts.test='vitest --environment jsdom'
        $package.devDependencies.vitest='latest';$package.devDependencies.jsdom='latest'
        Set-TauriText "$Repository/package.json" (($package | ConvertTo-Json -Depth 10)+"`n")
        foreach ($file in Get-ChildItem "$root/src" -File) {
            $target=$file.Name.Replace('.template','');$text=[IO.File]::ReadAllText($file.FullName).Replace('{{TITLE_JSON}}',($Identity.title | ConvertTo-Json -Compress))
            Set-TauriText "$Repository/src/$target" $text
        }
        $title=[Net.WebUtility]::HtmlEncode($Identity.title)
        Set-TauriText "$Repository/index.html" "<!doctype html>`n<html lang=`"en`"><head><meta charset=`"UTF-8`"><meta name=`"viewport`" content=`"width=device-width, initial-scale=1.0`"><title>$title</title></head><body><div id=`"app`"></div><script type=`"module`" src=`"/src/main.ts`"></script></body></html>`n"
        # Retain upstream Vite settings while checking the concrete integration we rely on.
        $vite=[IO.File]::ReadAllText("$Repository/vite.config.ts")
        if ($vite -notmatch 'port:\s*1420' -or $vite -notmatch 'strictPort:\s*true' -or -not $vite.Contains('**/src-tauri/**')) {throw 'Unsupported Vite generator layout: fixed port and Rust watch exclusions missing.'}
        foreach ($file in Get-ChildItem "$root/tools" -File) {[IO.File]::WriteAllBytes("$Repository/tools/$($file.Name)",(ConvertTo-BootstrapTextBytes ([IO.File]::ReadAllBytes($file.FullName))))}
        $gate=@{schemaVersion=1;preset='tauri';requiredChecks=@('documentation','typescript','frontend-tests','frontend-build','rust-format','rust-lint','rust-tests','tauri-build');tauri=@{selectedRelease=$Resolution.selections.tauri;crateName=$Selection.crateName}}
        Set-TauriText "$Repository/tools/verify.json" (($gate | ConvertTo-Json -Depth 5)+"`n")
        $ignore=[IO.File]::ReadAllText("$Repository/.gitignore")+"`n"+[IO.File]::ReadAllText("$generator/.gitignore")+"`n"+[IO.File]::ReadAllText("$root/gitignore.fragment")
        Set-TauriText "$Repository/.gitignore" $ignore
        $overlay=@(Get-BootstrapPreparedManifest $Repository @(Get-TauriSourcePaths $Repository))
        Save-TauriCheckpoint 'overlay' @{manifest=@($overlay | ForEach-Object {@{path=$_.path;sha256=$_.sha256}})} $Checkpoints $Checkpoint
    }
    $retainedOverlay=@($Checkpoints.overlay.manifest)
    # The completed lock receipt supersedes the overlay's provisional npm specifications.
    if ($Checkpoints.ContainsKey('locks') -and @($Checkpoints.locks.manifest | Where-Object path -CEQ 'package.json').Count -eq 1) {$retainedOverlay=@($retainedOverlay | Where-Object path -CNE 'package.json')}
    Assert-TauriRetainedFiles $Repository $retainedOverlay
    if (-not $Checkpoints.ContainsKey('locks')) {
        if ($Checkpoints.ContainsKey('locks-started') -or (Test-Path "$Repository/package-lock.json") -or (Test-Path "$Repository/src-tauri/Cargo.lock")) {throw 'Dependency preparation has no completed lock receipt. Preserve unresolved locks; do not generate a replacement set.'}
        Save-TauriCheckpoint 'locks-started' @{startedAt=[DateTime]::UtcNow.ToString('o')} $Checkpoints $Checkpoint
        $packageBefore=[IO.File]::ReadAllBytes("$Repository/package.json")
        try {
            $npmLock=& $Process $npm.exe ($npm.prefix+@('install','--package-lock-only','--no-audit','--no-fund')) $Repository $environment
            if ($npmLock.ExitCode -ne 0 -or -not (Test-Path "$Repository/package-lock.json" -PathType Leaf)) {throw "npm lock generation failed or missing: $($npmLock.Output)"}
            $npmProof=[IO.File]::ReadAllText("$Repository/package-lock.json") | ConvertFrom-Json -AsHashtable
            $package=[Text.Encoding]::UTF8.GetString($packageBefore) | ConvertFrom-Json -AsHashtable
            foreach ($name in @('vitest','jsdom')) {
                $path='node_modules/'+$name
                if (-not $npmProof.ContainsKey('packages') -or -not $npmProof.packages.ContainsKey($path) -or -not $npmProof.packages[$path].ContainsKey('version') -or $npmProof.packages[$path].version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {throw "npm lock does not prove a stable resolved $name version."}
                $package.devDependencies[$name]='^'+$npmProof.packages[$path].version
            }
            Set-TauriText "$Repository/package.json" (($package | ConvertTo-Json -Depth 10)+"`n")
            $npmLock=& $Process $npm.exe ($npm.prefix+@('install','--package-lock-only','--no-audit','--no-fund')) $Repository $environment
            if ($npmLock.ExitCode -ne 0 -or -not (Test-Path "$Repository/package-lock.json" -PathType Leaf)) {throw "npm lock synchronization failed or missing: $($npmLock.Output)"}
            $cargoLock=& $Process $cargo @('generate-lockfile','--manifest-path','src-tauri/Cargo.toml') $Repository $environment
            if ($cargoLock.ExitCode -ne 0 -or -not (Test-Path "$Repository/src-tauri/Cargo.lock" -PathType Leaf)) {throw "Cargo lock generation failed or missing: $($cargoLock.Output)"}
            $cargoSelected=& $Process $cargo @('update','--manifest-path','src-tauri/Cargo.toml','-p','tauri','--precise',$Resolution.selections.tauri) $Repository $environment
            if ($cargoSelected.ExitCode -ne 0) {throw "Cargo selected-release locking failed: $($cargoSelected.Output)"}
            foreach ($path in @('package-lock.json','src-tauri/Cargo.lock')) {[IO.File]::WriteAllBytes("$Repository/$path",(ConvertTo-BootstrapTextBytes ([IO.File]::ReadAllBytes("$Repository/$path"))))}
            Assert-TauriNpmLock $Repository
            $metadata=& $Process $cargo @('metadata','--manifest-path','src-tauri/Cargo.toml','--locked','--format-version','1','--quiet') $Repository $environment
            if ($metadata.ExitCode -ne 0) {throw "Locked Cargo metadata failed: $($metadata.Output)"}
            Assert-TauriSelectedRelease $Resolution ($metadata.Output | ConvertFrom-Json -AsHashtable) -RequireExactPreparedVersions
            $locks=@(Get-BootstrapPreparedManifest $Repository @('package.json','package-lock.json','src-tauri/Cargo.lock'))
        } catch {
            $failure=$_.Exception.Message
            Remove-BootstrapOwnedItems $Repository @("$Repository/package-lock.json","$Repository/src-tauri/Cargo.lock")
            [IO.File]::WriteAllBytes("$Repository/package.json",$packageBefore)
            $Checkpoints.Remove('locks-started')
            Save-TauriCheckpoint 'locks-failed' @{failedAt=[DateTime]::UtcNow.ToString('o');message=$failure;retryable=$true} $Checkpoints $Checkpoint
            throw
        }
        Save-TauriCheckpoint 'locks' @{manifest=@($locks | ForEach-Object {@{path=$_.path;sha256=$_.sha256}})} $Checkpoints $Checkpoint
    }
    Assert-TauriRetainedFiles $Repository $Checkpoints.locks.manifest
    $installed=& $Process $npm.exe ($npm.prefix+@('ci','--no-audit','--no-fund')) $Repository $environment
    if ($installed.ExitCode -ne 0) {throw "Locked npm installation failed: $($installed.Output)"}
    $metadata=& $Process $cargo @('metadata','--manifest-path','src-tauri/Cargo.toml','--locked','--format-version','1','--quiet') $Repository $environment
    if ($metadata.ExitCode -ne 0) {throw "Locked Cargo metadata failed: $($metadata.Output)"}
    $parsed=$metadata.Output | ConvertFrom-Json -AsHashtable
    Assert-TauriSelectedRelease $Resolution $parsed -RequireExactPreparedVersions
    $npmLock=[IO.File]::ReadAllText("$Repository/package-lock.json") | ConvertFrom-Json -AsHashtable
    $versions=@{};foreach ($path in $npmLock.packages.Keys | Where-Object {$_ -like 'node_modules/*'}) {$versions[$path.Substring(13)]=$npmLock.packages[$path].version}
    $receipt.generatorVersion=$Resolution.selections.generator;$receipt.frontendPackages=$versions;$receipt.rustPackages=@($parsed.packages | ForEach-Object {@{name=$_.name;version=$_.version}})
    return @{trackedPaths=@(Get-TauriSourcePaths $Repository);receipts=@($receipt);checkpoints=$Checkpoints}
}
Export-ModuleMember -Function Initialize-TauriPreset,Get-TauriSourcePaths,Assert-TauriSelectedRelease

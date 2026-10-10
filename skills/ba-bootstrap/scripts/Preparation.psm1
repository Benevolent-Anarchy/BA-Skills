#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Project.psm1')
Import-Module (Join-Path $PSScriptRoot 'State.psm1')
Import-Module (Join-Path $PSScriptRoot 'Dependencies.psm1')
Import-Module (Join-Path $PSScriptRoot '../assets/project/tools/Verification.psm1')

function Remove-BootstrapOwnedItems([string]$Root,[string[]]$Paths) {
    $rootPath=[IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Root))
    $targets=@($Paths | ForEach-Object {[IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($_))} | Select-Object -Unique)
    # Validate the entire batch, including descendants, before deleting its first item.
    foreach ($target in $targets) {
        if ($target -ieq $rootPath) {throw 'Cleanup cannot delete its ownership root.'}
        Assert-BootstrapOwnedPath $rootPath $target
        if (Test-Path -LiteralPath $target -PathType Container) {
            foreach ($item in Get-ChildItem -LiteralPath $target -Recurse -Force) {
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {throw "Cleanup contains a linked path: $($item.FullName)"}
            }
        }
    }
    foreach ($target in $targets | Sort-Object Length -Descending) {
        if (Test-Path -LiteralPath $target) {Remove-Item -LiteralPath $target -Recurse -Force}
    }
}
function Get-BootstrapDisposablePreparationPaths([hashtable]$Journal,[string]$StateRoot) {
    $root=[IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($StateRoot))
    $id=[guid]::Empty
    if (-not [guid]::TryParse($Journal.invocationId,[ref]$id) -or $id.ToString() -cne $Journal.invocationId) {throw 'Invalid preparation cleanup invocation ID.'}
    Join-Path $root "preparing/$id"
    $prepared=Join-Path $root 'prepared'
    Assert-BootstrapOwnedPath $root $prepared
    if (Test-Path -LiteralPath $prepared -PathType Container) {
        Get-ChildItem -LiteralPath $prepared -Force | Where-Object {$_.Name -cmatch ('^\.'+[regex]::Escape($id.ToString())+'\.[a-zA-Z0-9]+\.partial$')} | ForEach-Object {$_.FullName}
    }
}
function Remove-BootstrapCompletedPreparation([hashtable]$Journal,[string]$StateRoot) {
    if (-not ($Journal.phases.ContainsKey('complete') -and $Journal.phases.complete -ceq 'verified')) {throw 'Preparation cleanup requires a recorded complete invocation.'}
    Remove-BootstrapOwnedItems $StateRoot @(Get-BootstrapDisposablePreparationPaths $Journal $StateRoot)
}
function Get-BootstrapPreparedManifest([string]$Repository,[string[]]$Paths) {
    $Repository=[IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Repository))
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($relative in ($Paths | Sort-Object)) {
        Assert-BootstrapRelativePath $relative
        if (-not $seen.Add($relative)) {throw "Duplicate or case-colliding manifest path: $relative"}
        $file=Join-Path $Repository $relative
        Assert-BootstrapOwnedPath $Repository $file
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {throw "Prepared source file missing: $relative"}
        $cursor=$Repository
        foreach ($segment in $relative.Split('/')) {
            if (-not @(Get-ChildItem -LiteralPath $cursor -Force | Where-Object Name -CEQ $segment).Count) {throw "Prepared source path has incorrect case: $relative"}
            $cursor=Join-Path $cursor $segment
        }
        [byte[]]$bytes=[IO.File]::ReadAllBytes($file)
        @{path=$relative;bytes=$bytes;sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()}
    }
}

function Read-BootstrapPreparedProject([hashtable]$Journal,[string]$StateRoot) {
    if ($Journal.schemaVersion -ne 2 -or $Journal.preparation.snapshot -cne "prepared/$($Journal.invocationId)/source") {throw 'Prepared snapshot receipt is missing or invalid; preserve state for recovery.'}
    $root=[IO.Path]::GetFullPath($StateRoot)
    $source=Join-Path $root $Journal.preparation.snapshot
    Assert-BootstrapOwnedPath $root $source
    $receiptPath=Join-Path (Split-Path $source -Parent) 'receipt.json'
    Assert-BootstrapOwnedPath $root $receiptPath
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf) -or -not (Test-Path -LiteralPath $source -PathType Container)) {throw 'Prepared snapshot or receipt missing; preserve state for recovery.'}
    $receipt=ConvertFrom-BootstrapJson ([IO.File]::ReadAllText($receiptPath))
    if ($receipt.schemaVersion -ne 1 -or $receipt.invocationId -cne $Journal.invocationId -or $receipt.inputHash -cne $Journal.inputHash -or $receipt.manifestHash -cne $Journal.preparation.manifestHash -or $receipt.manifestHash -cne (Get-BootstrapTemplateVersion $Journal.manifest) -or $receipt.manifestHash -cne (Get-BootstrapTemplateVersion $receipt.manifest)) {throw 'Prepared snapshot receipt differs from invocation/manifest.'}
    $items=@(Get-ChildItem -LiteralPath $source -Recurse -Force)
    if (@($items | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count) {throw 'Prepared snapshot contains a linked path.'}
    $actual=@($items | Where-Object {-not $_.PSIsContainer} | ForEach-Object {[IO.Path]::GetRelativePath($source,$_.FullName).Replace('\','/')} | Sort-Object)
    if (($actual -join "`n") -cne (@($Journal.manifest.path | Sort-Object) -join "`n")) {throw 'Prepared snapshot paths are missing or unexpected.'}
    $manifest=@(Get-BootstrapPreparedManifest $source @($Journal.manifest.path))
    if ((Get-BootstrapTemplateVersion $manifest) -cne $Journal.preparation.manifestHash) {throw 'Prepared snapshot bytes/hash differ; preserve the evidence.'}
    return @{sourcePath=$source;manifest=$manifest;selection=$Journal.presetSelection;resolution=$Journal.resolution}
}

function Save-BootstrapPreparedProject([hashtable]$Journal,[string]$JournalPath,[IO.FileStream]$Lock,[string]$Source,[object[]]$Manifest) {
    $owned=$null
    if ($null -eq $Lock) {$owned=Enter-BootstrapLock $JournalPath;$Lock=$owned}
    try {
        if ($Journal.schemaVersion -ne 2) {throw 'Prepared projects require v2 invocation state.'}
        $stateRoot=[IO.Path]::GetFullPath((Split-Path $JournalPath -Parent))
        $relative="prepared/$($Journal.invocationId)/source"
        $destination=Join-Path $stateRoot $relative
        Assert-BootstrapOwnedPath $stateRoot $destination
        $hash=Get-BootstrapTemplateVersion $Manifest
        if ($Journal.preparation.manifestHash -and $Journal.preparation.manifestHash -cne $hash) {throw 'Frozen manifest differs; preserve the original snapshot.'}
        $Journal.manifest=@($Manifest | Sort-Object path | ForEach-Object {@{path=$_.path;sha256=$_.sha256}})
        $Journal.templateVersion=$hash;$Journal.preparation.manifestHash=$hash;$Journal.preparation.snapshot=$relative
        $Journal.preparation.phase='snapshotting'
        Write-BootstrapJournal $JournalPath $Journal $Lock
        $snapshotRoot=Split-Path $destination -Parent
        if (Test-Path -LiteralPath $snapshotRoot) {
            Read-BootstrapPreparedProject $Journal $stateRoot | Out-Null
        } else {
            $preparedParent=Split-Path $snapshotRoot -Parent
            [IO.Directory]::CreateDirectory($preparedParent) | Out-Null
            $temporary=Join-Path $preparedParent ('.'+$Journal.invocationId+'.'+[guid]::NewGuid().ToString('N')+'.partial')
            Assert-BootstrapOwnedPath $stateRoot $temporary
            $temporarySource=Join-Path $temporary 'source'
            # Re-read the declared source to ensure it still matches the frozen bytes.
            $actual=@(Get-BootstrapPreparedManifest $Source @($Manifest.path))
            if ((Get-BootstrapTemplateVersion $actual) -cne $hash) {throw 'Prepared source changed before snapshot publication.'}
            Write-BootstrapManifest $temporarySource $actual | Out-Null
            $receipt=@{schemaVersion=1;invocationId=$Journal.invocationId;inputHash=$Journal.inputHash;manifestHash=$hash;manifest=$Journal.manifest}
            [IO.File]::WriteAllText((Join-Path $temporary 'receipt.json'),($receipt | ConvertTo-Json -Depth 40),[Text.UTF8Encoding]::new($false))
            [IO.Directory]::Move($temporary,$snapshotRoot)
            Read-BootstrapPreparedProject $Journal $stateRoot | Out-Null
        }
        $Journal.preparation.phase='frozen'
        Write-BootstrapJournal $JournalPath $Journal $Lock
    } finally {if ($null -ne $owned) {$owned.Dispose()}}
}
function Get-BootstrapPreparationSource([hashtable]$Journal,[string]$StateRoot) {
    $root=[IO.Path]::GetFullPath($StateRoot)
    $source=Join-Path $root "preparing/$($Journal.invocationId)/source"
    Assert-BootstrapOwnedPath $root $source
    return $source
}
function Assert-BootstrapPreparedBytes([string]$Source,[object[]]$Manifest) {
    $actual=@(Get-BootstrapPreparedManifest $Source @($Manifest.path))
    if ((Get-BootstrapTemplateVersion $actual) -cne (Get-BootstrapTemplateVersion $Manifest)) {throw 'Prepared source bytes differ from the retained manifest.'}
}
function Get-BootstrapPublicationSource([hashtable]$Journal,[string]$StateRoot) {
    $snapshot=Join-Path ([IO.Path]::GetFullPath($StateRoot)) $Journal.preparation.snapshot
    Assert-BootstrapOwnedPath ([IO.Path]::GetFullPath($StateRoot)) $snapshot
    if ($Journal.preparation.phase -ceq 'snapshotting' -and -not (Test-Path (Split-Path $snapshot -Parent)) -and $Journal.preparation.checkpoints.ContainsKey('source-ready')) {
        $source=Get-BootstrapPreparationSource $Journal $StateRoot
        $ready=$Journal.preparation.checkpoints['source-ready'].manifest
        if ((Get-BootstrapTemplateVersion $ready) -cne $Journal.preparation.manifestHash -or (Get-BootstrapTemplateVersion $Journal.manifest) -cne $Journal.preparation.manifestHash) {throw 'Unpublished source receipt differs from the frozen manifest.'}
        Assert-BootstrapPreparedBytes $source $ready
        return @{sourcePath=$source;manifest=@(Get-BootstrapPreparedManifest $source @($ready.path));selection=$Journal.presetSelection;resolution=$Journal.resolution}
    }
    return Read-BootstrapPreparedProject $Journal $StateRoot
}
function Initialize-BootstrapPreparation {
    param([hashtable]$Identity,[hashtable]$Selection,[hashtable]$Journal,[string]$StateRoot,[scriptblock]$Checkpoint,
        [scriptblock]$MetadataRequest={param($uri) Invoke-BootstrapMetadataRequest $uri},
        [scriptblock]$Download={param($uri,$path) Invoke-WebRequest -Uri $uri -OutFile $path | Out-Null},
        [scriptblock]$Process={param($exe,$arguments,$cwd,$environment) Invoke-VerificationProcess $exe $arguments $cwd $environment})
    $source=Get-BootstrapPreparationSource $Journal $StateRoot
    $checkpoints=$Journal.preparation.checkpoints
    if ($checkpoints.ContainsKey('source-ready')) {
        $manifest=@(Get-BootstrapPreparedManifest $source @($checkpoints['source-ready'].manifest.path))
        Assert-BootstrapPreparedBytes $source $checkpoints['source-ready'].manifest
        return @{sourcePath=$source;manifest=$manifest;receipts=$checkpoints['source-ready'].receipts}
    }
    if ($null -eq $Journal.resolution) {
        $Journal.resolution=Get-BootstrapDependencyResolution $Selection $MetadataRequest
        & $Checkpoint 'resolution' @{resolvedAt=$Journal.resolution.resolvedAt} | Out-Null
    }
    if (-not $checkpoints.ContainsKey('foundation')) {
        $manifest=@(Get-ProjectManifest $Identity -PresetSelection $Selection)
        Write-BootstrapManifest $source $manifest | Out-Null
        & $Checkpoint 'foundation' @{manifest=@($manifest | ForEach-Object {@{path=$_.path;sha256=$_.sha256}})} | Out-Null
    } else {
        $foundation=@($checkpoints.foundation.manifest)
        if ($checkpoints.ContainsKey('overlay') -or $checkpoints.ContainsKey('godot-source')) {$foundation=@($foundation | Where-Object {$_.path -notin @('.gitignore','tools/verify.json')})}
        Assert-BootstrapPreparedBytes $source $foundation
    }
    $engine=switch ($Selection.name) {
        foundation {@{trackedPaths=@($checkpoints.foundation.manifest.path);receipts=@()}}
        godot {
            Import-Module (Join-Path $PSScriptRoot 'GodotPreset.psm1')
            Initialize-GodotPreset $Identity $Selection $Journal.resolution $source $Download $Process -Checkpoints $checkpoints -Checkpoint $Checkpoint
        }
        tauri {
            Import-Module (Join-Path $PSScriptRoot 'TauriPreset.psm1')
            Initialize-TauriPreset $Identity $Selection $Journal.resolution $source $Process $Download -Checkpoints $checkpoints -Checkpoint $Checkpoint
        }
    }
    $manifest=@(Get-BootstrapPreparedManifest $source @($engine.trackedPaths))
    & $Checkpoint 'source-ready' @{manifest=@($manifest | ForEach-Object {@{path=$_.path;sha256=$_.sha256}});receipts=$engine.receipts} | Out-Null
    return @{sourcePath=$source;manifest=$manifest;receipts=$engine.receipts}
}
function Install-BootstrapLockedDependencies([string]$Repository,[hashtable]$Selection,[scriptblock]$Process={param($exe,$arguments,$cwd,$environment) Invoke-VerificationProcess $exe $arguments $cwd $environment}) {
    if ($Selection.name -cne 'tauri') {return}
    Import-Module (Join-Path $Repository 'tools/TauriVerification.psm1') -Force
    $npm=Get-TauriNpm;$environment=Get-TauriProcessEnvironment $Repository
    $result=& $Process $npm.exe ($npm.prefix+@('ci','--no-audit','--no-fund')) $Repository $environment
    if ($result.ExitCode -ne 0) {throw "Checkout locked dependency installation failed: $($result.Output)"}
}
function Invoke-BootstrapProjectGate([string]$Repository,[scriptblock]$Process={param($exe,$arguments,$cwd,$environment) Invoke-VerificationProcess $exe $arguments $cwd $environment}) {
    $module=Import-Module (Join-Path $Repository 'tools/Verification.psm1') -Force -PassThru
    $gate=$module.ExportedCommands['Invoke-ProjectVerification']
    if ($gate.Parameters.ContainsKey('RequireExactPreparedVersions')) {& $gate $Repository $Process -RequireExactPreparedVersions}
    else {& $gate $Repository $Process} # Earlier frozen helpers already enforce the exact Tauri release.
}
Export-ModuleMember -Function Get-BootstrapPreparedManifest,Read-BootstrapPreparedProject,Save-BootstrapPreparedProject,Get-BootstrapPreparationSource,Get-BootstrapPublicationSource,Assert-BootstrapPreparedBytes,Initialize-BootstrapPreparation,Install-BootstrapLockedDependencies,Invoke-BootstrapProjectGate,Remove-BootstrapOwnedItems,Get-BootstrapDisposablePreparationPaths,Remove-BootstrapCompletedPreparation

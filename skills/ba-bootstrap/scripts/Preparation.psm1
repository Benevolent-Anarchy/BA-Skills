#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Project.psm1')
Import-Module (Join-Path $PSScriptRoot 'State.psm1')

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
Export-ModuleMember -Function Get-BootstrapPreparedManifest,Read-BootstrapPreparedProject,Save-BootstrapPreparedProject

#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Project.psm1')
function Get-BootstrapStateRoot {
    if (-not $env:LOCALAPPDATA) {throw 'LOCALAPPDATA is unavailable; supply a state root to the module.'}
    Join-Path $env:LOCALAPPDATA 'BA-Skills/ba-bootstrap/state'
}
function Get-BootstrapJournalPath([hashtable]$Identity,[string]$StateRoot=(Get-BootstrapStateRoot)) {
    $key=Get-BootstrapContentHash ($Identity.owner+'/'+$Identity.repository).ToLowerInvariant()
    [IO.Path]::GetFullPath((Join-Path $StateRoot ($key+'.json')))
}
function Get-BootstrapInputHash([hashtable]$Identity,[hashtable]$PresetSelection) {
    $values=@($Identity.title,$Identity.description,$Identity.owner.ToLowerInvariant(),$Identity.repository,$Identity.projectPath.ToLowerInvariant())
    if ($null -ne $PresetSelection) {$values+=@('bootstrap-state-v2',$PresetSelection.name,[int]$PresetSelection.recipeVersion,$PresetSelection.renderer,$PresetSelection.appIdentifier,$PresetSelection.packageName,$PresetSelection.crateName)}
    Get-BootstrapContentHash ($values | ConvertTo-Json -Compress)
}
function Get-BootstrapTemplateVersion($Manifest) {
    Get-BootstrapContentHash (@($Manifest | Sort-Object path | ForEach-Object {$_.path+':'+$_.sha256}) -join "`n")
}
function New-BootstrapJournal([hashtable]$Identity,$Manifest,[hashtable]$PresetSelection) {
    $journal=@{schemaVersion=1;invocationId=[guid]::NewGuid().ToString();identity=$Identity;inputHash=(Get-BootstrapInputHash $Identity);templateVersion=(Get-BootstrapTemplateVersion $Manifest);manifest=@($Manifest | ForEach-Object {@{path=$_.path;sha256=$_.sha256}});repositories=@{};phases=@{};refs=@{};browserEvidence=@{};createdAt=[datetime]::UtcNow.ToString('o')}
    if ($null -ne $PresetSelection) {
        $journal.schemaVersion=2;$journal.presetSelection=$PresetSelection.Clone();$journal.recipeVersion=$PresetSelection.recipeVersion
        $journal.inputHash=Get-BootstrapInputHash $Identity $PresetSelection
        $journal.resolution=$null;$journal.preparation=@{phase='not-started';snapshot=$null;manifestHash=$null;checkpoints=@{}}
        $journal.verification=@{staging=$null;checkout=$null}
    }
    return $journal
}
function ConvertFrom-BootstrapJson([string]$Text) {
    # Preserve ISO-looking strings (identity inputs and observation timestamps) on PS 7.2 too.
    function Convert-Element([System.Text.Json.JsonElement]$Element) {
        switch ($Element.ValueKind.ToString()) {
            Object {
                $map=@{}
                foreach ($property in $Element.EnumerateObject()) {$map[$property.Name]=Convert-Element $property.Value}
                return $map
            }
            Array {
                $array=@(foreach ($child in $Element.EnumerateArray()) {Convert-Element $child})
                return ,$array
            }
            String {return $Element.GetString()}
            Number {return $Element.GetDouble()}
            True {return $true}
            False {return $false}
            Null {return $null}
            default {throw 'Unsupported JSON value.'}
        }
    }
    $document=[System.Text.Json.JsonDocument]::Parse($Text)
    try {return Convert-Element $document.RootElement} finally {$document.Dispose()}
}
function Read-BootstrapJournal([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {return $null}
    try {
        $journal=ConvertFrom-BootstrapJson ([IO.File]::ReadAllText($Path))
        if ($journal.schemaVersion -notin @(1,2) -or $journal.identity -isnot [hashtable] -or -not $journal.identity.fullName -or -not $journal.invocationId -or $journal.inputHash -notmatch '^[a-f0-9]{64}$' -or $journal.templateVersion -notmatch '^[a-f0-9]{64}$' -or $journal.manifest -isnot [array] -or $journal.repositories -isnot [hashtable] -or $journal.phases -isnot [hashtable] -or $journal.refs -isnot [hashtable] -or $journal.browserEvidence -isnot [hashtable]) {throw 'Invalid schema.'}
        $invocation=[guid]::Empty
        if (-not [guid]::TryParse($journal.invocationId,[ref]$invocation) -or $invocation.ToString() -cne $journal.invocationId) {throw 'Invalid invocation ID.'}
        $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $journal.manifest) {
            Assert-BootstrapRelativePath $entry.path
            if (-not $paths.Add($entry.path) -or $entry.sha256 -notmatch '^[a-f0-9]{64}$') {throw 'Invalid manifest.'}
        }
        if ($journal.schemaVersion -eq 2) {
            if ($journal.presetSelection -isnot [hashtable] -or $journal.presetSelection.name -notin @('foundation','godot','tauri') -or $journal.recipeVersion -lt 1 -or [int]$journal.recipeVersion -ne $journal.recipeVersion -or $journal.recipeVersion -ne $journal.presetSelection.recipeVersion -or $journal.preparation -isnot [hashtable] -or $journal.verification -isnot [hashtable]) {throw 'Invalid preset state.'}
            foreach ($key in @('renderer','appIdentifier','packageName','crateName')) {if (-not $journal.presetSelection.ContainsKey($key)) {throw 'Missing preset option.'}}
            foreach ($key in @('phase','snapshot','manifestHash','checkpoints')) {if (-not $journal.preparation.ContainsKey($key)) {throw 'Invalid preparation state.'}}
            if ($journal.preparation.checkpoints -isnot [hashtable] -or $journal.preparation.phase -notin @('not-started','preparing','snapshotting','frozen')) {throw 'Invalid preparation phase.'}
            if ($journal.preparation.snapshot -and $journal.preparation.snapshot -cne "prepared/$($journal.invocationId)/source") {throw 'Invalid snapshot path.'}
            if ($journal.inputHash -cne (Get-BootstrapInputHash $journal.identity $journal.presetSelection)) {throw 'Invalid preset input hash.'}
        }
        return $journal
    } catch {throw "Cannot read bootstrap journal '$Path': invalid JSON or schema. Preserve it for recovery."}
}
function Assert-BootstrapJournal($Journal,$Identity,$Manifest,[hashtable]$PresetSelection) {
    if ($Journal.schemaVersion -eq 1) {
        if ($null -ne $PresetSelection -and $PresetSelection.name -ne 'foundation') {throw 'Legacy journal records foundation; a conflicting preset cannot replace it.'}
        if ($Journal.inputHash -ne (Get-BootstrapInputHash $Identity)) {throw 'Journal input differs from the requested identity. Resume using its stored inputs.'}
        if ($Journal.phases.ContainsKey('complete') -and $Journal.phases.complete -eq 'verified') {return}
        if ($Journal.templateVersion -ne (Get-BootstrapTemplateVersion $Manifest)) {throw 'Journal template differs from this skill version. Preserve the journal and recover with the matching version.'}
    } else {
        if ($null -eq $PresetSelection) {$PresetSelection=$Journal.presetSelection}
        if ($Journal.inputHash -cne (Get-BootstrapInputHash $Identity $PresetSelection)) {throw 'Journal input/preset differs from the requested invocation. Resume using its stored inputs.'}
    }
}
function Enter-BootstrapLock([string]$Path) {
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    try {return [IO.File]::Open($Path+'.lock',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)} catch {throw 'Bootstrap journal is locked by another invocation.'}
}
function Write-BootstrapJournal([string]$Path,[hashtable]$Journal,[IO.FileStream]$Lock) {
    $owned=$null
    if ($null -eq $Lock) {$owned=Enter-BootstrapLock $Path}
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temporary,($Journal | ConvertTo-Json -Depth 40),[Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary,$Path,$true)
    } finally {if ($null -ne $owned) {$owned.Dispose()}}
}
Export-ModuleMember -Function Get-BootstrapStateRoot,Get-BootstrapJournalPath,Get-BootstrapInputHash,Get-BootstrapTemplateVersion,New-BootstrapJournal,Read-BootstrapJournal,Assert-BootstrapJournal,Enter-BootstrapLock,Write-BootstrapJournal,ConvertFrom-BootstrapJson

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
function Get-BootstrapInputHash([hashtable]$Identity) {
    Get-BootstrapContentHash (@($Identity.title,$Identity.description,$Identity.owner.ToLowerInvariant(),$Identity.repository,$Identity.projectPath.ToLowerInvariant()) | ConvertTo-Json -Compress)
}
function Get-BootstrapTemplateVersion($Manifest) {
    Get-BootstrapContentHash (@($Manifest | Sort-Object path | ForEach-Object {$_.path+':'+$_.sha256}) -join "`n")
}
function New-BootstrapJournal([hashtable]$Identity,$Manifest) {
    @{schemaVersion=1;invocationId=[guid]::NewGuid().ToString();identity=$Identity;inputHash=(Get-BootstrapInputHash $Identity);templateVersion=(Get-BootstrapTemplateVersion $Manifest);manifest=@($Manifest | ForEach-Object {@{path=$_.path;sha256=$_.sha256}});repositories=@{};phases=@{};refs=@{};browserEvidence=@{};createdAt=[datetime]::UtcNow.ToString('o')}
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
        if ($journal.schemaVersion -ne 1 -or -not $journal.identity.fullName -or -not $journal.invocationId -or -not $journal.inputHash -or -not $journal.templateVersion -or $journal.repositories -isnot [hashtable] -or $journal.phases -isnot [hashtable] -or $journal.refs -isnot [hashtable] -or $journal.browserEvidence -isnot [hashtable]) {throw 'Invalid schema.'}
        return $journal
    } catch {throw "Cannot read bootstrap journal '$Path': invalid JSON or schema. Preserve it for recovery."}
}
function Assert-BootstrapJournal($Journal,$Identity,$Manifest) {
    if ($Journal.inputHash -ne (Get-BootstrapInputHash $Identity)) {throw 'Journal input differs from the requested identity. Resume using its stored inputs.'}
    if ($Journal.templateVersion -ne (Get-BootstrapTemplateVersion $Manifest)) {throw 'Journal template differs from this skill version. Preserve the journal and recover with the matching version.'}
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

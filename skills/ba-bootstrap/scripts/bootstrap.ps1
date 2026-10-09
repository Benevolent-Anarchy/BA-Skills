#requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('plan','create','status','resume','local-setup')][string]$Mode='plan',
    [string]$Name,[string]$Description,[string]$Parent='C:\Users\cicel\Dev',
    [string]$Owner='Benevolent-Anarchy',[string]$Repository,
    [switch]$Interactive,[switch]$RefreshPlugins
)
$ErrorActionPreference='Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'Project.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Bootstrap.psm1') -Force
    $required=if ($Mode -eq 'local-setup') {@('Repository')} elseif ($Mode -in @('status','resume')) {@('Name')} else {@('Name','Description')}
    if ($Interactive) {
        foreach ($field in $required) {
            if ([string]::IsNullOrWhiteSpace((Get-Variable $field -ValueOnly))) {Set-Variable $field (Read-Host $field)}
        }
        if ($Mode -in @('plan','create')) {
            if (-not $PSBoundParameters.ContainsKey('Parent')) {$answer=Read-Host "Parent directory [$Parent]";if ($answer) {$Parent=$answer}}
            if (-not $PSBoundParameters.ContainsKey('Owner')) {$answer=Read-Host "GitHub owner [$Owner; cicely-f is also available]";if ($answer) {$Owner=$answer}}
        }
    }
    $missing=@($required | Where-Object {[string]::IsNullOrWhiteSpace((Get-Variable $_ -ValueOnly))})
    if ($missing.Count) {@{status='missing-input';missing=$missing} | ConvertTo-Json -Depth 10;exit 1}
    if ($Mode -eq 'local-setup') {throw 'Local Obsidian setup is not available in this implementation stage.'}
    $identity=if ($Mode -in @('status','resume')) {Get-BootstrapStoredIdentity -Name $Name -Owner $Owner} else {New-BootstrapIdentity -Name $Name -Description $Description -Parent $Parent -Owner $Owner}
    $report=switch ($Mode) {
        plan {Get-BootstrapPlan -Identity $identity}
        status {Get-BootstrapStatus -Identity $identity}
        default {Invoke-Bootstrap -Identity $identity}
    }
    $report | ConvertTo-Json -Depth 40
    if ($report.status -in @('ready','complete')) {exit 0}
    exit 1
} catch {
    @{status='blocked';conflicts=@($_.Exception.Message)} | ConvertTo-Json -Depth 10
    exit 1
}

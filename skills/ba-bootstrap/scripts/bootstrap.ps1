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
    if ($Mode -eq 'local-setup') {
        Import-Module (Join-Path $PSScriptRoot 'Obsidian.psm1') -Force
        $identity=Get-LocalProjectIdentity -Repository $Repository
        $setup=Install-ProjectObsidian -Identity $identity -RefreshPlugins:$RefreshPlugins
        $setup.status=if ($setup.installedVerified -and $setup.enabledVerified -and $setup.pending.Count -eq 0) {'complete'} else {'partial'}
        $setup | ConvertTo-Json -Depth 40
        if ($setup.status -eq 'complete') {exit 0}
        exit 1
    }
    $identity=if ($Mode -in @('status','resume')) {Get-BootstrapStoredIdentity -Name $Name -Owner $Owner} else {New-BootstrapIdentity -Name $Name -Description $Description -Parent $Parent -Owner $Owner}
    $report=switch ($Mode) {
        plan {Get-BootstrapPlan -Identity $identity}
        status {Get-BootstrapStatus -Identity $identity}
        default {Invoke-Bootstrap -Identity $identity -RefreshPlugins:$RefreshPlugins}
    }
    $report | ConvertTo-Json -Depth 40
    if ($report.status -in @('ready','complete')) {exit 0}
    exit 1
} catch {
    @{status='blocked';conflicts=@($_.Exception.Message)} | ConvertTo-Json -Depth 10
    exit 1
}

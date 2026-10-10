#requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('plan','create','status','resume','discard','local-setup')][string]$Mode='plan',
    [string]$Name,[string]$Description,[string]$Parent='C:\Users\cicel\Dev',
    [string]$Owner='Benevolent-Anarchy',[string]$Repository,
    [ValidateSet('foundation','godot','tauri')][string]$Preset='godot',
    [ValidateSet('compatibility','forward-plus','mobile')][string]$Renderer,[string]$AppIdentifier,
    [switch]$Interactive,[switch]$RefreshPlugins
)
$ErrorActionPreference='Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'Project.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Bootstrap.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Presets.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'State.psm1') -Force
    $required=if ($Mode -eq 'local-setup') {@('Repository')} elseif ($Mode -in @('status','resume','discard')) {@('Name')} else {@('Name','Description')}
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
        foreach ($option in @('Preset','Renderer','AppIdentifier')) {if ($PSBoundParameters.ContainsKey($option)) {throw "local-setup configures Obsidian only; engine option $option cannot be used."}}
        Import-Module (Join-Path $PSScriptRoot 'Obsidian.psm1') -Force
        $identity=Get-LocalProjectIdentity -Repository $Repository
        $setup=Install-ProjectObsidian -Identity $identity -RefreshPlugins:$RefreshPlugins
        $setup.status=if ($setup.installedVerified -and $setup.enabledVerified -and $setup.pending.Count -eq 0) {'complete'} else {'partial'}
        $setup | ConvertTo-Json -Depth 40
        if ($setup.status -eq 'complete') {exit 0}
        exit 1
    }
    $identity=if ($Mode -in @('status','resume','discard')) {Get-BootstrapStoredIdentity -Name $Name -Owner $Owner} else {New-BootstrapIdentity -Name $Name -Description $Description -Parent $Parent -Owner $Owner}
    $journal=Read-BootstrapJournal (Get-BootstrapJournalPath $identity)
    if ($null -ne $journal) {
        $selection=Get-BootstrapStoredSelection -Name $Name -Owner $Owner
        Assert-BootstrapPresetOverride $selection $PSBoundParameters
        if ($Mode -in @('status','resume','discard')) {
            if ($PSBoundParameters.ContainsKey('Description') -and $Description -cne $identity.description) {throw 'Explicit description conflicts with stored invocation.'}
            if ($PSBoundParameters.ContainsKey('Parent') -and [IO.Path]::GetFullPath($Parent) -ine $identity.parent) {throw 'Explicit parent conflicts with stored invocation.'}
        }
    } else {
        if ($Interactive) {
            if (-not $PSBoundParameters.ContainsKey('Preset')) {$answer=Read-Host "Preset [$Preset; tauri or foundation]";if($answer){$Preset=$answer}}
            if ($Preset -ieq 'godot' -and -not $PSBoundParameters.ContainsKey('Renderer')) {$answer=Read-Host 'Renderer [compatibility; forward-plus or mobile]';$Renderer=if($answer){$answer}else{'compatibility'}}
            if ($Preset -ieq 'tauri' -and -not $PSBoundParameters.ContainsKey('AppIdentifier')) {$suggestion=(Resolve-BootstrapPreset $identity -Preset tauri).appIdentifier;$answer=Read-Host "Application identifier [$suggestion]";$AppIdentifier=if($answer){$answer}else{$suggestion}}
        }
        $options=@{Identity=$identity;Preset=$Preset}
        if ($PSBoundParameters.ContainsKey('Renderer') -or $Renderer) {$options.Renderer=$Renderer}
        if ($PSBoundParameters.ContainsKey('AppIdentifier') -or $AppIdentifier) {$options.AppIdentifier=$AppIdentifier}
        $selection=Resolve-BootstrapPreset @options
    }
    $report=switch ($Mode) {
        plan {Get-BootstrapPlan -Identity $identity -PresetSelection $selection}
        status {Get-BootstrapStatus -Identity $identity}
        discard {Remove-BootstrapInvocation -Identity $identity}
        default {Invoke-Bootstrap -Identity $identity -PresetSelection $selection -RefreshPlugins:$RefreshPlugins}
    }
    $report | ConvertTo-Json -Depth 40
    if ($report.status -in @('ready','complete','discarded')) {exit 0}
    exit 1
} catch {
    @{status='blocked';conflicts=@($_.Exception.Message)} | ConvertTo-Json -Depth 10
    exit 1
}

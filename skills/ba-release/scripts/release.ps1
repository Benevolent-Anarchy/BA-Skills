# Exposes validation, read-only planning, local preparation, publication and journal inspection.
#requires -Version 7.3
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('setup','validate','doctor','plan','prepare','extend','hold','unhold','publish','status','confirm')][string]$Mode,
    [string]$Repository,
    [string[]]$Destination = @(),
    [string]$StateRoot,
    [string]$StatePath,
    [string]$GodotExecutable,
    [string]$TemplateRoot,
    [string]$EditorSettingsPath,
    [string]$AndroidSdkPath,
    [string]$JavaSdkPath,
    [string]$ButlerExecutable = 'butler',
    [string]$GhExecutable = 'gh',
    [string]$SteamCmdExecutable = 'steamcmd',
    [string]$ReceiptPath,
    [string]$AnswersPath,
    [string]$ExpectedConfigSha256,
    [switch]$Interactive,
    [ValidateSet('current','patch','minor','major')][string]$VersionChange='current',
    [switch]$NewRelease,
    [string]$ApprovedPlanId,
    [string]$ApprovedNotesSha256,
    [string]$HoldReason,
    [switch]$PlayTrackReviewed,
    [switch]$RetryUncertain,
    [switch]$ReplacePlayEdit,
    [switch]$MigrateConfiguration
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Release.psm1') -Force
$selected = @($Destination | ForEach-Object {$_.Split(',')} | Where-Object {$_})
try {
    # Bind explicit tool paths to the caller's location before any mode changes directory.
    # Bare command names retain PATH lookup; missing explicit paths remain missing.
    foreach ($parameter in @('GodotExecutable','ButlerExecutable','GhExecutable','SteamCmdExecutable')) {
        $executable=Get-Variable -Name $parameter -ValueOnly
        if ($executable -and -not [IO.Path]::IsPathFullyQualified($executable) -and [IO.Path]::GetFileName($executable) -cne $executable) {
            Set-Variable -Name $parameter -Value $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($executable)
        }
    }
    if ($Mode -eq 'unhold' -and $PSBoundParameters.ContainsKey('HoldReason')) {throw '-HoldReason cannot be supplied to unhold.'}
    if ($PlayTrackReviewed -and $Mode -ne 'unhold') {throw '-PlayTrackReviewed applies only to unhold.'}
    if ($MigrateConfiguration -and $Mode -ne 'extend') {throw '-MigrateConfiguration applies only to extend.'}
    if ($Mode -in @('setup','validate','doctor','plan','prepare') -and -not $Repository) { throw '-Repository must name the inspected game Git root.' }
    if ($Mode -in @('extend','hold','unhold','publish','status','confirm') -and -not $StatePath) { throw '-StatePath must name an existing prepared release.' }
    if ($Mode -eq 'confirm' -and -not $ReceiptPath) {throw '-ReceiptPath must name an actual observed store result.'}
    switch ($Mode) {
        'setup' {
            $report=Get-ReleaseSetup $Repository $selected
            if ($Interactive -and -not $AnswersPath) {
                Invoke-ReleaseInteractiveSetup $Repository $selected | ConvertTo-Json -Depth 30
            } elseif ($AnswersPath) {Set-ReleaseSetup $Repository $AnswersPath $ExpectedConfigSha256 | ConvertTo-Json -Depth 30}
            else {$report | ConvertTo-Json -Depth 30}
        }
        'validate' {
            $settings = Get-ReleaseConfiguration -Repository $Repository
            [ordered]@{valid=$true; version=$settings.version; exports=$settings.presets; notesRepository=$settings.notesRepository; previousRelease=$settings.config.previousReleaseRef; destinations=$settings.config.destinations} | ConvertTo-Json -Depth 20
        }
        'doctor' {
            $report=Get-ReleaseDoctor -Repository $Repository -Destination $selected -GodotExecutable $GodotExecutable -TemplateRoot $TemplateRoot -EditorSettingsPath $EditorSettingsPath -AndroidSdkPath $AndroidSdkPath -JavaSdkPath $JavaSdkPath -ButlerExecutable $ButlerExecutable -SteamCmdExecutable $SteamCmdExecutable -GhExecutable $GhExecutable
            $report | ConvertTo-Json -Depth 20
            if (-not $report.ready) {exit 2}
        }
        'plan' {
            $plan = Get-ReleasePlan -Repository $Repository -Destination $selected -StateRoot $StateRoot -VersionChange $VersionChange
            $plan | ConvertTo-Json -Depth 30
            if (-not $plan.ready) { exit 2 }
        }
        'prepare' {
            if ($selected.Count -eq 0) {
                $chooser=(Get-ReleaseSetup $Repository).selection
                if ($Interactive) {$selected=@((Read-Host ('Choose destination IDs for this release: '+(($chooser.choices | ForEach-Object {$_.id}) -join ', '))).Split(',') | ForEach-Object {$_.Trim()} | Where-Object {$_})}
                if ($selected.Count -eq 0) {@{status='selection-required';selection=$chooser} | ConvertTo-Json -Depth 10;exit 2}
            }
            $result = Invoke-ReleasePrepare -Repository $Repository -Destination $selected -StateRoot $StateRoot -GodotExecutable $GodotExecutable -VersionChange $VersionChange -NewRelease:$NewRelease -ButlerExecutable $ButlerExecutable
            $result | ConvertTo-Json -Depth 20
            if ($result.status -in @('preparation-failed','source-update-required')) { exit 3 }
        }
        'extend' {
            $result=Expand-ReleaseDestinations -StatePath $StatePath -Destination $selected -GodotExecutable $GodotExecutable -ButlerExecutable $ButlerExecutable -MigrateConfiguration:$MigrateConfiguration
            $result | ConvertTo-Json -Depth 20
            if ($result.status -in @('preparation-failed','source-update-required')) {exit 3}
        }
        'hold' {
            Set-ReleaseDestinationHold -StatePath $StatePath -Destination $selected -Reason $HoldReason | ConvertTo-Json -Depth 20
        }
        'unhold' {
            Set-ReleaseDestinationHold -StatePath $StatePath -Destination $selected -Release -PlayTrackReviewed:$PlayTrackReviewed | ConvertTo-Json -Depth 20
        }
        'publish' {
            if ($selected.Count -gt 0 -or $Repository -or $StateRoot -or $GodotExecutable) { throw 'Publish uses only the sealed StatePath; selection and source options cannot replace the prepared plan.' }
            $result = Invoke-ReleasePublish -StatePath $StatePath -ApprovedPlanId $ApprovedPlanId -ApprovedNotesSha256 $ApprovedNotesSha256 -ButlerExecutable $ButlerExecutable -GhExecutable $GhExecutable -SteamCmdExecutable $SteamCmdExecutable -RetryUncertain:$RetryUncertain -ReplacePlayEdit:$ReplacePlayEdit
            $result | ConvertTo-Json -Depth 20
            if ($result.status -ne 'published') { exit 3 }
        }
        'status' {
            $state = Get-Content -LiteralPath (Join-Path $StatePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
            $notesPath = Join-Path $StatePath 'notes.md'
            $notesHash=$null;$notesError=$null
            try {$notesHash=Get-ReleaseNotesHash $StatePath $state.plan} catch {$notesError=$_.Exception.Message}
            $notesFiles=@($notesPath)+@($state.plan.destinations | Where-Object {$_.selected -and $_.type -eq 'google-play'} | ForEach-Object {Join-Path $StatePath "notes.$($_.id).txt"})
            [ordered]@{status=$state.status; version=$state.plan.version; planId=$state.plan.planId; selectedDestinations=$state.plan.selectedDestinations; plan=$state.plan; artifacts=$state.artifacts; notesFiles=$notesFiles; notesSha256=$notesHash; notesError=$notesError; approval=$state.approval; verification=$state.verification; checks=$state['checks']; exports=$state.exports; destinations=$state.destinations} | ConvertTo-Json -Depth 30
        }
        'confirm' {
            $result=Confirm-ReleaseStoreCompletion -StatePath $StatePath -ReceiptPath $ReceiptPath
            $result | ConvertTo-Json -Depth 30
            if ($result.status -ne 'published') {exit 3}
        }
    }
} catch {
    [ordered]@{error=$_.Exception.Message; mode=$Mode} | ConvertTo-Json -Compress
    exit 1
}

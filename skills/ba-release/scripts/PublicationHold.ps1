# Persists explicit holds on prepared destinations without changing release identity or store state.

# Checks one-line public hold text before it can enter a journal or availability history.
function Assert-ReleaseHoldReason([string]$Reason) {
    if ([string]::IsNullOrWhiteSpace($Reason) -or $Reason.Length -gt 1000 -or $Reason -match '[\p{Cc}\p{Zl}\p{Zp}]') {throw 'A single-line public hold reason of 1 to 1000 characters is required.'}
    Assert-ReleaseCredentialFreeText $Reason
}

# Validates the complete request before journaling a hold or explicitly releasing one.
function Set-ReleaseDestinationHold([string]$StatePath, [string[]]$Destination, [string]$Reason, [switch]$Release, [switch]$PlayTrackReviewed) {
    if (-not $Destination.Count -or @($Destination | Where-Object {[string]::IsNullOrWhiteSpace($_)}).Count) {throw 'Explicit destination IDs are required for a hold or unhold.'}
    if ($Release -and $PSBoundParameters.ContainsKey('Reason')) {throw 'A hold reason cannot be supplied to unhold.'}
    if ($PlayTrackReviewed -and -not $Release) {throw 'Play track review applies only to unhold.'}
    if (-not $Release) {Assert-ReleaseHoldReason $Reason}
    $StatePath=Resolve-ReleaseStatePath $StatePath
    $lock=Lock-ReleaseState $StatePath
    try {
        $stateFile=Join-Path $StatePath 'state.json'
        $state=[IO.File]::ReadAllText($stateFile) | ConvertFrom-Json -AsHashtable
        if ($state.schemaVersion -ne 1 -or $state.verification -ne 'succeeded' -or $state.status -in @('preparing','preparation-failed')) {throw 'Destination holds require a successfully prepared release.'}
        $ids=@($Destination | Sort-Object -Unique -CaseSensitive)
        foreach ($id in $ids) {
            $selected=@($state.plan.destinations | Where-Object {$_.id -ceq $id -and $_.selected})
            if ($selected.Count -ne 1) {throw 'Hold destination must belong to the selected prepared plan.'}
            $record=$state.destinations[$id]
            $remoteProgress=@($record.remote.Keys | Where-Object {$_ -cnotin @('sourceCommit','notesHashes')})
            # An older, already-unheld Play attempt may acknowledge review without clearing its outcome.
            $reviewExistingAttempt=$Release -and $PlayTrackReviewed -and $selected[0].type -eq 'google-play' -and $record.status -in @('failed','uncertain','in-progress') -and $record.Contains('hold') -and $record.hold.Contains('releasedAt')
            if (-not $reviewExistingAttempt -and ($remoteProgress.Count -gt 0 -or $record.status -notin @('pending','held','failed','awaiting-release'))) {throw 'Hold/unhold requires a pending, held, definitively failed or awaiting-release destination without remote progress; reconcile started or uncertain store operations.'}
            if ($Release -and $record.status -ne 'held' -and (-not $record.Contains('hold') -or -not $record.hold.Contains('releasedAt'))) {throw 'Unhold requires an existing destination hold.'}
            if ($Release -and $selected[0].type -eq 'google-play' -and -not $PlayTrackReviewed) {throw 'Google Play unhold requires a fresh review of the live track and retained version codes; acknowledge it with -PlayTrackReviewed.'}
        }
        if ($PlayTrackReviewed -and -not @($state.plan.destinations | Where-Object {$_.id -cin $ids -and $_.type -eq 'google-play'}).Count) {throw 'Play track review requires a selected Google Play destination.'}
        $changed=$false
        foreach ($id in $ids) {
            $record=$state.destinations[$id]
            if ($Release) {
                if ($record.status -eq 'held') {
                    $record.status='pending';$record.hold.releasedAt=[DateTimeOffset]::UtcNow.ToString('o');$changed=$true
                }
                if ($PlayTrackReviewed -and @($state.plan.destinations | Where-Object {$_.id -ceq $id -and $_.type -eq 'google-play'}).Count -and -not $record.hold.Contains('playTrackReviewedAt')) {
                    $record.hold.playTrackReviewedAt=[DateTimeOffset]::UtcNow.ToString('o');$changed=$true
                }
            } elseif ($record.status -ne 'held' -or $record.hold.reason -cne $Reason) {
                $record.status='held';$record.hold=[ordered]@{reason=$Reason;heldAt=[DateTimeOffset]::UtcNow.ToString('o')};$changed=$true
            }
        }
        if ($changed) {
            $state.status=Get-ReleaseOverallStatus $state
            Write-ReleaseJson $stateFile $state
        }
        return @{status=$state.status;statePath=$StatePath;version=$state.plan.version;destinations=$state.destinations}
    } finally {$lock.Dispose()}
}

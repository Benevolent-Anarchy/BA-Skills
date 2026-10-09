# Persists explicit holds on prepared destinations without changing release identity or store state.

# Validates the complete request before journaling a hold or explicitly releasing one.
function Set-ReleaseDestinationHold([string]$StatePath, [string[]]$Destination, [string]$Reason, [switch]$Release) {
    if (-not $Destination.Count -or @($Destination | Where-Object {[string]::IsNullOrWhiteSpace($_)}).Count) {throw 'Explicit destination IDs are required for a hold or unhold.'}
    if (-not $Release -and ([string]::IsNullOrWhiteSpace($Reason) -or $Reason.Length -gt 1000)) {throw 'A public hold reason of 1 to 1000 characters is required.'}
    $StatePath=(Get-Item -LiteralPath $StatePath).FullName
    $lock=Lock-ReleaseState $StatePath
    try {
        $stateFile=Join-Path $StatePath 'state.json'
        $state=[IO.File]::ReadAllText($stateFile) | ConvertFrom-Json -AsHashtable
        if ($state.schemaVersion -ne 1 -or $state.verification -ne 'succeeded' -or $state.status -in @('preparing','preparation-failed')) {throw 'Destination holds require a successfully prepared release.'}
        $ids=@($Destination | Sort-Object -Unique -CaseSensitive)
        foreach ($id in $ids) {
            if (@($state.plan.destinations | Where-Object {$_.id -ceq $id -and $_.selected}).Count -ne 1) {throw 'Hold destination must belong to the selected prepared plan.'}
            $record=$state.destinations[$id]
            if ($record.attempts -ne 0 -or $record.remote.Count -gt 0 -or $record.status -notin @('pending','held')) {throw 'Publication has already started for this destination; reconcile its result rather than hiding it with a hold.'}
            if ($Release -and $record.status -ne 'held' -and (-not $record.Contains('hold') -or -not $record.hold.Contains('releasedAt'))) {throw 'Unhold requires an existing destination hold.'}
        }
        $changed=$false
        foreach ($id in $ids) {
            $record=$state.destinations[$id]
            if ($Release) {
                if ($record.status -eq 'held') {
                    $record.status='pending';$record.hold.releasedAt=[DateTimeOffset]::UtcNow.ToString('o');$changed=$true
                }
            } elseif ($record.status -ne 'held' -or $record.hold.reason -cne $Reason) {
                $record.status='held';$record.hold=[ordered]@{reason=$Reason;heldAt=[DateTimeOffset]::UtcNow.ToString('o')};$changed=$true
            }
        }
        if ($changed) {
            $state.status=if (@($state.destinations.Values | Where-Object {$_.attempts -gt 0}).Count) {Get-ReleaseOverallStatus $state} else {'prepared'}
            Write-ReleaseJson $stateFile $state
        }
        return @{status=$state.status;statePath=$StatePath;version=$state.plan.version;destinations=$state.destinations}
    } finally {$lock.Dispose()}
}

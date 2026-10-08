# Tracks confirmed live channel baselines and extends a sealed release without repeating its completed work.

# Identifies a real store channel independently of the local configuration entry's name.
function Get-ReleaseStoreKey($Destination) {
    switch ($Destination.type) {
        'itch' {return "itch:$($Destination.target)"}
        'steam' {return "steam:$($Destination.appId):$($Destination.branch)"}
        'google-play' {return "play:$($Destination.packageName):$($Destination.track)"}
        default {return $null}
    }
}

# Reads per-user live receipts without network operations or writes.
function Get-ReleaseLiveLedger([string]$Repository, [string]$StateRoot) {
    $Repository=(Get-Item -LiteralPath $Repository).FullName
    $id=(Get-ReleaseTextHash $Repository).Substring(0,20)
    $path=Join-Path (Join-Path (Get-ReleaseStateRoot $StateRoot) $id) 'live.json'
    if (Test-Path -LiteralPath $path -PathType Leaf) {return [IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable}
    return [ordered]@{}
}

# Resolves frozen or observed channel baselines; a configured null is never replaced by a guess.
function Get-ReleaseDestinationBaselines($Settings, $Destinations, [string]$Head, $Snapshot, [string]$StateRoot) {
    $ledger=if ($null -eq $Snapshot) {Get-ReleaseLiveLedger $Settings.repository $StateRoot} else {@{}}
    $result=[ordered]@{}
    foreach ($destination in $Destinations) {
        if (-not $destination.selected -or $destination.type -eq 'notes') {continue}
        $key=Get-ReleaseStoreKey $destination
        $ref=if ($null -ne $Snapshot -and $Snapshot.Contains($destination.id)) {$Snapshot[$destination.id]}
        elseif ($ledger.Contains($key)) {$ledger[$key].sourceCommit}
        elseif ($Settings.config.Contains('destinationBaselines') -and $Settings.config.destinationBaselines.Contains($destination.id)) {$Settings.config.destinationBaselines[$destination.id]}
        else {$Settings.config.previousReleaseRef}
        $commit=$null
        if ($null -ne $ref) {
            $commit=Read-ReleaseGit $Settings.repository @('rev-parse','--verify',"$ref^{commit}")
            $ancestor=Invoke-ReleaseTool 'git' @('--no-optional-locks','-C',$Settings.repository,'merge-base','--is-ancestor',$commit,$Head) $Settings.repository
            if ($ancestor.exitCode -ne 0) {throw "Last live baseline for $($destination.id) must be an ancestor of the selected source."}
        }
        $result[$destination.id]=$commit
    }
    return $result
}

# Advances only channels with actual live evidence, preserving unselected and submitted channels.
function Update-ReleaseLiveLedger([string]$StatePath, $State) {
    $repositoryState=Split-Path $StatePath -Parent
    $lock=Lock-ReleaseState $repositoryState
    try {
        $path=Join-Path $repositoryState 'live.json'
        $ledger=if (Test-Path -LiteralPath $path) {[IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable} else {[ordered]@{}}
        foreach ($destination in $State.plan.destinations) {
            if (-not $destination.selected -or $destination.type -eq 'notes') {continue}
            $record=$State.destinations[$destination.id]
            if (-not $record.remote.Contains('live') -or $record.remote.live -ne $true) {continue}
            $key=Get-ReleaseStoreKey $destination
            $sourceCommit=if ($record.remote.Contains('sourceCommit') -and $record.remote.sourceCommit) {$record.remote.sourceCommit} else {$State.plan.head}
            # An older release completing late must not roll a channel's baseline backwards silently.
            if ($ledger.Contains($key) -and $ledger[$key].sourceCommit -cne $sourceCommit) {
                $ancestor=Invoke-ReleaseTool 'git' @('--no-optional-locks','-C',$State.plan.repository,'merge-base','--is-ancestor',$ledger[$key].sourceCommit,$sourceCommit) $State.plan.repository
                if ($ancestor.exitCode -ne 0) {throw 'An older live release cannot replace a newer channel baseline without explicit reconciliation.'}
            }
            if ($ledger.Contains($key) -and $ledger[$key].sourceCommit -ceq $sourceCommit -and $ledger[$key].version -ceq $State.plan.version) {continue}
            $ledger[$key]=@{sourceCommit=$sourceCommit;version=$State.plan.version;statePath=$StatePath;destination=$destination.id;observedAt=[DateTimeOffset]::UtcNow.ToString('o')}
        }
        Write-ReleaseJson $path $ledger
    } finally {$lock.Dispose()}
}

# Adds explicit destinations, reuses existing artifacts/statuses and requires approval of the expanded plan.
function Expand-ReleaseDestinations([string]$StatePath, [string[]]$Destination, [string]$GodotExecutable, [string]$ButlerExecutable='butler') {
    $StatePath=(Get-Item -LiteralPath $StatePath).FullName
    if (-not $Destination.Count) {throw 'Select additional destinations explicitly.'}
    $lock=Lock-ReleaseState $StatePath
    try {
    $stateFile=Join-Path $StatePath 'state.json'
    $state=[IO.File]::ReadAllText($stateFile) | ConvertFrom-Json -AsHashtable
    $settings=Get-ReleaseConfiguration $state.plan.repository
    $selected=@(($state.plan.selectedDestinations+@($Destination)) | Sort-Object -Unique -CaseSensitive)
    $added=@($selected | Where-Object {$_ -cnotin $state.plan.selectedDestinations})
    if (-not $added.Count) {$lock.Dispose();$lock=$null;return Invoke-ReleasePrepare $state.plan.repository $selected (Split-Path (Split-Path $StatePath -Parent) -Parent) $GodotExecutable -ButlerExecutable $ButlerExecutable}
    if ($settings.configHash -cne $state.plan.configSha256 -or $settings.version -cne $state.plan.version) {throw 'Extension requires the same version and inspected configuration as the prepared release.'}
    $fresh=Get-ReleasePlan $settings.repository $selected $null (Split-Path (Split-Path $StatePath -Parent) -Parent)
    # Reserve only new Android artifacts; adding another store for sealed bytes needs no counter change.
    $counterPresets=@(Get-ReleaseAndroidCounterPresets $settings $fresh $added | Where-Object {$_ -cnotin @($state.artifacts | ForEach-Object {$_.preset})})
    $extensionId=(Get-ReleaseTextHash ($selected -join ',')).Substring(0,20)
    $extensionRoot=Join-Path $StatePath "extension-source/$extensionId"
    Assert-ReleaseArtifacts $StatePath $state
    Assert-ReleaseSubmittedNotes $state $StatePath
    if ($state.Contains('canonicalNotesSha256') -and $state.canonicalNotesSha256 -cne (Get-FileHash (Join-Path $StatePath 'notes.md')).Hash.ToLowerInvariant()) {throw 'Canonical notes changed after publication.'}
    $currentHead=Read-ReleaseGit $settings.repository @('rev-parse','HEAD')
    if ($currentHead -cne $state.plan.head) {
        $reservationPath=Join-Path $extensionRoot 'active-source.json'
        if (-not (Test-Path -LiteralPath $reservationPath)) {throw 'Source changed since preparation; extension cannot silently choose another source release.'}
        $pending=[IO.File]::ReadAllText($reservationPath) | ConvertFrom-Json -AsHashtable
        $diff=@((Read-ReleaseGit $settings.repository @('diff','--name-only',$state.plan.head,$currentHead,'--')).Split("`n") | Where-Object {$_})
        if ($pending.originalHead -cne $state.plan.head -or @($diff | Where-Object {$_ -cnotin @($pending.files | ForEach-Object {$_.path})}).Count) {throw 'Extension source differs beyond its reserved Android settings.'}
    }
    $sourceResult=$null
    if ($counterPresets.Count) {
        if (-not $fresh.configurationReady) {throw "Extension plan is blocked: $($fresh.blockers -join ' ')"}
        $sourceResult=Initialize-ReleaseSource $settings $fresh $extensionRoot 'current' -CounterPreset $counterPresets
        if ($sourceResult -and $sourceResult.status -eq 'source-update-required') {return $sourceResult}
        $settings=Get-ReleaseConfiguration $settings.repository
    }
    $head=Read-ReleaseGit $settings.repository @('rev-parse','HEAD')
    if ($head -cne $state.plan.head) {
        $reservationPath=Join-Path $extensionRoot 'active-source.json'
        if (-not (Test-Path -LiteralPath $reservationPath)) {throw 'Source changed since preparation; extension cannot silently choose another source release.'}
        $reservation=[IO.File]::ReadAllText($reservationPath) | ConvertFrom-Json -AsHashtable
        $diff=@((Read-ReleaseGit $settings.repository @('diff','--name-only',$state.plan.head,$head,'--')).Split("`n") | Where-Object {$_})
        if ($reservation.originalHead -cne $state.plan.head -or $reservation.status -ne 'committed' -or @($diff | Where-Object {$_ -cnotin @($reservation.files | ForEach-Object {$_.path})}).Count) {throw 'Extension source differs beyond its reserved Android settings.'}
    }
    $snapshot=[ordered]@{}
    foreach ($id in $state.plan.baselines.Keys) {$snapshot[$id]=$state.plan.baselines[$id]}
    $observed=Get-ReleasePlan $settings.repository $selected $null (Split-Path (Split-Path $StatePath -Parent) -Parent)
    foreach ($id in $added) {if ($observed.baselines.Contains($id)) {$snapshot[$id]=$observed.baselines[$id]}}
    $plan=Get-ReleasePlan $settings.repository $selected $snapshot
    if (-not $plan.ready) {throw "Extension plan is blocked: $($plan.blockers -join ' ')"}
        $current=[IO.File]::ReadAllText($stateFile) | ConvertFrom-Json -AsHashtable
        if ($current.plan.planId -cne $state.plan.planId) {throw 'Release changed during extension; inspect current state before retrying.'}
        Assert-ReleaseArtifacts $StatePath $state
        if ($state.Contains('canonicalNotesSha256') -and $state.canonicalNotesSha256 -cne (Get-FileHash (Join-Path $StatePath 'notes.md')).Hash.ToLowerInvariant()) {throw 'Canonical notes changed after publication.'}
        if (-not $state.Contains('history')) {$state.history=@()}
        $state.history+=@{plan=$state.plan;approval=$state.approval}
        $state.plan=$plan;$state.status='preparing';$state.approval=$null
        # Source verification must run again if Android settings changed; existing exports stay sealed.
        if ($head -cne $current.plan.head) {$state.verification='pending'}
        foreach ($id in $added) {$state.destinations[$id]=@{status='pending';attempts=0;error=$null;remote=[ordered]@{}}}
        Write-ReleaseJson $stateFile $state
    } finally {if ($lock) {$lock.Dispose()}}
    return Invoke-ReleasePrepare $settings.repository $selected (Split-Path (Split-Path $StatePath -Parent) -Parent) $GodotExecutable -ButlerExecutable $ButlerExecutable
}

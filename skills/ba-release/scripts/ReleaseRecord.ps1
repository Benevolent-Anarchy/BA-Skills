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

# Places a game's live ledger by its GitHub repository, so every checkout, worktree and clone of the game under one state root reads and advances the same one.
function Get-ReleaseLedgerDirectory([string]$SourceRepository, [string]$StateRoot) {
    $id=(Get-ReleaseTextHash ('github.com/'+$SourceRepository.ToLowerInvariant())).Substring(0,20)
    return Join-Path (Join-Path (Get-ReleaseStateRoot $StateRoot) 'repositories') $id
}

# Names a prepared plan's GitHub repository, which its notes repository always names as "<owner>/<name>-release-notes".
function Get-ReleasePlanSourceRepository($Plan) {
    return $Plan.notesRepository -replace '-release-notes$',''
}

# Gathers a game's live records, its shared ledger's first. Before ledgers were shared, each checkout kept one in the
# folder named by its own path's hash ($OwnId); another such folder counts only where its state says it released this game.
function Get-ReleaseLiveRecords([string]$SourceRepository, [string]$StateRoot, [string]$OwnId) {
    $root=Get-ReleaseStateRoot $StateRoot
    $records=[Collections.Generic.List[object]]::new()
    $shared=Join-Path (Get-ReleaseLedgerDirectory $SourceRepository $root) 'live.json'
    if (Test-Path -LiteralPath $shared -PathType Leaf) {
        $ledger=[IO.File]::ReadAllText($shared) | ConvertFrom-Json -AsHashtable
        foreach ($key in $ledger.Keys) {$records.Add(@{key=$key;entry=$ledger[$key]})}
    }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {return ,$records}
    $notesRepository="$SourceRepository-release-notes"
    foreach ($folder in @(Get-ChildItem -LiteralPath $root -Directory | Where-Object {$_.Name -cmatch '^[0-9a-f]{20}$'} | Sort-Object Name)) {
        $path=Join-Path $folder.FullName 'live.json'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {continue}
        $ledger=[IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable
        foreach ($key in $ledger.Keys) {
            $entry=$ledger[$key]
            if ($folder.Name -cne $OwnId) {
                if ([string]$entry.version -cnotmatch '^[0-9A-Za-z][0-9A-Za-z.+-]*$') {continue}
                $statePath=Join-Path (Join-Path $folder.FullName $entry.version) 'state.json'
                if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {continue}
                $state=[IO.File]::ReadAllText($statePath) | ConvertFrom-Json -AsHashtable
                if ([string]$state.plan.notesRepository -ine $notesRepository) {continue}
            }
            $records.Add(@{key=$key;entry=$entry})
        }
    }
    return ,$records
}

# Keeps, for each store channel, the record of the latest source to go live. Records on sources that diverged, or that
# this repository lacks, are refused rather than guessed between, since either could be the one players have.
function Merge-ReleaseLiveRecords([string]$Repository, $Records) {
    $ledger=[ordered]@{}
    foreach ($record in $Records) {
        $key=$record.key;$entry=$record.entry
        if (-not $ledger.Contains($key)) {$ledger[$key]=$entry;continue}
        $kept=$ledger[$key]
        if ($kept.sourceCommit -ceq $entry.sourceCommit) {continue}
        $later=Invoke-ReleaseTool 'git' @('--no-optional-locks','-C',$Repository,'merge-base','--is-ancestor',$kept.sourceCommit,$entry.sourceCommit) $Repository
        if ($later.exitCode -eq 0) {$ledger[$key]=$entry;continue}
        $earlier=Invoke-ReleaseTool 'git' @('--no-optional-locks','-C',$Repository,'merge-base','--is-ancestor',$entry.sourceCommit,$kept.sourceCommit) $Repository
        if ($earlier.exitCode -ne 0) {throw "Live records for $key disagree: $($kept.sourceCommit) and $($entry.sourceCommit) do not follow one from the other in this repository. Fetch them, or reconcile which went live last, before planning."}
    }
    return $ledger
}

# Reads the game's live records without network operations or writes: its shared ledger, and those checkouts kept before it.
function Get-ReleaseLiveLedger([string]$Repository, [string]$StateRoot) {
    $Repository=(Get-Item -LiteralPath $Repository).FullName
    $ownId=(Get-ReleaseTextHash $Repository).Substring(0,20)
    $records=Get-ReleaseLiveRecords (Get-ReleaseSourceRepository $Repository) $StateRoot $ownId
    return Merge-ReleaseLiveRecords $Repository $records
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

# Lists every live receipt in a game's records: each row's own, and the earlier ones a shared row keeps in 'recorded'.
function Get-ReleaseLiveReceipts($Records) {
    foreach ($record in $Records) {
        @{key=$record.key;entry=$record.entry}
        if ($record.entry -is [Collections.IDictionary] -and $record.entry.Contains('recorded')) {
            foreach ($receipt in @($record.entry.recorded)) {if ($receipt) {@{key=$record.key;entry=$receipt}}}
        }
    }
}

# Advances only channels with actual live evidence, preserving unselected and submitted channels, in the game's shared ledger.
# Each row keeps every receipt recorded for its channel, so a release whose receipts are replayed after a newer release went
# live on one of its channels leaves that newer row alone. Only a receipt recorded for the first time on an older or diverged
# source is refused, and only once every other channel has been saved, so retrying the step that failed repairs the rest.
function Update-ReleaseLiveLedger([string]$StatePath, $State) {
    $repositoryState=Split-Path $StatePath -Parent
    $sourceRepository=Get-ReleasePlanSourceRepository $State.plan
    $directory=Get-ReleaseLedgerDirectory $sourceRepository (Split-Path $repositoryState -Parent)
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $lock=Lock-ReleaseState $directory
    try {
        $path=Join-Path $directory 'live.json'
        $ledger=if (Test-Path -LiteralPath $path) {[IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable} else {[ordered]@{}}
        # Receipts a checkout recorded for itself before the ledger was shared were recorded too.
        $receipts=@(Get-ReleaseLiveReceipts (Get-ReleaseLiveRecords $sourceRepository (Split-Path $repositoryState -Parent) (Split-Path $repositoryState -Leaf)))
        $refused=[Collections.Generic.List[string]]::new()
        foreach ($destination in $State.plan.destinations) {
            if (-not $destination.selected -or $destination.type -eq 'notes') {continue}
            $record=$State.destinations[$destination.id]
            if (-not $record.remote.Contains('live') -or $record.remote.live -ne $true) {continue}
            $key=Get-ReleaseStoreKey $destination
            $sourceCommit=if ($record.remote.Contains('sourceCommit') -and $record.remote.sourceCommit) {$record.remote.sourceCommit} else {$State.plan.head}
            $row=if ($ledger.Contains($key)) {$ledger[$key]} else {$null}
            if ($row -and $row.sourceCommit -cne $sourceCommit) {
                $ancestor=Invoke-ReleaseTool 'git' @('--no-optional-locks','-C',$State.plan.repository,'merge-base','--is-ancestor',$row.sourceCommit,$sourceCommit) $State.plan.repository
                if ($ancestor.exitCode -ne 0) {
                    # An older release completing late must not roll a channel's baseline backwards silently.
                    $replayed=@($receipts | Where-Object {$_.key -ceq $key -and $_.entry.sourceCommit -ceq $sourceCommit -and $_.entry.version -ceq $State.plan.version}).Count -gt 0
                    if (-not $replayed) {$refused.Add($destination.id)}
                    continue
                }
            }
            if ($row -and $row.sourceCommit -ceq $sourceCommit -and $row.version -ceq $State.plan.version) {continue}
            $receipt=[ordered]@{sourceCommit=$sourceCommit;version=$State.plan.version;statePath=$StatePath;destination=$destination.id;observedAt=[DateTimeOffset]::UtcNow.ToString('o')}
            $earlier=if (-not $row) {@()} elseif ($row.Contains('recorded')) {@($row.recorded)} else {@([ordered]@{sourceCommit=$row.sourceCommit;version=$row.version;statePath=$row.statePath;destination=$row.destination;observedAt=$row.observedAt})}
            $ledger[$key]=[ordered]@{sourceCommit=$sourceCommit;version=$State.plan.version;statePath=$StatePath;destination=$destination.id;observedAt=$receipt.observedAt;recorded=@($earlier)+@($receipt)}
        }
        Write-ReleaseJson $path $ledger
        if ($refused.Count) {throw "An older live release cannot replace a newer channel baseline without explicit reconciliation: $($refused -join ', ')."}
    } finally {$lock.Dispose()}
}

# Reads a committed file as checkout would write it, without touching the index or working tree.
function Read-ReleaseCommittedText([string]$Repository, [string]$Commit, [string]$Path) {
    $start=[Diagnostics.ProcessStartInfo]::new('git')
    foreach ($argument in @('--no-optional-locks','-C',$Repository,'cat-file','--filters',"${Commit}:$Path")) {$start.ArgumentList.Add($argument)}
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($start)
    try {
        $errors=$process.StandardError.ReadToEndAsync()
        $bytes=[IO.MemoryStream]::new()
        $process.StandardOutput.BaseStream.CopyTo($bytes)
        $process.WaitForExit();$null=$errors.Result
        if ($process.ExitCode -ne 0) {throw 'Git read failed: cat-file. Check the repository or ref.'}
        $bytes.Position=0
        # Decodes as File.ReadAllText does, so the text hash compares with the one taken at preparation.
        $reader=[IO.StreamReader]::new($bytes,[Text.UTF8Encoding]::new($false),$true)
        try {return $reader.ReadToEnd()} finally {$reader.Dispose()}
    } finally {$process.Dispose()}
}

# Serializes a configuration value with object members in ordinal order, so only real differences compare unequal.
function Get-ReleaseComparableValue($Value) {
    return Get-ReleaseComparablePlanJson (ConvertTo-Json -InputObject $Value -Depth 30 -Compress)
}

# Accepts a committed release.json change only when it adds stores; everything the release already planned stays frozen.
function Get-ReleaseConfigurationMigration($State, $Settings, [string]$Head) {
    $repository=$Settings.repository;$from=$State.plan.head
    if ($Head -ceq $from) {throw 'Commit the reviewed release.json change before migrating the prepared release.'}
    $ancestor=Invoke-ReleaseTool 'git' @('--no-optional-locks','-C',$repository,'merge-base','--is-ancestor',$from,$Head) $repository
    if ($ancestor.exitCode -ne 0) {throw 'Configuration migration requires source that descends from the prepared release.'}
    $diff=@((Read-ReleaseGit $repository @('diff','--name-only',$from,$Head,'--')).Split("`n") | Where-Object {$_})
    if (@($diff | Where-Object {$_ -cne 'release.json'}).Count) {throw 'Source changed beyond release.json since preparation; configuration migration cannot choose another source release.'}
    # Git text normalization can change only line endings between the prepared file and its commit.
    $text=Read-ReleaseCommittedText $repository $from 'release.json';$lf=$text.Replace("`r`n","`n")
    $prepared=@(@($text,$lf,$lf.Replace("`n","`r`n")) | Where-Object {(Get-ReleaseTextHash $_) -ceq $State.plan.configSha256})
    if (-not $prepared.Count) {throw 'The prepared configuration cannot be read back from its source commit.'}
    # The diff above leaves project files untouched, so the frozen document validates against the same presets.
    $frozen=(Get-ReleaseConfiguration $repository $prepared[0]).config
    $current=$Settings.config
    $fields=[ordered]@{schemaVersion='schemaVersion';project='project';previousReleaseRef='previousRelease';verification='verification.gate';androidVersionCodePolicy='androidVersionCodePolicy'}
    foreach ($field in $fields.Keys) {
        if ((Get-ReleaseComparableValue $frozen[$field]) -cne (Get-ReleaseComparableValue $current[$field])) {throw "Configuration migration only adds stores; $($fields[$field]) changed since preparation."}
    }
    if (@($frozen.exports | Where-Object {$_ -cnotin $current.exports}).Count) {throw 'Configuration migration cannot remove an export the release already planned.'}
    foreach ($check in $frozen.standalone) {
        $match=@($current.standalone | Where-Object {$_.preset -ceq $check.preset})
        if ($match.Count -ne 1 -or (Get-ReleaseComparableValue $match[0]) -cne (Get-ReleaseComparableValue $check)) {throw "Configuration migration cannot change the standalone check for $($check.preset)."}
    }
    foreach ($destination in $frozen.destinations) {
        $match=@($current.destinations | Where-Object {$_.id -ceq $destination.id})
        if ($match.Count -ne 1) {throw "Configuration migration cannot remove destination $($destination.id)."}
        if ((Get-ReleaseComparableValue $match[0]) -cne (Get-ReleaseComparableValue $destination) -or
            (Get-ReleaseComparableValue $current.destinationBaselines[$destination.id]) -cne (Get-ReleaseComparableValue $frozen.destinationBaselines[$destination.id])) {throw "Configuration migration cannot change existing destination $($destination.id) or its baseline."}
    }
    $known=@($frozen.destinations | ForEach-Object {$_.id});$checked=@($frozen.standalone | ForEach-Object {$_.preset})
    return [ordered]@{
        fromHead=$from;toHead=$Head;fromConfigSha256=$State.plan.configSha256;toConfigSha256=$Settings.configHash
        addedDestinations=@($current.destinations | Where-Object {$_.id -cnotin $known} | ForEach-Object {$_.id})
        addedExports=@($current.exports | Where-Object {$_ -cnotin $frozen.exports})
        addedStandaloneChecks=@($current.standalone | Where-Object {$_.preset -cnotin $checked} | ForEach-Object {$_.preset})
    }
}

# Requires each added channel's last live source to precede the release's original source, not a later settings commit.
function Assert-ReleaseAddedBaselines($State, $Baselines, [string[]]$Added) {
    $source=if ($State.Contains('history') -and $State.history.Count) {$State.history[0].plan.head} else {$State.plan.head}
    foreach ($id in $Added) {
        if (-not $Baselines.Contains($id) -or $null -eq $Baselines[$id]) {continue}
        $ancestor=Invoke-ReleaseTool 'git' @('--no-optional-locks','-C',$State.plan.repository,'merge-base','--is-ancestor',$Baselines[$id],$source) $State.plan.repository
        if ($ancestor.exitCode -ne 0) {throw "Last live baseline for $id must precede the release's original source commit."}
    }
}

# Adds explicit destinations, reuses existing artifacts/statuses and requires approval of the expanded plan.
# A committed release.json change that only adds stores is adopted first, explicitly, through -MigrateConfiguration.
function Expand-ReleaseDestinations([string]$StatePath, [string[]]$Destination, [string]$GodotExecutable, [string]$ButlerExecutable='butler', [switch]$MigrateConfiguration) {
    $StatePath=(Get-Item -LiteralPath $StatePath).FullName
    if (-not $Destination.Count) {throw 'Select additional destinations explicitly.'}
    $stateRoot=Split-Path (Split-Path $StatePath -Parent) -Parent
    $lock=Lock-ReleaseState $StatePath
    try {
    $stateFile=Join-Path $StatePath 'state.json'
    $state=[IO.File]::ReadAllText($stateFile) | ConvertFrom-Json -AsHashtable
    $settings=Get-ReleaseConfiguration $state.plan.repository
    $selected=@(($state.plan.selectedDestinations+@($Destination)) | Sort-Object -Unique -CaseSensitive)
    $added=@($selected | Where-Object {$_ -cnotin $state.plan.selectedDestinations})
    if (-not $added.Count) {$lock.Dispose();$lock=$null;return Invoke-ReleasePrepare $state.plan.repository $selected $stateRoot $GodotExecutable -ButlerExecutable $ButlerExecutable}
    if ($settings.version -cne $state.plan.version) {throw 'Extension requires the same version as the prepared release.'}
    $fresh=Get-ReleasePlan $settings.repository $selected $null $stateRoot
    Assert-ReleaseAddedBaselines $state $fresh.baselines $added
    if ($settings.configHash -cne $state.plan.configSha256) {
        $migration=Get-ReleaseConfigurationMigration $state $settings $fresh.head
        Assert-ReleaseArtifacts $StatePath $state
        Assert-ReleaseSubmittedNotes $state $StatePath
        if ($state.Contains('canonicalNotesSha256') -and $state.canonicalNotesSha256 -cne (Get-FileHash (Join-Path $StatePath 'notes.md')).Hash.ToLowerInvariant()) {throw 'Canonical notes changed after publication.'}
        # Every introduced destination is frozen with the release, selected or not, so each must be complete now.
        $adopted=@(@($selected)+@($migration.addedDestinations) | Sort-Object -Unique -CaseSensitive)
        $introduced=@($adopted | Where-Object {$_ -cnotin $state.plan.selectedDestinations})
        $observed=Get-ReleasePlan $settings.repository $adopted $null $stateRoot
        Assert-ReleaseAddedBaselines $state $observed.baselines $introduced
        $snapshot=[ordered]@{}
        foreach ($id in $state.plan.baselines.Keys) {$snapshot[$id]=$state.plan.baselines[$id]}
        foreach ($id in $introduced) {if ($observed.baselines.Contains($id)) {$snapshot[$id]=$observed.baselines[$id]}}
        $expanded=Get-ReleasePlan $settings.repository $adopted $snapshot $stateRoot
        if (-not $expanded.ready) {throw "Configuration migration adopts every added destination, selected or not; complete them or leave them out of the committed change. Plan is blocked: $($expanded.blockers -join ' ')"}
        # Phase one rebinds only the original selection, keeping its frozen baselines and notes boundary.
        $migrated=Get-ReleasePlan $settings.repository $state.plan.selectedDestinations $state.plan.baselines $stateRoot
        if (-not $migrated.ready) {throw "Migrated release plan is blocked: $($migrated.blockers -join ' ')"}
        if ($migrated.previousCommit -cne $state.plan.previousCommit) {throw 'Configuration migration cannot move the previous-release boundary of the prepared release.'}
        # Planning rereads HEAD and release.json, so save only plans built from the snapshot that passed validation.
        foreach ($candidate in @($fresh,$observed,$expanded,$migrated)) {
            if ($candidate.head -cne $migration.toHead -or $candidate.configSha256 -cne $migration.toConfigSha256) {throw 'Source or release.json changed during migration; nothing was saved. Review the new change, then retry.'}
        }
        if (-not $MigrateConfiguration) {
            $what=if ($migration.addedDestinations.Count) {'adding '+($migration.addedDestinations -join ', ')} else {'adding no destinations'}
            throw "release.json changed since preparation, $what. Review that committed change, then repeat extend with -MigrateConfiguration."
        }
        if (-not $state.Contains('history')) {$state.history=@()}
        $state.history+=@{plan=$state.plan;approval=$state.approval;configurationMigration=$migration}
        $state.plan=$migrated;$state.status='preparing';$state.approval=$null;$state.verification='pending'
        foreach ($id in $migration.addedDestinations) {$state.destinations[$id]=[ordered]@{status='not-selected';attempts=0;error=$null;remote=[ordered]@{}}}
        Write-ReleaseJson $stateFile $state
        # Phase two is the ordinary extension of the migrated release; rerunning resumes it from here.
        $lock.Dispose();$lock=$null
        $result=Expand-ReleaseDestinations $StatePath $Destination $GodotExecutable $ButlerExecutable
        $result.configurationMigration=$migration
        return $result
    }
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
    if ($plan.head -cne $head -or $plan.configSha256 -cne $state.plan.configSha256) {throw 'Source or release.json changed during extension; nothing was saved. Inspect the change, then retry.'}
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

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

# Reads a JSON object from a release state file, or gives $null where it cannot be read, parsed, or is not an object.
function Read-ReleaseStateObject([string]$Path) {
    try {$value=[IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable -ErrorAction Stop} catch {return $null}
    if ($value -is [Collections.IDictionary]) {return $value}
    return $null
}

# Makes the classified error for a damaged live ledger. It names the file by its place under the state root, never by its
# private absolute path, since the reason can be kept in a release journal.
function New-ReleaseDamagedStateError([string]$Root, [string]$Path) {
    $place=[IO.Path]::GetRelativePath($Root,$Path).Replace('\','/')
    return (New-ReleaseDiagnosticError "Release state '$place' under the state root cannot be read, and it records this game's live releases; repair it, then retry.")
}

# Reads a game's shared live ledger: one row per store channel, each keeping in 'recorded' every receipt recorded for it.
# Ledgers each checkout kept in its own state directory before ledgers were shared are not read; a game moving from them
# sets release.json's previousRelease once, to the source its last release's public notes name. A damaged ledger stops,
# naming the file, rather than being read as proof that nothing shipped.
function Read-ReleaseSharedLedger([string]$SourceRepository, [string]$StateRoot) {
    $root=Get-ReleaseStateRoot $StateRoot
    $path=Join-Path (Get-ReleaseLedgerDirectory $SourceRepository $root) 'live.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {return [ordered]@{}}
    $ledger=Read-ReleaseStateObject $path
    if ($null -eq $ledger) {throw (New-ReleaseDamagedStateError $root $path)}
    return $ledger
}

# Reads the game's shared live ledger without network operations or writes.
function Get-ReleaseLiveLedger([string]$Repository, [string]$StateRoot) {
    $Repository=(Get-Item -LiteralPath $Repository).FullName
    return Read-ReleaseSharedLedger (Get-ReleaseSourceRepository $Repository) $StateRoot
}

# Finds where a release's canonical notes count from: the newest of release.json's previousRelease ($Configured) and every
# source of this game any checkout recorded live, on any channel, for another version, among $Head's ancestors. This
# version's own receipts are left out, so publishing it never moves its own boundary. Sources that neither contains the
# other cannot be ordered, so the boundary is then reported as ambiguous rather than guessed.
function Get-ReleasePublishedBoundary($Settings, [string]$Head, [string]$Version, [string]$Configured, [string]$StateRoot) {
    $repository=$Settings.repository
    $isAncestor={param($ancestor,$descendant) (Invoke-ReleaseTool 'git' @('--no-optional-locks','-C',$repository,'merge-base','--is-ancestor',$ancestor,$descendant) $repository).exitCode -eq 0}
    $candidates=[Collections.Generic.List[string]]::new()
    if ($Configured) {$candidates.Add($Configured)}
    foreach ($receipt in @(Get-ReleaseLiveReceipts (Read-ReleaseSharedLedger (Get-ReleasePlanSourceRepository $Settings) $StateRoot))) {
        $entry=$receipt.entry
        if ($entry -isnot [Collections.IDictionary] -or [string]$entry.version -ceq $Version) {continue}
        $commit=[string]$entry.sourceCommit
        if ($commit -cnotmatch '^[0-9a-f]{40}(?:[0-9a-f]{24})?$' -or $commit -cin $candidates) {continue}
        if (& $isAncestor $commit $Head) {$candidates.Add($commit)}
    }
    # Keep only the sources no other contains; exactly one left is the boundary.
    $newest=@()
    foreach ($commit in $candidates) {
        if (@($newest | Where-Object {& $isAncestor $commit $_}).Count) {continue}
        $newest=@(@($newest | Where-Object {-not (& $isAncestor $_ $commit)})+@($commit))
    }
    if ($newest.Count -gt 1) {return @{commit=$null;ambiguous="The previous published release is ambiguous: $($newest -join ' and ') each went live and neither contains the other. Set previousRelease in release.json to a commit containing them, from which the canonical notes should count."}}
    return @{commit=$(if ($newest.Count) {$newest[0]} else {$null});ambiguous=$null}
}

# Resolves frozen or observed channel baselines; a configured null is never replaced by a guess. A snapshot freezes the
# channels it names, such as a prepared release's own; any other selected channel is observed in the live ledger.
function Get-ReleaseDestinationBaselines($Settings, $Destinations, [string]$Head, $Snapshot, [string]$StateRoot) {
    $observed=@($Destinations | Where-Object {$_.selected -and $_.type -ne 'notes' -and ($null -eq $Snapshot -or -not $Snapshot.Contains($_.id))})
    $ledger=if ($observed.Count) {Get-ReleaseLiveLedger $Settings.repository $StateRoot} else {@{}}
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

# Lists every live receipt in a shared ledger: each row's own, and the earlier ones it keeps in 'recorded'.
function Get-ReleaseLiveReceipts($Ledger) {
    foreach ($key in @($Ledger.Keys)) {
        $row=$Ledger[$key]
        @{key=$key;entry=$row}
        if ($row -is [Collections.IDictionary] -and $row.Contains('recorded')) {
            foreach ($receipt in @($row.recorded)) {if ($receipt) {@{key=$key;entry=$receipt}}}
        }
    }
}

# Holds the game's shared ledger lock, so only one checkout at a time can check a store channel, change it and record it.
function Lock-ReleaseLiveLedger([string]$StatePath, $State) {
    $directory=Get-ReleaseLedgerDirectory (Get-ReleasePlanSourceRepository $State.plan) (Split-Path (Split-Path $StatePath -Parent) -Parent)
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    try {return Lock-ReleaseState $directory}
    catch {throw 'Another checkout of this game is publishing or confirming a release under this state root; retry once it finishes.'}
}

# Explains why sending $Destination's build from $SourceCommit would roll its store channel back, or gives $null. The
# channel's row in the shared ledger, read under the lock the caller holds, names the newest source live there; a build
# whose source does not contain it, or cannot be shown to contain it, would replace a newer release.
function Get-ReleaseChannelConflict([string]$StatePath, $State, $Destination, [string]$SourceCommit) {
    $ledger=Read-ReleaseSharedLedger (Get-ReleasePlanSourceRepository $State.plan) (Split-Path (Split-Path $StatePath -Parent) -Parent)
    $key=Get-ReleaseStoreKey $Destination
    if (-not $ledger.Contains($key)) {return $null}
    $row=$ledger[$key]
    $live=if ($row -is [Collections.IDictionary]) {[string]$row['sourceCommit']} else {''}
    if ($live -and $live -ceq $SourceCommit) {return $null}
    if ($live -cmatch '^[0-9a-f]{40}(?:[0-9a-f]{24})?$' -and (Invoke-ReleaseTool 'git' @('--no-optional-locks','-C',$State.plan.repository,'merge-base','--is-ancestor',$live,$SourceCommit) $State.plan.repository).exitCode -eq 0) {return $null}
    $version=if ($row -is [Collections.IDictionary] -and [string]$row['version'] -match '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$') {"Version $($row['version'])"} else {'A release'}
    return "$version is live on $key from a source this build's source does not contain; nothing was sent. Replacing it with this older release needs explicit reconciliation."
}

# Records live evidence in the game's shared ledger, whose lock the caller holds: for every selected channel, or only the
# destinations $Only names. Advances only channels with actual live evidence, preserving unselected and submitted channels.
# Each row keeps every receipt recorded for its channel, so a release whose receipts are replayed after a newer release went
# live on one of its channels leaves that newer row alone. Only a receipt recorded for the first time on an older or diverged
# source is refused, and only once every other channel has been saved, so retrying the step that failed repairs the rest.
function Save-ReleaseLiveReceipts([string]$StatePath, $State, [string[]]$Only=@()) {
    $sourceRepository=Get-ReleasePlanSourceRepository $State.plan
    $stateRoot=Split-Path (Split-Path $StatePath -Parent) -Parent
    $path=Join-Path (Get-ReleaseLedgerDirectory $sourceRepository $stateRoot) 'live.json'
    $ledger=Read-ReleaseSharedLedger $sourceRepository $stateRoot
    $refused=[Collections.Generic.List[string]]::new()
    foreach ($destination in $State.plan.destinations) {
        if (-not $destination.selected -or $destination.type -eq 'notes' -or ($Only.Count -and $destination.id -cnotin $Only)) {continue}
        $record=$State.destinations[$destination.id]
        if (-not $record.remote.Contains('live') -or $record.remote.live -ne $true) {continue}
        $key=Get-ReleaseStoreKey $destination
        $sourceCommit=if ($record.remote.Contains('sourceCommit') -and $record.remote.sourceCommit) {$record.remote.sourceCommit} else {$State.plan.head}
        $row=if ($ledger.Contains($key)) {$ledger[$key]} else {$null}
        if ($row -and $row.sourceCommit -cne $sourceCommit) {
            $ancestor=Invoke-ReleaseTool 'git' @('--no-optional-locks','-C',$State.plan.repository,'merge-base','--is-ancestor',$row.sourceCommit,$sourceCommit) $State.plan.repository
            if ($ancestor.exitCode -ne 0) {
                # An older release completing late must not roll a channel's baseline backwards silently; one whose
                # receipt the row already keeps is only being recorded again.
                $replayed=@(Get-ReleaseLiveReceipts ([ordered]@{$key=$row}) | Where-Object {$_.entry.sourceCommit -ceq $sourceCommit -and $_.entry.version -ceq $State.plan.version}).Count -gt 0
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
}

# Records every selected channel's live evidence in the game's shared ledger, taking its lock for the write.
function Update-ReleaseLiveLedger([string]$StatePath, $State) {
    $lock=Lock-ReleaseLiveLedger $StatePath $State
    try {Save-ReleaseLiveReceipts $StatePath $State} finally {$lock.Dispose()}
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
    # The release's own channels keep the baselines frozen with it, however far another checkout has since moved them;
    # only the added channels are observed now.
    $frozen=[ordered]@{}
    foreach ($id in $state.plan.baselines.Keys) {$frozen[$id]=$state.plan.baselines[$id]}
    $fresh=Get-ReleasePlan $settings.repository $selected $frozen $stateRoot -FrozenPrevious $state.plan.previousCommit
    Assert-ReleaseAddedBaselines $state $fresh.baselines $added
    if ($settings.configHash -cne $state.plan.configSha256) {
        $migration=Get-ReleaseConfigurationMigration $state $settings $fresh.head
        Assert-ReleaseArtifacts $StatePath $state
        Assert-ReleaseSubmittedNotes $state $StatePath
        if ($state.Contains('canonicalNotesSha256') -and $state.canonicalNotesSha256 -cne (Get-FileHash (Join-Path $StatePath 'notes.md')).Hash.ToLowerInvariant()) {throw 'Canonical notes changed after publication.'}
        # Every introduced destination is frozen with the release, selected or not, so each must be complete now.
        $adopted=@(@($selected)+@($migration.addedDestinations) | Sort-Object -Unique -CaseSensitive)
        $introduced=@($adopted | Where-Object {$_ -cnotin $state.plan.selectedDestinations})
        $observed=Get-ReleasePlan $settings.repository $adopted $frozen $stateRoot -FrozenPrevious $state.plan.previousCommit
        Assert-ReleaseAddedBaselines $state $observed.baselines $introduced
        $snapshot=[ordered]@{}
        foreach ($id in $state.plan.baselines.Keys) {$snapshot[$id]=$state.plan.baselines[$id]}
        foreach ($id in $introduced) {if ($observed.baselines.Contains($id)) {$snapshot[$id]=$observed.baselines[$id]}}
        $expanded=Get-ReleasePlan $settings.repository $adopted $snapshot $stateRoot -FrozenPrevious $state.plan.previousCommit
        if (-not $expanded.ready) {throw "Configuration migration adopts every added destination, selected or not; complete them or leave them out of the committed change. Plan is blocked: $($expanded.blockers -join ' ')"}
        # Phase one rebinds only the original selection, keeping its frozen baselines and notes boundary.
        $migrated=Get-ReleasePlan $settings.repository $state.plan.selectedDestinations $state.plan.baselines $stateRoot -FrozenPrevious $state.plan.previousCommit
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
    $observed=Get-ReleasePlan $settings.repository $selected $frozen $stateRoot -FrozenPrevious $state.plan.previousCommit
    foreach ($id in $added) {if ($observed.baselines.Contains($id)) {$snapshot[$id]=$observed.baselines[$id]}}
    $plan=Get-ReleasePlan $settings.repository $selected $snapshot -FrozenPrevious $state.plan.previousCommit
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

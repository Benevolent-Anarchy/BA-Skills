# Records every build any checkout has started sending to each store channel, live or not, refuses a build whose source
# does not contain one sent or live there, and records an explicitly authorized abandonment of a build that never went live.

# Places the game's record of store writes beside its live ledger: for each store channel, every build any checkout under
# the state root has started sending there, live or not, such as a Steam build or Play edit still awaiting console work.
function Get-ReleaseSentPath([string]$StatePath, $State) {
    return Join-Path (Get-ReleaseLedgerDirectory (Get-ReleasePlanSourceRepository $State.plan) (Split-Path (Split-Path $StatePath -Parent) -Parent)) 'sent.json'
}

# Tells whether a journal's destination record shows a store write was started: an attempt in progress, uncertain, complete
# or abandoned, or any remote progress beyond local bookkeeping, as holds also require.
function Test-ReleaseStoreWriteStarted($Record) {
    if ($Record -isnot [Collections.IDictionary]) {return $false}
    if ([string]$Record['status'] -in @('succeeded','submitted','awaiting-store-action','uncertain','in-progress','abandoned')) {return $true}
    $remote=$Record['remote']
    return ($remote -is [Collections.IDictionary] -and @($remote.Keys | Where-Object {$_ -cnotin @('sourceCommit','notesHashes')}).Count -gt 0)
}

# Names the source a destination record sent its build from: its recorded provenance, else its release's source.
function Get-ReleaseRecordSource($Plan, $Record) {
    $remote=$Record['remote']
    if ($remote -is [Collections.IDictionary] -and $remote['sourceCommit']) {return [string]$remote['sourceCommit']}
    return [string]$Plan['head']
}

# Names the game a journal belongs to, by the GitHub repository its notes repository names, or gives $null where the
# journal cannot be read as a release plan.
function Get-ReleaseJournalGame($Journal) {
    if ($Journal -isnot [Collections.IDictionary] -or $Journal['plan'] -isnot [Collections.IDictionary]) {return $null}
    $notes=[string]$Journal['plan']['notesRepository']
    if ($notes -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+-release-notes$') {return $null}
    return ($notes -replace '-release-notes$','').ToLowerInvariant()
}

# Builds a game's first record of store writes from every journal under the state root. Releases published before the
# record existed may already have sent builds that are not live, such as a Steam build awaiting activation or a Play edit
# in review. A journal that cannot be read stops this, naming it, rather than being read as proof that nothing was sent,
# unless the other journals of its checkout show the checkout belongs to another game.
function Get-ReleaseSentSeed([string]$StatePath, $State) {
    $root=Split-Path (Split-Path $StatePath -Parent) -Parent
    $game=(Get-ReleasePlanSourceRepository $State.plan).ToLowerInvariant()
    $seededAt=[DateTimeOffset]::UtcNow.ToString('o')
    $sent=[ordered]@{}
    foreach ($checkout in @(Get-ChildItem -LiteralPath $root -Directory -Force | Where-Object {$_.Name -cne 'repositories'} | Sort-Object Name -CaseSensitive)) {
        $journals=@(foreach ($folder in @(Get-ChildItem -LiteralPath $checkout.FullName -Directory -Force | Sort-Object Name -CaseSensitive)) {
            $path=Join-Path $folder.FullName 'state.json'
            if (Test-Path -LiteralPath $path -PathType Leaf) {@{path=$path;state=(Read-ReleaseStateObject $path)}}
        })
        $games=@($journals | ForEach-Object {Get-ReleaseJournalGame $_.state} | Where-Object {$_})
        foreach ($journal in $journals) {
            $journalGame=Get-ReleaseJournalGame $journal.state
            if (-not $journalGame) {
                if ($games.Count -and $game -cnotin $games) {continue}
                throw (New-ReleaseDamagedStateError $root $journal.path)
            }
            if ($journalGame -cne $game) {continue}
            $plan=$journal.state['plan']
            $records=$journal.state['destinations']
            foreach ($destination in @($plan['destinations'])) {
                if ($destination -isnot [Collections.IDictionary] -or $destination['selected'] -ne $true -or $destination['type'] -notin @('itch','steam','google-play')) {continue}
                $record=if ($records -is [Collections.IDictionary]) {$records[[string]$destination['id']]} else {$null}
                if (-not (Test-ReleaseStoreWriteStarted $record)) {continue}
                $key=Get-ReleaseStoreKey $destination
                $entry=[ordered]@{sourceCommit=(Get-ReleaseRecordSource $plan $record);version=[string]$plan['version'];statePath=(Split-Path $journal.path -Parent);destination=[string]$destination['id'];seededAt=$seededAt}
                if ($record['remote'] -is [Collections.IDictionary] -and $record['remote']['abandonment']) {$entry.abandoned=$record['remote']['abandonment']}
                $sent[$key]=@(if ($sent.Contains($key)) {$sent[$key]})+@($entry)
            }
        }
    }
    return $sent
}

# Writes a game's first record of store writes, seeded from every journal under the state root, under the ledger lock the
# caller holds. An existing record is left as it is.
function Initialize-ReleaseSentRecord([string]$StatePath, $State) {
    $path=Get-ReleaseSentPath $StatePath $State
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {Write-ReleaseJson $path (Get-ReleaseSentSeed $StatePath $State)}
}

# Reads the game's record of store writes, whose ledger lock the caller holds; one not written yet is seeded from the
# journals. A damaged record stops, naming the file, rather than being read as proof that nothing was sent.
function Read-ReleaseSentRecord([string]$StatePath, $State) {
    $path=Get-ReleaseSentPath $StatePath $State
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {return (Get-ReleaseSentSeed $StatePath $State)}
    $sent=Read-ReleaseStateObject $path
    if ($null -eq $sent) {throw (New-ReleaseDamagedStateError (Split-Path (Split-Path $StatePath -Parent) -Parent) $path)}
    return $sent
}

# Records, under the ledger lock the caller holds, that this release sends or has sent $Destination's build from
# $SourceCommit to its channel. Gives whether this call added the entry, so an attempt that never reached the store can
# take it back.
function Add-ReleaseSentReceipt([string]$StatePath, $State, $Destination, [string]$SourceCommit) {
    $sent=Read-ReleaseSentRecord $StatePath $State
    $key=Get-ReleaseStoreKey $Destination
    $entries=@(if ($sent.Contains($key)) {$sent[$key]})
    if (@($entries | Where-Object {$_ -is [Collections.IDictionary] -and $_['sourceCommit'] -ceq $SourceCommit -and $_['version'] -ceq $State.plan.version}).Count) {return $false}
    $sent[$key]=@($entries)+@([ordered]@{sourceCommit=$SourceCommit;version=$State.plan.version;statePath=$StatePath;destination=$Destination.id;sentAt=[DateTimeOffset]::UtcNow.ToString('o')})
    Write-ReleaseJson (Get-ReleaseSentPath $StatePath $State) $sent
    return $true
}

# Takes back the entry Add-ReleaseSentReceipt added for an attempt that failed before reaching the store.
function Remove-ReleaseSentReceipt([string]$StatePath, $State, $Destination, [string]$SourceCommit) {
    $sent=Read-ReleaseSentRecord $StatePath $State
    $key=Get-ReleaseStoreKey $Destination
    if (-not $sent.Contains($key)) {return}
    $sent[$key]=@(@($sent[$key]) | Where-Object {-not ($_ -is [Collections.IDictionary] -and $_['sourceCommit'] -ceq $SourceCommit -and $_['version'] -ceq $State.plan.version)})
    if (-not $sent[$key].Count) {$sent.Remove($key)}
    Write-ReleaseJson (Get-ReleaseSentPath $StatePath $State) $sent
}

# Explains why sending $Destination's build from $SourceCommit would roll its store channel back, or gives $null. Read under
# the lock the caller holds, the channel's row in the shared ledger names the newest source live there, and the record of
# store writes every build sent there, live or not, other than one recorded abandoned; a build whose source does not
# contain one of them, or cannot be shown to contain it, would replace a newer release.
function Get-ReleaseChannelConflict([string]$StatePath, $State, $Destination, [string]$SourceCommit) {
    $key=Get-ReleaseStoreKey $Destination
    $ledger=Read-ReleaseSharedLedger (Get-ReleasePlanSourceRepository $State.plan) (Split-Path (Split-Path $StatePath -Parent) -Parent)
    $sent=Read-ReleaseSentRecord $StatePath $State
    $newer=@(
        if ($ledger.Contains($key)) {@{entry=$ledger[$key];reached='is live on';remedy='needs explicit reconciliation'}}
        if ($sent.Contains($key)) {foreach ($entry in @($sent[$key])) {
            if ($entry -is [Collections.IDictionary] -and $entry['abandoned']) {continue}
            @{entry=$entry;reached='has been sent to';remedy="needs explicit reconciliation: if that build was abandoned without going live, record it with abandon from the release state that sent it"}
        }}
    )
    foreach ($candidate in $newer) {
        $entry=$candidate.entry
        $commit=if ($entry -is [Collections.IDictionary]) {[string]$entry['sourceCommit']} else {''}
        if ($commit -and $commit -ceq $SourceCommit) {continue}
        if ($commit -cmatch '^[0-9a-f]{40}(?:[0-9a-f]{24})?$' -and (Invoke-ReleaseTool 'git' @('--no-optional-locks','-C',$State.plan.repository,'merge-base','--is-ancestor',$commit,$SourceCommit) $State.plan.repository).exitCode -eq 0) {continue}
        $version=if ($entry -is [Collections.IDictionary] -and [string]$entry['version'] -match '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$') {"Version $($entry['version'])"} else {'A release'}
        return "$version $($candidate.reached) $key from a source this build's source does not contain; this build was not sent. Replacing it $($candidate.remedy)."
    }
    return $null
}

# Records, with the user's explicit authorization, that a build this release sent to a store channel was abandoned without
# going live, as an observed receipt shows. The destination becomes 'abandoned', keeping its attempts and remote evidence,
# and its entries in the record of store writes are marked rather than removed, so a release whose source does not contain
# that build can be sent there. Repeating it repairs a record interrupted after the journal was saved. Never calls a store.
function Confirm-ReleaseAbandonment([string]$StatePath, [string]$ReceiptPath, [switch]$Authorized) {
    $StatePath=(Get-Item -LiteralPath $StatePath).FullName
    $lock=Lock-ReleaseState $StatePath
    $ledgerLock=$null
    try {
        $stateFile=Join-Path $StatePath 'state.json'
        $state=[IO.File]::ReadAllText($stateFile) | ConvertFrom-Json -AsHashtable
        $receipt=Read-ReleaseObservedReceipt $ReceiptPath
        $common=@('destination','planId','observedAt','live','evidenceUrl')
        Assert-ReleaseFields $receipt ($common+@('appId','buildId','branch','packageName','versionCode','track','target')) $common 'abandonment receipt'
        $destinations=@($state.plan.destinations | Where-Object {$_.id -ceq $receipt.destination -and $_.selected -and $_.type -in @('itch','steam','google-play')})
        if ($destinations.Count -ne 1) {throw 'Receipt must identify one selected store destination.'}
        $destination=$destinations[0];$record=$state.destinations[$destination.id]
        if ($record.status -notin @('awaiting-store-action','submitted','uncertain','in-progress','failed','abandoned') -or -not (Test-ReleaseStoreWriteStarted $record) -or ($record.remote.Contains('live') -and $record.remote.live)) {throw 'Abandonment requires a store write this release started that never went live; a live release is replaced only by a newer one.'}
        if (-not $state.approval -or $receipt.planId -cne $state.plan.planId -or $state.approval.planId -cne $state.plan.planId) {throw 'Receipt requires the approved plan of the release that sent the build.'}
        $observed=[DateTimeOffset]::MinValue
        if ($receipt.observedAt -isnot [string] -or $receipt.observedAt -notmatch '(Z|[+-]\d{2}:\d{2})$' -or -not [DateTimeOffset]::TryParse($receipt.observedAt,[ref]$observed) -or $observed -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {throw 'observedAt must be the actual observation timestamp with timezone, not a future time.'}
        if ($receipt.live -isnot [bool] -or $receipt.live -ne $false) {throw 'The abandoned build must have been explicitly observed not live.'}
        if ($destination.type -eq 'steam') {
            Assert-ReleaseFields $receipt ($common+@('appId','buildId','branch')) ($common+@('appId','buildId','branch')) 'Steam abandonment receipt'
            if (($receipt.appId -isnot [long] -and $receipt.appId -isnot [int]) -or $receipt.appId -ne $destination.appId -or $receipt.branch -cne $destination.branch) {throw 'Receipt app and branch differ from the approved Steam destination.'}
            $recorded=if ($record.remote.Contains('buildId')) {[string]$record.remote.buildId} else {$null}
            if ($receipt.buildId -cne $recorded) {throw 'Receipt buildId must be the recorded Steam build, or null when no build was recorded.'}
            if ($receipt.evidenceUrl -isnot [string] -or $receipt.evidenceUrl -notmatch "^https://partner\.steamgames\.com/apps/builds/$([regex]::Escape([string]$destination.appId))/?$") {throw 'Receipt evidenceUrl must be the inspected Steamworks builds page.'}
        } elseif ($destination.type -eq 'google-play') {
            Assert-ReleaseFields $receipt ($common+@('packageName','versionCode','track')) ($common+@('packageName','versionCode','track')) 'Play abandonment receipt'
            if ($receipt.packageName -cne $destination.packageName -or ($receipt.versionCode -isnot [long] -and $receipt.versionCode -isnot [int]) -or $receipt.versionCode -ne $destination.versionCode -or $receipt.track -cne $destination.track) {throw 'Receipt package, version code and track must be the approved Play release.'}
            if ($receipt.evidenceUrl -isnot [string] -or $receipt.evidenceUrl -notmatch '^https://play\.google\.com/console(?:[/?][^\s]*)?$') {throw 'Receipt evidenceUrl must identify the observed Play Console page.'}
        } else {
            Assert-ReleaseFields $receipt ($common+@('target')) ($common+@('target')) 'itch abandonment receipt'
            $game=$destination.target.Split(':')[0].Split('/')
            if ($receipt.target -cne $destination.target -or $receipt.evidenceUrl -cne "https://$($game[0]).itch.io/$($game[1])") {throw 'Itch receipt requires the approved target and its inspected game page.'}
        }
        $key=Get-ReleaseStoreKey $destination
        if (-not $Authorized) {throw "Abandoning this build lets a release whose source does not contain it be sent to $key. Repeat with -AbandonAuthorized only once the user has explicitly authorized that; nothing was recorded."}
        if ($record.status -ne 'abandoned') {
            $record.remote.abandonment=[ordered]@{receipt=$receipt;authorizedAt=[DateTimeOffset]::UtcNow.ToString('o')}
            $record.status='abandoned';$record.error=$null
            $state.status=Get-ReleaseOverallStatus $state
            Write-ReleaseJson $stateFile $state
        }
        $ledgerLock=Lock-ReleaseLiveLedger $StatePath $state
        Initialize-ReleaseSentRecord $StatePath $state
        $sent=Read-ReleaseSentRecord $StatePath $state
        $source=Get-ReleaseRecordSource $state.plan $record
        $entries=@(if ($sent.Contains($key)) {$sent[$key]})
        $own=@($entries | Where-Object {$_ -is [Collections.IDictionary] -and $_['sourceCommit'] -ceq $source -and $_['version'] -ceq $state.plan.version})
        if (-not $own.Count) {
            $own=@([ordered]@{sourceCommit=$source;version=$state.plan.version;statePath=$StatePath;destination=$destination.id;sentAt=$null})
            $entries+=$own
        }
        foreach ($entry in $own) {$entry['abandoned']=$record.remote.abandonment}
        $sent[$key]=$entries
        Write-ReleaseJson (Get-ReleaseSentPath $StatePath $state) $sent
        return @{status=$state.status;statePath=$StatePath;version=$state.plan.version;destinations=$state.destinations}
    } finally {if ($ledgerLock) {$ledgerLock.Dispose()};$lock.Dispose()}
}

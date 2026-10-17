# Verifies that every checkout of a game shares one live ledger, and that ledgers kept per checkout before it are still read.

# Writes a live ledger as a checkout at $Checkout kept it before ledgers were shared: under the hash of its path, beside a state naming its game's notes repository.
function Write-LegacyLiveLedger([string]$StateRoot, [string]$Checkout, [string]$NotesRepository, [string]$Version, [string]$Commit) {
    $id=& (Get-Module Release) {param($path) (Get-ReleaseTextHash $path).Substring(0,20)} $Checkout
    $folder=Join-Path $StateRoot $id
    New-Item -ItemType Directory -Path (Join-Path $folder $Version) -Force | Out-Null
    Write-Json (Join-Path $folder "$Version/state.json") @{plan=@{notesRepository=$NotesRepository;version=$Version}}
    Write-Json (Join-Path $folder 'live.json') @{'itch:example/real-game:windows'=@{sourceCommit=$Commit;version=$Version;destination='itch-windows';statePath=(Join-Path $folder $Version)}}
}

# Prepares only the notes of the release prepared at $StorePath, in a new worktree named $Name at that release's current
# source, with the same canonical notes, and returns the notes-only state's path.
function New-NotesCheckout([string]$Repo, [string]$StateRoot, [string]$StorePath, [string]$Name) {
    $storeState=Get-Content (Join-Path $StorePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    $worktree=Join-Path $sandbox $Name
    Invoke-FixtureGit $Repo @('worktree','add','--quiet','--detach',$worktree,$storeState.plan.head) | Out-Null
    $notes=Invoke-ReleasePrepare $worktree @('notes') $StateRoot
    Copy-Item (Join-Path $StorePath 'notes.md') (Join-Path $notes.statePath 'notes.md') -Force
    return $notes.statePath
}

# Approves and publishes the notes-only state at $NotesPath, and returns the result and the availability record it left.
function Publish-NotesCheckout([string]$NotesPath) {
    $notesState=Get-Content (Join-Path $NotesPath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    $result=Invoke-ReleasePublish -StatePath $NotesPath -GhExecutable $gh -ApprovedPlanId $notesState.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $NotesPath $notesState.plan)
    return @{result=$result;availability=(Get-Content ($env:BA_FIXTURE_NOTE_STORE+'.availability') -Raw)}
}

# Publishes only the notes of the release prepared at $StorePath from a new worktree named $Name, as the two steps above do.
function Publish-NotesFromAnotherCheckout([string]$Repo, [string]$StateRoot, [string]$StorePath, [string]$Name) {
    return Publish-NotesCheckout (New-NotesCheckout $Repo $StateRoot $StorePath $Name)
}

Test 'a worktree or clone of a game plans from the baselines another checkout published' {
    $repo=New-Fixture 'shared-ledger'
    $stateRoot=Join-Path $sandbox 'shared-ledger-state'
    $prepared=Invoke-ReleasePrepare $repo @('itch-windows') $stateRoot $engine
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan) | Out-Null
    $released=$state.plan.head
    # The publishing checkout's own folder is gone, so only a ledger kept for the game can still say what shipped.
    Remove-Item -LiteralPath (Join-Path (Split-Path $prepared.statePath -Parent) 'live.json') -ErrorAction SilentlyContinue
    $worktree=Join-Path $sandbox 'shared-ledger-worktree'
    Invoke-FixtureGit $repo @('worktree','add','--quiet','--detach',$worktree,$released) | Out-Null
    $clone=Join-Path $sandbox 'shared-ledger-clone'
    Invoke-FixtureGit $sandbox @('clone','--quiet',$repo,$clone) | Out-Null
    Invoke-FixtureGit $clone @('remote','set-url','origin','git@github.com:example/real-game.git') | Out-Null
    foreach ($checkout in @($worktree,$clone)) {
        $plan=Get-ReleasePlan -Repository $checkout -Destination @('itch-windows') -StateRoot $stateRoot
        Assert ($plan.baselines['itch-windows'] -ceq $released) "A second checkout fell back to release.json instead of the published baseline: $checkout"
    }
}
Test 'ledgers kept per checkout before sharing are read alongside, for this game only, latest first' {
    $repo=New-Fixture 'legacy-ledgers'
    $stateRoot=Join-Path $sandbox 'legacy-ledgers-state'
    $older=Invoke-FixtureGit $repo @('rev-parse','v1.2.2')
    $newer=Invoke-FixtureGit $repo @('rev-parse','HEAD')
    'later work' | Set-Content (Join-Path $repo 'later.txt')
    Invoke-FixtureGit $repo @('add','later.txt') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Later work') | Out-Null
    $later=Invoke-FixtureGit $repo @('rev-parse','HEAD')
    Write-LegacyLiveLedger $stateRoot 'C:\old\checkout-one' 'Example/Real-Game-release-notes' '1.2.2' $older
    Write-LegacyLiveLedger $stateRoot 'C:\old\checkout-two' 'example/real-game-release-notes' '1.2.3' $newer
    Write-LegacyLiveLedger $stateRoot 'C:\old\another-game' 'Example/Other-Game-release-notes' '9.0.0' $later
    $plan=Get-ReleasePlan -Repository $repo -Destination @('itch-windows') -StateRoot $stateRoot
    Assert ($plan.baselines['itch-windows'] -ceq $newer) "Older per-checkout ledgers were not read, or another game's was: $($plan.baselines['itch-windows'])"
}
Test 'live records from two checkouts that disagree are refused rather than guessed between' {
    $repo=New-Fixture 'diverged-ledgers'
    $stateRoot=Join-Path $sandbox 'diverged-ledgers-state'
    $shipped=Invoke-FixtureGit $repo @('rev-parse','HEAD')
    Invoke-FixtureGit $repo @('switch','--quiet','-c','side','v1.2.2') | Out-Null
    'side work' | Set-Content (Join-Path $repo 'side.txt')
    Invoke-FixtureGit $repo @('add','side.txt') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Side work') | Out-Null
    $side=Invoke-FixtureGit $repo @('rev-parse','HEAD')
    Invoke-FixtureGit $repo @('switch','--quiet','main') | Out-Null
    Write-LegacyLiveLedger $stateRoot 'C:\old\main-checkout' 'Example/Real-Game-release-notes' '1.2.3' $shipped
    Write-LegacyLiveLedger $stateRoot 'C:\old\side-checkout' 'Example/Real-Game-release-notes' '1.2.3' $side
    Expect-Error {Get-ReleasePlan -Repository $repo -Destination @('itch-windows') -StateRoot $stateRoot} 'disagree'
    # Only the channel whose records disagree is stopped; another channel still plans.
    $plan=Get-ReleasePlan -Repository $repo -Destination @('itch-linux') -StateRoot $stateRoot
    Assert ($plan.baselines['itch-linux'] -ceq (Invoke-FixtureGit $repo @('rev-parse','v1.2.2'))) 'Disagreeing records on one channel stopped planning another.'
}
Test 'an older release extends to a new channel after another checkout shipped newer on its existing one' {
    $repo=New-StoreFixture 'staggered-extension'
    $stateRoot=Join-Path $sandbox 'staggered-extension-state'
    $env:BA_STEAM_USERNAME='fixture'
    try {
        $older=Invoke-ReleasePrepare $repo @('itch-windows') $stateRoot $engine
        $olderState=Get-Content (Join-Path $older.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        Invoke-ReleasePublish -StatePath $older.statePath -ButlerExecutable $butler -ApprovedPlanId $olderState.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $older.statePath $olderState.plan) | Out-Null
        $worktree=Join-Path $sandbox 'staggered-extension-newer'
        Invoke-FixtureGit $repo @('worktree','add','--quiet','-b','newer',$worktree) | Out-Null
        'newer work' | Set-Content (Join-Path $worktree 'newer.txt')
        Invoke-FixtureGit $worktree @('add','newer.txt') | Out-Null
        Invoke-FixtureGit $worktree @('commit','--quiet','-m','Newer work') | Out-Null
        Invoke-ReleasePrepare $worktree @('itch-windows','steam') $stateRoot $engine -VersionChange patch | Out-Null
        Invoke-FixtureGit $worktree @('add','project.godot') | Out-Null
        Invoke-FixtureGit $worktree @('commit','--quiet','-m','Reserve the newer version') | Out-Null
        $newer=Invoke-ReleasePrepare $worktree @('itch-windows','steam') $stateRoot $engine -VersionChange patch
        $newerState=Get-Content (Join-Path $newer.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        $newerNotes=Get-ReleaseNotesHash $newer.statePath $newerState.plan
        Invoke-ReleasePublish -StatePath $newer.statePath -ButlerExecutable $butler -SteamCmdExecutable $steam -ApprovedPlanId $newerState.plan.planId -ApprovedNotesSha256 $newerNotes | Out-Null
        $receipt=Join-Path $newer.statePath 'steam-observation.json'
        Write-Json $receipt @{destination='steam';planId=$newerState.plan.planId;notesSha256=$newerNotes;observedAt=[DateTimeOffset]::UtcNow.ToString('o');live=$true;appId=100;buildId='999';branch='default';announcementUrl='https://store.steampowered.com/news/app/100/view/555'}
        Confirm-ReleaseStoreCompletion $newer.statePath $receipt | Out-Null
        # Steam already has the newer release, so the older one cannot catch it up; Linux has never shipped, so it can.
        Expect-Error {Expand-ReleaseDestinations $older.statePath @('steam') $engine} 'ancestor|precede'
        $extended=Expand-ReleaseDestinations $older.statePath @('itch-linux') $engine
        $state=Get-Content (Join-Path $older.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert ($extended.status -eq 'prepared') "Extending the older release to Linux did not prepare: $($extended.status)"
        Assert ($state.plan.baselines['itch-windows'] -ceq $olderState.plan.baselines['itch-windows'] -and $state.plan.baselines['itch-linux'] -ceq (Invoke-FixtureGit $repo @('rev-parse','v1.2.2'))) 'Extension did not keep frozen baselines and observe only the added channel.'
    } finally {Remove-Item Env:BA_STEAM_USERNAME}
}
Test 'confirming an older release records its channel and keeps the newer release another checkout published' {
    $repo=New-StoreFixture 'older-confirmation'
    $stateRoot=Join-Path $sandbox 'older-confirmation-state'
    $env:BA_STEAM_USERNAME='fixture'
    try {
        $older=Invoke-ReleasePrepare $repo @('itch-windows','steam') $stateRoot $engine
        $olderState=Get-Content (Join-Path $older.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        $olderNotes=Get-ReleaseNotesHash $older.statePath $olderState.plan
        Invoke-ReleasePublish -StatePath $older.statePath -ButlerExecutable $butler -SteamCmdExecutable $steam -ApprovedPlanId $olderState.plan.planId -ApprovedNotesSha256 $olderNotes | Out-Null
        $worktree=Join-Path $sandbox 'older-confirmation-newer'
        Invoke-FixtureGit $repo @('worktree','add','--quiet','-b','newer',$worktree) | Out-Null
        'newer work' | Set-Content (Join-Path $worktree 'newer.txt')
        Invoke-FixtureGit $worktree @('add','newer.txt') | Out-Null
        Invoke-FixtureGit $worktree @('commit','--quiet','-m','Newer work') | Out-Null
        Invoke-ReleasePrepare $worktree @('itch-windows') $stateRoot $engine -VersionChange patch | Out-Null
        Invoke-FixtureGit $worktree @('add','project.godot') | Out-Null
        Invoke-FixtureGit $worktree @('commit','--quiet','-m','Reserve the newer version') | Out-Null
        $newer=Invoke-ReleasePrepare $worktree @('itch-windows') $stateRoot $engine -VersionChange patch
        $newerState=Get-Content (Join-Path $newer.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        Invoke-ReleasePublish -StatePath $newer.statePath -ButlerExecutable $butler -ApprovedPlanId $newerState.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $newer.statePath $newerState.plan) | Out-Null
        $receipt=Join-Path $older.statePath 'steam-observation.json'
        Write-Json $receipt @{destination='steam';planId=$olderState.plan.planId;notesSha256=$olderNotes;observedAt=[DateTimeOffset]::UtcNow.ToString('o');live=$true;appId=100;buildId='999';branch='default';announcementUrl='https://store.steampowered.com/news/app/100/view/555'}
        Confirm-ReleaseStoreCompletion $older.statePath $receipt | Out-Null
        $ledger=Get-ReleaseLiveLedger $repo $stateRoot
        Assert ($ledger['steam:100:default'].sourceCommit -ceq $olderState.plan.head) "The older release's confirmed Steam build was not recorded."
        Assert ($ledger['itch:example/real-game:windows'].sourceCommit -ceq $newerState.plan.head) 'Replaying the older release rolled back the newer itch release.'
        # A ledger write interrupted after the confirmation was saved leaves Steam out; confirming again records it.
        $shared=Join-Path (& (Get-Module Release) {param($root) Get-ReleaseLedgerDirectory 'Example/Real-Game' $root} $stateRoot) 'live.json'
        $rows=Get-Content $shared -Raw | ConvertFrom-Json -AsHashtable
        $rows.Remove('steam:100:default')
        Write-Json $shared $rows
        Confirm-ReleaseStoreCompletion $older.statePath $receipt | Out-Null
        $ledger=Get-ReleaseLiveLedger $repo $stateRoot
        Assert ($ledger['steam:100:default'].sourceCommit -ceq $olderState.plan.head -and $ledger['itch:example/real-game:windows'].sourceCommit -ceq $newerState.plan.head) 'Confirming again did not repair the interrupted ledger write.'
    } finally {Remove-Item Env:BA_STEAM_USERNAME}
}
Test 'an older release going live for the first time after a newer one is refused, keeping the newer row' {
    $repo=New-StoreFixture 'late-older-steam'
    $stateRoot=Join-Path $sandbox 'late-older-steam-state'
    $steamReceipt={param($statePath, $state, $notes) $path=Join-Path $statePath 'steam-observation.json'
        Write-Json $path @{destination='steam';planId=$state.plan.planId;notesSha256=$notes;observedAt=[DateTimeOffset]::UtcNow.ToString('o');live=$true;appId=100;buildId='999';branch='default';announcementUrl='https://store.steampowered.com/news/app/100/view/555'}
        $path}
    $env:BA_STEAM_USERNAME='fixture'
    try {
        $older=Invoke-ReleasePrepare $repo @('steam') $stateRoot $engine
        $olderState=Get-Content (Join-Path $older.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        $olderNotes=Get-ReleaseNotesHash $older.statePath $olderState.plan
        Invoke-ReleasePublish -StatePath $older.statePath -SteamCmdExecutable $steam -ApprovedPlanId $olderState.plan.planId -ApprovedNotesSha256 $olderNotes | Out-Null
        $worktree=Join-Path $sandbox 'late-older-steam-newer'
        Invoke-FixtureGit $repo @('worktree','add','--quiet','-b','newer',$worktree) | Out-Null
        'newer work' | Set-Content (Join-Path $worktree 'newer.txt')
        Invoke-FixtureGit $worktree @('add','newer.txt') | Out-Null
        Invoke-FixtureGit $worktree @('commit','--quiet','-m','Newer work') | Out-Null
        Invoke-ReleasePrepare $worktree @('steam') $stateRoot $engine -VersionChange patch | Out-Null
        Invoke-FixtureGit $worktree @('add','project.godot') | Out-Null
        Invoke-FixtureGit $worktree @('commit','--quiet','-m','Reserve the newer version') | Out-Null
        $newer=Invoke-ReleasePrepare $worktree @('steam') $stateRoot $engine -VersionChange patch
        $newerState=Get-Content (Join-Path $newer.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        $newerNotes=Get-ReleaseNotesHash $newer.statePath $newerState.plan
        Invoke-ReleasePublish -StatePath $newer.statePath -SteamCmdExecutable $steam -ApprovedPlanId $newerState.plan.planId -ApprovedNotesSha256 $newerNotes | Out-Null
        Confirm-ReleaseStoreCompletion $newer.statePath (& $steamReceipt $newer.statePath $newerState $newerNotes) | Out-Null
        $olderReceipt=& $steamReceipt $older.statePath $olderState $olderNotes
        Expect-Error {Confirm-ReleaseStoreCompletion $older.statePath $olderReceipt} 'reconciliation'
        Expect-Error {Confirm-ReleaseStoreCompletion $older.statePath $olderReceipt} 'reconciliation'
        $ledger=Get-ReleaseLiveLedger $repo $stateRoot
        Assert ($ledger['steam:100:default'].sourceCommit -ceq $newerState.plan.head) 'A late older Steam build silently replaced the newer live baseline.'
    } finally {Remove-Item Env:BA_STEAM_USERNAME}
}
Test 'a notes-only release in another checkout reports the stores the first checkout made live' {
    $repo=New-Fixture 'shared-availability'
    $stateRoot=Join-Path $sandbox 'shared-availability-state'
    $env:BA_FIXTURE_NOTE_STORE=Join-Path $sandbox 'shared-availability-note.md'
    try {
        $store=Invoke-ReleasePrepare $repo @('itch-windows','notes') $stateRoot $engine
        $storeState=Get-Content (Join-Path $store.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        Invoke-ReleasePublish -StatePath $store.statePath -ButlerExecutable $butler -GhExecutable $gh -ApprovedPlanId $storeState.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $store.statePath $storeState.plan) | Out-Null
        $written=Get-Content ($env:BA_FIXTURE_NOTE_STORE+'.availability') -Raw
        Assert (($written | ConvertFrom-Json -AsHashtable).destinations['itch-windows'].live -eq $true) 'The publishing checkout did not record itch as live.'
        $notes=Publish-NotesFromAnotherCheckout $repo $stateRoot $store.statePath 'shared-availability-notes'
        Assert ($notes.result.destinations.notes.status -eq 'succeeded') "Notes did not ship on the first checkout's live record: $($notes.result.destinations.notes.status)"
        Assert ($notes.availability -ceq $written) "The notes-only checkout rewrote availability: $($notes.availability)"
    } finally {Remove-Item Env:BA_FIXTURE_NOTE_STORE}
}
Test 'a notes-only checkout keeps availability for stores still awaiting console work' {
    $repo=New-StoreFixture 'pending-availability'
    $stateRoot=Join-Path $sandbox 'pending-availability-state'
    $env:BA_FIXTURE_NOTE_STORE=Join-Path $sandbox 'pending-availability-note.md'
    $env:BA_STEAM_USERNAME='fixture'
    try {
        $store=Invoke-ReleasePrepare $repo @('itch-windows','steam','notes') $stateRoot $engine
        $storeState=Get-Content (Join-Path $store.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        Invoke-ReleasePublish -StatePath $store.statePath -ButlerExecutable $butler -SteamCmdExecutable $steam -GhExecutable $gh -ApprovedPlanId $storeState.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $store.statePath $storeState.plan) | Out-Null
        $written=Get-Content ($env:BA_FIXTURE_NOTE_STORE+'.availability') -Raw
        $steamRow=($written | ConvertFrom-Json -AsHashtable).destinations.steam
        Assert ($steamRow.status -eq 'awaiting-store-action' -and $steamRow.selected -and $steamRow.buildId -eq '999') "The publishing checkout did not record Steam's pending work: $($steamRow | ConvertTo-Json -Compress)"
        $notes=Publish-NotesFromAnotherCheckout $repo $stateRoot $store.statePath 'pending-availability-notes'
        Assert ($notes.availability -ceq $written) "The notes-only checkout rewrote pending Steam work: $($notes.availability)"
    } finally {Remove-Item Env:BA_FIXTURE_NOTE_STORE;Remove-Item Env:BA_STEAM_USERNAME}
}
Test 'a notes-only checkout keeps availability for an extended release whose channels have different sources' {
    $repo=New-StoreFixture 'extended-availability';Add-FixtureApk $repo
    $stateRoot=Join-Path $sandbox 'extended-availability-state'
    $env:BA_FIXTURE_NOTE_STORE=Join-Path $sandbox 'extended-availability-note.md'
    try {
        $store=Invoke-ReleasePrepare $repo @('itch-windows','notes') $stateRoot $engine
        $state=Get-Content (Join-Path $store.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        Invoke-ReleasePublish -StatePath $store.statePath -ButlerExecutable $butler -GhExecutable $gh -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $store.statePath $state.plan) | Out-Null
        Expand-ReleaseDestinations $store.statePath @('itch-android') $engine | Out-Null
        Invoke-FixtureGit $repo @('add','export_presets.cfg') | Out-Null
        Invoke-FixtureGit $repo @('commit','--quiet','-m','Reserve the APK counter') | Out-Null
        Expand-ReleaseDestinations $store.statePath @('itch-android') $engine | Out-Null
        $state=Get-Content (Join-Path $store.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        Invoke-ReleasePublish -StatePath $store.statePath -ButlerExecutable $butler -GhExecutable $gh -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $store.statePath $state.plan) | Out-Null
        $written=Get-Content ($env:BA_FIXTURE_NOTE_STORE+'.availability') -Raw
        $rows=($written | ConvertFrom-Json -AsHashtable).destinations
        Assert ($rows['itch-windows'].live -eq $true -and $rows['itch-android'].live -eq $true) "The extended release did not record both channels live: $written"
        $windows=@($state.artifacts | Where-Object {$_.preset -ceq 'Windows existing'})[0].sourceCommit
        Assert ($windows -cne $state.plan.head) 'The fixture did not keep Windows at an older source than the extended release.'
        $notes=Publish-NotesFromAnotherCheckout $repo $stateRoot $store.statePath 'extended-availability-notes'
        Assert ($notes.availability -ceq $written) "The notes-only checkout dropped the Windows build kept from the original source: $($notes.availability)"
    } finally {Remove-Item Env:BA_FIXTURE_NOTE_STORE}
}
Test 'a notes-only checkout from before the release was extended refuses to rewrite its availability' {
    $repo=New-StoreFixture 'superseded-notes';Add-FixtureApk $repo
    $stateRoot=Join-Path $sandbox 'superseded-notes-state'
    $env:BA_FIXTURE_NOTE_STORE=Join-Path $sandbox 'superseded-notes-note.md'
    try {
        $store=Invoke-ReleasePrepare $repo @('itch-windows','notes') $stateRoot $engine
        $state=Get-Content (Join-Path $store.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        Invoke-ReleasePublish -StatePath $store.statePath -ButlerExecutable $butler -GhExecutable $gh -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $store.statePath $state.plan) | Out-Null
        # One notes-only checkout publishes before the extension, another is only prepared before it.
        $published=Publish-NotesFromAnotherCheckout $repo $stateRoot $store.statePath 'superseded-notes-published'
        Assert ($published.result.destinations.notes.status -eq 'succeeded') 'The notes-only checkout did not publish before the extension.'
        $waiting=New-NotesCheckout $repo $stateRoot $store.statePath 'superseded-notes-waiting'
        Expand-ReleaseDestinations $store.statePath @('itch-android') $engine | Out-Null
        Invoke-FixtureGit $repo @('add','export_presets.cfg') | Out-Null
        Invoke-FixtureGit $repo @('commit','--quiet','-m','Reserve the APK counter') | Out-Null
        Expand-ReleaseDestinations $store.statePath @('itch-android') $engine | Out-Null
        $state=Get-Content (Join-Path $store.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        Invoke-ReleasePublish -StatePath $store.statePath -ButlerExecutable $butler -GhExecutable $gh -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $store.statePath $state.plan) | Out-Null
        $written=Get-Content ($env:BA_FIXTURE_NOTE_STORE+'.availability') -Raw
        Assert (($written | ConvertFrom-Json -AsHashtable).sourceCommit -ceq $state.plan.head) 'The extended release did not record its own source.'
        $retry=Invoke-ReleasePublish -StatePath $published.result.statePath -GhExecutable $gh
        Assert ((Get-Content ($env:BA_FIXTURE_NOTE_STORE+'.availability') -Raw) -ceq $written) 'Retrying a notes-only checkout from before the extension rewrote its availability.'
        Assert ($retry.status -ne 'published' -and $retry.destinations.notes.error -match 'extended') "The obsolete retry was not refused with its reason: $($retry.status) $($retry.destinations.notes.error)"
        $late=Publish-NotesCheckout $waiting
        Assert ($late.availability -ceq $written) 'A notes-only checkout prepared before the extension rewrote its availability.'
        Assert ($late.result.status -ne 'published' -and $late.result.destinations.notes.error -match 'extended') "The obsolete publication was not refused with its reason: $($late.result.status) $($late.result.destinations.notes.error)"
    } finally {Remove-Item Env:BA_FIXTURE_NOTE_STORE}
}

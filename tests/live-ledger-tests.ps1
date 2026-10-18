# Verifies that every checkout of a game shares one live ledger, that ledgers kept per checkout before it are not read, and
# that a prepared release keeps its boundary and never replaces a newer release live on one of its channels.

# Writes a live ledger as a checkout at $Checkout kept it before ledgers were shared: under the hash of its path, beside a state naming its game's notes repository.
function Write-LegacyLiveLedger([string]$StateRoot, [string]$Checkout, [string]$NotesRepository, [string]$Version, [string]$Commit) {
    $id=& (Get-Module Release) {param($path) (Get-ReleaseTextHash $path).Substring(0,20)} $Checkout
    $folder=Join-Path $StateRoot $id
    New-Item -ItemType Directory -Path (Join-Path $folder $Version) -Force | Out-Null
    Write-Json (Join-Path $folder "$Version/state.json") @{plan=@{notesRepository=$NotesRepository;version=$Version}}
    Write-Json (Join-Path $folder 'live.json') @{'itch:example/real-game:windows'=@{sourceCommit=$Commit;version=$Version;destination='itch-windows';statePath=(Join-Path $folder $Version)}}
}

# Gives the path of the fixture game's shared live ledger under $StateRoot.
function Get-SharedLedgerPath([string]$StateRoot) {
    return Join-Path (& (Get-Module Release) {param($root) Get-ReleaseLedgerDirectory 'Example/Real-Game' $root} $StateRoot) 'live.json'
}

# Writes the fixture game's shared live ledger under $StateRoot with $Rows, one per store channel, as publication records them.
function Write-SharedLedger([string]$StateRoot, $Rows) {
    $path=Get-SharedLedgerPath $StateRoot
    New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
    Write-Json $path $Rows
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
Test 'ledgers kept per checkout before sharing are not read, so previousRelease stands until it is moved' {
    $repo=New-Fixture 'legacy-ledgers'
    $stateRoot=Join-Path $sandbox 'legacy-ledgers-state'
    $configured=Invoke-FixtureGit $repo @('rev-parse','v1.2.2')
    Write-LegacyLiveLedger $stateRoot 'C:\old\checkout' 'Example/Real-Game-release-notes' '1.2.3' (Invoke-FixtureGit $repo @('rev-parse','HEAD'))
    $plan=Get-ReleasePlan -Repository $repo -Destination @('itch-windows','notes') -StateRoot $stateRoot -VersionChange patch
    Assert ($plan.baselines['itch-windows'] -ceq $configured -and $plan.previousCommit -ceq $configured) "A ledger kept per checkout was read: $($plan.baselines['itch-windows']) $($plan.previousCommit)"
}
Test 'a damaged shared ledger stops planning and names the file' {
    $repo=New-Fixture 'damaged-shared-ledger'
    $stateRoot=Join-Path $sandbox 'damaged-shared-ledger-state'
    $path=Get-SharedLedgerPath $stateRoot
    New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($path,'{ not json')
    $place=[IO.Path]::GetRelativePath($stateRoot,$path).Replace('\','/')
    Expect-Error {Get-ReleasePlan -Repository $repo -Destination @('itch-windows') -StateRoot $stateRoot} ([regex]::Escape($place))
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
Test 'canonical notes count from the newest release any checkout published, previousRelease or not' {
    $repo=New-Fixture 'canonical-boundary'
    $stateRoot=Join-Path $sandbox 'canonical-boundary-state'
    $published=Invoke-ReleasePrepare $repo @('itch-windows') $stateRoot $engine
    $state=Get-Content (Join-Path $published.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    Invoke-ReleasePublish -StatePath $published.statePath -ButlerExecutable $butler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $published.statePath $state.plan) | Out-Null
    $worktree=Join-Path $sandbox 'canonical-boundary-newer'
    Invoke-FixtureGit $repo @('worktree','add','--quiet','-b','newer',$worktree) | Out-Null
    'a new feature' | Set-Content (Join-Path $worktree 'feature.txt')
    Invoke-FixtureGit $worktree @('add','feature.txt') | Out-Null
    Invoke-FixtureGit $worktree @('commit','--quiet','-m','Add a new feature') | Out-Null
    $plan=Get-ReleasePlan -Repository $worktree -Destination @('itch-windows','notes') -StateRoot $stateRoot -VersionChange patch
    Assert ($plan.previousCommit -ceq $state.plan.head) "Canonical notes did not count from the published release: $($plan.previousCommit)"
    Assert ((@($plan.changes | ForEach-Object {$_.subject}) -join '|') -ceq 'Add a new feature' -and $plan.notesDraft -notmatch 'Fix controller focus' -and $plan.notesDraft -match 'Add a new feature') "Canonical notes repeated what was already published: $($plan.notesDraft)"
    Change-Config $worktree {param($c) $c.previousRelease=$null}
    Invoke-FixtureGit $worktree @('add','release.json') | Out-Null
    Invoke-FixtureGit $worktree @('commit','--quiet','-m','Leave previousRelease unconfirmed') | Out-Null
    $plan=Get-ReleasePlan -Repository $worktree -Destination @('itch-windows','notes') -StateRoot $stateRoot -VersionChange patch
    Assert ($plan.previousCommit -ceq $state.plan.head -and -not @($plan.blockers | Where-Object {$_ -match 'unconfirmed'}).Count) "An unconfirmed previousRelease ignored the published release: $($plan.previousCommit) $($plan.blockers -join ' ')"
}
Test 'canonical notes wait for previousRelease when two published sources neither contains the other' {
    $repo=New-Fixture 'ambiguous-boundary'
    $stateRoot=Join-Path $sandbox 'ambiguous-boundary-state'
    $main=Invoke-FixtureGit $repo @('rev-parse','HEAD')
    Invoke-FixtureGit $repo @('switch','--quiet','-c','hotfix','v1.2.2') | Out-Null
    'hotfix' | Set-Content (Join-Path $repo 'hotfix.txt')
    Invoke-FixtureGit $repo @('add','hotfix.txt') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Hotfix') | Out-Null
    $hotfix=Invoke-FixtureGit $repo @('rev-parse','HEAD')
    Invoke-FixtureGit $repo @('switch','--quiet','main') | Out-Null
    Invoke-FixtureGit $repo @('merge','--quiet','--no-edit','hotfix') | Out-Null
    $merge=Invoke-FixtureGit $repo @('rev-parse','HEAD')
    Write-SharedLedger $stateRoot ([ordered]@{
        'itch:example/real-game:windows'=@{sourceCommit=$main;version='1.1.0';destination='itch-windows'}
        'itch:example/real-game:linux'=@{sourceCommit=$hotfix;version='1.1.1';destination='itch-linux'}
    })
    $plan=Get-ReleasePlan -Repository $repo -Destination @('notes') -StateRoot $stateRoot
    Assert (@($plan.blockers | Where-Object {$_ -match 'ambiguous'}).Count -and -not $plan.ready) "Two unordered published sources did not block the canonical notes: $($plan.previousCommit)"
    Change-Config $repo {param($c) $c.previousRelease=$merge}
    Invoke-FixtureGit $repo @('add','release.json') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Count notes from the merge') | Out-Null
    $plan=Get-ReleasePlan -Repository $repo -Destination @('notes') -StateRoot $stateRoot
    Assert ($plan.previousCommit -ceq $merge -and -not @($plan.blockers | Where-Object {$_ -match 'ambiguous'}).Count) "previousRelease containing both did not settle the boundary: $($plan.previousCommit) $($plan.blockers -join ' ')"
}
Test 'canonical notes keep a publication on a channel since removed from release.json' {
    $repo=New-Fixture 'retired-channel'
    $stateRoot=Join-Path $sandbox 'retired-channel-state'
    $shipped=Invoke-FixtureGit $repo @('rev-parse','HEAD')
    Write-SharedLedger $stateRoot @{'itch:example/real-game:linux'=@{sourceCommit=$shipped;version='1.2.3';destination='itch-linux'}}
    $plan=Get-ReleasePlan -Repository $repo -Destination @('notes') -StateRoot $stateRoot -VersionChange patch
    Assert ($plan.previousCommit -ceq $shipped) "The Linux publication did not set the boundary while Linux was configured: $($plan.previousCommit)"
    Change-Config $repo {param($c) $c.distributions.itch.channels.Remove('linux')}
    'a new feature' | Set-Content (Join-Path $repo 'feature.txt')
    Invoke-FixtureGit $repo @('add','release.json','feature.txt') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Retire Linux and add a feature') | Out-Null
    $plan=Get-ReleasePlan -Repository $repo -Destination @('notes') -StateRoot $stateRoot -VersionChange patch
    Assert ($plan.previousCommit -ceq $shipped -and $plan.notesDraft -notmatch 'Fix controller focus') "Retiring Linux dropped its publication from the canonical notes: $($plan.previousCommit)"
}
Test 'availability is left alone when a state that recorded this release live cannot be read' {
    $repo=New-StoreFixture 'missing-journal';Add-FixtureApk $repo
    $stateRoot=Join-Path $sandbox 'missing-journal-state'
    $env:BA_FIXTURE_NOTE_STORE=Join-Path $sandbox 'missing-journal-note.md'
    $journal=$null
    try {
        $store=Invoke-ReleasePrepare $repo @('itch-windows','notes') $stateRoot $engine
        $state=Get-Content (Join-Path $store.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        Invoke-ReleasePublish -StatePath $store.statePath -ButlerExecutable $butler -GhExecutable $gh -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $store.statePath $state.plan) | Out-Null
        $beforeExtension=New-NotesCheckout $repo $stateRoot $store.statePath 'missing-journal-before'
        Expand-ReleaseDestinations $store.statePath @('itch-android') $engine | Out-Null
        Invoke-FixtureGit $repo @('add','export_presets.cfg') | Out-Null
        Invoke-FixtureGit $repo @('commit','--quiet','-m','Reserve the APK counter') | Out-Null
        Expand-ReleaseDestinations $store.statePath @('itch-android') $engine | Out-Null
        $state=Get-Content (Join-Path $store.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        Invoke-ReleasePublish -StatePath $store.statePath -ButlerExecutable $butler -GhExecutable $gh -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $store.statePath $state.plan) | Out-Null
        $written=Get-Content ($env:BA_FIXTURE_NOTE_STORE+'.availability') -Raw
        $current=Publish-NotesFromAnotherCheckout $repo $stateRoot $store.statePath 'missing-journal-current'
        Assert ($current.result.status -eq 'published' -and $current.availability -ceq $written) 'The notes-only checkout did not publish while the publishing state was readable.'
        $journal=Join-Path $store.statePath 'state.json'
        Move-Item -LiteralPath $journal -Destination "$journal.away"
        $retry=Invoke-ReleasePublish -StatePath $current.result.statePath -GhExecutable $gh
        Assert ((Get-Content ($env:BA_FIXTURE_NOTE_STORE+'.availability') -Raw) -ceq $written) 'A missing publishing state let a retry rewrite availability.'
        Assert ($retry.status -ne 'published' -and $retry.destinations.notes.error -match 'cannot be read') "The retry was not refused with its reason: $($retry.status) $($retry.destinations.notes.error)"
        $obsolete=Publish-NotesCheckout $beforeExtension
        Assert ($obsolete.availability -ceq $written -and $obsolete.result.status -ne 'published' -and $obsolete.result.destinations.notes.error -match 'cannot be read') "A checkout from before the extension wrote availability while the state holding its history was missing: $($obsolete.result.destinations.notes.error)"
        Move-Item -LiteralPath "$journal.away" -Destination $journal
        $journal=$null
        $restored=Invoke-ReleasePublish -StatePath $current.result.statePath -GhExecutable $gh
        Assert ($restored.status -eq 'published' -and (Get-Content ($env:BA_FIXTURE_NOTE_STORE+'.availability') -Raw) -ceq $written) "Restoring the publishing state did not let the retry complete: $($restored.status)"
    } finally {if ($journal -and (Test-Path -LiteralPath "$journal.away")) {Move-Item -LiteralPath "$journal.away" -Destination $journal};Remove-Item Env:BA_FIXTURE_NOTE_STORE}
}
Test 'availability is left alone when the state behind an earlier receipt in a row''s history cannot be read' {
    $repo=New-Fixture 'missing-history-journal'
    $stateRoot=Join-Path $sandbox 'missing-history-journal-state'
    $env:BA_FIXTURE_NOTE_STORE=Join-Path $sandbox 'missing-history-journal-note.md'
    try {
        $older=Invoke-ReleasePrepare $repo @('itch-windows','notes') $stateRoot $engine
        $state=Get-Content (Join-Path $older.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        Invoke-ReleasePublish -StatePath $older.statePath -ButlerExecutable $butler -GhExecutable $gh -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $older.statePath $state.plan) | Out-Null
        $written=Get-Content ($env:BA_FIXTURE_NOTE_STORE+'.availability') -Raw
        $worktree=Join-Path $sandbox 'missing-history-journal-newer'
        Invoke-FixtureGit $repo @('worktree','add','--quiet','-b','newer',$worktree) | Out-Null
        Invoke-ReleasePrepare $worktree @('itch-windows') $stateRoot $engine -VersionChange patch | Out-Null
        Invoke-FixtureGit $worktree @('add','project.godot') | Out-Null
        Invoke-FixtureGit $worktree @('commit','--quiet','-m','Reserve the newer version') | Out-Null
        $newer=Invoke-ReleasePrepare $worktree @('itch-windows') $stateRoot $engine -VersionChange patch
        $newerState=Get-Content (Join-Path $newer.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        Invoke-ReleasePublish -StatePath $newer.statePath -ButlerExecutable $butler -ApprovedPlanId $newerState.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $newer.statePath $newerState.plan) | Out-Null
        $notes=New-NotesCheckout $repo $stateRoot $older.statePath 'missing-history-journal-notes'
        Remove-Item -LiteralPath (Join-Path $older.statePath 'state.json')
        $late=Publish-NotesCheckout $notes
        Assert ($late.availability -ceq $written -and $late.result.status -ne 'published' -and $late.result.destinations.notes.error -match 'cannot be read') "A missing state behind an earlier receipt let availability be rewritten: $($late.result.status) $($late.result.destinations.notes.error)"
    } finally {Remove-Item Env:BA_FIXTURE_NOTE_STORE}
}
Test 'a recovered availability refresh clears its earlier error, whether or not it writes' {
    $repo=New-Fixture 'recovered-refresh'
    $stateRoot=Join-Path $sandbox 'recovered-refresh-state'
    $env:BA_FIXTURE_NOTE_STORE=Join-Path $sandbox 'recovered-refresh-note.md'
    $journal=$null
    try {
        $store=Invoke-ReleasePrepare $repo @('itch-windows','notes') $stateRoot $engine
        $state=Get-Content (Join-Path $store.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        Invoke-ReleasePublish -StatePath $store.statePath -ButlerExecutable $butler -GhExecutable $gh -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $store.statePath $state.plan) | Out-Null
        $availabilityPath=$env:BA_FIXTURE_NOTE_STORE+'.availability'
        $written=Get-Content $availabilityPath -Raw
        $notes=Publish-NotesFromAnotherCheckout $repo $stateRoot $store.statePath 'recovered-refresh-notes'
        $notesState=Join-Path $notes.result.statePath 'state.json'
        $journal=Join-Path $store.statePath 'state.json'
        # Each recovery follows a refused refresh, once with the record already right and once with it needing a write.
        foreach ($recovery in @('identical','rewritten')) {
            Move-Item -LiteralPath $journal -Destination "$journal.away"
            $refused=Invoke-ReleasePublish -StatePath $notes.result.statePath -GhExecutable $gh
            Assert ($refused.destinations.notes.error -match 'cannot be read') "The refresh was not refused while the state was missing: $($refused.destinations.notes.error)"
            Move-Item -LiteralPath "$journal.away" -Destination $journal
            if ($recovery -eq 'rewritten') {[IO.File]::WriteAllText($availabilityPath,$written.Replace('"live": true','"live": false'))}
            $recovered=Invoke-ReleasePublish -StatePath $notes.result.statePath -GhExecutable $gh
            $saved=(Get-Content $notesState -Raw | ConvertFrom-Json -AsHashtable).destinations.notes
            Assert ($recovered.status -eq 'published' -and (Get-Content $availabilityPath -Raw) -ceq $written) "The $recovery recovery did not restore truthful availability: $($recovered.status)"
            Assert ($null -eq $recovered.destinations.notes.error -and $null -eq $saved.error) "The $recovery recovery kept the earlier refresh error: $($recovered.destinations.notes.error) / $($saved.error)"
        }
    } finally {if ($journal -and (Test-Path -LiteralPath "$journal.away")) {Move-Item -LiteralPath "$journal.away" -Destination $journal};Remove-Item Env:BA_FIXTURE_NOTE_STORE}
}
Test 'a prepared release keeps its boundary after previousRelease moves past its source, away from it or is deleted' {
    $repo=New-Fixture 'frozen-boundary'
    $stateRoot=Join-Path $sandbox 'frozen-boundary-state'
    $original=Invoke-FixtureGit $repo @('rev-parse','v1.2.2')
    $prepared=Invoke-ReleasePrepare $repo @('itch-windows') $stateRoot $engine
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    # Commits beside the checked-out branch: one descends from the prepared source, the other diverges from it.
    $later=Invoke-FixtureGit $repo @('commit-tree','HEAD^{tree}','-p','HEAD','-m','Later work')
    $divergent=Invoke-FixtureGit $repo @('commit-tree',"$original^{tree}",'-p',$original,'-m','Divergent work')
    $moves=[ordered]@{
        'moved past the source'={Invoke-FixtureGit $repo @('tag','--force','v1.2.2',$later) | Out-Null}
        'moved away from the source'={Invoke-FixtureGit $repo @('tag','--force','v1.2.2',$divergent) | Out-Null}
        'deleted'={Invoke-FixtureGit $repo @('tag','--delete','v1.2.2') | Out-Null}
    }
    foreach ($move in $moves.Keys) {
        & $moves[$move]
        Expect-Error {Get-ReleasePlan -Repository $repo -Destination @('itch-windows') -StateRoot $stateRoot -VersionChange patch} 'ancestor|rev-parse'
        $frozen=Get-ReleasePlan $repo @('itch-windows') $state.plan.baselines $stateRoot -FrozenPrevious $state.plan.previousCommit
        Assert ($frozen.ready -and $frozen.planId -ceq $state.plan.planId -and $frozen.previousCommit -ceq $original) "With previousRelease $move, the prepared plan changed: $($frozen.previousCommit) $($frozen.blockers -join ' ')"
        $retry=Invoke-ReleasePrepare $repo @('itch-windows') $stateRoot $engine
        Assert ($retry.status -eq 'prepared' -and $retry.statePath -eq $prepared.statePath -and $retry.planId -ceq $state.plan.planId) "With previousRelease $move, preparation did not resume the release: $($retry.status)"
    }
    # Only the saved commit itself can stand as the boundary.
    Expect-Error {Get-ReleasePlan $repo @('itch-windows') $state.plan.baselines $stateRoot -FrozenPrevious $later} 'previous-release commit'
    Expect-Error {Get-ReleasePlan $repo @('itch-windows') $state.plan.baselines $stateRoot -FrozenPrevious 'main~1'} 'previous-release commit'
    # With the ref gone, an added channel takes its baseline from the live ledger; the release keeps its own boundary.
    Write-SharedLedger $stateRoot @{'itch:example/real-game:linux'=@{sourceCommit=$original;version='1.2.2';statePath=(Join-Path $stateRoot 'earlier/1.2.2');destination='itch-linux';observedAt=[DateTimeOffset]::UtcNow.ToString('o')}}
    $extended=Expand-ReleaseDestinations $prepared.statePath @('itch-linux') $engine
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($extended.status -eq 'prepared' -and $state.plan.previousCommit -ceq $original -and $state.plan.baselines['itch-linux'] -ceq $original) "Extension without the ref did not keep the boundary: $($extended.status) $($state.plan.previousCommit)"
    $env:BA_FIXTURE_ALLOW_LINUX='1'
    try {$published=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan)}
    finally {Remove-Item Env:BA_FIXTURE_ALLOW_LINUX}
    Assert ($published.status -eq 'published') "Publication without the ref failed: $($published.status)"
}
Test 'an older approved release sends nothing to a channel where a newer release is live, and still reaches an unaffected one' {
    $repo=New-Fixture 'stale-upload'
    $stateRoot=Join-Path $sandbox 'stale-upload-state'
    $env:BA_FIXTURE_UPLOAD_LOG=Join-Path $sandbox 'stale-upload.log'
    try {
        $older=Invoke-ReleasePrepare $repo @('itch-windows') $stateRoot $engine
        $olderState=Get-Content (Join-Path $older.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        $olderNotes=Get-ReleaseNotesHash $older.statePath $olderState.plan
        $worktree=Join-Path $sandbox 'stale-upload-newer'
        Invoke-FixtureGit $repo @('worktree','add','--quiet','-b','newer',$worktree) | Out-Null
        Invoke-ReleasePrepare $worktree @('itch-windows') $stateRoot $engine -VersionChange patch | Out-Null
        Invoke-FixtureGit $worktree @('add','project.godot') | Out-Null
        Invoke-FixtureGit $worktree @('commit','--quiet','-m','Reserve the newer version') | Out-Null
        $newer=Invoke-ReleasePrepare $worktree @('itch-windows') $stateRoot $engine -VersionChange patch
        $newerState=Get-Content (Join-Path $newer.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        Invoke-ReleasePublish -StatePath $newer.statePath -ButlerExecutable $butler -ApprovedPlanId $newerState.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $newer.statePath $newerState.plan) | Out-Null
        $result=Invoke-ReleasePublish -StatePath $older.statePath -ButlerExecutable $butler -ApprovedPlanId $olderState.plan.planId -ApprovedNotesSha256 $olderNotes
        $uploads=@(Get-Content $env:BA_FIXTURE_UPLOAD_LOG)
        Assert (($uploads -join '|') -ceq 'butler example/real-game:windows 1.2.4') "The older release reached the newer channel: $($uploads -join '|')"
        $saved=(Get-Content (Join-Path $older.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable).destinations['itch-windows']
        Assert ($saved.status -eq 'failed' -and -not $saved.remote.Contains('live') -and $saved.attempts -eq 0 -and $saved.error -match 'Version 1\.2\.4 is live.*reconciliation') "The refusal was not recorded before any receipt: $($saved | ConvertTo-Json -Compress)"
        Assert ($result.status -eq 'publication-failed') "A refused release was reported as $($result.status)."
        $ledger=Get-ReleaseLiveLedger $repo $stateRoot
        Assert ($ledger['itch:example/real-game:windows'].sourceCommit -ceq $newerState.plan.head -and @($ledger['itch:example/real-game:windows'].recorded).Count -eq 1) 'The refused release changed the newer row.'
        # Replaying the newer release sends nothing again; the older one still reaches a channel with nothing newer live.
        $replay=Invoke-ReleasePublish -StatePath $newer.statePath -ButlerExecutable $butler
        Assert ($replay.status -eq 'published' -and @(Get-Content $env:BA_FIXTURE_UPLOAD_LOG).Count -eq 1) "Replaying the newer release did not complete without uploading: $($replay.status)"
        Expand-ReleaseDestinations $older.statePath @('itch-linux') $engine | Out-Null
        $olderState=Get-Content (Join-Path $older.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        $env:BA_FIXTURE_ALLOW_LINUX='1'
        try {$extended=Invoke-ReleasePublish -StatePath $older.statePath -ButlerExecutable $butler -ApprovedPlanId $olderState.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $older.statePath $olderState.plan)}
        finally {Remove-Item Env:BA_FIXTURE_ALLOW_LINUX}
        $uploads=@(Get-Content $env:BA_FIXTURE_UPLOAD_LOG)
        Assert (($uploads -join '|') -ceq 'butler example/real-game:windows 1.2.4|butler example/real-game:linux 1.2.3') "The extension did not reach only the unaffected channel: $($uploads -join '|')"
        Assert ($extended.status -eq 'partial-failure' -and $extended.destinations['itch-linux'].status -eq 'succeeded' -and $extended.destinations['itch-windows'].status -eq 'failed') "The extension reported $($extended.status)."
    } finally {Remove-Item Env:BA_FIXTURE_UPLOAD_LOG}
}
Test 'no store receives an older build while a newer release is live on its channel or another checkout holds the ledger' {
    $repo=New-StoreFixture 'stale-stores'
    $stateRoot=Join-Path $sandbox 'stale-stores-state'
    $env:BA_FIXTURE_UPLOAD_LOG=Join-Path $sandbox 'stale-stores.log'
    $env:BA_STEAM_USERNAME='fixture'
    try {
        $stores=@('itch-windows','steam','google-play')
        $prepared=Invoke-ReleasePrepare $repo $stores $stateRoot $engine
        $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        $api=New-PlayServer
        # Another checkout publishing under the same state root holds the game's ledger, so this one stops before any store write.
        $ledgerDirectory=Split-Path (Get-SharedLedgerPath $stateRoot) -Parent
        New-Item -ItemType Directory -Path $ledgerDirectory -Force | Out-Null
        $held=[IO.File]::Open((Join-Path $ledgerDirectory '.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try {Expect-Error {Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -SteamCmdExecutable $steam -PlayTransport $api.handler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan)} 'Another checkout'}
        finally {$held.Dispose()}
        $saved=(Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable).destinations
        Assert (-not @($stores | Where-Object {$saved[$_].status -ne 'pending'}).Count) "A held ledger let publication start: $(@($stores | ForEach-Object {$saved[$_].status}) -join ', ')"
        # A newer source is live on every channel, so none receives this release.
        $newer=Invoke-FixtureGit $repo @('commit-tree','HEAD^{tree}','-p','HEAD','-m','Newer release')
        Write-SharedLedger $stateRoot ([ordered]@{
            'itch:example/real-game:windows'=@{sourceCommit=$newer;version='1.2.4';destination='itch-windows'}
            'steam:100:default'=@{sourceCommit=$newer;version='1.2.4';destination='steam'}
            'play:com.example.realgame:production'=@{sourceCommit=$newer;version='1.2.4';destination='google-play'}
        })
        $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -SteamCmdExecutable $steam -PlayTransport $api.handler
        Assert (-not (Test-Path -LiteralPath $env:BA_FIXTURE_UPLOAD_LOG) -and $api.server.calls.Count -eq 0) "An older build reached a store: $(if (Test-Path -LiteralPath $env:BA_FIXTURE_UPLOAD_LOG) {Get-Content $env:BA_FIXTURE_UPLOAD_LOG}) $($api.server.calls.Count) Play calls"
        foreach ($id in $stores) {
            $record=$result.destinations[$id]
            Assert ($record.status -eq 'failed' -and $record.attempts -eq 0 -and $record.error -match 'reconciliation') "$id was not refused before its store write: $($record.status) $($record.error)"
        }
        Assert ($result.status -eq 'publication-failed') "Refusing every store was reported as $($result.status)."
    } finally {Remove-Item Env:BA_FIXTURE_UPLOAD_LOG;Remove-Item Env:BA_STEAM_USERNAME}
}
Test 'an older build is refused where a newer Steam build or Play edit was sent but is not yet live' {
    $repo=New-StoreFixture 'stale-unconfirmed'
    $stateRoot=Join-Path $sandbox 'stale-unconfirmed-state'
    $env:BA_FIXTURE_UPLOAD_LOG=Join-Path $sandbox 'stale-unconfirmed.log'
    try {
        $stores=@('steam','google-play')
        $older=Invoke-ReleasePrepare $repo $stores $stateRoot $engine
        $olderState=Get-Content (Join-Path $older.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        $worktree=Join-Path $sandbox 'stale-unconfirmed-newer'
        Invoke-FixtureGit $repo @('worktree','add','--quiet','-b','newer',$worktree) | Out-Null
        Invoke-ReleasePrepare $worktree $stores $stateRoot $engine -VersionChange patch | Out-Null
        Invoke-FixtureGit $worktree @('add','project.godot') | Out-Null
        Invoke-FixtureGit $worktree @('commit','--quiet','-m','Reserve the newer version') | Out-Null
        $newer=Invoke-ReleasePrepare $worktree $stores $stateRoot $engine -VersionChange patch
        $newerState=Get-Content (Join-Path $newer.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        $newerApi=New-PlayServer;$newerApi.server.version='1.2.4'
        # Without a SteamCMD account the newer Steam attempt fails before uploading, so it records nothing as sent.
        Remove-Item Env:BA_STEAM_USERNAME -ErrorAction SilentlyContinue
        Invoke-ReleasePublish -StatePath $newer.statePath -SteamCmdExecutable $steam -PlayTransport $newerApi.handler -ApprovedPlanId $newerState.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $newer.statePath $newerState.plan) | Out-Null
        $sentPath=Join-Path (Split-Path (Get-SharedLedgerPath $stateRoot) -Parent) 'sent.json'
        $sent=Get-Content $sentPath -Raw | ConvertFrom-Json -AsHashtable
        Assert (-not $sent.Contains('steam:100:default') -and @($sent['play:com.example.realgame:production']).Count -eq 1) "The store-write record does not match what reached the stores: $($sent.Keys -join ', ')"
        $env:BA_STEAM_USERNAME='fixture'
        $newerResult=Invoke-ReleasePublish -StatePath $newer.statePath -SteamCmdExecutable $steam -PlayTransport $newerApi.handler
        Assert ($newerResult.destinations.steam.status -eq 'awaiting-store-action' -and $newerResult.destinations['google-play'].status -eq 'submitted') "The newer release did not upload without going live: $($newerResult.destinations.steam.status) $($newerResult.destinations['google-play'].status)"
        Assert (-not (Get-ReleaseLiveLedger $repo $stateRoot).Count) 'An upload awaiting console work or review was recorded live.'
        $olderApi=New-PlayServer
        $result=Invoke-ReleasePublish -StatePath $older.statePath -SteamCmdExecutable $steam -PlayTransport $olderApi.handler -ApprovedPlanId $olderState.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $older.statePath $olderState.plan)
        $uploads=@(Get-Content $env:BA_FIXTURE_UPLOAD_LOG)
        Assert (($uploads -join '|') -ceq 'steamcmd 100 1.2.4' -and $olderApi.server.calls.Count -eq 0) "The older release reached a store: $($uploads -join '|') $($olderApi.server.calls.Count) Play calls"
        foreach ($id in $stores) {
            $record=$result.destinations[$id]
            Assert ($record.status -eq 'failed' -and $record.attempts -eq 0 -and $record.error -match 'Version 1\.2\.4 has been sent to.*reconciliation') "$id was not refused before its store write: $($record.status) $($record.error)"
        }
    } finally {Remove-Item Env:BA_FIXTURE_UPLOAD_LOG;Remove-Item Env:BA_STEAM_USERNAME -ErrorAction SilentlyContinue}
}

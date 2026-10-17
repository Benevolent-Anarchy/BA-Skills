# Verifies that every checkout of a game shares one live ledger, and that ledgers kept per checkout before it are still read.

# Writes a live ledger as a checkout at $Checkout kept it before ledgers were shared: under the hash of its path, beside a state naming its game's notes repository.
function Write-LegacyLiveLedger([string]$StateRoot, [string]$Checkout, [string]$NotesRepository, [string]$Version, [string]$Commit) {
    $id=& (Get-Module Release) {param($path) (Get-ReleaseTextHash $path).Substring(0,20)} $Checkout
    $folder=Join-Path $StateRoot $id
    New-Item -ItemType Directory -Path (Join-Path $folder $Version) -Force | Out-Null
    Write-Json (Join-Path $folder "$Version/state.json") @{plan=@{notesRepository=$NotesRepository;version=$Version}}
    Write-Json (Join-Path $folder 'live.json') @{'itch:example/real-game:windows'=@{sourceCommit=$Commit;version=$Version;destination='itch-windows';statePath=(Join-Path $folder $Version)}}
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
}

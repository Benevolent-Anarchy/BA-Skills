# Verifies that a game whose Play channel sets baselineAdvancesOn to submitted plans its next Play release from the last
# submitted one, that only that channel's baseline moves, and that nothing reads a submission as a release gone live.

# Publishes the store fixture's current version to Play alone, with baselines advancing on submission when asked, and returns
# the repository, its state root, the published state's path and the commit release.json's previousRelease names. With
# $OlderLive, the shared ledger first records that commit live on the Play channel, as a confirmed earlier release leaves it.
function Publish-SubmittedPlayFixture([string]$Name, [switch]$AdvanceOnSubmission, [switch]$OlderLive) {
    $repo=New-StoreFixture $Name
    if ($AdvanceOnSubmission) {
        Change-Config $repo {param($c) $c.distributions['google-play'].baselineAdvancesOn='submitted'}
        Invoke-FixtureGit $repo @('add','release.json') | Out-Null
        Invoke-FixtureGit $repo @('commit','--quiet','-m','Advance Play baselines on submission') | Out-Null
    }
    $stateRoot=Join-Path $sandbox "$Name-state"
    if ($OlderLive) {Write-SharedLedger $stateRoot @{'play:com.example.realgame:production'=@{sourceCommit=(Invoke-FixtureGit $repo @('rev-parse','v1.2.2^{commit}'));version='1.2.2';destination='google-play'}}}
    $prepared=Invoke-ReleasePrepare $repo @('google-play') $stateRoot $engine
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    $api=New-PlayServer
    $result=Invoke-ReleasePublish -StatePath $prepared.statePath -PlayTransport $api.handler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan)
    Assert ($result.destinations['google-play'].status -eq 'submitted') "The fixture release was not submitted: $($result.destinations['google-play'].status) $($result.destinations['google-play'].error)"
    return @{repo=$repo;stateRoot=$stateRoot;statePath=$prepared.statePath;head=$state.plan.head;configured=(Invoke-FixtureGit $repo @('rev-parse','v1.2.2^{commit}'))}
}

Test 'a Play submission is Play''s next baseline when baselines advance on submission, and is never read as live' {
    $fixture=Publish-SubmittedPlayFixture 'submitted-baseline' -AdvanceOnSubmission -OlderLive
    $sent=Get-Content (Get-SentRecordPath $fixture.stateRoot) -Raw | ConvertFrom-Json -AsHashtable
    Assert (@($sent['play:com.example.realgame:production'] | Where-Object {$_.sourceCommit -ceq $fixture.head -and $_.submittedAt}).Count -eq 1) 'The store-write record does not mark the build as submitted.'
    $newer=New-NewerRelease $fixture.repo $fixture.stateRoot @('google-play') 'submitted-baseline-newer'
    Assert ($newer.state.plan.baselines['google-play'] -ceq $fixture.head) "The next Play release did not count from the submission newer than the release live there: $($newer.state.plan.baselines['google-play'])"
    Assert ($newer.state.plan.previousCommit -ceq $fixture.configured) "A submission moved the canonical notes boundary: $($newer.state.plan.previousCommit)"
    $live=Get-ReleaseLiveLedger $fixture.repo $fixture.stateRoot
    Assert ($live.Count -eq 1 -and $live['play:com.example.realgame:production'].sourceCommit -ceq $fixture.configured) 'A submission was recorded live.'
}

Test 'without the setting a Play submission leaves Play''s baseline where release.json puts it' {
    $fixture=Publish-SubmittedPlayFixture 'submitted-baseline-default'
    $newer=New-NewerRelease $fixture.repo $fixture.stateRoot @('google-play') 'submitted-baseline-default-newer'
    Assert ($newer.state.plan.baselines['google-play'] -ceq $fixture.configured) "A submission moved Play's baseline without the setting: $($newer.state.plan.baselines['google-play'])"
}

Test 'a submission recorded before submissions were marked counts once replayed or seeded, and stops once abandoned' {
    $fixture=Publish-SubmittedPlayFixture 'submitted-baseline-seeded' -AdvanceOnSubmission
    # A record written before submissions were marked holds the build unmarked; replaying the release marks it.
    $sentPath=Get-SentRecordPath $fixture.stateRoot
    $sent=Get-Content $sentPath -Raw | ConvertFrom-Json -AsHashtable
    foreach ($entry in @($sent['play:com.example.realgame:production'])) {$entry.Remove('submittedAt')}
    Write-Json $sentPath $sent
    $plan=Get-ReleasePlan -Repository $fixture.repo -Destination @('google-play') -StateRoot $fixture.stateRoot
    Assert ($plan.baselines['google-play'] -ceq $fixture.configured) "An unmarked build counted as submitted: $($plan.baselines['google-play'])"
    Invoke-ReleasePublish -StatePath $fixture.statePath -PlayTransport (New-PlayServer).handler | Out-Null
    $plan=Get-ReleasePlan -Repository $fixture.repo -Destination @('google-play') -StateRoot $fixture.stateRoot
    Assert ($plan.baselines['google-play'] -ceq $fixture.head) "Replaying the release did not mark its submission: $($plan.baselines['google-play'])"
    # A release submitted before the record existed left nothing in it; planning reads the journals instead, writing nothing.
    Remove-Item -LiteralPath $sentPath
    $plan=Get-ReleasePlan -Repository $fixture.repo -Destination @('google-play') -StateRoot $fixture.stateRoot
    Assert ($plan.baselines['google-play'] -ceq $fixture.head) "A submission seeded from its journal did not count: $($plan.baselines['google-play'])"
    Assert (-not (Test-Path -LiteralPath $sentPath)) 'Planning wrote the store-write record.'
    $state=Get-Content (Join-Path $fixture.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    $receipt=Join-Path $fixture.statePath 'play-abandoned.json'
    Write-Json $receipt @{destination='google-play';planId=$state.plan.planId;observedAt=[DateTimeOffset]::UtcNow.ToString('o');live=$false;packageName='com.example.realgame';versionCode=12;track='production';evidenceUrl='https://play.google.com/console'}
    Confirm-ReleaseAbandonment $fixture.statePath $receipt -Authorized | Out-Null
    $plan=Get-ReleasePlan -Repository $fixture.repo -Destination @('google-play') -StateRoot $fixture.stateRoot
    Assert ($plan.baselines['google-play'] -ceq $fixture.configured) "An abandoned submission still counted: $($plan.baselines['google-play'])"
}

Test 'baselineAdvancesOn takes only live or submitted, and only on Google Play' {
    $repo=New-StoreFixture 'submitted-baseline-config'
    Change-Config $repo {param($c) $c.distributions['google-play'].baselineAdvancesOn='reviewed'}
    Expect-Error {Get-ReleasePlan -Repository $repo -Destination @('google-play')} 'baselineAdvancesOn must be live or submitted'
    foreach ($case in @(@{value='live';owed=$true},@{value='submitted';owed=$false})) {
        Change-Config $repo {param($c) $c.distributions['google-play'].baselineAdvancesOn=$case.value}
        $play=@((Get-ReleasePlan -Repository $repo -Destination @('google-play')).destinations | Where-Object id -EQ 'google-play')[0]
        Assert ($play.baselineAdvancesOn -ceq $case.value) "The plan does not carry the configured setting: $($play.baselineAdvancesOn)"
        Assert ((@($play.requiredActions | Where-Object {$_ -match 'Play Console after submission'}).Count -eq 1) -eq $case.owed) "With $($case.value), the console check after submission is listed wrongly: $($play.requiredActions -join ' | ')"
    }
    Change-Config $repo {param($c) $c.distributions.steam.baselineAdvancesOn='submitted'}
    Expect-Error {Get-ReleasePlan -Repository $repo -Destination @('steam')} 'distributions\.steam field: baselineAdvancesOn'
}

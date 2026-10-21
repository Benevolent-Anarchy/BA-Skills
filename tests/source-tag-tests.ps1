# Verifies that a game which turns sourceTag on names each shipped release with an annotated tag on origin, made only once a
# store is live, pushed alone and never moved, and that a game which leaves it out plans and publishes as it did before.

# Makes a fixture that tags its releases, whose pushes to origin go to a local bare repository standing in for GitHub. Only
# pushes are rewritten, so origin's fetch URL still names the GitHub repository the plan derives its repositories from.
function New-TagFixture([string]$Name, [switch]$Stores) {
    $repo=if ($Stores) {New-StoreFixture $Name} else {New-Fixture $Name}
    Change-Config $repo {param($c) $c.sourceTag=$true}
    Invoke-FixtureGit $repo @('add','release.json') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Tag releases on origin') | Out-Null
    $origin=Join-Path $sandbox "$Name-origin.git"
    Invoke-FixtureGit $sandbox @('init','--quiet','--bare',$origin) | Out-Null
    Invoke-FixtureGit $repo @('config',"url.$($origin.Replace('\','/')).pushInsteadOf",'https://github.com/Example/Real-Game.git') | Out-Null
    return @{repo=$repo;origin=$origin;stateRoot=(Join-Path $sandbox "$Name-state")}
}
# Lists the tags a bare origin holds, each with its object type and the commit it names.
function Get-OriginTags([string]$Origin) {
    $tags=@{}
    $text=Invoke-FixtureGit $Origin @('for-each-ref','refs/tags','--format=%(refname:short) %(objecttype) %(if)%(*objectname)%(then)%(*objectname)%(else)%(objectname)%(end)')
    foreach ($line in @($text.Split("`n") | Where-Object {$_})) {$parts=$line.Split(' ');$tags[$parts[0]]=@{type=$parts[1];commit=$parts[2]}}
    return $tags
}
# Reads a release journal.
function Read-TagState([string]$StatePath) {
    return Get-Content (Join-Path $StatePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
}
# Gives the approval arguments for a prepared release's displayed plan and notes.
function Get-TagApproval([string]$StatePath) {
    $state=Read-TagState $StatePath
    return @{ApprovedPlanId=$state.plan.planId;ApprovedNotesSha256=(Get-ReleaseNotesHash $StatePath $state.plan)}
}

Test 'a game without sourceTag plans no tag, a new setup turns it on, and a store change keeps the game''s choice' {
    $repo=New-Fixture 'tag-default'
    Assert (-not (Get-ReleasePlan $repo @('itch-windows')).Contains('sourceTag') -and -not (Get-ReleaseConfiguration $repo).config.sourceTag) 'A game without sourceTag planned a tag.'
    $answers=Join-Path $sandbox 'tag-default-answers.json'
    Write-Json $answers @{stores=@('itch','notes')}
    Set-ReleaseSetup $repo $answers (Get-ReleaseSetup $repo).configSha256 | Out-Null
    Assert (-not (Get-Content (Join-Path $repo 'release.json') -Raw | ConvertFrom-Json -AsHashtable).Contains('sourceTag')) 'Changing stores turned tagging on for a game already configured.'
    Write-Json $answers @{sourceTag=$true}
    Set-ReleaseSetup $repo $answers (Get-ReleaseSetup $repo).configSha256 | Out-Null
    Assert ((Get-ReleaseConfiguration $repo).config.sourceTag -eq $true) 'An explicit answer did not turn tagging on.'
    Remove-Item -LiteralPath (Join-Path $repo 'release.json')
    Assert ((Get-ReleaseSetup $repo).configuration.sourceTag -eq $true) 'A new setup did not propose tagging.'
    $repo=New-Fixture 'tag-not-boolean'
    Change-Config $repo {param($c) $c.sourceTag='yes'}
    Expect-Error {Get-ReleaseConfiguration $repo} 'sourceTag must be a boolean'
}

Test 'the plan names the tag, its commit, repository and message, and blocks a version that cannot be a tag' {
    $fixture=New-TagFixture 'tag-plan'
    $repo=$fixture.repo
    $plan=Get-ReleasePlan $repo @('itch-windows')
    $tag=$plan.sourceTag
    Assert ($plan.ready -and $tag.name -ceq 'v1.2.3' -and $tag.commit -ceq (Invoke-FixtureGit $repo @('rev-parse','HEAD')) -and $tag.repository -ceq 'Example/Real-Game' -and $tag.message -ceq 'Fixture 1.2.3') "The plan did not show the tag it would push: $($tag | ConvertTo-Json -Compress)"
    Assert ((Get-ReleasePlan $repo @('itch-windows') -VersionChange patch).sourceTag.name -ceq 'v1.2.4') 'A version preview did not name its own tag.'
    $doctor=Get-ReleaseDoctor -Repository $repo -Destination @('itch-windows') -GodotExecutable $engine -ButlerExecutable $butler
    Assert (@($doctor.checks | Where-Object {$_.id -eq 'source-tag' -and $_.status -eq 'unverified'}).Count -eq 1) 'Doctor did not report the tag as checked locally only.'
    $project=Join-Path $repo 'project.godot'
    [IO.File]::WriteAllText($project,[IO.File]::ReadAllText($project).Replace('config/version="1.2.3"','config/version="1.2.3-rc..1"'))
    Invoke-FixtureGit $repo @('commit','--quiet','-am','Choose a version no tag can name') | Out-Null
    $plan=Get-ReleasePlan $repo @('itch-windows')
    Assert (-not $plan.configurationReady -and ($plan.blockers -join ' ') -match 'v1\.2\.3-rc\.\.1 is not a valid Git tag name') "An impossible tag name did not block the plan: $($plan.blockers -join ' ')"
}

Test 'publication pushes one annotated tag on the release source once a store is live, and only once' {
    $fixture=New-TagFixture 'tag-publish'
    $repo=$fixture.repo
    # An unrelated annotated tag stays here, even where Git is set to send reachable annotated tags with every push.
    Invoke-FixtureGit $repo @('tag','--annotate','--message','Unrelated','unrelated-annotated','HEAD~1') | Out-Null
    Invoke-FixtureGit $repo @('config','push.followTags','true') | Out-Null
    $prepared=Invoke-ReleasePrepare $repo @('itch-windows') $fixture.stateRoot $engine
    $state=Read-TagState $prepared.statePath
    Assert (-not (Get-OriginTags $fixture.origin).Count -and -not (Invoke-FixtureGit $repo @('tag','--list','v1.2.3'))) 'Preparation made or pushed a tag.'
    $approval=Get-TagApproval $prepared.statePath
    $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler @approval
    Assert ($result.status -eq 'published' -and $result.sourceTag.status -eq 'succeeded') "Publication did not tag the live release: $($result.status) $($result.sourceTag | ConvertTo-Json -Compress)"
    $tags=Get-OriginTags $fixture.origin
    Assert ($tags.Count -eq 1 -and $tags['v1.2.3'].type -eq 'tag' -and $tags['v1.2.3'].commit -ceq $state.plan.head) "Origin did not get exactly the annotated tag on the release source: $($tags | ConvertTo-Json -Compress)"
    Assert ((Invoke-FixtureGit $repo @('tag','--list','--format=%(contents:subject)','v1.2.3')) -ceq 'Fixture 1.2.3') 'The tag message differs from the plan.'
    $again=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler
    Assert ($again.status -eq 'published' -and $again.destinations['itch-windows'].attempts -eq 1 -and (Get-OriginTags $fixture.origin).Count -eq 1) 'A repeated publication repeated work.'
    # A push whose outcome went unrecorded is found on origin, annotated, rather than taken for a conflict.
    $stateFile=Join-Path $prepared.statePath 'state.json'
    $journal=Read-TagState $prepared.statePath;$journal.sourceTag.status='failed';Write-Json $stateFile $journal
    $again=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler
    Assert ($again.status -eq 'published' -and $again.sourceTag.status -eq 'succeeded' -and $again.sourceTag.preflightStatus -eq 'succeeded') "The annotated tag already on origin was not recognized: $($again.sourceTag.error)"
}

Test 'a tag waits while no store is live and follows the store confirmed live' {
    $fixture=New-TagFixture 'tag-await' -Stores
    $prepared=Invoke-ReleasePrepare $fixture.repo @('steam') $fixture.stateRoot $engine
    $state=Read-TagState $prepared.statePath
    $approval=Get-TagApproval $prepared.statePath
    $env:BA_STEAM_USERNAME='fixture-account'
    try {$result=Invoke-ReleasePublish -StatePath $prepared.statePath -SteamCmdExecutable $steam @approval}
    finally {Remove-Item Env:BA_STEAM_USERNAME}
    Assert ($result.sourceTag.status -eq 'awaiting-release' -and $result.status -ne 'published' -and -not (Get-OriginTags $fixture.origin).Count) "An uploaded Steam build was tagged as shipped: $($result.status) $($result.sourceTag.status)"
    $receipt=Join-Path $sandbox 'tag-await-receipt.json'
    Write-Json $receipt @{destination='steam';planId=$state.plan.planId;notesSha256=$approval.ApprovedNotesSha256;observedAt=[DateTimeOffset]::UtcNow.ToString('o');live=$true;appId=100;buildId='999';branch='default';announcementUrl='https://store.steampowered.com/news/app/100/view/123'}
    $confirmed=Confirm-ReleaseStoreCompletion $prepared.statePath $receipt
    Assert ($confirmed.status -eq 'awaiting-release' -and -not (Get-OriginTags $fixture.origin).Count) "Confirmation called the release published before its tag: $($confirmed.status)"
    $result=Invoke-ReleasePublish -StatePath $prepared.statePath -SteamCmdExecutable $steam
    Assert ($result.status -eq 'published' -and $result.destinations.steam.attempts -eq 1 -and (Get-OriginTags $fixture.origin)['v1.2.3'].commit -ceq $state.plan.head) "The confirmed release was not tagged on its source: $($result.status) $($result.sourceTag.error)"
}

Test 'a tag of the release''s name on another commit is never moved and stops publication before any store write' {
    $fixture=New-TagFixture 'tag-conflict'
    $repo=$fixture.repo
    $prepared=Invoke-ReleasePrepare $repo @('itch-windows') $fixture.stateRoot $engine
    $state=Read-TagState $prepared.statePath
    $approval=Get-TagApproval $prepared.statePath
    $older=Invoke-FixtureGit $repo @('rev-parse','HEAD~1')
    Invoke-FixtureGit $repo @('push','--quiet','origin',"${older}:refs/tags/v1.2.3") | Out-Null
    $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler @approval
    Assert ($result.status -eq 'publication-failed' -and $result.sourceTag.preflightStatus -eq 'failed' -and $result.sourceTag.error -match "already names $older on origin.*never moved" -and $result.destinations['itch-windows'].attempts -eq 0) "A conflicting tag on origin did not stop publication: $($result.sourceTag.error)"
    Assert ((Get-OriginTags $fixture.origin)['v1.2.3'].commit -ceq $older) 'The conflicting tag on origin moved.'
    Invoke-FixtureGit $repo @('push','--quiet','origin',':refs/tags/v1.2.3') | Out-Null
    Invoke-FixtureGit $repo @('tag','v1.2.3',$older) | Out-Null
    $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler
    Assert ($result.sourceTag.preflightStatus -eq 'failed' -and $result.sourceTag.error -match 'in this checkout' -and $result.destinations['itch-windows'].attempts -eq 0) "A conflicting tag in this checkout did not stop publication: $($result.sourceTag.error)"
    Assert ((Invoke-FixtureGit $repo @('rev-parse','v1.2.3^{commit}')) -ceq $older -and -not (Get-OriginTags $fixture.origin).Count) 'The checkout''s conflicting tag moved or was pushed.'
    # The right tag on origin does not excuse the wrong one here.
    Invoke-FixtureGit $repo @('push','--quiet','origin',"$($state.plan.head):refs/tags/v1.2.3") | Out-Null
    $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler
    Assert ($result.sourceTag.preflightStatus -eq 'failed' -and $result.sourceTag.error -match "already names $older in this checkout" -and $result.destinations['itch-windows'].attempts -eq 0) "A conflicting tag here passed because origin's was right: $($result.sourceTag.error)"
    Assert ((Invoke-FixtureGit $repo @('rev-parse','v1.2.3^{commit}')) -ceq $older -and (Get-OriginTags $fixture.origin)['v1.2.3'].commit -ceq $state.plan.head) 'A tag moved while publication was refused.'
    # A tag already on the release's source, though made by hand, counts as done and is kept as it is.
    Invoke-FixtureGit $repo @('tag','--delete','v1.2.3') | Out-Null
    $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler
    Assert ($result.status -eq 'published' -and $result.sourceTag.status -eq 'succeeded' -and $null -eq $result.sourceTag.error) "A tag already on the release's source was not accepted: $($result.status) $($result.sourceTag.error)"
    Assert ((Get-OriginTags $fixture.origin)['v1.2.3'].type -eq 'commit') 'A hand-made tag on the release source was replaced.'
}

Test 'a rejected push leaves the store work done and retries from the tag already made, keeping origin''s URL private' {
    $fixture=New-TagFixture 'tag-push-failure'
    $repo=$fixture.repo
    $hook=Join-Path $fixture.origin 'hooks/pre-receive'
    [IO.File]::WriteAllText($hook,"#!/bin/sh`nexit 1`n")
    if (-not $IsWindows) {& chmod +x $hook}
    $prepared=Invoke-ReleasePrepare $repo @('itch-windows') $fixture.stateRoot $engine
    $approval=Get-TagApproval $prepared.statePath
    $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler @approval
    Assert ($result.status -eq 'partial-failure' -and $result.destinations['itch-windows'].status -eq 'succeeded' -and $result.sourceTag.status -eq 'failed' -and $result.sourceTag.error -match 'Pushing v1\.2\.3 to origin failed') "A rejected push was not reported on its own: $($result.status) $($result.sourceTag.error)"
    Assert (-not (Get-OriginTags $fixture.origin).Count -and (Invoke-FixtureGit $repo @('cat-file','-t','v1.2.3')) -ceq 'tag') 'The rejected push left no annotated tag here to retry.'
    $journal=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw
    Assert ($journal -notmatch [regex]::Escape($fixture.origin.Replace('\','/')) -and $journal -notmatch [regex]::Escape($fixture.origin.Replace('\','\\'))) 'The journal kept origin''s URL.'
    Remove-Item -LiteralPath $hook
    $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler
    Assert ($result.status -eq 'published' -and $result.destinations['itch-windows'].attempts -eq 1 -and (Get-OriginTags $fixture.origin)['v1.2.3'].type -eq 'tag') "The retry did not push the tag already made: $($result.status) $($result.sourceTag.error)"
}

Test 'Git without a tagger identity stops the tag before any store write' {
    $fixture=New-TagFixture 'tag-identity'
    $prepared=Invoke-ReleasePrepare $fixture.repo @('itch-windows') $fixture.stateRoot $engine
    $approval=Get-TagApproval $prepared.statePath
    # Git refuses a name made only of characters it strips, as it refuses a missing identity.
    $prior=$env:GIT_COMMITTER_NAME;$env:GIT_COMMITTER_NAME='<>'
    try {$result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler @approval}
    finally {if ($null -eq $prior) {Remove-Item Env:GIT_COMMITTER_NAME} else {$env:GIT_COMMITTER_NAME=$prior}}
    Assert ($result.sourceTag.preflightStatus -eq 'failed' -and $result.sourceTag.error -match 'tagger identity' -and $result.destinations['itch-windows'].attempts -eq 0) "A missing tagger identity did not stop publication: $($result.sourceTag.error)"
}

Test 'a push URL naming another repository, or a second push URL, stops the tag before any store write' {
    $fixture=New-TagFixture 'tag-push-url'
    $prepared=Invoke-ReleasePrepare $fixture.repo @('itch-windows') $fixture.stateRoot $engine
    $approval=Get-TagApproval $prepared.statePath
    Invoke-FixtureGit $fixture.repo @('config','remote.origin.pushurl','https://github.com/Example/Other-Game.git') | Out-Null
    $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler @approval
    Assert ($result.sourceTag.preflightStatus -eq 'failed' -and $result.sourceTag.error -match 'push URL does not name Example/Real-Game' -and $result.destinations['itch-windows'].attempts -eq 0) "A push URL elsewhere did not stop publication: $($result.sourceTag.error)"
    # Both name the planned repository, but a push would go to each, wherever URL rewriting sends them.
    Invoke-FixtureGit $fixture.repo @('config','remote.origin.pushurl','https://github.com/Example/Real-Game.git') | Out-Null
    Invoke-FixtureGit $fixture.repo @('config','--add','remote.origin.pushurl','git@github.com:Example/Real-Game.git') | Out-Null
    $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler
    Assert ($result.sourceTag.preflightStatus -eq 'failed' -and $result.sourceTag.error -match 'push to exactly one URL' -and $result.destinations['itch-windows'].attempts -eq 0 -and -not (Get-OriginTags $fixture.origin).Count) "Two push URLs did not stop publication: $($result.sourceTag.error)"
}

Test 'an edited tag commit in the journal no longer matches the approval, so nothing is sent or tagged' {
    $fixture=New-TagFixture 'tag-journal-edit'
    $repo=$fixture.repo
    $prepared=Invoke-ReleasePrepare $repo @('itch-windows') $fixture.stateRoot $engine
    $approval=Get-TagApproval $prepared.statePath
    $stateFile=Join-Path $prepared.statePath 'state.json'
    $journal=Read-TagState $prepared.statePath
    $older=Invoke-FixtureGit $repo @('rev-parse','HEAD~1')
    $same=Get-ReleasePlan $repo @('itch-windows') -StateRoot $fixture.stateRoot
    $edited=Get-ReleasePlan $repo @('itch-windows') -StateRoot $fixture.stateRoot -TagCommit $older
    Assert ($same.planId -ceq $journal.plan.planId -and $edited.planId -cne $journal.plan.planId) 'The plan ID does not cover the tag commit.'
    $journal.plan.sourceTag.commit=$older;Write-Json $stateFile $journal
    $env:BA_FIXTURE_UPLOAD_LOG=Join-Path $sandbox 'tag-journal-edit-uploads.txt'
    try {Expect-Error {Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler @approval} 'changed after preparation|approval'}
    finally {Remove-Item Env:BA_FIXTURE_UPLOAD_LOG}
    Assert (-not (Test-Path (Join-Path $sandbox 'tag-journal-edit-uploads.txt')) -and -not (Get-OriginTags $fixture.origin).Count -and -not (Invoke-FixtureGit $repo @('tag','--list','v1.2.3'))) 'An edited tag commit led to a store or tag write.'
}

Test 'a tag publication has not reached keeps a confirmed release from counting as published' {
    $fixture=New-TagFixture 'tag-interrupted' -Stores
    $prepared=Invoke-ReleasePrepare $fixture.repo @('steam') $fixture.stateRoot $engine
    $approval=Get-TagApproval $prepared.statePath
    $env:BA_STEAM_USERNAME='fixture-account'
    try {Invoke-ReleasePublish -StatePath $prepared.statePath -SteamCmdExecutable $steam @approval | Out-Null}
    finally {Remove-Item Env:BA_STEAM_USERNAME}
    # A run stopped after saving Steam's result, before the tag step, leaves the tag as the preflight recorded it.
    $stateFile=Join-Path $prepared.statePath 'state.json'
    $journal=Read-TagState $prepared.statePath
    $journal.sourceTag=[ordered]@{status='pending';error=$null;preflightStatus='succeeded'};Write-Json $stateFile $journal
    # A record never written, with every store done, still leaves the tag outstanding.
    $journal.Remove('sourceTag');$journal.destinations.steam.status='succeeded'
    Assert ((& (Get-Module Release) {param($state) Get-ReleaseOverallStatus $state} $journal) -eq 'awaiting-release') 'A planned tag never recorded was left out of the release status.'
    $state=Read-TagState $prepared.statePath
    $receipt=Join-Path $sandbox 'tag-interrupted-receipt.json'
    Write-Json $receipt @{destination='steam';planId=$state.plan.planId;notesSha256=$approval.ApprovedNotesSha256;observedAt=[DateTimeOffset]::UtcNow.ToString('o');live=$true;appId=100;buildId='999';branch='default';announcementUrl='https://store.steampowered.com/news/app/100/view/124'}
    $confirmed=Confirm-ReleaseStoreCompletion $prepared.statePath $receipt
    Assert ($confirmed.status -eq 'awaiting-release' -and -not (Get-OriginTags $fixture.origin).Count) "Confirmation called the release published with its tag still pending: $($confirmed.status)"
    $result=Invoke-ReleasePublish -StatePath $prepared.statePath -SteamCmdExecutable $steam
    Assert ($result.status -eq 'published' -and $result.destinations.steam.attempts -eq 1 -and (Get-OriginTags $fixture.origin)['v1.2.3'].commit -ceq $state.plan.head) "The next publication did not finish the tag: $($result.status) $($result.sourceTag.error)"
}

Test 'a tag made earlier is checked again before an extension''s new store write' {
    $fixture=New-TagFixture 'tag-extension-conflict' -Stores
    $repo=$fixture.repo
    $prepared=Invoke-ReleasePrepare $repo @('itch-windows') $fixture.stateRoot $engine
    $approval=Get-TagApproval $prepared.statePath
    $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler @approval
    Assert ($result.sourceTag.status -eq 'succeeded') "The first release was not tagged: $($result.sourceTag.error)"
    $source=(Read-TagState $prepared.statePath).plan.head
    $older=Invoke-FixtureGit $repo @('rev-parse','HEAD~1')
    Invoke-FixtureGit $repo @('tag','--delete','v1.2.3') | Out-Null
    Invoke-FixtureGit $repo @('tag','v1.2.3',$older) | Out-Null
    $extended=Expand-ReleaseDestinations $prepared.statePath @('steam') $engine
    Assert ($extended.status -eq 'prepared') "The release was not extended to Steam: $($extended.status)"
    $approval=Get-TagApproval $prepared.statePath
    $env:BA_STEAM_USERNAME='fixture-account'
    try {
        $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -SteamCmdExecutable $steam @approval
        Assert ($result.destinations.steam.attempts -eq 0 -and $result.sourceTag.status -eq 'succeeded' -and $result.sourceTag.preflightStatus -eq 'failed' -and $result.sourceTag.error -match "already names $older in this checkout" -and $result.status -ne 'published') "A tag conflict that appeared after tagging let the extension upload: $($result.status) $($result.sourceTag | ConvertTo-Json -Compress)"
        Assert ((Invoke-FixtureGit $repo @('rev-parse','v1.2.3^{commit}')) -ceq $older -and (Get-OriginTags $fixture.origin)['v1.2.3'].commit -ceq $source) 'A tag moved while the extension was refused.'
        # Once the stray tag is reconciled by hand, the added store goes out and the tag on origin stays as it was made.
        Invoke-FixtureGit $repo @('tag','--delete','v1.2.3') | Out-Null
        $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -SteamCmdExecutable $steam
    } finally {Remove-Item Env:BA_STEAM_USERNAME}
    Assert ($result.destinations.steam.attempts -eq 1 -and $result.destinations['itch-windows'].attempts -eq 1 -and $result.sourceTag.preflightStatus -eq 'succeeded' -and $null -eq $result.sourceTag.error -and (Get-OriginTags $fixture.origin)['v1.2.3'].commit -ceq $source) "The reconciled extension did not publish: $($result.status) $($result.sourceTag.error)"
}

Test 'a waiting tag defers to holds until a store is live, and a held release never counts as published' {
    $fixture=New-TagFixture 'tag-held' -Stores
    $prepared=Invoke-ReleasePrepare $fixture.repo @('itch-windows','steam') $fixture.stateRoot $engine
    $held=Set-ReleaseDestinationHold $prepared.statePath @('itch-windows','steam') 'Waiting for launch day.'
    Assert ($held.status -eq 'on-hold') "A wholly held tagged release was not on hold: $($held.status)"
    $approval=Get-TagApproval $prepared.statePath
    $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -SteamCmdExecutable $steam @approval
    Assert ($result.status -eq 'on-hold' -and $result.sourceTag.status -eq 'awaiting-release' -and -not (Get-OriginTags $fixture.origin).Count) "Publishing a wholly held release hid the hold: $($result.status) $($result.sourceTag.status)"
    Set-ReleaseDestinationHold $prepared.statePath @('steam') -Release | Out-Null
    $env:BA_STEAM_USERNAME='fixture-account'
    try {$result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -SteamCmdExecutable $steam}
    finally {Remove-Item Env:BA_STEAM_USERNAME}
    Assert ($result.status -eq 'needs-store-action' -and $result.sourceTag.status -eq 'awaiting-release') "An uploaded Steam build beside a hold was misreported: $($result.status) $($result.sourceTag.status)"
    $state=Read-TagState $prepared.statePath
    $receipt=Join-Path $sandbox 'tag-held-receipt.json'
    Write-Json $receipt @{destination='steam';planId=$state.plan.planId;notesSha256=$approval.ApprovedNotesSha256;observedAt=[DateTimeOffset]::UtcNow.ToString('o');live=$true;appId=100;buildId='999';branch='default';announcementUrl='https://store.steampowered.com/news/app/100/view/125'}
    $confirmed=Confirm-ReleaseStoreCompletion $prepared.statePath $receipt
    Assert ($confirmed.status -eq 'awaiting-release') "With Steam live the waiting tag did not show as the next step: $($confirmed.status)"
    $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -SteamCmdExecutable $steam
    Assert ($result.status -eq 'on-hold' -and $result.sourceTag.status -eq 'succeeded' -and $result.destinations['itch-windows'].status -eq 'held' -and (Get-OriginTags $fixture.origin)['v1.2.3'].commit -ceq $state.plan.head) "The tag did not follow the live store while itch stayed held: $($result.status) $($result.sourceTag.error)"
}

Test 'a tag gone from origin after tagging is owed again before an extension''s release counts as published' {
    $fixture=New-TagFixture 'tag-gone' -Stores
    $repo=$fixture.repo
    $prepared=Invoke-ReleasePrepare $repo @('itch-windows') $fixture.stateRoot $engine
    $approval=Get-TagApproval $prepared.statePath
    $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler @approval
    Assert ($result.sourceTag.status -eq 'succeeded') "The first release was not tagged: $($result.sourceTag.error)"
    $source=(Read-TagState $prepared.statePath).plan.head
    $made=Invoke-FixtureGit $repo @('rev-parse','refs/tags/v1.2.3')
    # Gone from origin only: this checkout's tag goes back as it was made.
    Invoke-FixtureGit $repo @('push','--quiet','origin',':refs/tags/v1.2.3') | Out-Null
    Assert ((Expand-ReleaseDestinations $prepared.statePath @('itch-linux') $engine).status -eq 'prepared') 'The release was not extended to itch Linux.'
    $approval=Get-TagApproval $prepared.statePath
    $env:BA_FIXTURE_ALLOW_LINUX='1'
    try {$result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler @approval}
    finally {Remove-Item Env:BA_FIXTURE_ALLOW_LINUX}
    Assert ($result.status -eq 'published' -and $result.destinations['itch-linux'].attempts -eq 1 -and $result.destinations['itch-windows'].attempts -eq 1 -and $result.sourceTag.status -eq 'succeeded' -and (Invoke-FixtureGit $fixture.origin @('for-each-ref','--format=%(objectname)','refs/tags/v1.2.3')) -ceq $made) "A tag gone from origin was taken as done: $($result.status) $(Get-OriginTags $fixture.origin | ConvertTo-Json -Compress)"
    # Gone from origin and here: the tag must be made anew, which needs a tagger, so nothing is sent until Git has one.
    Invoke-FixtureGit $repo @('push','--quiet','origin',':refs/tags/v1.2.3') | Out-Null
    Invoke-FixtureGit $repo @('tag','--delete','v1.2.3') | Out-Null
    Assert ((Expand-ReleaseDestinations $prepared.statePath @('steam') $engine).status -eq 'prepared') 'The release was not extended to Steam.'
    $approval=Get-TagApproval $prepared.statePath
    $env:BA_STEAM_USERNAME='fixture-account'
    $prior=$env:GIT_COMMITTER_NAME
    try {
        $env:GIT_COMMITTER_NAME='<>'
        $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -SteamCmdExecutable $steam @approval
        Assert ($result.destinations.steam.attempts -eq 0 -and $result.sourceTag.status -eq 'failed' -and $result.sourceTag.error -match 'tagger identity' -and $result.status -ne 'published' -and -not (Get-OriginTags $fixture.origin).Count) "A tag gone everywhere was taken as done without a tagger to make it: $($result.status) $($result.sourceTag | ConvertTo-Json -Compress)"
        if ($null -eq $prior) {Remove-Item Env:GIT_COMMITTER_NAME} else {$env:GIT_COMMITTER_NAME=$prior}
        $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -SteamCmdExecutable $steam
    } finally {
        Remove-Item Env:BA_STEAM_USERNAME
        if ($null -eq $prior) {Remove-Item Env:GIT_COMMITTER_NAME -ErrorAction SilentlyContinue} else {$env:GIT_COMMITTER_NAME=$prior}
    }
    $tags=Get-OriginTags $fixture.origin
    Assert ($result.destinations.steam.attempts -eq 1 -and $result.sourceTag.status -eq 'succeeded' -and $tags['v1.2.3'].type -eq 'tag' -and $tags['v1.2.3'].commit -ceq $source) "The tag was not made anew on the release's source: $($result.sourceTag.error) $($tags | ConvertTo-Json -Compress)"
}

Test 'a tag another checkout''s live store made ready is not hidden behind a hold here' {
    $fixture=New-TagFixture 'tag-shared-live' -Stores
    $repo=$fixture.repo
    # This checkout's Steam build is confirmed live while its tag still waits for the next publication.
    $first=Invoke-ReleasePrepare $repo @('steam') $fixture.stateRoot $engine
    $approval=Get-TagApproval $first.statePath
    $env:BA_STEAM_USERNAME='fixture-account'
    try {Invoke-ReleasePublish -StatePath $first.statePath -SteamCmdExecutable $steam @approval | Out-Null}
    finally {Remove-Item Env:BA_STEAM_USERNAME}
    $state=Read-TagState $first.statePath
    $receipt=Join-Path $sandbox 'tag-shared-live-receipt.json'
    Write-Json $receipt @{destination='steam';planId=$state.plan.planId;notesSha256=$approval.ApprovedNotesSha256;observedAt=[DateTimeOffset]::UtcNow.ToString('o');live=$true;appId=100;buildId='999';branch='default';announcementUrl='https://store.steampowered.com/news/app/100/view/126'}
    Assert ((Confirm-ReleaseStoreCompletion $first.statePath $receipt).status -eq 'awaiting-release' -and -not (Get-OriginTags $fixture.origin).Count) 'The fixture did not leave a live release waiting for its tag.'
    # Another checkout of the same source holds its only store, yet its tag can be made now.
    $worktree=Join-Path $sandbox 'tag-shared-live-worktree'
    Invoke-FixtureGit $repo @('worktree','add','--quiet','--detach',$worktree,$state.plan.head) | Out-Null
    $second=Invoke-ReleasePrepare $worktree @('itch-windows') $fixture.stateRoot $engine
    $held=Set-ReleaseDestinationHold $second.statePath @('itch-windows') 'Waiting for launch day.'
    Assert ($held.status -eq 'awaiting-release') "A hold hid tag work another checkout's live store made ready: $($held.status)"
    $approval=Get-TagApproval $second.statePath
    $result=Invoke-ReleasePublish -StatePath $second.statePath -ButlerExecutable $butler @approval
    Assert ($result.status -eq 'on-hold' -and $result.sourceTag.status -eq 'succeeded' -and $result.destinations['itch-windows'].attempts -eq 0 -and (Get-OriginTags $fixture.origin)['v1.2.3'].commit -ceq $state.plan.head) "The ready tag was not made while the store stayed held: $($result.status) $($result.sourceTag.error)"
}

Test 'doctor needs a tagger identity only for a tag still to be made' {
    $fixture=New-TagFixture 'tag-doctor'
    $repo=$fixture.repo
    $prior=$env:GIT_COMMITTER_NAME;$env:GIT_COMMITTER_NAME='<>'
    try {
        $check=@((Get-ReleaseDoctor -Repository $repo -Destination @('itch-windows') -GodotExecutable $engine -ButlerExecutable $butler).checks | Where-Object id -EQ 'source-tag')
        Assert ($check.Count -eq 1 -and $check[0].status -eq 'blocked' -and $check[0].message -match 'tagger identity') "Doctor did not block a tag it would have to make without a tagger: $($check | ConvertTo-Json -Compress)"
        Invoke-FixtureGit $repo @('tag','v1.2.3') | Out-Null
        $check=@((Get-ReleaseDoctor -Repository $repo -Destination @('itch-windows') -GodotExecutable $engine -ButlerExecutable $butler).checks | Where-Object id -EQ 'source-tag')
        Assert ($check.Count -eq 1 -and $check[0].status -eq 'unverified' -and $check[0].message -match 'already names the release''s source') "Doctor required a tagger for a tag it reuses: $($check | ConvertTo-Json -Compress)"
    } finally {if ($null -eq $prior) {Remove-Item Env:GIT_COMMITTER_NAME} else {$env:GIT_COMMITTER_NAME=$prior}}
}

Test 'an extension that moves HEAD for an Android counter keeps the tag on the release''s original source' {
    $fixture=New-TagFixture 'tag-extension' -Stores
    $repo=$fixture.repo
    Change-Config $repo {param($c) $c.androidVersionCodePolicy='increment-selected'}
    Invoke-FixtureGit $repo @('add','release.json') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Choose Android counter') | Out-Null
    $prepared=Invoke-ReleasePrepare $repo @('itch-windows') $fixture.stateRoot $engine
    $original=(Read-TagState $prepared.statePath).plan.head
    $approval=Get-TagApproval $prepared.statePath
    $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler @approval
    Assert ($result.sourceTag.status -eq 'succeeded') "The first release was not tagged: $($result.sourceTag.error)"
    $extended=Expand-ReleaseDestinations $prepared.statePath @('google-play') $engine
    Assert ($extended.status -eq 'source-update-required') "The later Play inclusion did not reserve its counter: $($extended.status)"
    Invoke-FixtureGit $repo @('add','export_presets.cfg') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Reserve later Play code') | Out-Null
    $extended=Expand-ReleaseDestinations $prepared.statePath @('google-play') $engine
    $state=Read-TagState $prepared.statePath
    Assert ($extended.status -eq 'prepared' -and $state.plan.head -cne $original -and $state.plan.sourceTag.commit -ceq $original) 'The extension moved the planned tag with HEAD.'
    $approval=Get-TagApproval $prepared.statePath
    $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -PlayTransport {throw 'Keep Play unsubmitted in this fixture.'} @approval
    Assert ($result.sourceTag.status -eq 'succeeded' -and $result.destinations['itch-windows'].attempts -eq 1 -and (Get-OriginTags $fixture.origin)['v1.2.3'].commit -ceq $original) "Publishing the extension moved or failed the tag: $($result.sourceTag.error)"
}

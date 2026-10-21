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
    # A tag already on the release's source, though made by hand, counts as done and is kept as it is.
    Invoke-FixtureGit $repo @('tag','--delete','v1.2.3') | Out-Null
    Invoke-FixtureGit $repo @('push','--quiet','origin',"$($state.plan.head):refs/tags/v1.2.3") | Out-Null
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

Test 'a push URL naming another repository stops the tag before any store write' {
    $fixture=New-TagFixture 'tag-push-url'
    $prepared=Invoke-ReleasePrepare $fixture.repo @('itch-windows') $fixture.stateRoot $engine
    $approval=Get-TagApproval $prepared.statePath
    Invoke-FixtureGit $fixture.repo @('config','remote.origin.pushurl','https://github.com/Example/Other-Game.git') | Out-Null
    $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler @approval
    Assert ($result.sourceTag.preflightStatus -eq 'failed' -and $result.sourceTag.error -match 'push URL does not name Example/Real-Game' -and $result.destinations['itch-windows'].attempts -eq 0) "A push URL elsewhere did not stop publication: $($result.sourceTag.error)"
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

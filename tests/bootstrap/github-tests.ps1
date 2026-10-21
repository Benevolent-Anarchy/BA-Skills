Import-Module "$skillRoot/scripts/Presets.psm1" -Force
Import-Module "$skillRoot/scripts/Preparation.psm1" -Force
function Get-FoundationFixturePlan($Identity,$Request,$StateRoot,$Git) {
    $parameters=@{Identity=$Identity;Request=$Request;StateRoot=$StateRoot;PresetSelection=(Resolve-BootstrapPreset $Identity -Preset foundation)}
    if ($null -ne $Git) {$parameters.Git=$Git}
    Get-BootstrapPlan @parameters
}
function Invoke-FoundationFixtureBootstrap($Identity,$StateRoot,$Request,$Git,$ObsidianSetup,[switch]$RefreshPlugins) {
    Invoke-Bootstrap -Identity $Identity -StateRoot $StateRoot -Request $Request -Git $Git -ObsidianSetup $ObsidianSetup -PresetSelection (Resolve-BootstrapPreset $Identity -Preset foundation) -RefreshPlugins:$RefreshPlugins
}
Import-Module "$skillRoot/scripts/Project.psm1" -Force
Import-Module "$skillRoot/scripts/GitHub.psm1" -Force
Import-Module "$skillRoot/scripts/State.psm1" -Force
if (Test-Path "$skillRoot/scripts/Bootstrap.psm1") {Import-Module "$skillRoot/scripts/Bootstrap.psm1" -Force}
. "$PSScriptRoot/GitHubFixture.ps1"
function New-ApiIdentity($Name) {New-BootstrapIdentity -Name $Name -Description 'Private project purpose' -Parent (New-BootstrapFixture 'project-parent')}
foreach ($case in @(
    @{name='relative';description='Successor to the [prototype notes](docs/prototype.md).'},
    @{name='anchor';description='See [the overview](#overview).'}
)) {
    Test "review description preflight blocks broken $($case.name) links without creation" {
        $f=New-GitHubFixture;$id=New-ApiIdentity ('Broken Description '+$case.name);$id.description=$case.description
        $plan=Get-FoundationFixturePlan $id $f.request $f.stateRoot $f.git
        $create=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
        foreach ($report in @($plan,$create)) {
            Assert ($report.status -eq 'blocked' -and ($report.conflicts -join ' ') -match 'README.md:3: link-target:') 'Broken description did not fail preflight with its documentation diagnostic.'
        }
        Assert ($f.repos.Count -eq 0 -and @($f.calls | Where-Object method -ne 'GET').Count -eq 0 -and $f.gitCalls.Count -eq 0) 'Invalid description changed repositories or Git state.'
        Assert (-not (Test-Path -LiteralPath $id.projectPath) -and @(Get-ChildItem -LiteralPath $f.stateRoot -Force).Count -eq 0) 'Invalid description created project files or a journal/lock.'
        $id.description='See [the project map](docs/NEXT.md).'
        Assert ((Get-FoundationFixturePlan $id $f.request $f.stateRoot $f.git).status -eq 'ready') 'Correcting the description remained blocked by bootstrap state.'
    }
}
Test 'review description preflight preserves valid local and external Markdown links' {
    $f=New-GitHubFixture;$id=New-ApiIdentity 'Valid Description Links'
    $id.description='See [the project map](docs/NEXT.md), [this project](#valid-description-links), and [the source](https://example.invalid/missing.md#overview).'
    Assert ((Get-FoundationFixturePlan $id $f.request $f.stateRoot $f.git).status -eq 'ready') 'Valid description links were rejected.'
    $report=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($report.phases.ContainsKey('privateContent') -and $report.phases.privateContent -eq 'verified' -and $f.repos.Count -eq 2) 'Valid linked description could not create its foundation.'
    Assert ([IO.File]::ReadAllText((Join-Path $id.projectPath 'README.md')).Contains($id.description)) 'Description Markdown was rewritten.'
}
function New-UnjournalledCommitFixture($Name) {
    $f=New-GitHubFixture;$id=New-ApiIdentity $Name;$baseGit=$f.git;$interruption=@{pending=$true}
    $git={param($Repository,$Arguments)
        if ($interruption.pending -and ($Arguments -join ' ') -eq 'rev-parse HEAD') {$interruption.pending=$false;return @{ExitCode=1;Output='Interrupted before recording the initial commit'}}
        & $baseGit $Repository $Arguments
    }.GetNewClosure()
    $first=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $git $f.obsidianSetup
    Assert ($first.status -eq 'partial' -and -not (Read-BootstrapJournal (Get-BootstrapJournalPath $id $f.stateRoot)).refs.ContainsKey('privateMain')) 'Fixture did not interrupt the commit receipt.'
    @{api=$f;identity=$id;git=$git}
}
Test 'followup unjournalled initial commit resumes once without changing the commit' {
    $case=New-UnjournalledCommitFixture 'Interrupted Commit';$f=$case.api;$id=$case.identity
    $head=Invoke-FixtureGit $id.projectPath @('rev-parse','HEAD');$path=Get-BootstrapJournalPath $id $f.stateRoot;$before=(Get-FileHash $path).Hash
    Assert ((Get-FoundationFixturePlan $id $f.request $f.stateRoot $case.git).status -eq 'ready') 'An exact initial foundation could not be recovered.'
    Assert ((Get-FileHash $path).Hash -eq $before) 'Read-only plan journalled recovery.'
    $second=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $case.git $f.obsidianSetup
    Assert ($second.phases.ContainsKey('privateContent') -and $second.phases.privateContent -eq 'verified') 'Interrupted commit could not resume.'
    $journal=Read-BootstrapJournal $path
    Assert ($journal.refs.privateMain -eq $head -and (Invoke-FixtureGit $id.projectPath @('rev-list','--count','HEAD')) -eq '1') 'Recovery made a second commit or recorded a different head.'
    Assert ((& git --git-dir=$($f.repos[$id.fullName].bare) rev-parse main) -eq $head) 'Recovery pushed a different commit.'
    Assert (@($f.gitCalls | Where-Object {$_.arguments[0] -eq 'commit'}).Count -eq 1 -and @($f.calls | Where-Object isRepositoryCreate).Count -eq 2) 'Recovery repeated commit or repository creation.'
}
Test 'followup unjournalled recovery refuses altered trees and additional history' {
    foreach ($change in @('extra','blob','history')) {
        $case=New-UnjournalledCommitFixture ('Interrupted '+$change);$f=$case.api;$id=$case.identity
        switch ($change) {
            extra {
                Write-FixtureText "$($id.projectPath)/unrelated.txt" 'Unrelated'
                Invoke-FixtureGit $id.projectPath @('add','unrelated.txt') | Out-Null
                Invoke-FixtureGit $id.projectPath @('commit','--amend','--no-edit') | Out-Null
            }
            blob {
                $readme=@(Get-ProjectManifest $id | Where-Object path -eq 'README.md')[0].text
                Write-FixtureText "$($id.projectPath)/README.md" ($readme+'Changed commit content')
                Invoke-FixtureGit $id.projectPath @('add','README.md') | Out-Null
                Invoke-FixtureGit $id.projectPath @('commit','--amend','--no-edit') | Out-Null
                Write-FixtureText "$($id.projectPath)/README.md" $readme
            }
            history {Invoke-FixtureGit $id.projectPath @('commit','--allow-empty','-m','Unrelated second commit') | Out-Null}
        }
        $before=$f.calls.Count
        $report=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $case.git $f.obsidianSetup
        Assert ($report.status -eq 'blocked') "Unexpected $change commit was accepted."
        Assert (@($f.calls | Select-Object -Skip $before | Where-Object method -ne 'GET').Count -eq 0 -and @($f.gitCalls | Where-Object {$_.arguments[0] -eq 'push'}).Count -eq 0) 'Invalid recovery mutated a remote.'
    }
}
Test 'review rejected creation reports the error and resumes after correction' {
    foreach ($case in @(@{kind='private';status=422},@{kind='public';status=403})) {
        $f=New-GitHubFixture;$id=New-ApiIdentity ('Rejected '+$case.kind)
        $f.createFailureKind=$case.kind;$f.createFailureStatus=$case.status
        $first=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
        Assert ($first.status -eq 'blocked' -and ($first.pending -join ' ') -match "HTTP $($case.status).*rejected by policy") 'Definitive rejection was hidden or quarantined as an unknown creation.'
        $path=Get-BootstrapJournalPath $id $f.stateRoot;$journal=Read-BootstrapJournal $path
        Assert ($journal.phases[$case.kind+'Repository'] -eq 'failed' -and $journal.creationFailures[$case.kind].errors[0].field -eq 'name') 'Rejected create error details were not retained.'
        $ids=$journal.repositories.Clone();$hash=(Get-FileHash $path).Hash;$offset=$f.calls.Count
        $status=Get-BootstrapStatus $id $f.stateRoot $f.request
        Assert ($status.status -eq 'blocked' -and ($status.pending -join ' ') -match 'rejected by policy') 'Status lost the actionable rejection.'
        Assert ((Get-FileHash $path).Hash -eq $hash -and @($f.calls | Select-Object -Skip $offset | Where-Object method -ne 'GET').Count -eq 0) 'Status changed state.'
        $f.createFailureStatus=$null
        $second=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
        Assert ($second.phases.privateContent -eq 'verified' -and $second.phases.publicContent -eq 'verified' -and $f.repos.Count -eq 2) 'Explicit retry could not finish repository foundations.'
        foreach ($kind in $ids.Keys) {Assert ($f.repos[$id.fullName].id -eq $ids[$kind]) 'Retry replaced the already journalled private repository.'}
        Assert (@($f.calls | Where-Object isRepositoryCreate).Count -eq 3) 'Retry duplicated successful creation or retried without a new invocation.'
        Assert (-not (Read-BootstrapJournal $path).creationFailures.ContainsKey($case.kind)) 'Successful retry retained a stale creation failure.'
    }
}
Test 'review rejected creation never adopts a newly colliding repository' {
    $f=New-GitHubFixture;$id=New-ApiIdentity 'Rejected Collision';$f.createFailureKind='public';$f.createFailureStatus=422
    Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup | Out-Null
    $f.createFailureStatus=$null;$f.existingPublic=$true;$before=$f.calls.Count
    $result=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($result.status -eq 'blocked' -and ($result.conflicts -join ' ') -match 'name already exists') 'A rejected create granted ownership of a later name collision.'
    Assert (@($f.calls | Select-Object -Skip $before | Where-Object method -ne 'GET').Count -eq 0) 'Collision caused a mutation.'
}
Test 'review uncertain creation remains quarantined in status and retries' {
    foreach ($code in @(0,408,503)) {
        $f=New-GitHubFixture;$id=New-ApiIdentity ('Uncertain '+$code);$f.createFailureStatus=$code
        $first=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
        Assert ($first.status -eq 'identity-unconfirmed') "Ambiguous HTTP $code was marked safe to retry."
        $f.createFailureStatus=$null
        Assert ((Get-BootstrapStatus $id $f.stateRoot $f.request).status -eq 'identity-unconfirmed') 'Status hid an unresolved creation.'
        Assert ((Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup).status -eq 'identity-unconfirmed') 'Unresolved creation was retried.'
        Assert (@($f.calls | Where-Object isRepositoryCreate).Count -eq 1) 'Ambiguous create repeated.'
    }
}
Test 'review global Git excludes cannot omit foundation files or stage unrelated files' {
    $f=New-GitHubFixture;$id=New-ApiIdentity 'Global Excludes';$configRoot=New-BootstrapFixture 'global-config'
    Write-FixtureText "$configRoot/ignore" "CLAUDE.md`nAGENTS.md`n*.env`n"
    $ignorePath="$configRoot/ignore".Replace('\','/')
    Write-FixtureText "$configRoot/gitconfig" "[core]`n    excludesFile = $ignorePath`n[user]`n    name = Fixture`n    email = fixture@example.invalid`n"
    $saved=$env:GIT_CONFIG_GLOBAL;$baseGit=$f.git
    $git={param($Repository,$Arguments)
        if ($Arguments[0] -eq 'add') {Write-FixtureText "$Repository/unrelated.env" 'Keep untracked'}
        & $baseGit $Repository $Arguments
    }.GetNewClosure()
    try {
        $env:GIT_CONFIG_GLOBAL="$configRoot/gitconfig"
        $report=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $git $f.obsidianSetup
        Assert ($report.phases.ContainsKey('privateContent') -and $report.phases.privateContent -eq 'verified') 'Global excludes blocked the private foundation.'
        $tracked=Invoke-FixtureGit $id.projectPath @('ls-files')
        Assert (($tracked -split "`n") -contains 'CLAUDE.md' -and ($tracked -split "`n") -contains 'AGENTS.md') 'Required agent entry points were omitted.'
        Assert ($tracked -notmatch 'unrelated.env' -and (Test-Path "$($id.projectPath)/unrelated.env")) 'Force staging included unrelated ignored content.'
    } finally {$env:GIT_CONFIG_GLOBAL=$saved}
}
Test 'creation disables pull requests through supported API readback and status detects reactivation' {
    $f=New-GitHubFixture;$id=New-ApiIdentity 'API Pull Requests';$f.supportsPullRequests=$true
    $report=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($report.phases.pullRequests -eq 'verified' -and -not $f.repos[$id.notesFullName].has_pull_requests) 'API Pull requests were not disabled and verified.'
    $f.repos[$id.notesFullName].has_pull_requests=$true
    $offset=$f.calls.Count
    $status=Get-BootstrapStatus $id $f.stateRoot $f.request
    Assert ($status.status -eq 'blocked' -and @($f.calls | Select-Object -Skip $offset | Where-Object method -ne 'GET').Count -eq 0) 'Status silently accepted/repaired reactivated pull requests.'
}
Test 'creation verifies public settings with current API fields and no legacy downloads field' {
    $f=New-GitHubFixture;$id=New-ApiIdentity 'Current Fields';$f.omitDownloads=$true
    $report=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($report.phases.publicSettings -eq 'verified') 'Omitted legacy field blocked supported settings.'
    $status=Get-BootstrapStatus $id $f.stateRoot $f.request
    Assert ($status.status -eq 'partial' -and $status.conflicts.Count -eq 0) 'Status required an unavailable field.'
}
Test 'creation compares recursive tree files while preserving unexpected-file failures' {
    foreach ($type in @('tree','blob')) {
        $f=New-GitHubFixture;$id=New-ApiIdentity 'Recursive Tree'
        $f.privateTreeExtras=@(@{path='docs';type=$type})
        $report=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
        if ($type -eq 'tree') {Assert ($report.phases.privateContent -eq 'verified') 'Directory nodes blocked manifest verification.'}
        else {Assert (-not $report.phases.ContainsKey('privateContent') -and ($report.pending -join ' ') -match 'tree differs') 'Unexpected file passed tree verification.'}
    }
}
Test 'creation handles the documented empty repository ref conflict without hiding other conflicts' {
    foreach ($message in @('Git Repository is empty.','Unrelated repository conflict.')) {
        $f=New-GitHubFixture;$id=New-ApiIdentity 'Empty Ref';$f.emptyRefStatus=409;$f.emptyRefMessage=$message
        $report=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
        if ($message -eq 'Git Repository is empty.') {
            Assert ($report.phases.privateContent -eq 'verified' -and $report.phases.publicContent -eq 'verified') 'Empty repository blocked initial push.'
        } else {
            Assert ($report.status -eq 'partial' -and @($f.gitCalls | Where-Object {$_.arguments[0] -eq 'push'}).Count -eq 0) 'Unrelated conflict caused a push.'
        }
    }
}
Test 'creation and status report installed plugins and skipped inconsistent releases' {
    $f=New-GitHubFixture;$id=New-ApiIdentity 'Plugin Report'
    $f.obsidianSetup={param($Identity,$StateRoot,$Refresh) @{installedVerified=$true;enabledVerified=$false;plugins=@(@{id='dataview';version='9.0.0';skipped=@(@{tag='9.1.0';reason='Manifest version differs'})});pending=@('App pending');journalPath='fixture'}}
    $report=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($report.obsidian.plugins[0].skipped[0].tag -eq '9.1.0') 'Create report hid skipped release.'
    $status=Get-BootstrapStatus $id $f.stateRoot $f.request
    Assert ($status.obsidian.plugins[0].version -eq '9.0.0' -and $status.obsidian.plugins[0].skipped[0].reason) 'Read-only status hid plugin receipt.'
}
Test 'creation preflights both names auth owner and local collisions before mutation' {
    foreach ($failure in @('public','auth','owner','access','local')) {
        $f=New-GitHubFixture -ExistingPublic:($failure -eq 'public');$id=New-ApiIdentity 'Collision'
        if ($failure -eq 'auth') {$f.authStatus=401}
        if ($failure -eq 'owner') {$f.ownerStatus=404}
        if ($failure -eq 'access') {$f.orgRole='member'}
        if ($failure -eq 'local') {Write-FixtureText "$($id.projectPath)/unrelated.txt" 'Preserve'}
        $report=Invoke-FoundationFixtureBootstrap -Identity $id -StateRoot $f.stateRoot -Request $f.request -Git $f.git -ObsidianSetup $f.obsidianSetup
        Assert ($report.status -eq 'blocked') "Collision accepted: $failure"
        Assert (@($f.calls | Where-Object method -ne 'GET').Count -eq 0) "Mutation preceded preflight: $failure"
    }
}
Test 'creation plans without changing remote or local state' {
    $f=New-GitHubFixture;$id=New-ApiIdentity 'Read Only'
    $plan=Get-FoundationFixturePlan $id $f.request $f.stateRoot
    Assert ($plan.status -eq 'ready') ($plan | ConvertTo-Json -Depth 9 -Compress)
    Assert (-not (Test-Path $id.projectPath)) 'Plan created checkout.'
    Assert (@(Get-ChildItem $f.stateRoot -Force).Count -eq 0) 'Plan wrote state.'
    Assert (@($f.calls | Where-Object method -ne 'GET').Count -eq 0) 'Plan mutated GitHub.'
}
Test 'creation seeds exact private and public trees with main and labels' {
    $f=New-GitHubFixture;$id=New-ApiIdentity 'Foundation'
    $report=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($report.status -eq 'partial') ($report | ConvertTo-Json -Depth 9 -Compress)
    Assert (@($report.pending | Where-Object {$_ -match 'Pull requests'}).Count -eq 1) 'Missing browser phase falsely complete.'
    $private=$f.repos[$id.fullName];$public=$f.repos[$id.notesFullName]
    Assert ($private.private -and $private.description -eq $id.description -and $private.has_issues) 'Wrong private identity.'
    Assert (-not $public.private -and $null -eq $public.description -and $public.readme -ceq (Get-PublicReadme $id)) 'Private material leaked.'
    Assert ($public.tree.Count -eq 1 -and $public.default_branch -eq 'main' -and -not $public.actions.enabled) 'Public foundation wrong.'
    Assert (-not $public.has_wiki -and -not $public.has_projects -and -not $public.has_discussions -and -not $public.has_issues -and -not $public.archived -and $public.permissions.push) 'Incorrect publication settings.'
    Assert ($private.labels.Count -eq 23) 'Label snapshot missing.'
    $journal=Read-BootstrapJournal (Get-BootstrapJournalPath $id $f.stateRoot)
    $staging=Get-BootstrapPreparationSource $journal $f.stateRoot
    Assert (@($f.gitCalls | Where-Object {$_.repository -notin @($id.projectPath,$staging)}).Count -eq 0) 'Git used a checkout other than the owned staging/private project.'
    Assert ((Invoke-FixtureGit $id.projectPath @('branch','--show-current')) -eq 'main') 'Wrong local branch.'
    Assert ((Invoke-FixtureGit $id.projectPath @('status','--porcelain')) -eq '') 'Foundation left dirty.'
}
Test 'creation resumes failed labels without recreating repos or contents' {
    $f=New-GitHubFixture -FailPhase labels;$id=New-ApiIdentity 'Retry'
    $first=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($first.status -eq 'partial') 'Failed phase not partial.'
    $f.failPhase=''
    $second=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert (@($f.calls | Where-Object isRepositoryCreate).Count -eq 2) 'Repos duplicated.'
    Assert ($second.phases.labels -eq 'verified') 'Labels did not resume.'
    Assert (@($f.calls | Where-Object { $_.method -eq 'PUT' -and $_.endpoint -like '*/contents/*' }).Count -eq 1) 'Content seed duplicated.'
}
Test 'creation quarantines an unconfirmed lost repository creation outcome' {
    $f=New-GitHubFixture;$f.lostCreate=$true;$id=New-ApiIdentity 'Ambiguous'
    $first=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($first.status -eq 'identity-unconfirmed') ($first | ConvertTo-Json -Compress -Depth 9)
    $f.lostCreate=$false
    $second=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($second.status -eq 'identity-unconfirmed') 'Unconfirmed repo adopted.'
    Assert (@($f.calls | Where-Object isRepositoryCreate).Count -eq 1) 'Ambiguous create retried.'
}
Test 'creation verifies lost push and public seed by readback before any retry' {
    $f=New-GitHubFixture;$f.lostPush=$true;$f.lostContents=$true;$id=New-ApiIdentity 'Lost Response'
    $report=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($report.phases.privateContent -eq 'verified' -and $report.phases.publicContent -eq 'verified') ($report | ConvertTo-Json -Depth 9 -Compress)
    Assert (@($f.gitCalls | Where-Object {$_.arguments[0] -eq 'push'}).Count -eq 1) 'Push repeated.'
}
Test 'creation refuses changed repository IDs origins and staged content during recovery' {
    foreach ($change in @('id','visibility','origin','stage','input')) {
        $f=New-GitHubFixture -FailPhase labels;$id=New-ApiIdentity ('Recovery '+$change)
        Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup | Out-Null
        $before=@($f.calls | Where-Object method -ne 'GET').Count
        switch ($change) {
            id {$f.repos[$id.fullName].id++}
            visibility {$f.repos[$id.notesFullName].private=$true}
            origin {Invoke-FixtureGit $id.projectPath @('remote','set-url','origin','https://github.com/other/unrelated.git') | Out-Null}
            stage {Write-FixtureText "$($id.projectPath)/unrelated.txt" 'Keep';Invoke-FixtureGit $id.projectPath @('add','unrelated.txt') | Out-Null}
            input {$id.description='Changed'}
        }
        $f.failPhase=''
        $report=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
        Assert ($report.status -eq 'blocked') "Changed $change accepted."
        Assert (@($f.calls | Where-Object method -ne 'GET').Count -eq $before) "Mutation preceded recovery validation: $change"
    }
}
Test 'creation status and resume report a completed project its owner made public' {
    $f=New-GitHubFixture;$f.supportsPullRequests=$true;$f.appEnabled=$true;$id=New-ApiIdentity 'Opened Later'
    Assert ((Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup).status -eq 'complete') 'Fixture did not complete.'
    Assert ((Get-BootstrapStatus $id $f.stateRoot $f.request).projectVisibility -eq 'private') 'Status did not report the private project.'
    $journalPath=Get-BootstrapJournalPath $id $f.stateRoot;$before=[IO.File]::ReadAllText($journalPath)
    $f.repos[$id.fullName].private=$false
    $mutations=@($f.calls | Where-Object method -ne 'GET').Count
    $status=Get-BootstrapStatus $id $f.stateRoot $f.request
    $resume=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    foreach ($report in @($status,$resume)) {
        Assert ($report.status -eq 'complete' -and $report.conflicts.Count -eq 0 -and $report.projectVisibility -eq 'public') ('Public project was not a non-blocking fact: '+($report | ConvertTo-Json -Depth 9 -Compress))
    }
    Assert ([IO.File]::ReadAllText($journalPath) -ceq $before -and @($f.calls | Where-Object method -ne 'GET').Count -eq $mutations) 'Visibility readback rewrote the journal or a repository.'
}
Test 'creation still refuses a changed identity or private companion once the project is public' {
    foreach ($change in @('id','name','companion')) {
        $f=New-GitHubFixture;$f.supportsPullRequests=$true;$f.appEnabled=$true;$id=New-ApiIdentity ('Opened '+$change)
        Assert ((Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup).status -eq 'complete') 'Fixture did not complete.'
        $f.repos[$id.fullName].private=$false
        switch ($change) {
            id {$f.repos[$id.fullName].id++}
            name {$f.repos[$id.fullName].full_name="$($id.owner)/Renamed-Project"}
            companion {$f.repos[$id.notesFullName].private=$true}
        }
        $mutations=@($f.calls | Where-Object method -ne 'GET').Count
        foreach ($report in @((Get-BootstrapStatus $id $f.stateRoot $f.request),(Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup))) {
            Assert ($report.status -eq 'blocked' -and ($report.conflicts -join ' ') -match 'identity differs|no longer public') "Changed $change accepted: $($report.conflicts -join '; ')"
        }
        Assert (@($f.calls | Where-Object method -ne 'GET').Count -eq $mutations) "Refused $change still mutated a repository."
    }
}
Test 'creation blocks a project made public before its foundation was published until it is private again' {
    $f=New-GitHubFixture;$id=New-ApiIdentity 'Opened Early';$f.emptyRefStatus=409;$f.emptyRefMessage='Unrelated repository conflict.'
    $first=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($first.status -eq 'partial' -and $first.phases.privateRepository -eq 'verified' -and -not $first.phases.ContainsKey('privateContent')) 'Fixture did not stop before publishing the foundation.'
    $f.emptyRefStatus=404;$f.repos[$id.fullName].private=$false
    $mutations=@($f.calls | Where-Object method -ne 'GET').Count
    foreach ($report in @((Get-BootstrapStatus $id $f.stateRoot $f.request),(Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup))) {
        Assert ($report.status -eq 'blocked' -and ($report.conflicts -join ' ') -match 'became public before bootstrap published its foundation') ('Early public project was accepted: '+($report | ConvertTo-Json -Depth 9 -Compress))
    }
    Assert (@($f.calls | Where-Object method -ne 'GET').Count -eq $mutations -and @($f.gitCalls | Where-Object {$_.arguments[0] -eq 'push'}).Count -eq 0) 'Foundation was published into a public repository.'
    $f.repos[$id.fullName].private=$true
    $resumed=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($resumed.phases.privateContent -eq 'verified' -and $resumed.projectVisibility -eq 'private') ('Private again, resume did not publish the foundation: '+($resumed | ConvertTo-Json -Depth 9 -Compress))
}
Test 'creation resumes a project made public after its foundation was published' {
    $f=New-GitHubFixture -FailPhase labels;$f.supportsPullRequests=$true;$f.appEnabled=$true;$id=New-ApiIdentity 'Opened Midway'
    $first=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($first.status -eq 'partial' -and $first.phases.privateContent -eq 'verified') 'Fixture did not reach labels.'
    $f.repos[$id.fullName].private=$false;$f.failPhase=''
    $resume=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($resume.status -eq 'complete' -and $resume.conflicts.Count -eq 0 -and $resume.projectVisibility -eq 'public') ('Published public project did not finish: '+($resume | ConvertTo-Json -Depth 9 -Compress))
    Assert (@($f.calls | Where-Object isRepositoryCreate).Count -eq 2 -and @($f.gitCalls | Where-Object {$_.arguments[0] -eq 'push'}).Count -eq 1) 'Resume recreated or pushed the project again.'
}
Test 'creation accepts only browser evidence tied to the public repository ID' {
    $f=New-GitHubFixture;$id=New-ApiIdentity 'Browser'
    Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup | Out-Null
    $evidence=@{repositoryId=0;disabled=$true;sourceUrl="https://github.com/$($id.notesFullName)/settings";observedAt=[datetime]::UtcNow.ToString('o')}
    Expect-Error {Set-BootstrapBrowserEvidence $id 'pullRequests' $evidence $f.stateRoot $f.request} 'identity|repository'
    $evidence.repositoryId=$f.repos[$id.notesFullName].id
    Set-BootstrapBrowserEvidence $id 'pullRequests' $evidence $f.stateRoot $f.request | Out-Null
    $report=Get-BootstrapStatus $id $f.stateRoot $f.request
    Assert ($report.phases.pullRequests -eq 'verified' -and $report.browserEvidence.pullRequests.observedAt -ceq $evidence.observedAt) ("Stored observation lost or mislabeled: "+($report | ConvertTo-Json -Depth 12 -Compress))
}
Test 'creation CLI rejects missing inputs promptly with structured output' {
    $out=& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File "$skillRoot/scripts/bootstrap.ps1" -Mode create 2>&1
    Assert ($LASTEXITCODE -eq 1) 'Missing input returned success.'
    $report=($out -join "`n") | ConvertFrom-Json -AsHashtable
    Assert ($report.status -eq 'missing-input' -and 'Name' -in $report.missing -and 'Description' -in $report.missing) 'No usable missing-input list.'
}
Test 'creation status reloads stored inputs without a description or parent prompt' {
    $f=New-GitHubFixture;$id=New-ApiIdentity 'Stored Inputs'
    Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup | Out-Null
    $loaded=Get-BootstrapStoredIdentity -Name $id.title -Owner $id.owner -StateRoot $f.stateRoot
    Assert ($loaded.description -eq $id.description -and $loaded.projectPath -eq $id.projectPath) 'Stored inputs replaced.'
}
Test 'creation status reads effective public settings without repairing changes' {
    $f=New-GitHubFixture;$id=New-ApiIdentity 'Status Drift'
    Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup | Out-Null
    $f.repos[$id.notesFullName].actions.enabled=$true
    $mutations=@($f.calls | Where-Object method -ne 'GET').Count
    $report=Get-BootstrapStatus $id $f.stateRoot $f.request
    Assert ($report.status -eq 'blocked') 'Changed Actions setting claimed verified.'
    Assert (@($f.calls | Where-Object method -ne 'GET').Count -eq $mutations) 'Status repaired settings.'
}
Test 'creation rejects incompatible manifests corrupt journals and altered public seed' {
    foreach ($change in @('template','journal','content')) {
        $f=New-GitHubFixture -FailPhase labels;$id=New-ApiIdentity ('Bad '+$change)
        Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup | Out-Null
        $path=Get-BootstrapJournalPath $id $f.stateRoot
        switch ($change) {
            template {$j=Read-BootstrapJournal $path;$j.templateVersion='old';Write-BootstrapJournal $path $j}
            journal {Write-FixtureText $path '{bad'}
            content {$j=Read-BootstrapJournal $path;$j.phases.Remove('publicContent');Write-BootstrapJournal $path $j;$f.repos[$id.notesFullName].readme='Changed README'}
        }
        $before=@($f.calls | Where-Object method -ne 'GET').Count
        $report=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
        Assert ($report.status -in @('partial','blocked')) "Changed $change accepted."
        Assert (@($f.calls | Where-Object method -ne 'GET').Count -eq $before) "Mutated before detecting $change conflict."
    }
}
Test 'creation repairs labels across pages while retaining extra labels' {
    $f=New-GitHubFixture -FailPhase labels;$id=New-ApiIdentity 'Label Pages'
    Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup | Out-Null
    $repo=$f.repos[$id.fullName]
    for ($i=0;$i -lt 103;$i++) {$repo.labels["extra-$i"]=@{name="extra-$i";color='ffffff';description='Keep'}}
    $repo.labels.bug=@{name='bug';color='000000';description='Different'}
    $f.failPhase=''
    $report=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($report.phases.labels -eq 'verified' -and $repo.labels.Count -eq 126 -and $repo.labels.bug.color -eq 'd73a4a') 'Labels lost or not repaired across pages.'
}
Test 'creation becomes complete only after browser and actual app verification' {
    $f=New-GitHubFixture;$id=New-ApiIdentity 'Complete'
    $report=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($report.status -eq 'partial' -and $report.phases.obsidian -eq 'needs-app') 'App pending state missing.'
    Set-BootstrapBrowserEvidence $id 'pullRequests' @{repositoryId=$f.repos[$id.notesFullName].id;disabled=$true;sourceUrl="https://github.com/$($id.notesFullName)/settings";observedAt=[datetime]::UtcNow.ToString('o')} $f.stateRoot $f.request | Out-Null
    $f.appEnabled=$true
    $report=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($report.status -eq 'complete') 'Verified foundation did not complete.'
    Write-FixtureText "$($id.projectPath)/docs/design/new-topic.md" '# Later development'
    $after=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($after.status -eq 'complete' -and [IO.File]::ReadAllText("$($id.projectPath)/docs/design/new-topic.md") -ceq '# Later development') 'Completed invocation overwrote later canon.'
}
Test 'creation partial reports point at the actual custom-state journal' {
    $f=New-GitHubFixture -FailPhase publicSettings;$id=New-ApiIdentity 'Reported State'
    $report=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($report.status -eq 'partial' -and $report.journalPath -eq (Get-BootstrapJournalPath $id $f.stateRoot)) 'Partial result points at a different state root.'
}
Test 'completed bootstrap directs explicit refresh to local setup without claiming success' {
    $f=New-GitHubFixture;$f.supportsPullRequests=$true;$f.appEnabled=$true
    $id=New-ApiIdentity 'Completed Refresh'
    Assert ((Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup).status -eq 'complete') 'Fixture did not complete.'
    $journalPath=Get-BootstrapJournalPath $id $f.stateRoot
    $before=[IO.File]::ReadAllText($journalPath)
    $mutations=@($f.calls | Where-Object method -ne 'GET').Count
    $f.obsidianSetup={throw 'Completed bootstrap must direct plugin work to local-setup.'}
    $report=Invoke-FoundationFixtureBootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup -RefreshPlugins
    Assert ($report.status -eq 'blocked' -and ($report.pending -join ' ') -match 'local-setup.+RefreshPlugins') 'Refresh was ignored or has no actionable local-setup instruction.'
    Assert ([IO.File]::ReadAllText($journalPath) -ceq $before) 'Completed journal changed.'
    Assert (@($f.calls | Where-Object method -ne 'GET').Count -eq $mutations) 'Completed refresh mutated a repository.'
}

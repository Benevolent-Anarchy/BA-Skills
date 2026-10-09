Import-Module "$skillRoot/scripts/Project.psm1" -Force
Import-Module "$skillRoot/scripts/GitHub.psm1" -Force
Import-Module "$skillRoot/scripts/State.psm1" -Force
if (Test-Path "$skillRoot/scripts/Bootstrap.psm1") {Import-Module "$skillRoot/scripts/Bootstrap.psm1" -Force}
. "$PSScriptRoot/GitHubFixture.ps1"
function New-ApiIdentity($Name) {New-BootstrapIdentity -Name $Name -Description 'Private project purpose' -Parent (New-BootstrapFixture 'project-parent')}
Test 'creation preflights both names auth owner and local collisions before mutation' {
    foreach ($failure in @('public','auth','owner','access','local')) {
        $f=New-GitHubFixture -ExistingPublic:($failure -eq 'public');$id=New-ApiIdentity 'Collision'
        if ($failure -eq 'auth') {$f.authStatus=401}
        if ($failure -eq 'owner') {$f.ownerStatus=404}
        if ($failure -eq 'access') {$f.orgRole='member'}
        if ($failure -eq 'local') {Write-FixtureText "$($id.projectPath)/unrelated.txt" 'Preserve'}
        $report=Invoke-Bootstrap -Identity $id -StateRoot $f.stateRoot -Request $f.request -Git $f.git -ObsidianSetup $f.obsidianSetup
        Assert ($report.status -eq 'blocked') "Collision accepted: $failure"
        Assert (@($f.calls | Where-Object method -ne 'GET').Count -eq 0) "Mutation preceded preflight: $failure"
    }
}
Test 'creation plans without changing remote or local state' {
    $f=New-GitHubFixture;$id=New-ApiIdentity 'Read Only'
    $plan=Get-BootstrapPlan $id $f.request $f.stateRoot
    Assert ($plan.status -eq 'ready') ($plan | ConvertTo-Json -Depth 9 -Compress)
    Assert (-not (Test-Path $id.projectPath)) 'Plan created checkout.'
    Assert (@(Get-ChildItem $f.stateRoot -Force).Count -eq 0) 'Plan wrote state.'
    Assert (@($f.calls | Where-Object method -ne 'GET').Count -eq 0) 'Plan mutated GitHub.'
}
Test 'creation seeds exact private and public trees with main and labels' {
    $f=New-GitHubFixture;$id=New-ApiIdentity 'Foundation'
    $report=Invoke-Bootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($report.status -eq 'partial') ($report | ConvertTo-Json -Depth 9 -Compress)
    Assert (@($report.pending | Where-Object {$_ -match 'Pull requests'}).Count -eq 1) 'Missing browser phase falsely complete.'
    $private=$f.repos[$id.fullName];$public=$f.repos[$id.notesFullName]
    Assert ($private.private -and $private.description -eq $id.description -and $private.has_issues) 'Wrong private identity.'
    Assert (-not $public.private -and $null -eq $public.description -and $public.readme -ceq (Get-PublicReadme $id)) 'Private material leaked.'
    Assert ($public.tree.Count -eq 1 -and $public.default_branch -eq 'main' -and -not $public.actions.enabled) 'Public foundation wrong.'
    Assert (-not $public.has_wiki -and -not $public.has_projects -and -not $public.has_discussions -and -not $public.has_issues -and -not $public.archived -and $public.permissions.push) 'Incorrect publication settings.'
    Assert ($private.labels.Count -eq 23) 'Label snapshot missing.'
    Assert (@($f.gitCalls | Where-Object repository -ne $id.projectPath).Count -eq 0) 'Local public checkout used.'
    Assert ((Invoke-FixtureGit $id.projectPath @('branch','--show-current')) -eq 'main') 'Wrong local branch.'
    Assert ((Invoke-FixtureGit $id.projectPath @('status','--porcelain')) -eq '') 'Foundation left dirty.'
}
Test 'creation resumes failed labels without recreating repos or contents' {
    $f=New-GitHubFixture -FailPhase labels;$id=New-ApiIdentity 'Retry'
    $first=Invoke-Bootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($first.status -eq 'partial') 'Failed phase not partial.'
    $f.failPhase=''
    $second=Invoke-Bootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert (@($f.calls | Where-Object isRepositoryCreate).Count -eq 2) 'Repos duplicated.'
    Assert ($second.phases.labels -eq 'verified') 'Labels did not resume.'
    Assert (@($f.calls | Where-Object { $_.method -eq 'PUT' -and $_.endpoint -like '*/contents/*' }).Count -eq 1) 'Content seed duplicated.'
}
Test 'creation quarantines an unconfirmed lost repository creation outcome' {
    $f=New-GitHubFixture;$f.lostCreate=$true;$id=New-ApiIdentity 'Ambiguous'
    $first=Invoke-Bootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($first.status -eq 'identity-unconfirmed') ($first | ConvertTo-Json -Compress -Depth 9)
    $f.lostCreate=$false
    $second=Invoke-Bootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($second.status -eq 'identity-unconfirmed') 'Unconfirmed repo adopted.'
    Assert (@($f.calls | Where-Object isRepositoryCreate).Count -eq 1) 'Ambiguous create retried.'
}
Test 'creation verifies lost push and public seed by readback before any retry' {
    $f=New-GitHubFixture;$f.lostPush=$true;$f.lostContents=$true;$id=New-ApiIdentity 'Lost Response'
    $report=Invoke-Bootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($report.phases.privateContent -eq 'verified' -and $report.phases.publicContent -eq 'verified') ($report | ConvertTo-Json -Depth 9 -Compress)
    Assert (@($f.gitCalls | Where-Object {$_.arguments[0] -eq 'push'}).Count -eq 1) 'Push repeated.'
}
Test 'creation refuses changed repository IDs origins and staged content during recovery' {
    foreach ($change in @('id','visibility','origin','stage','input')) {
        $f=New-GitHubFixture -FailPhase labels;$id=New-ApiIdentity ('Recovery '+$change)
        Invoke-Bootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup | Out-Null
        $before=@($f.calls | Where-Object method -ne 'GET').Count
        switch ($change) {
            id {$f.repos[$id.fullName].id++}
            visibility {$f.repos[$id.notesFullName].private=$true}
            origin {Invoke-FixtureGit $id.projectPath @('remote','set-url','origin','https://github.com/other/unrelated.git') | Out-Null}
            stage {Write-FixtureText "$($id.projectPath)/unrelated.txt" 'Keep';Invoke-FixtureGit $id.projectPath @('add','unrelated.txt') | Out-Null}
            input {$id.description='Changed'}
        }
        $f.failPhase=''
        $report=Invoke-Bootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
        Assert ($report.status -eq 'blocked') "Changed $change accepted."
        Assert (@($f.calls | Where-Object method -ne 'GET').Count -eq $before) "Mutation preceded recovery validation: $change"
    }
}
Test 'creation accepts only browser evidence tied to the public repository ID' {
    $f=New-GitHubFixture;$id=New-ApiIdentity 'Browser'
    Invoke-Bootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup | Out-Null
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
    Invoke-Bootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup | Out-Null
    $loaded=Get-BootstrapStoredIdentity -Name $id.title -Owner $id.owner -StateRoot $f.stateRoot
    Assert ($loaded.description -eq $id.description -and $loaded.projectPath -eq $id.projectPath) 'Stored inputs replaced.'
}
Test 'creation status reads effective public settings without repairing changes' {
    $f=New-GitHubFixture;$id=New-ApiIdentity 'Status Drift'
    Invoke-Bootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup | Out-Null
    $f.repos[$id.notesFullName].actions.enabled=$true
    $mutations=@($f.calls | Where-Object method -ne 'GET').Count
    $report=Get-BootstrapStatus $id $f.stateRoot $f.request
    Assert ($report.status -eq 'blocked') 'Changed Actions setting claimed verified.'
    Assert (@($f.calls | Where-Object method -ne 'GET').Count -eq $mutations) 'Status repaired settings.'
}
Test 'creation rejects incompatible manifests corrupt journals and altered public seed' {
    foreach ($change in @('template','journal','content')) {
        $f=New-GitHubFixture -FailPhase labels;$id=New-ApiIdentity ('Bad '+$change)
        Invoke-Bootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup | Out-Null
        $path=Get-BootstrapJournalPath $id $f.stateRoot
        switch ($change) {
            template {$j=Read-BootstrapJournal $path;$j.templateVersion='old';Write-BootstrapJournal $path $j}
            journal {Write-FixtureText $path '{bad'}
            content {$j=Read-BootstrapJournal $path;$j.phases.Remove('publicContent');Write-BootstrapJournal $path $j;$f.repos[$id.notesFullName].readme='Changed README'}
        }
        $before=@($f.calls | Where-Object method -ne 'GET').Count
        $report=Invoke-Bootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
        Assert ($report.status -in @('partial','blocked')) "Changed $change accepted."
        Assert (@($f.calls | Where-Object method -ne 'GET').Count -eq $before) "Mutated before detecting $change conflict."
    }
}
Test 'creation repairs labels across pages while retaining extra labels' {
    $f=New-GitHubFixture -FailPhase labels;$id=New-ApiIdentity 'Label Pages'
    Invoke-Bootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup | Out-Null
    $repo=$f.repos[$id.fullName]
    for ($i=0;$i -lt 103;$i++) {$repo.labels["extra-$i"]=@{name="extra-$i";color='ffffff';description='Keep'}}
    $repo.labels.bug=@{name='bug';color='000000';description='Different'}
    $f.failPhase=''
    $report=Invoke-Bootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($report.phases.labels -eq 'verified' -and $repo.labels.Count -eq 126 -and $repo.labels.bug.color -eq 'd73a4a') 'Labels lost or not repaired across pages.'
}
Test 'creation becomes complete only after browser and actual app verification' {
    $f=New-GitHubFixture;$id=New-ApiIdentity 'Complete'
    $report=Invoke-Bootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($report.status -eq 'partial' -and $report.phases.obsidian -eq 'needs-app') 'App pending state missing.'
    Set-BootstrapBrowserEvidence $id 'pullRequests' @{repositoryId=$f.repos[$id.notesFullName].id;disabled=$true;sourceUrl="https://github.com/$($id.notesFullName)/settings";observedAt=[datetime]::UtcNow.ToString('o')} $f.stateRoot $f.request | Out-Null
    $f.appEnabled=$true
    $report=Invoke-Bootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($report.status -eq 'complete') 'Verified foundation did not complete.'
    Write-FixtureText "$($id.projectPath)/docs/design/new-topic.md" '# Later development'
    $after=Invoke-Bootstrap $id $f.stateRoot $f.request $f.git $f.obsidianSetup
    Assert ($after.status -eq 'complete' -and [IO.File]::ReadAllText("$($id.projectPath)/docs/design/new-topic.md") -ceq '# Later development') 'Completed invocation overwrote later canon.'
}

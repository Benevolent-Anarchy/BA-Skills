function New-GitHubFixture([switch]$ExistingPublic,[string]$FailPhase='') {
    $fixture=@{stateRoot=(New-BootstrapFixture 'api-state');bareRoot=(New-BootstrapFixture 'bare');repos=@{};calls=[Collections.Generic.List[object]]::new();gitCalls=[Collections.Generic.List[object]]::new();failPhase=$FailPhase;lostCreate=$false;lostPush=$false;lostContents=$false;initialBranch='master';nextId=100;authStatus=200;ownerStatus=200;user='cicely-f';orgRole='admin';existingPublic=$ExistingPublic.IsPresent}
    $fixture.appEnabled=$false
    $fixture.emptyRefStatus=404
    $fixture.emptyRefMessage='Git Repository is empty.'
    $fixture.privateTreeExtras=@()
    $fixture.omitDownloads=$false
    $fixture.supportsPullRequests=$false
    $fixture.createFailureStatus=$null
    $fixture.createFailureKind='private'
    $fixture.obsidianSetup={param($Identity,$StateRoot,$Refresh) @{installedVerified=$true;enabledVerified=$fixture.appEnabled;plugins=@();pending=@('Fixture app enablement pending');journalPath='fixture'}}.GetNewClosure()
    $fixture.request={param($Method,$Endpoint,$Body)
        $fixture.calls.Add(@{method=$Method;endpoint=$Endpoint;body=$Body;isRepositoryCreate=($Method -eq 'POST' -and $Endpoint -match '^/(orgs/[^/]+|user)/repos$')})
        if ($Endpoint -eq '/user') {return @{StatusCode=$fixture.authStatus;Data=@{login=$fixture.user}}}
        if ($Endpoint -match '^/users/') {return @{StatusCode=$fixture.ownerStatus;Data=@{type='Organization';login='Benevolent-Anarchy'}}}
        if ($Endpoint -match '^/user/memberships/orgs/') {return @{StatusCode=200;Data=@{state='active';role=$fixture.orgRole}}}
        if ($Method -eq 'POST' -and $Endpoint -match '^/(orgs/[^/]+|user)/repos$') {
            if ($null -ne $fixture.createFailureStatus -and $Body.private -eq ($fixture.createFailureKind -eq 'private')) {
                return @{StatusCode=$fixture.createFailureStatus;Data=@{message='Repository creation rejected by policy.';errors=@(@{resource='Repository';field='name';code='invalid'})}}
            }
            $name='Benevolent-Anarchy/'+$Body.name
            $fixture.nextId++
            $repo=@{id=$fixture.nextId;full_name=$name;private=$Body.private;description=$null;default_branch=$fixture.initialBranch;has_issues=$Body.has_issues;has_wiki=$true;has_projects=$true;has_discussions=$true;has_downloads=$true;allow_auto_merge=$true;archived=$false;has_pages=$false;permissions=@{push=$true;admin=$true};actions=@{enabled=$true};labels=@{};readme=$null;tree=@()}
            if ($fixture.supportsPullRequests) {$repo.has_pull_requests=$true}
            if ($Body.ContainsKey('description')) {$repo.description=$Body.description}
            foreach ($key in @('has_wiki','has_projects')) {if ($Body.ContainsKey($key)) {$repo[$key]=$Body[$key]}}
            $repo.bare=Join-Path $fixture.bareRoot ($Body.name+'.git')
            & git init --bare --quiet $repo.bare 2>&1 | Out-Null
            $fixture.repos[$name]=$repo
            if ($fixture.lostCreate) {return @{StatusCode=0;Data=$null}}
            return @{StatusCode=201;Data=$repo}
        }
        if ($Endpoint -notmatch '^/repos/([^/]+/[^/?]+)(.*)$') {throw "Unexpected fake API endpoint: $Method $Endpoint"}
        $name=$Matches[1];$route=$Matches[2]
        if (-not $fixture.repos.ContainsKey($name)) {
            if ($fixture.existingPublic -and $name.EndsWith('-release-notes')) {return @{StatusCode=200;Data=@{id=90;full_name=$name;private=$false}}}
            return @{StatusCode=404;Data=$null}
        }
        $repo=$fixture.repos[$name]
        if ($route -eq '') {
            if ($Method -eq 'PATCH' -and $name.EndsWith('-release-notes') -and $Body.ContainsKey('has_discussions') -and $fixture.failPhase -eq 'publicSettings') {return @{StatusCode=503;Data=$null}}
            if ($Method -eq 'PATCH') {foreach ($key in $Body.Keys) {$repo[$key]=$Body[$key]}}
            if ($fixture.omitDownloads) {$data=$repo.Clone();$data.Remove('has_downloads');return @{StatusCode=200;Data=$data}}
            return @{StatusCode=200;Data=$repo}
        }
        if ($route -match '^/labels') {
            if ($fixture.failPhase -eq 'labels') {return @{StatusCode=503;Data=$null}}
            if ($Method -eq 'GET') {
                $page=1;if ($route -match '[?&]page=(\d+)') {$page=[int]$Matches[1]}
                return @{StatusCode=200;Data=@($repo.labels.Values | Sort-Object name | Select-Object -Skip (($page-1)*100) -First 100)}
            }
            $repo.labels[$Body.name]=$Body.Clone();return @{StatusCode=201;Data=$Body}
        }
        if ($route -eq '/actions/permissions') {if ($Method -eq 'PUT') {$repo.actions=$Body.Clone()};return @{StatusCode=200;Data=$repo.actions}}
        if ($route -eq '/pages') {return @{StatusCode=404;Data=$null}}
        if ($route -eq '/contents/README.md') {
            if ($Method -eq 'PUT') {
                $repo.readme=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Body.content));$repo.tree=@(@{path='README.md';type='blob'})
                if ($fixture.lostContents) {return @{StatusCode=0;Data=$null}}
                return @{StatusCode=201;Data=@{}}
            }
            if ($null -eq $repo.readme) {return @{StatusCode=404;Data=$null}}
            return @{StatusCode=200;Data=@{encoding='base64';content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($repo.readme))}}
        }
        if ($route -match '^/branches/([^/]+)/rename$') {$repo.default_branch=$Body.new_name;return @{StatusCode=201;Data=@{name=$Body.new_name}}}
        if ($route -match '^/git/ref/heads/main$') {
            if (-not $repo.private) {if ($repo.readme -and $repo.default_branch -eq 'main') {return @{StatusCode=200;Data=@{object=@{sha=('a'*40)}}}}}
            else {
                $sha=& git --git-dir=$($repo.bare) rev-parse --verify refs/heads/main 2>$null
                if ($LASTEXITCODE -eq 0) {return @{StatusCode=200;Data=@{object=@{sha=$sha}}}}
            }
            if ($repo.private -and $fixture.emptyRefStatus -eq 409) {return @{StatusCode=409;Data=@{message=$fixture.emptyRefMessage}}}
            return @{StatusCode=404;Data=$null}
        }
        if ($route -match '^/git/trees/') {
            $tree=$repo.tree
            if ($repo.private) {$tree=@(& git --git-dir=$($repo.bare) ls-tree -r --name-only main | ForEach-Object {@{path=$_;type='blob'}})+$fixture.privateTreeExtras}
            return @{StatusCode=200;Data=@{tree=$tree;truncated=$false}}
        }
        throw "Unexpected fake route: $Method $route"
    }.GetNewClosure()
    $fixture.git={param($Repository,$Arguments)
        $fixture.gitCalls.Add(@{repository=$Repository;arguments=$Arguments})
        if ($Arguments[0] -eq 'push') {
            $origin=& git -C $Repository remote get-url origin
            $name=$origin -replace '^https://github.com/','' -replace '\.git$',''
            $out=& git -C $Repository push $fixture.repos[$name].bare main 2>&1
            $code=$LASTEXITCODE
            if ($fixture.lostPush) {return @{ExitCode=1;Output='Connection lost after push'}}
            return @{ExitCode=$code;Output=($out -join "`n")}
        }
        return Invoke-BootstrapGit $Repository $Arguments
    }.GetNewClosure()
    return $fixture
}

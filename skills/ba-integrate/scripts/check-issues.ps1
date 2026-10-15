# Checks that the issues a merged pull request should have closed are closed, and for any
# still open, finds out why instead of closing it. Which issues it should have closed is
# GitHub's reading, not one made here. The issues GitHub lists as closing the pull request,
# from the description's keywords or a link made by hand, come from GitHub's own list. A
# commit message closes issues only once its commit reaches the default branch, so only
# the messages that landed count: the commits GitHub records this pull request as having
# introduced, found by walking back from the merge commit, whether a merge's commits, a
# rebase's copies or a squash alone. No list holds what those messages close, so each one
# naming a keyword is rendered by GitHub in this repository: GitHub decides which
# repository each reference names, whether that issue exists and whether it is an issue at
# all, and leaves code alone, and a reference it resolves to an issue closes it when one of
# GitHub's closing keywords comes right before it. Every page of every list is read. A
# count short of GitHub's total, a merged pull request without its merge commit or its
# commits, a merge commit GitHub does not record as introduced by it, or a message GitHub
# could not render is an error, never an empty audit. For an open issue it reports what it
# can establish: the pull request has not merged; it merged into a branch that is not the
# default, where GitHub closes nothing; the issue was reopened after this merge, and by
# whom; the merge was so recent that GitHub may still be processing it; or the issue lives
# in another repository. The pull request is read from the repository the remote names. It
# changes nothing. Writes one JSON document, with an `error` member and exit code 1 on
# failure.
#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][int]$PullRequest,
    # A merge newer than this may not have been processed by GitHub yet.
    [int]$RecentSeconds = 120,
    [string]$Remote = 'origin',
    # The GitHub CLI to run, gh on PATH by default; tests pass a stand-in script.
    [string]$GitHubCli
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'Integrate.psm1') -Force

# Runs the GitHub CLI in the repository and returns its output parsed as JSON; an error
# names $What.
function Invoke-GitHub([string[]]$Arguments, [string]$What) {
    $call = Invoke-GitHubCli $script:gh $Arguments $Repository
    if ($call.Code -ne 0) { throw "Could not read $What from GitHub. gh said: $($call.Out) $($call.Err)" }
    return $call.Out | ConvertFrom-Json
}

# The closed and reopened events in an issue's timeline, oldest first, read a page at a
# time and filtered here rather than by a gh filter expression, whose quotes PowerShell
# before 7.3 would strip from the native argument.
function Get-ClosingEvents([string]$IssueRepository, [int]$Number) {
    $events = [Collections.Generic.List[object]]::new()
    for ($page = 1; ; $page++) {
        $items = @(Invoke-GitHub @('api', "repos/$IssueRepository/issues/$Number/timeline?per_page=100&page=$page") "page $page of the timeline of $IssueRepository#$Number")
        foreach ($item in $items) {
            if ($item.event -in @('closed', 'reopened')) {
                $events.Add([pscustomobject]@{ event = $item.event; at = ([datetime]$item.created_at).ToUniversalTime(); actor = $item.actor.login })
            }
        }
        if ($items.Count -lt 100) { break }
    }
    return $events.ToArray()
}

# A UTC time as text.
function Format-Time([datetime]$Time) { return $Time.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

# Every node of one GraphQL connection, read page by page with its own cursor. $Fields are
# the query's variables as gh arguments, $Select picks the connection out of a response,
# and $What names it in errors. A total short of GitHub's own count is an error, so an
# audit that missed something never passes as one that found nothing.
function Read-Connection([string]$Query, [string[]]$Fields, [scriptblock]$Select, [string]$What) {
    $nodes = [Collections.Generic.List[object]]::new()
    $after = $null
    $total = $null
    do {
        $arguments = @('api', 'graphql', '-f', "query=$Query") + $Fields
        if ($after) { $arguments += @('-f', "after=$after") }
        $page = & $Select (Invoke-GitHub $arguments $What).data
        if (-not $page) { throw "GitHub returned no $What." }
        $total = $page.totalCount
        foreach ($node in @($page.nodes)) { $nodes.Add($node) }
        $after = if ($page.pageInfo.hasNextPage) { $page.pageInfo.endCursor } else { $null }
        if ($page.pageInfo.hasNextPage -and -not $after) { throw "GitHub reported more $What without a cursor to read them." }
    } while ($after)
    if ($nodes.Count -ne [int]$total) { throw "Read $($nodes.Count) of the $total $What, so the audit would be incomplete." }
    return $nodes.ToArray()
}

# What GitHub records about the pull request: every issue it lists as closing it, those
# linked by hand, its head, every commit, and the commit that merged it, which GitHub
# lists apart from the commits.
function Get-PullRequestSources {
    $owner, $name = $here -split '/', 2
    $fields = @('-f', "owner=$owner", '-f', "name=$name", '-F', "number=$PullRequest")
    $closingQuery = @'
query ClosingIssues($owner: String!, $name: String!, $number: Int!, $manual: Boolean!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      closingIssuesReferences(first: 100, after: $after, userLinkedOnly: $manual) {
        totalCount
        pageInfo { hasNextPage endCursor }
        nodes { number url repository { nameWithOwner } }
      }
    }
  }
}
'@
    $commitsQuery = @'
query PullRequestCommits($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      headRefOid
      mergeCommit { oid message parents(first: 2) { totalCount } }
      commits(first: 100, after: $after) {
        totalCount
        pageInfo { hasNextPage endCursor }
        nodes { commit { oid message } }
      }
    }
  }
}
'@
    $closing = @(Read-Connection $closingQuery ($fields + @('-F', 'manual=false')) { $args[0].repository.pullRequest.closingIssuesReferences } "issues GitHub lists as closing #$PullRequest")
    $manual = @(Read-Connection $closingQuery ($fields + @('-F', 'manual=true')) { $args[0].repository.pullRequest.closingIssuesReferences } "issues linked by hand to #$PullRequest")
    # The head and merge commit come with the first page of commits.
    $script:pullRequestRecord = $null
    $commits = @(Read-Connection $commitsQuery $fields { if (-not $script:pullRequestRecord) { $script:pullRequestRecord = $args[0].repository.pullRequest }; $args[0].repository.pullRequest.commits } "commits on #$PullRequest")
    $record = $script:pullRequestRecord
    return [pscustomobject]@{
        Closing = $closing; Manual = @($manual | ForEach-Object url); Head = $record.headRefOid
        Commits = @($commits | ForEach-Object { [pscustomobject]@{ oid = $_.commit.oid; message = $_.commit.message } })
        Merge = $record.mergeCommit
    }
}

# One commit as GitHub records it: its message, its parents, and whether GitHub records
# this pull request as the one that introduced it to the repository.
function Get-CommitRecord([string]$Oid) {
    $owner, $name = $here -split '/', 2
    $query = @'
query LandedCommit($owner: String!, $name: String!, $oid: GitObjectID!) {
  repository(owner: $owner, name: $name) {
    object(oid: $oid) {
      ... on Commit {
        oid
        message
        parents(first: 100) { totalCount nodes { oid } }
        associatedPullRequests(first: 10) { totalCount nodes { number repository { nameWithOwner } } }
      }
    }
  }
}
'@
    $commit = (Invoke-GitHub @('api', 'graphql', '-f', "query=$query", '-f', "owner=$owner", '-f', "name=$name", '-f', "oid=$Oid") "commit $Oid").data.repository.object
    if (-not $commit -or -not $commit.oid) { throw "GitHub has no commit $Oid, so which commits landed with #$PullRequest is unknown." }
    $parents = @($commit.parents.nodes | ForEach-Object oid)
    $associated = @($commit.associatedPullRequests.nodes | Where-Object { [int]$_.number -eq $PullRequest -and $_.repository.nameWithOwner -eq $here })
    if ($parents.Count -ne [int]$commit.parents.totalCount -or (-not $associated -and @($commit.associatedPullRequests.nodes).Count -ne [int]$commit.associatedPullRequests.totalCount)) { throw "GitHub listed only part of what it records about commit $Oid, so the audit would be incomplete." }
    return [pscustomobject]@{ oid = $commit.oid; message = $commit.message; parents = $parents; introduced = [bool]$associated }
}

# The commits whose messages reached the default branch, each marked when it is the merge
# commit itself. GitHub records which merged pull request introduced each commit to the
# repository, so walking back from the merge commit through every parent, while GitHub
# says this pull request introduced the commit, finds what landed whatever the shape of
# the merge: a merge's commits, a rebase's copies, which leave out the commits GitHub
# drops, or a squash alone. A head the walk reaches means every listed commit landed too,
# as its ancestors. It fails rather than guess when GitHub lists no commits for a merged
# pull request, when it does not record the merge commit as introduced by it, or when it
# records more landed commits than the pull request has. A pull request not merged has
# landed nothing; its commits are what a merge would land. The kind of landing found is
# kept in $script:landing for the report.
function Get-LandedCommits($Sources) {
    $merge = $Sources.Merge
    $mergeOid = if ($merge) { $merge.oid }
    $script:landing = $null
    if ($pr.state -ne 'MERGED') { return @($Sources.Commits | ForEach-Object { [pscustomobject]@{ oid = $_.oid; message = $_.message; landedAsMerge = $false } }) }
    if (-not $merge) { throw "GitHub reports #$PullRequest merged but not the commit that merged it, so that commit's message could not be audited." }
    if ($Sources.Commits.Count -eq 0) { throw "GitHub lists no commits for #$PullRequest though it merged, as after a branch is rewritten, so which messages landed is unknown." }
    $landed = [ordered]@{}
    $seen = [Collections.Generic.HashSet[string]]::new()
    $queue = [Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($merge.oid)
    while ($queue.Count -gt 0) {
        $oid = $queue.Dequeue()
        if (-not $seen.Add($oid)) { continue }
        $commit = Get-CommitRecord $oid
        if (-not $commit.introduced) {
            if ($oid -eq $merge.oid) { throw "GitHub does not record #$PullRequest as introducing its merge commit $oid, so which commits landed is unknown." }
            continue
        }
        $landed[$oid] = $commit
        if ($landed.Count -gt $Sources.Commits.Count + 1) { throw "GitHub records more commits as introduced by #$PullRequest than the $($Sources.Commits.Count) it lists, so which messages landed is unknown." }
        foreach ($parent in $commit.parents) { $queue.Enqueue($parent) }
    }
    if ($landed.Contains($Sources.Head)) {
        foreach ($commit in $Sources.Commits) { if (-not $landed.Contains($commit.oid)) { $landed[$commit.oid] = $commit } }
    }
    $script:landing = if ($merge.oid -eq $Sources.Head) { 'fast-forward' }
        elseif ([int]$merge.parents.totalCount -ge 2) { 'merge' }
        elseif ($landed.Count -eq 1) { 'squash' }
        else { 'rebase' }
    return @($landed.Values | ForEach-Object { [pscustomobject]@{ oid = $_.oid; message = $_.message; landedAsMerge = $_.oid -eq $merge.oid } })
}

# The issues a commit message closes, as GitHub reads it. GitHub renders the message in
# this repository and resolves each reference itself; only a link to an issue, with one of
# GitHub's closing keywords right before it, counts, and the issue is the one GitHub's
# canonical data-url names, whatever comment its href points at. A message without any
# keyword is not sent. The message travels in a file, so no quote in it depends on how
# PowerShell passes native arguments.
function Get-CommitClosingReferences([string]$Message, [string]$What) {
    if ($Message -notmatch '(?i)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b') { return }
    $request = Join-Path ([IO.Path]::GetTempPath()) ('ba-integrate-render-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($request, ([ordered]@{ text = $Message; mode = 'gfm'; context = $here } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    try { $call = Invoke-GitHubCli $script:gh @('api', '--method', 'POST', 'markdown', '--input', $request) $Repository }
    finally { Remove-Item -LiteralPath $request -Force -ErrorAction SilentlyContinue }
    if ($call.Code -ne 0) { throw "Could not have GitHub read the references in the message of $What. gh said: $($call.Out) $($call.Err)" }
    foreach ($match in [regex]::Matches($call.Out, '(?i)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?):?\s+<a\s([^>]*)>')) {
        $attributes = $match.Groups[1].Value
        if ($attributes -notmatch '\bdata-hovercard-type="issue"') { continue }
        $link = [regex]::Match($attributes, '\bdata-url="https://github\.com/(?<repository>[^/"]+/[^/"]+)/issues/(?<number>\d+)"')
        if (-not $link.Success) { continue }
        $issueRepository = $link.Groups['repository'].Value
        [pscustomobject]@{ url = "https://github.com/$issueRepository/issues/$($link.Groups['number'].Value)"; repository = $issueRepository; number = [int]$link.Groups['number'].Value }
    }
}

try {
    $Repository = (Resolve-Path -LiteralPath $Repository).Path
    $script:gh = if ($GitHubCli) { $GitHubCli } else { Get-GitHubCli }
    # The repository the remote names, never one gh picks from GH_REPO or its own default.
    $here = Get-GitHubRepository $Repository $Remote
    $repo = Invoke-GitHub @('repo', 'view', $here, '--json', 'nameWithOwner,defaultBranchRef') $here
    $defaultBranch = $repo.defaultBranchRef.name
    $pr = Invoke-GitHub @('pr', 'view', "$PullRequest", '--repo', $here, '--json', 'number,url,state,mergedAt,baseRefName') "#$PullRequest"
    $sources = Get-PullRequestSources

    # Expected issues, each once by URL, with where it was named: listed by GitHub as
    # closing the pull request, and whether by hand; in the message of a commit that
    # landed; or in the message of the commit that merged it.
    $expected = [ordered]@{}
    function Add-Expected($Reference, [string]$Source) {
        if (-not $expected.Contains($Reference.url)) {
            $expected[$Reference.url] = [ordered]@{ url = $Reference.url; repository = $Reference.repository; number = $Reference.number; linked = $false; manualLink = $false; commits = @(); inMergeCommit = $false }
        }
        $entry = $expected[$Reference.url]
        if ($Source -eq 'linked') { $entry.linked = $true; $entry.manualLink = $Reference.url -in $sources.Manual }
        elseif ($Source -eq 'merge') { $entry.inMergeCommit = $true }
        else { $entry.commits = @($entry.commits + $Source | Sort-Object -Unique) }
    }
    foreach ($ref in $sources.Closing) {
        Add-Expected ([pscustomobject]@{ url = $ref.url; repository = $ref.repository.nameWithOwner; number = [int]$ref.number }) 'linked'
    }
    # Only messages that reached the default branch can close anything: a squash's
    # original commits never do, while its final message and a rebase's copies do.
    foreach ($commit in @(Get-LandedCommits $sources)) {
        $short = $commit.oid.Substring(0, 8)
        $source, $what = if ($commit.landedAsMerge) { 'merge', "the merge commit $short" } else { $short, "commit $short" }
        foreach ($ref in @(Get-CommitClosingReferences "$($commit.message)" $what)) { Add-Expected $ref $source }
    }
    $mergeCommit = if ($pr.state -eq 'MERGED') { $sources.Merge.oid }
    foreach ($entry in $expected.Values) {
        $entry.linkedBy = if ($entry.manualLink) { 'manual link' }
            elseif ($entry.linked) { 'description keyword' }
            elseif ($entry.commits.Count -gt 0) { 'commit keyword' }
            else { 'merge commit keyword' }
    }

    $mergedAgo = if ($pr.mergedAt) { [int]((Get-Date).ToUniversalTime() - ([datetime]$pr.mergedAt).ToUniversalTime()).TotalSeconds } else { $null }
    $issues = foreach ($entry in $expected.Values) {
        $issue = Invoke-GitHub @('issue', 'view', $entry.url, '--json', 'state,stateReason,closedAt') $entry.url
        $entry.state = $issue.state
        $entry.closedAt = $issue.closedAt
        $findings = [Collections.Generic.List[string]]::new()
        if ($issue.state -ne 'CLOSED') {
            if ($pr.state -ne 'MERGED') { $findings.Add("#$PullRequest has not merged; it is $($pr.state).") }
            elseif ($pr.baseRefName -ne $defaultBranch) { $findings.Add("#$PullRequest merged into $($pr.baseRefName), not the default branch $defaultBranch, and GitHub closes issues only for pull requests merged into the default branch.") }
            if ($entry.repository -ne $here) { $findings.Add("It lives in $($entry.repository), not $here.") }
            # Only a reopening after this merge can explain why the merge left it open;
            # older history is no cause and must not hide that none was found.
            if ($pr.state -eq 'MERGED' -and $pr.mergedAt) {
                $merged = ([datetime]$pr.mergedAt).ToUniversalTime()
                $since = @(Get-ClosingEvents $entry.repository $entry.number | Where-Object { $_.at -ge $merged })
                $reopened = @($since | Where-Object event -EQ 'reopened') | Select-Object -Last 1
                if ($reopened) {
                    $closed = @($since | Where-Object { $_.event -eq 'closed' -and $_.at -le $reopened.at }) | Select-Object -Last 1
                    $findings.Add($(if ($closed) { "It was closed at $(Format-Time $closed.at), after this merge, and reopened by $($reopened.actor) at $(Format-Time $reopened.at)." }
                        else { "It was reopened by $($reopened.actor) at $(Format-Time $reopened.at), after this merge." }))
                }
            }
            if ($pr.state -eq 'MERGED' -and $null -ne $mergedAgo -and $mergedAgo -lt $RecentSeconds) { $findings.Add("#$PullRequest merged only $mergedAgo seconds ago, so GitHub may still be processing it; check again shortly.") }
            if ($findings.Count -eq 0) { $findings.Add('No cause found: GitHub should have closed it. Look at the issue and the pull request by hand.') }
        }
        $entry.findings = @($findings)
        $entry
    }

    [ordered]@{
        pullRequest = $PullRequest; url = $pr.url; state = $pr.state; mergedAt = $pr.mergedAt; mergeCommit = $mergeCommit; landing = $script:landing
        baseRef = $pr.baseRefName; defaultBranch = $defaultBranch
        allClosed = -not @($issues | Where-Object { $_.state -ne 'CLOSED' })
        issues = @($issues)
    } | ConvertTo-Json -Depth 6
    exit 0
} catch {
    [ordered]@{ pullRequest = $PullRequest; error = (Hide-UrlCredentials $_.Exception.Message) } | ConvertTo-Json
    exit 1
}

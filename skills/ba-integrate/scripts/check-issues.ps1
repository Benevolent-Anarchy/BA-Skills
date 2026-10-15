# Checks that the issues a merged pull request should have closed are closed, and for any
# still open, finds out why instead of closing it. Which issues it should have closed is
# GitHub's reading, not one made here. The issues GitHub lists as closing the pull request,
# from the description's keywords or a link made by hand, come from GitHub's own list. A
# commit message closes issues only once its commit reaches the default branch, so only
# the messages that landed count, as the merge commit's ancestry shows: every commit of a
# merge or fast-forward, a rebase's copies, or a squash alone, the merge commit's own
# message included. Those appear in no list, so each one naming a keyword is rendered by
# GitHub in this repository: GitHub decides which repository each reference names, whether
# that issue exists and whether it is an issue at all, and leaves code alone, and a
# reference it resolves to an issue closes it when one of GitHub's closing keywords comes
# right before it. Every page of every list is read; a count that falls short of GitHub's
# total, a merged pull request without its merge commit, or a message GitHub could not
# render is an error, never an empty audit. For an open issue
# it reports what it can establish: the pull request has not merged; it merged into a
# branch that is not the default, where GitHub closes nothing; the issue was reopened after
# this merge, and by whom; the merge was so recent that GitHub may still be processing it;
# or the issue lives in another repository. The pull request is read from the repository
# the remote names. It changes nothing. Writes one JSON document, with an `error` member
# and exit code 1 on failure.
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
# and $What names it in errors. With $Stop, reading ends once that many nodes are in;
# otherwise a total short of GitHub's own count is an error, so an audit that missed
# something never passes as one that found nothing.
function Read-Connection([string]$Query, [string[]]$Fields, [scriptblock]$Select, [string]$What, [int]$Stop = 0) {
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
    } while ($after -and ($Stop -eq 0 -or $nodes.Count -lt $Stop))
    if ($Stop -eq 0 -and $nodes.Count -ne [int]$total) { throw "Read $($nodes.Count) of the $total $What, so the audit would be incomplete." }
    return $(if ($Stop) { @($nodes | Select-Object -First $Stop) } else { $nodes.ToArray() })
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
      mergeCommit { oid message authoredDate parents(first: 2) { totalCount nodes { oid } } }
      commits(first: 100, after: $after) {
        totalCount
        pageInfo { hasNextPage endCursor }
        nodes { commit { oid message authoredDate parents { totalCount } } }
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
        Commits = @($commits | ForEach-Object { [pscustomobject]@{ oid = $_.commit.oid; message = $_.commit.message; authoredDate = $_.commit.authoredDate; isMerge = [int]$_.commit.parents.totalCount -gt 1 } })
        Merge = $record.mergeCommit
    }
}

# The commits whose messages reached the default branch, as the merge commit's ancestry
# shows, each marked when it is the merge commit itself. A merge whose second parent is
# the head, or a fast-forward to the head, landed every commit. A rebase landed copies,
# each with its original's message and author date, ending at the merge commit; merge
# commits in the pull request are not copied. A squash landed the merge commit alone. A
# pull request not merged has landed nothing yet; its commits are what a merge would land.
# The kind of landing found is kept in $script:landing for the report.
function Get-LandedCommits($Sources) {
    $merge = $Sources.Merge
    $mergeOid = if ($merge) { $merge.oid }
    $every = @($Sources.Commits | ForEach-Object { [pscustomobject]@{ oid = $_.oid; message = $_.message; landedAsMerge = $_.oid -eq $mergeOid } })
    $script:landing = $null
    if ($pr.state -ne 'MERGED') { return $every }
    if (-not $merge) { throw "GitHub reports #$PullRequest merged but not the commit that merged it, so that commit's message could not be audited." }
    $parents = @($merge.parents.nodes | ForEach-Object oid)
    if ($merge.oid -eq $Sources.Head) { $script:landing = 'fast-forward'; return $every }
    if ([int]$merge.parents.totalCount -ge 2) {
        if ($parents[1] -ne $Sources.Head) { throw "#$PullRequest's merge commit $($merge.oid) does not merge its head $($Sources.Head), so which commits landed is unknown." }
        $script:landing = 'merge'
        return $every + @([pscustomobject]@{ oid = $merge.oid; message = $merge.message; landedAsMerge = $true })
    }
    $copied = @($Sources.Commits | Where-Object { -not $_.isMerge })
    if ($copied.Count -gt 0) {
        $owner, $name = $here -split '/', 2
        $historyQuery = @'
query LandedHistory($owner: String!, $name: String!, $oid: GitObjectID!, $after: String) {
  repository(owner: $owner, name: $name) {
    object(oid: $oid) {
      ... on Commit {
        history(first: 100, after: $after) {
          totalCount
          pageInfo { hasNextPage endCursor }
          nodes { oid message authoredDate }
        }
      }
    }
  }
}
'@
        $history = @(Read-Connection $historyQuery @('-f', "owner=$owner", '-f', "name=$name", '-f', "oid=$($merge.oid)") { $args[0].repository.object.history } "history of #$PullRequest's merge commit" $copied.Count)
        $rebased = $history.Count -eq $copied.Count
        for ($i = 0; $rebased -and $i -lt $copied.Count; $i++) {
            $original = $copied[$copied.Count - 1 - $i]
            $rebased = $history[$i].message -eq $original.message -and $history[$i].authoredDate -eq $original.authoredDate
        }
        if ($rebased) { $script:landing = 'rebase'; return @($history | ForEach-Object { [pscustomobject]@{ oid = $_.oid; message = $_.message; landedAsMerge = $_.oid -eq $merge.oid } }) }
    }
    $script:landing = 'squash'
    return @([pscustomobject]@{ oid = $merge.oid; message = $merge.message; landedAsMerge = $true })
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

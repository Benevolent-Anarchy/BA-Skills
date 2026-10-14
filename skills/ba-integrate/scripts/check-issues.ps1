# Checks that the issues a merged pull request should have closed are closed, and for any
# still open, finds out why instead of closing it. An issue is expected to close when
# GitHub lists it as closing the pull request (a closing keyword, or a link made by hand),
# or when the description or the message of a commit that landed names it with a closing
# keyword; every page of the commits is read, and a count that falls short of GitHub's
# total is an error, never an empty audit. For an open one it reports what it can
# establish: the pull request has not merged; it merged into a branch that is not the
# default, where GitHub closes nothing; the issue was reopened after this merge, and by
# whom; the merge was so recent that GitHub may still be processing it; the description's
# keyword is not one GitHub linked; or the issue lives in another repository. The pull
# request is read from the repository the remote names. It changes nothing. Writes one
# JSON document, with an `error` member and exit code 1 on failure.
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

# The canonical URL of an issue reference in a description: owner/repo#N, #N in this
# repository, or a full issue URL.
function Resolve-IssueUrl([string]$Owner, [string]$Name, [string]$Number) {
    return "https://github.com/$Owner/$Name/issues/$Number"
}

# The issues $Text names with a closing keyword, as url, repository and number; a bare #N
# is in this repository.
function Get-KeywordReferences([string]$Text) {
    $keyword = '(?i)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b:?\s+(?:https://github\.com/(?<o1>[\w.-]+)/(?<r1>[\w.-]+)/issues/(?<n1>\d+)|(?:(?<o2>[\w.-]+)/(?<r2>[\w.-]+))?#(?<n2>\d+))'
    foreach ($match in [regex]::Matches($Text, $keyword)) {
        $owner, $name = if ($match.Groups['o1'].Success) { $match.Groups['o1'].Value, $match.Groups['r1'].Value }
            elseif ($match.Groups['o2'].Success) { $match.Groups['o2'].Value, $match.Groups['r2'].Value }
            else { $here -split '/', 2 }
        $number = if ($match.Groups['n1'].Success) { $match.Groups['n1'].Value } else { $match.Groups['n2'].Value }
        [pscustomobject]@{ url = (Resolve-IssueUrl $owner $name $number); repository = "$owner/$name"; number = [int]$number }
    }
}

# Every commit the pull request landed, as oid and message, read page by page. Falling short
# of GitHub's own count is an error: an audit that missed commits must not pass as one
# that found nothing.
function Get-MergedCommits {
    $owner, $name = $here -split '/', 2
    $query = @'
query($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      commits(first: 100, after: $after) {
        totalCount
        pageInfo { hasNextPage endCursor }
        nodes { commit { oid message } }
      }
    }
  }
}
'@
    $commits = [Collections.Generic.List[object]]::new()
    $after = $null
    $total = $null
    do {
        $arguments = @('api', 'graphql', '-f', "query=$query", '-f', "owner=$owner", '-f', "name=$name", '-F', "number=$PullRequest")
        if ($after) { $arguments += @('-f', "after=$after") }
        $page = (Invoke-GitHub $arguments "the commits of #$PullRequest").data.repository.pullRequest.commits
        $total = [int]$page.totalCount
        foreach ($node in @($page.nodes)) { $commits.Add([pscustomobject]@{ oid = $node.commit.oid; message = $node.commit.message }) }
        $after = if ($page.pageInfo.hasNextPage) { $page.pageInfo.endCursor } else { $null }
        if ($page.pageInfo.hasNextPage -and -not $after) { throw "GitHub reported more commits on #$PullRequest without a cursor to read them." }
    } while ($after)
    if ($commits.Count -ne $total) { throw "Read $($commits.Count) of the $total commits on #$PullRequest, so the audit would be incomplete." }
    return $commits.ToArray()
}

try {
    $Repository = (Resolve-Path -LiteralPath $Repository).Path
    $script:gh = if ($GitHubCli) { $GitHubCli } else { Get-GitHubCli }
    # The repository the remote names, never one gh picks from GH_REPO or its own default.
    $here = Get-GitHubRepository $Repository $Remote
    $repo = Invoke-GitHub @('repo', 'view', $here, '--json', 'nameWithOwner,defaultBranchRef') $here
    $defaultBranch = $repo.defaultBranchRef.name
    $pr = Invoke-GitHub @('pr', 'view', "$PullRequest", '--repo', $here, '--json', 'number,url,state,mergedAt,baseRefName,body,closingIssuesReferences') "#$PullRequest"

    # Expected issues, each once by URL, with where it was named: linked by GitHub, named in
    # the description, or named in the message of a commit that landed.
    $expected = [ordered]@{}
    function Add-Expected($Reference, [string]$Source) {
        if (-not $expected.Contains($Reference.url)) {
            $expected[$Reference.url] = [ordered]@{ url = $Reference.url; repository = $Reference.repository; number = $Reference.number; linked = $false; inDescription = $false; commits = @() }
        }
        $entry = $expected[$Reference.url]
        if ($Source -eq 'linked') { $entry.linked = $true }
        elseif ($Source -eq 'description') { $entry.inDescription = $true }
        else { $entry.commits = @($entry.commits + $Source | Sort-Object -Unique) }
    }
    foreach ($ref in @($pr.closingIssuesReferences)) {
        $repositoryName = "$($ref.repository.owner.login)/$($ref.repository.name)"
        Add-Expected ([pscustomobject]@{ url = (Resolve-IssueUrl $ref.repository.owner.login $ref.repository.name $ref.number); repository = $repositoryName; number = [int]$ref.number }) 'linked'
    }
    foreach ($ref in @(Get-KeywordReferences "$($pr.body)")) { Add-Expected $ref 'description' }
    foreach ($commit in @(Get-MergedCommits)) {
        foreach ($ref in @(Get-KeywordReferences "$($commit.message)")) { Add-Expected $ref $commit.oid.Substring(0, 8) }
    }
    foreach ($entry in $expected.Values) {
        $named = $entry.inDescription -or $entry.commits.Count -gt 0
        $entry.linkedBy = if ($entry.linked -and $named) { 'keyword' }
            elseif ($entry.linked) { 'manual link' }
            elseif ($entry.inDescription) { 'keyword GitHub did not link' }
            else { 'commit keyword' }
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
            if ($entry.linkedBy -eq 'keyword GitHub did not link') { $findings.Add('The description names it with a closing keyword, but GitHub does not list it as closing this pull request, so the reference did not resolve or was written in a form GitHub does not read.') }
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
        pullRequest = $PullRequest; url = $pr.url; state = $pr.state; mergedAt = $pr.mergedAt
        baseRef = $pr.baseRefName; defaultBranch = $defaultBranch
        allClosed = -not @($issues | Where-Object { $_.state -ne 'CLOSED' })
        issues = @($issues)
    } | ConvertTo-Json -Depth 6
    exit 0
} catch {
    [ordered]@{ pullRequest = $PullRequest; error = (Hide-UrlCredentials $_.Exception.Message) } | ConvertTo-Json
    exit 1
}

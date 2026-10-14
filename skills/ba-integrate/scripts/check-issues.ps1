# Checks that the issues a merged pull request should have closed are closed, and for any
# still open, finds out why instead of closing it. An issue is expected to close when
# GitHub lists it as closing the pull request (a closing keyword, or a link made by hand)
# or when the description names it with a closing keyword. For an open one it reports what
# it can establish: the pull request has not merged; it merged into a branch that is not
# the default, where GitHub closes nothing; the issue was closed and then reopened, and by
# whom; the merge was so recent that GitHub may still be processing it; the description's
# keyword is not one GitHub linked; or the issue lives in another repository. It changes
# nothing. Writes one JSON document, with an `error` member and exit code 1 on failure.
#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][int]$PullRequest,
    # A merge newer than this may not have been processed by GitHub yet.
    [int]$RecentSeconds = 120,
    # The GitHub CLI to run, gh on PATH by default; tests pass a stand-in script.
    [string]$GitHubCli
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'Integrate.psm1') -Force

# Runs the GitHub CLI in the repository and returns its output parsed as JSON, or as one
# JSON document per line with -Lines; an error names $What.
function Invoke-GitHub([string[]]$Arguments, [string]$What, [switch]$Lines) {
    $call = Invoke-GitHubCli $script:gh $Arguments $Repository
    if ($call.Code -ne 0) { throw "Could not read $What from GitHub. gh said: $($call.Out) $($call.Err)" }
    if ($Lines) { return @($call.Out -split '\r?\n' | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }) }
    return $call.Out | ConvertFrom-Json
}

# The canonical URL of an issue reference in a description: owner/repo#N, #N in this
# repository, or a full issue URL.
function Resolve-IssueUrl([string]$Owner, [string]$Name, [string]$Number) {
    return "https://github.com/$Owner/$Name/issues/$Number"
}

try {
    $Repository = (Resolve-Path -LiteralPath $Repository).Path
    $script:gh = if ($GitHubCli) { $GitHubCli } else { Get-GitHubCli }
    $repo = Invoke-GitHub @('repo', 'view', '--json', 'nameWithOwner,defaultBranchRef') 'the repository'
    $defaultBranch = $repo.defaultBranchRef.name
    $here = $repo.nameWithOwner
    $pr = Invoke-GitHub @('pr', 'view', "$PullRequest", '--json', 'number,url,state,mergedAt,baseRefName,body,closingIssuesReferences') "#$PullRequest"

    # Expected issues: those GitHub links as closing, then any the description names with
    # a closing keyword that GitHub did not link.
    $expected = [ordered]@{}
    foreach ($ref in @($pr.closingIssuesReferences)) {
        $url = Resolve-IssueUrl $ref.repository.owner.login $ref.repository.name $ref.number
        $expected[$url] = [ordered]@{ url = $url; repository = "$($ref.repository.owner.login)/$($ref.repository.name)"; number = [int]$ref.number; linkedBy = 'manual link' }
    }
    $keyword = '(?i)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b:?\s+(?:https://github\.com/(?<o1>[\w.-]+)/(?<r1>[\w.-]+)/issues/(?<n1>\d+)|(?:(?<o2>[\w.-]+)/(?<r2>[\w.-]+))?#(?<n2>\d+))'
    foreach ($match in [regex]::Matches("$($pr.body)", $keyword)) {
        $owner, $name = if ($match.Groups['o1'].Success) { $match.Groups['o1'].Value, $match.Groups['r1'].Value }
            elseif ($match.Groups['o2'].Success) { $match.Groups['o2'].Value, $match.Groups['r2'].Value }
            else { $here -split '/', 2 }
        $number = if ($match.Groups['n1'].Success) { $match.Groups['n1'].Value } else { $match.Groups['n2'].Value }
        $url = Resolve-IssueUrl $owner $name $number
        if ($expected.Contains($url)) { $expected[$url].linkedBy = 'keyword' }
        else { $expected[$url] = [ordered]@{ url = $url; repository = "$owner/$name"; number = [int]$number; linkedBy = 'keyword GitHub did not link' } }
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
            $events = Invoke-GitHub @('api', "repos/$($entry.repository)/issues/$($entry.number)/timeline", '--paginate', '--jq', '.[] | select(.event == "closed" or .event == "reopened") | {event, created_at, actor: .actor.login}') "the timeline of $($entry.url)" -Lines
            $reopened = @($events | Where-Object event -EQ 'reopened') | Select-Object -Last 1
            if ($reopened) {
                $when = if ($reopened.created_at -is [datetime]) { $reopened.created_at.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { "$($reopened.created_at)" }
                $findings.Add("It was reopened by $($reopened.actor) at $when after being closed.")
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
    [ordered]@{ pullRequest = $PullRequest; error = $_.Exception.Message } | ConvertTo-Json
    exit 1
}

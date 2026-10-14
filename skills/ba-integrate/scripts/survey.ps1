# Surveys a repository's open pull requests before integrating them: which are ready
# (not drafts), what each changes, which build on others, which contain the unmerged work
# of a pull request that is not ready, which pairs conflict with each other or with the
# base branch, and an order to merge them in. It reads every page GitHub returns. It
# changes nothing but fetched objects; every merge it tries is computed by
# `git merge-tree`, without a checkout. Writes one JSON document, with an `error` member
# and exit code 1 on failure.
#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,
    [string]$Base,
    [string]$PullRequestsJson,
    # The GitHub CLI to run, gh on PATH by default; tests pass a stand-in script.
    [string]$GitHubCli
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'Integrate.psm1') -Force

$pullRequestsQuery = @'
query($owner: String!, $name: String!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, first: 100, after: $after, orderBy: {field: CREATED_AT, direction: ASC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number title url isDraft isCrossRepository createdAt
        headRefName headRefOid baseRefName mergeable reviewDecision
        reviewThreads(first: 100) { pageInfo { hasNextPage endCursor } nodes { isResolved } }
      }
    }
  }
}
'@
$reviewThreadsQuery = @'
query($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { isResolved } }
    }
  }
}
'@

# Runs a GraphQL query through the GitHub CLI and returns its `data`. Integer variables go
# as typed fields and strings as raw ones; a $null variable is left out.
function Invoke-GitHubQuery([string]$Gh, [string]$Query, [hashtable]$Variables) {
    $arguments = @('api', 'graphql', '-f', "query=$Query")
    foreach ($key in $Variables.Keys) {
        $value = $Variables[$key]
        if ($null -eq $value) { continue }
        $arguments += if ($value -is [int]) { @('-F', "$key=$value") } else { @('-f', "$key=$value") }
    }
    $output = & $Gh @arguments
    if ($LASTEXITCODE -ne 0) { throw "gh api graphql failed: $output" }
    return (($output | Out-String) | ConvertFrom-Json).data
}

# The cursor of the next page of $Connection, or $null when it was the last page.
function Get-NextCursor($Connection, [string]$What) {
    if (-not $Connection.pageInfo.hasNextPage) { return $null }
    if (-not $Connection.pageInfo.endCursor) { throw "GitHub reported more $What without a cursor to read them; the survey would be incomplete." }
    return $Connection.pageInfo.endCursor
}

# The open pull requests of the repository's GitHub remote, every page of them, as the
# records the rest of the survey reads. The unresolved review threads of each pull request
# that is not a draft are counted across every page too.
function Get-GitHubPullRequests {
    $gh = if ($GitHubCli) { $GitHubCli } else { Get-GitHubCli }
    # The pull requests come from the repository origin names, the one the heads are
    # fetched from, never one gh picks from GH_REPO or its own default.
    $owner, $name = (Get-GitHubRepository $Repository 'origin') -split '/', 2
    Push-Location -LiteralPath $Repository
    try {
        $nodes = [Collections.Generic.List[object]]::new()
        $after = $null
        do {
            $page = (Invoke-GitHubQuery $gh $pullRequestsQuery @{ owner = $owner; name = $name; after = $after }).repository.pullRequests
            foreach ($node in @($page.nodes)) { $nodes.Add($node) }
            $after = Get-NextCursor $page 'open pull requests'
        } while ($after)

        foreach ($node in $nodes) {
            $threads = $node.reviewThreads
            $unresolved = @($threads.nodes | Where-Object { -not $_.isResolved }).Count
            $after = if ($node.isDraft) { $null } else { Get-NextCursor $threads "review threads on #$($node.number)" }
            while ($after) {
                $threads = (Invoke-GitHubQuery $gh $reviewThreadsQuery @{ owner = $owner; name = $name; number = [int]$node.number; after = $after }).repository.pullRequest.reviewThreads
                $unresolved += @($threads.nodes | Where-Object { -not $_.isResolved }).Count
                $after = Get-NextCursor $threads "review threads on #$($node.number)"
            }
            [pscustomobject]@{
                number = $node.number; title = $node.title; url = $node.url
                isDraft = $node.isDraft; isCrossRepository = $node.isCrossRepository
                headRefName = $node.headRefName; headRefOid = $node.headRefOid; baseRefName = $node.baseRefName
                mergeable = $node.mergeable; reviewDecision = $node.reviewDecision
                unresolvedReviewThreads = $unresolved
            }
        }
    } finally { Pop-Location }
}

# Makes every pull request's head available locally: one fetch for them all, or one each
# if that fails because a pull request closed meanwhile. A head still missing is left for
# the caller to report.
function Get-PullRequestHeads([object[]]$PullRequests) {
    if ($PullRequests.Count -eq 0) { return }
    $refspecs = @($PullRequests | ForEach-Object { "refs/pull/$($_.number)/head" })
    $all = Invoke-Git $Repository (@('fetch', '--quiet', '--no-tags', 'origin') + $refspecs) -Allowed 0, 1, 128
    if ($all.Code -eq 0) { return }
    foreach ($refspec in $refspecs) { Invoke-Git $Repository @('fetch', '--quiet', '--no-tags', 'origin', $refspec) -Allowed 0, 1, 128 | Out-Null }
}

# True when commit $Sha is available in the repository.
function Test-Commit([string]$Sha) {
    return (Invoke-Git $Repository @('cat-file', '-e', "$Sha^{commit}") -Allowed 0, 1, 128).Code -eq 0
}

# How many commits the base lacks that the skipped pull request and the ready one share:
# the unready history merging the ready one would land. It counts from where they
# diverge, so a draft that moved on after the ready branch forked from it still counts.
# A skipped pull request built on the ready one shares only the ready one's own commits,
# so one that targets the ready branch, or contains its whole head, counts nothing.
function Get-SharedUnmergedCommits($Skipped, $ReadyPr) {
    if ($Skipped.baseRefName -eq $ReadyPr.headRefName) { return 0 }
    $mergeBase = Invoke-Git $Repository @('merge-base', $Skipped.headRefOid, $ReadyPr.headRefOid) -Allowed 0, 1
    if ($mergeBase.Code -ne 0 -or -not $mergeBase.Lines) { return 0 }
    $shared = $mergeBase.Lines[0]
    if ($shared -eq $ReadyPr.headRefOid) { return 0 }
    return [int](Invoke-Git $Repository @('rev-list', '--count', "$baseSha..$shared")).Lines[0]
}

# The paths a three-way merge of two commits leaves in conflict; empty when it is clean.
function Get-MergeConflicts([string]$Left, [string]$Right) {
    $result = Invoke-Git $Repository @('merge-tree', '--write-tree', '--name-only', '--no-messages', $Left, $Right) -Allowed 0, 1
    if ($result.Code -eq 0) { return @() }
    return @($result.Lines | Select-Object -Skip 1 | Where-Object { $_ } | Sort-Object -Unique)
}

try {
    $Repository = (Resolve-Path -LiteralPath $Repository).Path
    $fromGitHub = -not $PullRequestsJson
    if ($fromGitHub) { Invoke-Git $Repository @('fetch', '--quiet', '--no-tags', 'origin') | Out-Null }
    if (-not $Base) {
        $remoteHead = (Invoke-Git $Repository @('symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD') -Allowed 0, 1).Lines
        $Base = if ($remoteHead) { $remoteHead[0] } else { 'origin/main' }
    }
    $baseBranch = $Base -replace '^origin/', ''
    $baseSha = (Invoke-Git $Repository @('rev-parse', '--verify', "$Base^{commit}")).Lines[0]

    $all = if ($fromGitHub) { @(Get-GitHubPullRequests) } else { @(Get-Content -LiteralPath $PullRequestsJson -Raw | ConvertFrom-Json) }
    $skipped = [Collections.Generic.List[object]]::new()
    $unready = [Collections.Generic.List[object]]::new()
    $ready = [Collections.Generic.List[object]]::new()
    foreach ($pr in ($all | Sort-Object { [int]$_.number })) {
        # JSON numbers arrive as Int64; every table below is keyed by Int32.
        $pr.number = [int]$pr.number
        $reason = if ($pr.isDraft) { 'draft' } elseif ($pr.isCrossRepository) { 'from a fork' } else { $null }
        if ($reason) {
            $skipped.Add([ordered]@{ number = $pr.number; reason = $reason })
            $unready.Add([pscustomobject]@{ pr = $pr; reason = $reason })
            continue
        }
        $ready.Add($pr)
    }
    # A PR must target the base branch or another ready PR's branch; dropping one can strand
    # a PR stacked on it, so repeat until nothing more drops out.
    do {
        $heads = @($ready | ForEach-Object headRefName)
        $stranded = @($ready | Where-Object { $_.baseRefName -ne $baseBranch -and $_.baseRefName -notin $heads })
        foreach ($pr in $stranded) {
            $reason = "targets $($pr.baseRefName), which is neither $baseBranch nor a ready PR's branch"
            $skipped.Add([ordered]@{ number = $pr.number; reason = $reason })
            $unready.Add([pscustomobject]@{ pr = $pr; reason = $reason })
            [void]$ready.Remove($pr)
        }
    } while ($stranded.Count -gt 0)

    if ($fromGitHub) { Get-PullRequestHeads @(@($ready) + @($unready | ForEach-Object pr)) }
    foreach ($pr in $ready) {
        if (-not (Test-Commit $pr.headRefOid)) { throw "PR #$($pr.number)'s head $($pr.headRefOid) is not available locally; it may have moved while surveying. Run the survey again." }
    }
    # Work that is not ready can still reach the base inside a ready PR built on it, so
    # each skipped head that the base lacks is looked for in every ready head.
    $pending = @($unready | Where-Object { (Test-Commit $_.pr.headRefOid) -and -not (Test-Ancestor $Repository $_.pr.headRefOid $baseSha) })
    $unchecked = @($unready | Where-Object { -not (Test-Commit $_.pr.headRefOid) } | ForEach-Object { $_.pr.number })

    $facts = @{}
    foreach ($pr in $ready) {
        $head = $pr.headRefOid
        $mergeBase = (Invoke-Git $Repository @('merge-base', $baseSha, $head)).Lines[0]
        $facts[$pr.number] = [ordered]@{
            number = $pr.number; title = $pr.title; url = $pr.url
            head = $pr.headRefName; headSha = $head; baseRef = $pr.baseRefName
            dependsOn = @()
            includesUnready = @(foreach ($skippedPr in $pending) {
                $shared = Get-SharedUnmergedCommits $skippedPr.pr $pr
                if ($shared -gt 0) { [ordered]@{ number = $skippedPr.pr.number; reason = $skippedPr.reason; sharedCommits = $shared } }
            })
            commits = [int](Invoke-Git $Repository @('rev-list', '--count', "$baseSha..$head")).Lines[0]
            behindBase = [int](Invoke-Git $Repository @('rev-list', '--count', "$head..$baseSha")).Lines[0]
            files = @((Invoke-Git $Repository @('diff', '--name-only', $mergeBase, $head)).Lines | Where-Object { $_ })
            conflictsWithBase = @(Get-MergeConflicts $baseSha $head)
            reviewDecision = $pr.reviewDecision
            unresolvedReviewThreads = $pr.unresolvedReviewThreads
            mergeable = $pr.mergeable
            reason = $null
        }
    }

    # B builds on A when it targets A's branch or contains A's head while A is unmerged.
    $numbers = @($ready | ForEach-Object number)
    foreach ($a in $ready) {
        foreach ($b in $ready) {
            if ($a.number -eq $b.number -or $a.headRefOid -eq $b.headRefOid) { continue }
            $stacked = $b.baseRefName -eq $a.headRefName
            $contains = $facts[$a.number].commits -gt 0 -and (Test-Ancestor $Repository $a.headRefOid $b.headRefOid)
            if ($stacked -or $contains) { $facts[$b.number].dependsOn = @($facts[$b.number].dependsOn + $a.number | Sort-Object -Unique) }
        }
    }

    $conflicts = [Collections.Generic.List[object]]::new()
    $partners = @{}
    foreach ($n in $numbers) { $partners[$n] = [Collections.Generic.List[int]]::new() }
    for ($i = 0; $i -lt $ready.Count; $i++) {
        for ($j = $i + 1; $j -lt $ready.Count; $j++) {
            $a = $ready[$i]; $b = $ready[$j]
            if ($a.number -in $facts[$b.number].dependsOn -or $b.number -in $facts[$a.number].dependsOn) { continue }
            $files = @(Get-MergeConflicts $a.headRefOid $b.headRefOid)
            if ($files.Count -eq 0) { continue }
            $conflicts.Add([ordered]@{ between = @($a.number, $b.number); files = $files })
            $partners[$a.number].Add($b.number); $partners[$b.number].Add($a.number)
        }
    }

    # Order: a PR only after those it builds on; of the rest, those conflicting with the
    # fewest others first, oldest (lowest number) breaking ties.
    $order = [Collections.Generic.List[int]]::new()
    $remaining = [Collections.Generic.List[int]]::new([int[]]$numbers)
    while ($remaining.Count -gt 0) {
        $available = @($remaining | Where-Object { @($facts[$_].dependsOn | Where-Object { $_ -notin $order }).Count -eq 0 })
        if ($available.Count -eq 0) { throw "Pull requests $($remaining -join ', ') build on each other in a cycle." }
        $pick = $available | Sort-Object { $partners[$_].Count }, { $_ } | Select-Object -First 1
        $why = [Collections.Generic.List[string]]::new()
        if ($facts[$pick].dependsOn.Count -gt 0) { $why.Add("after #$($facts[$pick].dependsOn -join ', #'), which it builds on") }
        if ($partners[$pick].Count -eq 0) { $why.Add('conflicts with no other ready PR') }
        else { $why.Add("conflicts with #$(@($partners[$pick] | Sort-Object) -join ', #')") }
        if ($facts[$pick].conflictsWithBase.Count -gt 0) { $why.Add("conflicts with $baseBranch in $($facts[$pick].conflictsWithBase.Count) file(s)") }
        if ($facts[$pick].commits -eq 0) { $why.Add("has no commits that $baseBranch lacks") }
        if ($facts[$pick].includesUnready.Count -gt 0) { $why.Add("contains the unmerged work of $(@($facts[$pick].includesUnready | ForEach-Object { "#$($_.number) ($($_.reason))" }) -join ', ')") }
        $facts[$pick].reason = $why -join '; '
        $order.Add($pick); [void]$remaining.Remove($pick)
    }

    [ordered]@{
        repository = $Repository
        base = [ordered]@{ ref = $Base; branch = $baseBranch; sha = $baseSha }
        order = @($order)
        pullRequests = @($order | ForEach-Object { $facts[$_] })
        conflicts = @($conflicts)
        skipped = @($skipped)
        # Skipped PRs whose heads could not be fetched, so no ready head was checked for them.
        uncheckedSkipped = @($unchecked)
    } | ConvertTo-Json -Depth 8
    exit 0
} catch {
    [ordered]@{ error = $_.Exception.Message } | ConvertTo-Json
    exit 1
}

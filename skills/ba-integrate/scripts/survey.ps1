# Surveys a repository's open pull requests before integrating them: which are ready
# (not drafts), what each changes, which build on others, which pairs conflict with each
# other or with the base branch, and an order to merge them in. It changes nothing but
# fetched objects; every merge it tries is computed by `git merge-tree`, without a
# checkout. Writes one JSON document, with an `error` member and exit code 1 on failure.
#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,
    [string]$Base,
    [string]$PullRequestsJson
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

# Runs git in the repository and returns its exit code and output lines; any exit code
# outside $Allowed is an error carrying git's own message.
function Invoke-Git([string[]]$Arguments, [int[]]$Allowed = @(0)) {
    $output = & git -c core.quotePath=false -C $Repository @Arguments 2>&1
    $code = $LASTEXITCODE
    $lines = @($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
    if ($code -notin $Allowed) {
        $message = @($output | ForEach-Object { "$_" }) -join ' '
        throw "git $($Arguments -join ' ') failed ($code): $message"
    }
    return [pscustomobject]@{ Code = $code; Lines = $lines }
}

# The open pull requests of the repository's GitHub remote, as the records the rest of
# the survey reads.
function Get-GitHubPullRequests {
    # On Windows an extensionless shell shim named `gh` can shadow gh.exe on PATH, and
    # PowerShell cannot run it; take the real executable.
    $gh = @(Get-Command gh -CommandType Application -All -ErrorAction SilentlyContinue |
        Where-Object { -not $IsWindows -or $_.Extension -eq '.exe' } | Select-Object -First 1).Source
    if (-not $gh) { throw 'The GitHub CLI (gh) is not installed or not on PATH.' }
    Push-Location -LiteralPath $Repository
    try {
        $identity = & $gh repo view --json owner,name | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw 'gh could not identify the repository; is it authenticated?' }
        $query = @'
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, first: 100, orderBy: {field: CREATED_AT, direction: ASC}) {
      nodes {
        number title url isDraft isCrossRepository createdAt
        headRefName headRefOid baseRefName mergeable reviewDecision
        reviewThreads(first: 100) { nodes { isResolved } }
      }
    }
  }
}
'@
        $response = & $gh api graphql -f "query=$query" -F "owner=$($identity.owner.login)" -F "name=$($identity.name)" | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw 'gh could not list the open pull requests.' }
    } finally { Pop-Location }
    foreach ($node in $response.data.repository.pullRequests.nodes) {
        [pscustomobject]@{
            number = $node.number; title = $node.title; url = $node.url
            isDraft = $node.isDraft; isCrossRepository = $node.isCrossRepository
            headRefName = $node.headRefName; headRefOid = $node.headRefOid; baseRefName = $node.baseRefName
            mergeable = $node.mergeable; reviewDecision = $node.reviewDecision
            unresolvedReviewThreads = @($node.reviewThreads.nodes | Where-Object { -not $_.isResolved }).Count
        }
    }
}

# The paths a three-way merge of two commits leaves in conflict; empty when it is clean.
function Get-MergeConflicts([string]$Left, [string]$Right) {
    $result = Invoke-Git @('merge-tree', '--write-tree', '--name-only', '--no-messages', $Left, $Right) -Allowed 0, 1
    if ($result.Code -eq 0) { return @() }
    return @($result.Lines | Select-Object -Skip 1 | Where-Object { $_ } | Sort-Object -Unique)
}

# True when commit $Ancestor is reachable from commit $Descendant.
function Test-Ancestor([string]$Ancestor, [string]$Descendant) {
    return (Invoke-Git @('merge-base', '--is-ancestor', $Ancestor, $Descendant) -Allowed 0, 1).Code -eq 0
}

try {
    $Repository = (Resolve-Path -LiteralPath $Repository).Path
    $fromGitHub = -not $PullRequestsJson
    if ($fromGitHub) { Invoke-Git @('fetch', '--quiet', '--no-tags', 'origin') | Out-Null }
    if (-not $Base) {
        $remoteHead = (Invoke-Git @('symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD') -Allowed 0, 1).Lines
        $Base = if ($remoteHead) { $remoteHead[0] } else { 'origin/main' }
    }
    $baseBranch = $Base -replace '^origin/', ''
    $baseSha = (Invoke-Git @('rev-parse', '--verify', "$Base^{commit}")).Lines[0]

    $all = if ($fromGitHub) { @(Get-GitHubPullRequests) } else { @(Get-Content -LiteralPath $PullRequestsJson -Raw | ConvertFrom-Json) }
    $skipped = [Collections.Generic.List[object]]::new()
    $ready = [Collections.Generic.List[object]]::new()
    foreach ($pr in ($all | Sort-Object { [int]$_.number })) {
        # JSON numbers arrive as Int64; every table below is keyed by Int32.
        $pr.number = [int]$pr.number
        if ($pr.isDraft) { $skipped.Add([ordered]@{ number = $pr.number; reason = 'draft' }); continue }
        if ($pr.isCrossRepository) { $skipped.Add([ordered]@{ number = $pr.number; reason = 'from a fork' }); continue }
        $ready.Add($pr)
    }
    # A PR must target the base branch or another ready PR's branch; dropping one can strand
    # a PR stacked on it, so repeat until nothing more drops out.
    do {
        $heads = @($ready | ForEach-Object headRefName)
        $stranded = @($ready | Where-Object { $_.baseRefName -ne $baseBranch -and $_.baseRefName -notin $heads })
        foreach ($pr in $stranded) {
            $skipped.Add([ordered]@{ number = $pr.number; reason = "targets $($pr.baseRefName), which is neither $baseBranch nor a ready PR's branch" })
            [void]$ready.Remove($pr)
        }
    } while ($stranded.Count -gt 0)

    foreach ($pr in $ready) {
        if ($fromGitHub) { Invoke-Git @('fetch', '--quiet', '--no-tags', 'origin', "refs/pull/$($pr.number)/head") | Out-Null }
        $known = Invoke-Git @('cat-file', '-e', "$($pr.headRefOid)^{commit}") -Allowed 0, 1, 128
        if ($known.Code -ne 0) { throw "PR #$($pr.number)'s head $($pr.headRefOid) is not available locally; it may have moved while surveying. Run the survey again." }
    }

    $facts = @{}
    foreach ($pr in $ready) {
        $head = $pr.headRefOid
        $mergeBase = (Invoke-Git @('merge-base', $baseSha, $head)).Lines[0]
        $facts[$pr.number] = [ordered]@{
            number = $pr.number; title = $pr.title; url = $pr.url
            head = $pr.headRefName; headSha = $head; baseRef = $pr.baseRefName
            dependsOn = @()
            commits = [int](Invoke-Git @('rev-list', '--count', "$baseSha..$head")).Lines[0]
            behindBase = [int](Invoke-Git @('rev-list', '--count', "$head..$baseSha")).Lines[0]
            files = @((Invoke-Git @('diff', '--name-only', $mergeBase, $head)).Lines | Where-Object { $_ })
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
            $contains = $facts[$a.number].commits -gt 0 -and (Test-Ancestor $a.headRefOid $b.headRefOid)
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
    } | ConvertTo-Json -Depth 8
    exit 0
} catch {
    [ordered]@{ error = $_.Exception.Message } | ConvertTo-Json
    exit 1
}

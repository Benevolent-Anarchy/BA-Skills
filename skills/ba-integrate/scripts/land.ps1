# Lands one updated pull request on the base branch, refusing anything that differs from
# the approved plan. Before pushing anything it checks the updated head holds the rehearsed
# tree and contains both the approved head and the expected base, that the remote base
# and branch are exactly where the plan expects, and that GitHub still shows the pull
# request open, ready, on that branch and targeting that base. It makes the merge commit on
# the expected base, pushes the update to the branch, checks GitHub again, and pushes the
# merge commit to the base. Each push names the exact value it replaces and is a
# fast-forward of it, so a ref that moved in either direction, or vanished, fails its push
# and no history is ever rewritten. It then waits for GitHub to report the pull request
# merged, since GitHub records a pushed merge asynchronously. Run again with the same
# arguments after a failure, it resumes: it accepts a branch already holding the update
# and a base already holding this merge. Writes one JSON document, with an `error` member
# and exit code 1 on failure.
#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Worktree,
    [Parameter(Mandatory)][int]$PullRequest,
    [Parameter(Mandatory)][string]$Branch,
    [Parameter(Mandatory)][string]$ApprovedHead,
    [Parameter(Mandatory)][string]$Updated,
    [Parameter(Mandatory)][string]$BaseBranch,
    [Parameter(Mandatory)][string]$ExpectedBase,
    [Parameter(Mandatory)][string]$Rehearsed,
    [Parameter(Mandatory)][string]$Message,
    [string]$Remote = 'origin',
    [int]$TimeoutSeconds = 120,
    [int]$PollSeconds = 5,
    # The GitHub CLI to run, gh on PATH by default; tests pass a stand-in script.
    [string]$GitHubCli
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'Integrate.psm1') -Force

$result = [ordered]@{ pullRequest = $PullRequest; branchPushed = $false; landed = $false; merged = $false }
# Set once this run starts its own merge commit, so a failure abandons only that merge,
# leaving the worktree ready for a retry, and never one that was already in progress.
$startedMerge = $false

# What GitHub shows for the pull request now, or $null when it could not be read.
function Get-PullRequestView {
    $call = Invoke-GitHubCli $script:gh @('pr', 'view', "$PullRequest", '--repo', $script:gitHubRepository, '--json', 'state,isDraft,headRefOid,headRefName,baseRefName,closingIssuesReferences') $Worktree
    if ($call.Code -ne 0) { $script:lastGitHubError = "$($call.Out) $($call.Err)"; return $null }
    try { return $call.Out | ConvertFrom-Json } catch { $script:lastGitHubError = "$($call.Out) $($call.Err)"; return $null }
}

# Refuses unless GitHub shows the pull request open, ready, on $Branch, targeting
# $BaseBranch and at one of $Heads. GitHub can take a moment to see a push, so a head it
# has not caught up with yet is waited for, while any other difference refuses at once.
# $When says what has been pushed so far, for the error.
function Assert-PullRequestReady([string[]]$Heads, [string]$When) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $view = Get-PullRequestView
        if (-not $view) { throw "Could not read #$PullRequest from GitHub $When. gh said: $script:lastGitHubError" }
        if ($view.state -ne 'OPEN') { throw "#$PullRequest is $($view.state) on GitHub $When." }
        if ($view.isDraft) { throw "#$PullRequest is a draft again on GitHub $When." }
        if ($view.headRefName -ne $Branch) { throw "#$PullRequest's branch on GitHub is $($view.headRefName), not $Branch, $When." }
        if ($view.baseRefName -ne $BaseBranch) { throw "#$PullRequest now targets $($view.baseRefName), not $BaseBranch, $When." }
        if ($view.headRefOid -in $Heads) { return }
        if ((Get-Date) -ge $deadline) { throw "GitHub shows #$PullRequest at $($view.headRefOid), not $($Heads -join ' or '), $When." }
        Start-Sleep -Seconds $PollSeconds
    }
}

# Pushes $Commit to $Ref on the remote only while the remote still has $Expected there,
# which the commit must descend from, so the push is never anything but a fast-forward of
# the value inspected. Returns git's output when the remote refuses.
function Push-Expected([string]$Commit, [string]$Ref, [string]$Expected) {
    if (-not (Test-Ancestor $Worktree $Expected $Commit)) { throw "$Commit does not descend from $Expected; refusing to rewrite $Ref." }
    $push = Invoke-Git $Worktree @('push', '--quiet', "--force-with-lease=refs/heads/${Ref}:$Expected", $Remote, "${Commit}:refs/heads/$Ref") -Allowed 0, 1, 128
    if ($push.Code -eq 0) { return $null }
    return $push.Text
}

# The pushes made so far, for errors after the first push.
function Get-PushedSoFar { if ($result.branchPushed) { "$Branch now holds the update $updatedSha" } else { "$Branch is unchanged" } }

try {
    $script:gh = if ($GitHubCli) { $GitHubCli } else { Get-GitHubCli }
    $Worktree = (Resolve-Path -LiteralPath $Worktree).Path
    # The pull request is read from the repository the pushes go to, never one gh picks.
    $script:gitHubRepository = Get-GitHubRepository $Worktree $Remote
    $approved = Resolve-Commit $Worktree $ApprovedHead 'Approved head'
    $updatedSha = Resolve-Commit $Worktree $Updated 'Updated head'
    $expected = Resolve-Commit $Worktree $ExpectedBase 'Expected base'
    $rehearsedSha = Resolve-Commit $Worktree $Rehearsed 'Rehearsed step'
    $rehearsedTree = (Invoke-Git $Worktree @('rev-parse', "$rehearsedSha^{tree}")).Lines[0]
    $result.branchTip = $updatedSha
    if (-not (Test-Ancestor $Worktree $approved $updatedSha)) { throw 'The updated head does not contain the approved head. Nothing was pushed.' }
    if (-not (Test-Ancestor $Worktree $expected $updatedSha)) { throw 'The updated head does not contain the expected base. Nothing was pushed.' }
    if ((Invoke-Git $Worktree @('rev-parse', "$updatedSha^{tree}")).Lines[0] -ne $rehearsedTree) { throw 'The updated head differs from the rehearsed step. Nothing was pushed.' }

    # A base already holding this very merge means an earlier run landed it; resume at the
    # wait. Anything else on the base is a base that moved.
    $remoteBase = Get-RemoteBranch $Worktree $Remote $BaseBranch
    $resumed = $false
    if ($remoteBase -and $remoteBase -ne $expected -and (Test-CommitExists $Worktree $remoteBase)) {
        $parents = @((Invoke-Git $Worktree @('rev-list', '--parents', '-n', '1', $remoteBase)).Lines[0] -split ' ')
        $tree = (Invoke-Git $Worktree @('rev-parse', "$remoteBase^{tree}")).Lines[0]
        $resumed = $parents.Count -eq 3 -and $parents[1] -eq $expected -and $parents[2] -eq $updatedSha -and $tree -eq $rehearsedTree
    }
    if ($resumed) {
        $result.resumed = $true; $result.landed = $true; $result.mergeCommit = $remoteBase
        $result.branchPushed = (Get-RemoteBranch $Worktree $Remote $Branch) -eq $updatedSha
    } else {
        if ($remoteBase -ne $expected) { throw "$BaseBranch has moved: the plan expects $expected, and $Remote has $(if ($remoteBase) { $remoteBase } else { 'no such branch' }). Nothing was pushed." }
        $remoteBranch = Get-RemoteBranch $Worktree $Remote $Branch
        if ($remoteBranch -ne $approved -and $remoteBranch -ne $updatedSha) { throw "$Branch has moved: the plan expects $approved, and $Remote has $(if ($remoteBranch) { $remoteBranch } else { 'no such branch' }). Nothing was pushed." }
        Assert-PullRequestReady @($approved, $updatedSha) 'before anything was pushed; nothing was pushed'

        # The merge commit: on the expected base, merging the update, which already contains it.
        if (-not (Test-CleanWorktree $Worktree)) { throw 'The integration worktree has uncommitted changes or a merge in progress. Nothing was pushed.' }
        Invoke-Git $Worktree @('checkout', '--quiet', '--detach', $expected) | Out-Null
        $startedMerge = $true
        Invoke-Git $Worktree @('merge', '--no-ff', '--no-commit', $updatedSha) | Out-Null
        $messageFile = Join-Path ([IO.Path]::GetTempPath()) ('ba-integrate-message-' + [guid]::NewGuid().ToString('N') + '.txt')
        [IO.File]::WriteAllText($messageFile, $Message, [Text.UTF8Encoding]::new($false))
        try { Invoke-Git $Worktree @('commit', '--quiet', '-F', $messageFile) | Out-Null }
        catch { throw "Making the merge commit failed, so nothing was pushed: $($_.Exception.Message)" }
        finally { Remove-Item -LiteralPath $messageFile -Force -ErrorAction SilentlyContinue }
        $merge = (Invoke-Git $Worktree @('rev-parse', 'HEAD')).Lines[0]
        if ((Invoke-Git $Worktree @('rev-parse', 'HEAD^{tree}')).Lines[0] -ne $rehearsedTree) { throw 'The merge commit differs from the rehearsed step. Nothing was pushed.' }

        if ($remoteBranch -ne $updatedSha) {
            $refused = Push-Expected $updatedSha $Branch $remoteBranch
            if ($refused) { throw "Pushing $Branch was refused: it is no longer at $remoteBranch. Nothing was pushed. Git said: $refused" }
            $result.branchPushed = $true
        }
        Assert-PullRequestReady @($updatedSha) "after the branch push, before landing; $(Get-PushedSoFar) and $BaseBranch is unchanged"
        $refused = Push-Expected $merge $BaseBranch $expected
        if ($refused) { throw "Pushing $BaseBranch was refused: it is no longer at $expected. Nothing was merged; $(Get-PushedSoFar). Git said: $refused" }
        $result.landed = $true
        $result.mergeCommit = $merge
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $view = Get-PullRequestView
        if ($view -and $view.state -eq 'MERGED') { break }
        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)
    $result.state = if ($view) { $view.state } else { $null }
    if (-not $view -or $view.state -ne 'MERGED') {
        $seen = if ($view) { "still reports #$PullRequest as $($view.state)" } else { "could not be read: $script:lastGitHubError" }
        throw "Landed on $BaseBranch as $($result.mergeCommit), but GitHub $seen. Do not delete its branch or start the next step. Run this again with the same arguments to resume waiting."
    }
    $result.merged = $true
    # An issue may live in another repository, so each keeps its URL and repository.
    $result.closingIssues = @($view.closingIssuesReferences | ForEach-Object {
        [ordered]@{ url = $_.url; repository = "$($_.repository.owner.login)/$($_.repository.name)"; number = $_.number }
    })
    $result | ConvertTo-Json -Depth 5
    exit 0
} catch {
    # A merge this run started and never committed is abandoned, so the same arguments can
    # be run again once the cause is fixed.
    if ($startedMerge -and $Worktree -and (Test-Path -LiteralPath $Worktree)) {
        $pending = & git -C $Worktree rev-parse --quiet --verify MERGE_HEAD 2>$null
        if ($pending) { & git -C $Worktree merge --abort 2>$null | Out-Null }
    }
    $result.error = (Hide-UrlCredentials $_.Exception.Message)
    $result | ConvertTo-Json -Depth 5
    exit 1
}

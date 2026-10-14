# Lands one updated pull request on the base branch, refusing anything that differs from
# the approved plan. It checks the updated head holds the rehearsed tree and contains
# both the approved head and the expected base, and that the remote base and branch are
# still where the plan expects. It then pushes the update to the branch, makes the merge
# commit on the expected base, and pushes that to the base without force. A base that
# moves after the check therefore fails the push instead of landing an unrehearsed tree,
# and nothing goes through a merge queue. With -PullRequest it waits for GitHub to report
# the pull request merged, since GitHub records a pushed merge asynchronously. Writes one
# JSON document, with an `error` member and exit code 1 on failure.
#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Worktree,
    [Parameter(Mandatory)][string]$Branch,
    [Parameter(Mandatory)][string]$ApprovedHead,
    [Parameter(Mandatory)][string]$Updated,
    [Parameter(Mandatory)][string]$BaseBranch,
    [Parameter(Mandatory)][string]$ExpectedBase,
    [Parameter(Mandatory)][string]$Rehearsed,
    [Parameter(Mandatory)][string]$Message,
    [int]$PullRequest = 0,
    [string]$Remote = 'origin',
    [int]$TimeoutSeconds = 120
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'Integrate.psm1') -Force

$result = [ordered]@{ branchPushed = $false; landed = $false }
try {
    $Worktree = (Resolve-Path -LiteralPath $Worktree).Path
    $approved = Resolve-Commit $Worktree $ApprovedHead 'Approved head'
    $updatedSha = Resolve-Commit $Worktree $Updated 'Updated head'
    $expected = Resolve-Commit $Worktree $ExpectedBase 'Expected base'
    $rehearsedSha = Resolve-Commit $Worktree $Rehearsed 'Rehearsed step'
    $rehearsedTree = (Invoke-Git $Worktree @('rev-parse', "$rehearsedSha^{tree}")).Lines[0]
    if (-not (Test-Ancestor $Worktree $approved $updatedSha)) { throw 'The updated head does not contain the approved head. Nothing was pushed.' }
    if (-not (Test-Ancestor $Worktree $expected $updatedSha)) { throw 'The updated head does not contain the expected base. Nothing was pushed.' }
    if ((Invoke-Git $Worktree @('rev-parse', "$updatedSha^{tree}")).Lines[0] -ne $rehearsedTree) { throw 'The updated head differs from the rehearsed step. Nothing was pushed.' }

    $remoteBase = Get-RemoteBranch $Worktree $Remote $BaseBranch
    if ($remoteBase -ne $expected) { throw "$BaseBranch has moved: the plan expects $expected, and $Remote has $(if ($remoteBase) { $remoteBase } else { 'no such branch' }). Nothing was pushed." }
    $remoteBranch = Get-RemoteBranch $Worktree $Remote $Branch
    if ($remoteBranch -ne $approved -and $remoteBranch -ne $updatedSha) { throw "$Branch has moved: the plan expects $approved, and $Remote has $(if ($remoteBranch) { $remoteBranch } else { 'no such branch' }). Nothing was pushed." }

    if ($remoteBranch -ne $updatedSha) {
        $push = Invoke-Git $Worktree @('push', '--quiet', $Remote, "${updatedSha}:refs/heads/$Branch") -Allowed 0, 1, 128
        if ($push.Code -ne 0) { throw "Pushing $Branch was rejected, so it moved after the check. Nothing was merged. Git said: $($push.Text)" }
        $result.branchPushed = $true
    }

    if (-not (Test-CleanWorktree $Worktree)) { throw "The integration worktree has uncommitted changes or a merge in progress. $Branch $(if ($result.branchPushed) { 'now holds the update' } else { 'is unchanged' }); nothing was merged." }
    Invoke-Git $Worktree @('checkout', '--quiet', '--detach', $expected) | Out-Null
    Invoke-Git $Worktree @('merge', '--no-ff', '--no-commit', $updatedSha) | Out-Null
    $messageFile = Join-Path ([IO.Path]::GetTempPath()) ('ba-integrate-message-' + [guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllText($messageFile, $Message, [Text.UTF8Encoding]::new($false))
    try { Invoke-Git $Worktree @('commit', '--quiet', '-F', $messageFile) | Out-Null }
    finally { Remove-Item -LiteralPath $messageFile -Force -ErrorAction SilentlyContinue }
    $merge = (Invoke-Git $Worktree @('rev-parse', 'HEAD')).Lines[0]
    if ((Invoke-Git $Worktree @('rev-parse', 'HEAD^{tree}')).Lines[0] -ne $rehearsedTree) { throw "The merge commit differs from the rehearsed step. Nothing was merged; $Branch $(if ($result.branchPushed) { 'now holds the update' } else { 'is unchanged' })." }

    $push = Invoke-Git $Worktree @('push', '--quiet', $Remote, "${merge}:refs/heads/$BaseBranch") -Allowed 0, 1, 128
    if ($push.Code -ne 0) { throw "Pushing $BaseBranch was rejected, so it moved after the check. Nothing was merged; $Branch $(if ($result.branchPushed) { 'now holds the update' } else { 'is unchanged' }). Git said: $($push.Text)" }
    $result.landed = $true
    $result.mergeCommit = $merge
    $result.branchTip = $updatedSha

    if ($PullRequest -gt 0) {
        $gh = Get-GitHubCli
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        Push-Location -LiteralPath $Worktree
        try {
            do {
                $view = & $gh pr view $PullRequest --json state,closingIssuesReferences | ConvertFrom-Json
                if ($view.state -eq 'MERGED') { break }
                Start-Sleep -Seconds 5
            } while ((Get-Date) -lt $deadline)
        } finally { Pop-Location }
        $result.state = $view.state
        if ($view.state -ne 'MERGED') { throw "Landed on $BaseBranch as $merge, but GitHub still reports #$PullRequest as $($view.state). Do not delete its branch or start the next step until it reports MERGED." }
        $result.closingIssues = @($view.closingIssuesReferences | ForEach-Object { $_.number })
    }
    $result | ConvertTo-Json -Depth 5
    exit 0
} catch {
    $result.error = $_.Exception.Message
    $result | ConvertTo-Json -Depth 5
    exit 1
}

# Brings a pull request's head up to date with the integration base exactly as the
# rehearsal predicted. In the integration worktree it checks out the head, merges the base
# into it without committing, takes every path the merge leaves in conflict from the
# rehearsed step's commit, and commits only while a merge is pending. Taking conflicted
# paths from the rehearsed commit replays every kind of resolution, including a file one
# side deleted, which rerere cannot. The result's tree must equal the rehearsed step's
# tree. It pushes nothing. Writes one JSON document, with an `error` member and exit code
# 1 on failure.
#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Worktree,
    [Parameter(Mandatory)][string]$Head,
    [Parameter(Mandatory)][string]$Base,
    [Parameter(Mandatory)][string]$Rehearsed,
    [string]$Message = 'Merge the integration base into this pull request'
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'Integrate.psm1') -Force

$result = [ordered]@{}
# Set once this run starts its own merge, so a failure abandons only that merge and never
# one that was already in progress, with someone's resolution in it.
$startedMerge = $false
try {
    $Worktree = (Resolve-Path -LiteralPath $Worktree).Path
    $headSha = Resolve-Commit $Worktree $Head 'Head'
    $baseSha = Resolve-Commit $Worktree $Base 'Base'
    $rehearsedSha = Resolve-Commit $Worktree $Rehearsed 'Rehearsed step'
    $result.head = $headSha; $result.base = $baseSha; $result.rehearsed = $rehearsedSha
    if (-not (Test-CleanWorktree $Worktree)) { throw 'The integration worktree has uncommitted changes or a merge in progress; nothing was changed.' }

    Invoke-Git $Worktree @('checkout', '--quiet', '--detach', $headSha) | Out-Null
    $replayed = @()
    $upToDate = Test-Ancestor $Worktree $baseSha $headSha
    if (-not $upToDate) {
        $startedMerge = $true
        Invoke-Git $Worktree @('merge', '--no-ff', '--no-commit', '--no-edit', $baseSha) -Allowed 0, 1 | Out-Null
        $replayed = @((Invoke-Git $Worktree @('diff', '--name-only', '--diff-filter=U')).Lines | Where-Object { $_ } | Sort-Object -Unique)
        foreach ($path in $replayed) {
            $kept = (Invoke-Git $Worktree @('cat-file', '-e', "${rehearsedSha}:$path") -Allowed 0, 1, 128).Code -eq 0
            if ($kept) { Invoke-Git $Worktree @('checkout', $rehearsedSha, '--', $path) | Out-Null }
            else { Invoke-Git $Worktree @('rm', '--quiet', '--force', '--', $path) | Out-Null }
        }
        $left = @((Invoke-Git $Worktree @('diff', '--name-only', '--diff-filter=U')).Lines | Where-Object { $_ })
        if ($left.Count -gt 0) { throw "Paths still unmerged after replaying the rehearsal: $($left -join ', ')." }
        $pending = (Invoke-Git $Worktree @('rev-parse', '--quiet', '--verify', 'MERGE_HEAD') -Allowed 0, 1).Code -eq 0
        if ($pending) { Invoke-Git $Worktree @('commit', '--quiet', '-m', $Message) | Out-Null }
    }

    $result.commit = (Invoke-Git $Worktree @('rev-parse', 'HEAD')).Lines[0]
    $result.tree = (Invoke-Git $Worktree @('rev-parse', 'HEAD^{tree}')).Lines[0]
    $result.rehearsedTree = (Invoke-Git $Worktree @('rev-parse', "$rehearsedSha^{tree}")).Lines[0]
    $result.upToDate = $upToDate
    $result.replayed = $replayed
    $result.matches = $result.tree -eq $result.rehearsedTree
    if (-not $result.matches) {
        $result.differences = @((Invoke-Git $Worktree @('diff', '--name-only', $rehearsedSha, 'HEAD')).Lines | Where-Object { $_ })
        throw "The updated head differs from the rehearsed step in $($result.differences.Count) path(s): $($result.differences -join ', ')."
    }
    $result | ConvertTo-Json -Depth 5
    exit 0
} catch {
    # Leave the worktree usable: abandon a merge this run started and left half done.
    if ($startedMerge -and $Worktree -and (Test-Path -LiteralPath $Worktree)) {
        $merging = & git -C $Worktree rev-parse --quiet --verify MERGE_HEAD 2>$null
        if ($merging) { & git -C $Worktree merge --abort 2>$null | Out-Null }
    }
    $result.error = (Hide-UrlCredentials $_.Exception.Message)
    $result | ConvertTo-Json -Depth 5
    exit 1
}

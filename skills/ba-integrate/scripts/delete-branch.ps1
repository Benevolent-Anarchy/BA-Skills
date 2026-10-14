# Deletes a merged pull request's branch on the remote, only while it still points at the
# commit that merged and no open pull request targets it. GitHub can close a pull request
# whose base branch is deleted, so one stacked on this branch must be retargeted first;
# the deletion refuses and names them until then. A branch someone pushed to since is
# preserved and reported, and an already deleted one is left alone. The deletion is a push
# with an expected value, so a push landing between the check and the deletion makes the
# deletion fail instead of discarding unmerged work. Writes one JSON document whose
# `outcome` is `deleted`, `moved` or `absent`, with an `error` member and exit code 1 on
# failure or refusal.
#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$Branch,
    [Parameter(Mandatory)][string]$MergedTip,
    [Parameter(Mandatory)][string]$BaseBranch,
    [string]$Remote = 'origin',
    # The GitHub CLI to run, gh on PATH by default; tests pass a stand-in script.
    [string]$GitHubCli
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'Integrate.psm1') -Force

$result = [ordered]@{ branch = $Branch; deleted = $false }
try {
    $Repository = (Resolve-Path -LiteralPath $Repository).Path
    $gh = if ($GitHubCli) { $GitHubCli } else { Get-GitHubCli }
    $tip = Resolve-Commit $Repository $MergedTip 'Merged tip'
    Invoke-Git $Repository @('fetch', '--quiet', '--no-tags', $Remote, "refs/heads/$BaseBranch") | Out-Null
    $base = Resolve-Commit $Repository 'FETCH_HEAD' "$Remote's $BaseBranch"
    if (-not (Test-Ancestor $Repository $tip $base)) { throw "$tip is not in $BaseBranch, so $Branch has not merged. Nothing was deleted." }

    $current = Get-RemoteBranch $Repository $Remote $Branch
    if ($current -eq $tip) {
        $listed = Invoke-GitHubCli $gh @('pr', 'list', '--base', $Branch, '--state', 'open', '--limit', '100', '--json', 'number,url') $Repository
        if ($listed.Code -ne 0) { throw "Could not ask GitHub which pull requests target $Branch, so nothing was deleted. gh said: $($listed.Out) $($listed.Err)" }
        $dependents = @($listed.Out | ConvertFrom-Json)
        if ($dependents.Count -gt 0) {
            $result.dependents = @($dependents | ForEach-Object { [ordered]@{ number = $_.number; url = $_.url } })
            throw "Open pull requests still target ${Branch}: $(@($dependents | ForEach-Object { "#$($_.number)" }) -join ', '). Retarget them to $BaseBranch first; nothing was deleted."
        }
        $push = Invoke-Git $Repository @('push', '--quiet', "--force-with-lease=refs/heads/${Branch}:$tip", $Remote, ":refs/heads/$Branch") -Allowed 0, 1, 128
        if ($push.Code -eq 0) { $result.deleted = $true; $result.outcome = 'deleted' }
        else {
            $current = Get-RemoteBranch $Repository $Remote $Branch
            if ($current -eq $tip) { throw "Deleting $Branch failed though it still points at the merged tip. Git said: $($push.Text)" }
        }
    }
    if (-not $result.deleted) {
        if (-not $current) { $result.outcome = 'absent' }
        else { $result.outcome = 'moved'; $result.current = $current }
    }
    $result | ConvertTo-Json -Depth 5
    exit 0
} catch {
    $result.error = $_.Exception.Message
    $result | ConvertTo-Json -Depth 5
    exit 1
}

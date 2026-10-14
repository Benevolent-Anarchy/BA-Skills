# Deletes a merged pull request's branch on the remote, only while it still points at the
# commit that merged. A branch someone pushed to since is preserved and reported, and an
# already deleted one is left alone. The deletion is a push with an expected value, so a
# push landing between the check and the deletion makes the deletion fail instead of
# discarding unmerged work. Writes one JSON document whose `outcome` is `deleted`,
# `moved` or `absent`, with an `error` member and exit code 1 on failure.
#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$Branch,
    [Parameter(Mandatory)][string]$MergedTip,
    [Parameter(Mandatory)][string]$BaseBranch,
    [string]$Remote = 'origin'
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'Integrate.psm1') -Force

$result = [ordered]@{ branch = $Branch; deleted = $false }
try {
    $Repository = (Resolve-Path -LiteralPath $Repository).Path
    $tip = Resolve-Commit $Repository $MergedTip 'Merged tip'
    Invoke-Git $Repository @('fetch', '--quiet', '--no-tags', $Remote, "refs/heads/$BaseBranch") | Out-Null
    $base = Resolve-Commit $Repository 'FETCH_HEAD' "$Remote's $BaseBranch"
    if (-not (Test-Ancestor $Repository $tip $base)) { throw "$tip is not in $BaseBranch, so $Branch has not merged. Nothing was deleted." }

    $current = Get-RemoteBranch $Repository $Remote $Branch
    if ($current -eq $tip) {
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

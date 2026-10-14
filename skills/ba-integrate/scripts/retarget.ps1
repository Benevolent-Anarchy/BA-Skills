# Lists, or retargets to the base, every open pull request that targets a branch, drafts
# included, read page by page from the GitHub repository the remote's URL names. With
# -List it changes nothing, so the plan can name them. Without it, it retargets exactly
# the approved set: if the pull requests targeting the branch are not the ones -Approved
# names, it retargets none and says how they differ. Otherwise it retargets each to the
# base and reads the list again to confirm none is left, since GitHub can close a pull
# request whose base branch is deleted, and a stacked one must land on the base. Writes
# one JSON document, with an `error` member and exit code 1 on failure, including when
# any pull request is still left targeting the branch.
#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$Branch,
    [Parameter(Mandatory)][string]$BaseBranch,
    [switch]$List,
    # The pull request numbers the plan approved retargeting, comma-separated, or `none`. An
    # explicit word rather than an empty string, which PowerShell before 7.3 drops from a
    # native command line.
    [string]$Approved,
    [string]$Remote = 'origin',
    # The GitHub CLI to run, gh on PATH by default; tests pass a stand-in script.
    [string]$GitHubCli
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'Integrate.psm1') -Force

$result = [ordered]@{ branch = $Branch; base = $BaseBranch }
try {
    $Repository = (Resolve-Path -LiteralPath $Repository).Path
    $gh = if ($GitHubCli) { $GitHubCli } else { Get-GitHubCli }
    $gitHubRepository = Get-GitHubRepository $Repository $Remote
    $result.repository = $gitHubRepository
    $targeting = @(Get-PullRequestsTargeting $gh $gitHubRepository $Branch $Repository)
    $result.targeting = $targeting
    if (-not $List) {
        if (-not $Approved) { throw 'Retargeting needs -Approved: the numbers the plan approved, or none. Nothing was retargeted.' }
        $approvedSet = if ($Approved -eq 'none') { @() } else { @("$Approved" -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { [int]$_ } | Sort-Object -Unique) }
        $found = @($targeting | ForEach-Object { [int]$_.number } | Sort-Object -Unique)
        $unexpected = @($found | Where-Object { $_ -notin $approvedSet })
        $missing = @($approvedSet | Where-Object { $_ -notin $found })
        if ($unexpected.Count -gt 0 -or $missing.Count -gt 0) {
            $result.unexpected = $unexpected; $result.missing = $missing
            $differences = @(if ($unexpected.Count) { "not approved: #$($unexpected -join ', #')" }; if ($missing.Count) { "approved but no longer targeting it: #$($missing -join ', #')" })
            throw "The pull requests targeting $Branch differ from the plan ($($differences -join '; ')). Nothing was retargeted."
        }
        $retargeted = [Collections.Generic.List[int]]::new()
        $result.retargeted = @()
        foreach ($pr in $targeting) {
            $edit = Invoke-GitHubCli $gh @('pr', 'edit', "$($pr.number)", '--repo', $gitHubRepository, '--base', $BaseBranch) $Repository
            if ($edit.Code -ne 0) { throw "Retargeting #$($pr.number) to $BaseBranch failed after retargeting $(if ($retargeted.Count) { "#$($retargeted -join ', #')" } else { 'none' }). gh said: $($edit.Out) $($edit.Err)" }
            $retargeted.Add($pr.number)
            $result.retargeted = @($retargeted)
        }
        $left = @(Get-PullRequestsTargeting $gh $gitHubRepository $Branch $Repository)
        $result.remaining = $left
        if ($left.Count -gt 0) { throw "Pull requests still target ${Branch} after retargeting: $(@($left | ForEach-Object { "#$($_.number)" }) -join ', ')." }
    }
    $result | ConvertTo-Json -Depth 6
    exit 0
} catch {
    $result.error = $_.Exception.Message
    $result | ConvertTo-Json -Depth 6
    exit 1
}

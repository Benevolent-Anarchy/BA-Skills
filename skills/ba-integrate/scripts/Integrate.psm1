# Shared helpers for the ba-integrate scripts: running git in a given repository with its
# exit code and output, resolving commits and remote branches, and finding the GitHub CLI.

# Runs git in $Repository and returns its exit code and output lines; an exit code outside
# $Allowed is an error carrying git's own message. Paths are literal, never globs, so a
# path such as `Pack[Patreon]/a.png` means that file.
function Invoke-Git([string]$Repository, [string[]]$Arguments, [int[]]$Allowed = @(0)) {
    $output = & git --literal-pathspecs -c core.quotePath=false -C $Repository @Arguments 2>&1
    $code = $LASTEXITCODE
    $lines = @($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
    if ($code -notin $Allowed) {
        $message = @($output | ForEach-Object { "$_" }) -join ' '
        throw "git $($Arguments -join ' ') failed ($code): $message"
    }
    return [pscustomobject]@{ Code = $code; Lines = $lines; Text = (@($output | ForEach-Object { "$_" }) -join ' ') }
}

# The full commit $Revision names, or an error naming it as $What.
function Resolve-Commit([string]$Repository, [string]$Revision, [string]$What) {
    $result = Invoke-Git $Repository @('rev-parse', '--verify', '--quiet', "$Revision^{commit}") -Allowed 0, 1, 128
    if ($result.Code -ne 0 -or -not $result.Lines) { throw "$What $Revision is not a commit in this repository." }
    return $result.Lines[0]
}

# True when commit $Sha is available in $Repository.
function Test-CommitExists([string]$Repository, [string]$Sha) {
    return (Invoke-Git $Repository @('cat-file', '-e', "$Sha^{commit}") -Allowed 0, 1, 128).Code -eq 0
}

# True when commit $Ancestor is reachable from commit $Descendant.
function Test-Ancestor([string]$Repository, [string]$Ancestor, [string]$Descendant) {
    return (Invoke-Git $Repository @('merge-base', '--is-ancestor', $Ancestor, $Descendant) -Allowed 0, 1).Code -eq 0
}

# The commit $Branch points at on $Remote right now, or $null when it does not exist there.
function Get-RemoteBranch([string]$Repository, [string]$Remote, [string]$Branch) {
    $line = (Invoke-Git $Repository @('ls-remote', '--heads', $Remote, "refs/heads/$Branch")).Lines |
        Where-Object { $_ -match "\srefs/heads/$([regex]::Escape($Branch))$" } | Select-Object -First 1
    if (-not $line) { return $null }
    return ($line -split '\s+')[0]
}

# True when the worktree has no staged or unstaged changes to tracked files and no merge
# in progress; untracked and ignored files do not count.
function Test-CleanWorktree([string]$Repository) {
    $changes = (Invoke-Git $Repository @('status', '--porcelain', '--untracked-files=no')).Lines | Where-Object { $_ }
    $merging = (Invoke-Git $Repository @('rev-parse', '--quiet', '--verify', 'MERGE_HEAD') -Allowed 0, 1).Code -eq 0
    return -not $changes -and -not $merging
}

# The GitHub CLI executable. On Windows an extensionless shell shim named `gh` can shadow
# gh.exe on PATH, and PowerShell cannot run it, so take the real executable.
function Get-GitHubCli {
    $gh = @(Get-Command gh -CommandType Application -All -ErrorAction SilentlyContinue |
        Where-Object { -not $IsWindows -or $_.Extension -eq '.exe' } | Select-Object -First 1).Source
    if (-not $gh) { throw 'The GitHub CLI (gh) is not installed or not on PATH.' }
    return $gh
}

Export-ModuleMember -Function Invoke-Git, Resolve-Commit, Test-CommitExists, Test-Ancestor, Get-RemoteBranch, Test-CleanWorktree, Get-GitHubCli

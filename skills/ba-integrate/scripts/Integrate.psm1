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

# Runs the GitHub CLI $Gh with $Arguments in $Directory and returns its exit code, its
# standard output, and its error output kept apart. A warning gh prints, such as an update
# notice, goes to its error output and so never corrupts the JSON on its standard output.
function Invoke-GitHubCli([string]$Gh, [string[]]$Arguments, [string]$Directory) {
    Push-Location -LiteralPath $Directory
    try { $output = & $Gh @Arguments 2>&1; $code = $LASTEXITCODE }
    finally { Pop-Location }
    $out = @($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n"
    $err = @($output | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join ' '
    return [pscustomobject]@{ Code = $code; Out = $out; Err = $err }
}

# The GitHub repository, as owner/name, that $Remote of $Repository pushes to. It comes
# from the remote's configured push URL, or its URL, as written, so every gh call can name
# the repository the scripts push to instead of leaving gh to choose one from GH_REPO or
# its own default. A remote that is not on github.com is refused.
function Get-GitHubRepository([string]$Repository, [string]$Remote = 'origin') {
    $url = (Invoke-Git $Repository @('config', '--get', "remote.$Remote.pushurl") -Allowed 0, 1).Lines | Select-Object -First 1
    if (-not $url) { $url = (Invoke-Git $Repository @('config', '--get', "remote.$Remote.url") -Allowed 0, 1).Lines | Select-Object -First 1 }
    if (-not $url) { throw "$Remote has no URL, so its GitHub repository is unknown. Nothing was changed." }
    $match = [regex]::Match($url, '^(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)(?<owner>[\w.-]+)/(?<name>[\w.-]+?)(?:\.git)?/?$')
    if (-not $match.Success) { throw "$Remote ($url) is not a github.com repository, so the scripts cannot tell GitHub which repository they act on. Nothing was changed." }
    return "$($match.Groups['owner'].Value)/$($match.Groups['name'].Value)"
}

# Every open pull request in GitHub repository $GitHubRepository targeting $Branch, read
# page by page so none is left out, as number, url, title and isDraft.
function Get-PullRequestsTargeting([string]$Gh, [string]$GitHubRepository, [string]$Branch, [string]$Directory) {
    $owner, $name = $GitHubRepository -split '/', 2
    $query = @'
query($owner: String!, $name: String!, $branch: String!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, baseRefName: $branch, first: 100, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes { number url title isDraft }
    }
  }
}
'@
    $found = [Collections.Generic.List[object]]::new()
    $after = $null
    do {
        $arguments = @('api', 'graphql', '-f', "query=$query", '-f', "owner=$owner", '-f', "name=$name", '-f', "branch=$Branch")
        if ($after) { $arguments += @('-f', "after=$after") }
        $call = Invoke-GitHubCli $Gh $arguments $Directory
        if ($call.Code -ne 0) { throw "Could not list the pull requests targeting $Branch in $GitHubRepository. gh said: $($call.Out) $($call.Err)" }
        $page = ($call.Out | ConvertFrom-Json).data.repository.pullRequests
        foreach ($node in @($page.nodes)) { $found.Add([ordered]@{ number = [int]$node.number; url = $node.url; title = $node.title; isDraft = [bool]$node.isDraft }) }
        $after = if ($page.pageInfo.hasNextPage) { $page.pageInfo.endCursor } else { $null }
        if ($page.pageInfo.hasNextPage -and -not $after) { throw "GitHub reported more pull requests targeting $Branch without a cursor to read them." }
    } while ($after)
    return $found.ToArray()
}

# The GitHub CLI executable. On Windows an extensionless shell shim named `gh` can shadow
# gh.exe on PATH, and PowerShell cannot run it, so take the real executable.
function Get-GitHubCli {
    $gh = @(Get-Command gh -CommandType Application -All -ErrorAction SilentlyContinue |
        Where-Object { -not $IsWindows -or $_.Extension -eq '.exe' } | Select-Object -First 1).Source
    if (-not $gh) { throw 'The GitHub CLI (gh) is not installed or not on PATH.' }
    return $gh
}

Export-ModuleMember -Function Invoke-Git, Resolve-Commit, Test-CommitExists, Test-Ancestor, Get-RemoteBranch, Test-CleanWorktree, Invoke-GitHubCli, Get-GitHubRepository, Get-PullRequestsTargeting, Get-GitHubCli

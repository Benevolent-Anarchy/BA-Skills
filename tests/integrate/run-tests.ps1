# Runs the ba-integrate survey against disposable local repositories whose branches
# stand in for pull requests, so no test touches GitHub.
#requires -Version 7.2
[CmdletBinding()]
param([string]$Filter = '*')
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$script:Passed = 0; $script:Failed = 0
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$survey = Join-Path $root 'skills/ba-integrate/scripts/survey.ps1'
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('ba-integrate-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null

## Fails the current test with $Message unless $Condition holds.
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

## Runs one named test, counting it as passed or failed; -Filter selects tests by name.
function Test([string]$Name, [scriptblock]$Body) {
    if ($Name -notlike $Filter) { return }
    try { & $Body; $script:Passed++; Write-Output "PASS $Name" }
    catch { $script:Failed++; Write-Output "FAIL $Name : $($_.Exception.Message)" }
}

## Runs git in a fixture repository and returns its output, failing the test on an error.
function Invoke-FixtureGit([string]$Repository, [string[]]$Arguments) {
    $output = & git -C $Repository @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Fixture git $($Arguments -join ' ') failed: $output" }
    return ($output -join "`n")
}

## Writes UTF-8 text without a byte-order mark, creating parent folders.
function Write-FixtureText([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

## A new repository on branch main whose first commit holds $Files (path to text).
function New-FixtureRepository([hashtable]$Files) {
    $path = Join-Path $sandbox ('repo-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path | Out-Null
    Invoke-FixtureGit $path @('init', '--quiet', '--initial-branch=main') | Out-Null
    Invoke-FixtureGit $path @('config', 'user.name', 'Fixture') | Out-Null
    Invoke-FixtureGit $path @('config', 'user.email', 'fixture@example.invalid') | Out-Null
    Invoke-FixtureGit $path @('config', 'core.autocrlf', 'false') | Out-Null
    foreach ($file in $Files.Keys) { Write-FixtureText (Join-Path $path $file) $Files[$file] }
    Invoke-FixtureGit $path @('add', '-A') | Out-Null
    Invoke-FixtureGit $path @('commit', '--quiet', '-m', 'Initial') | Out-Null
    return $path
}

## Commits $Files onto branch $Name, created from $From if it does not exist yet, deleting
## the paths in $Remove, and returns the new commit; the checkout is left on main.
function Add-FixtureCommit([string]$Repository, [string]$Name, [string]$From, [hashtable]$Files, [string[]]$Remove = @()) {
    $exists = (& git -C $Repository rev-parse --verify --quiet "refs/heads/$Name"); $null = $LASTEXITCODE
    if ($exists) { Invoke-FixtureGit $Repository @('checkout', '--quiet', $Name) | Out-Null }
    else { Invoke-FixtureGit $Repository @('checkout', '--quiet', '-b', $Name, $From) | Out-Null }
    foreach ($file in $Files.Keys) { Write-FixtureText (Join-Path $Repository $file) $Files[$file] }
    foreach ($file in $Remove) { Invoke-FixtureGit $Repository @('rm', '--quiet', '--', $file) | Out-Null }
    Invoke-FixtureGit $Repository @('add', '-A') | Out-Null
    Invoke-FixtureGit $Repository @('commit', '--quiet', '-m', "Change $Name") | Out-Null
    $sha = Invoke-FixtureGit $Repository @('rev-parse', 'HEAD')
    Invoke-FixtureGit $Repository @('checkout', '--quiet', 'main') | Out-Null
    return $sha.Trim()
}

## A pull-request record as the survey reads it from GitHub.
function New-PullRequest([int]$Number, [string]$Head, [string]$Sha, [string]$BaseRef = 'main', [switch]$Draft, [switch]$Fork) {
    return [ordered]@{
        number = $Number; title = "PR $Number"; url = "https://example.invalid/pull/$Number"
        isDraft = [bool]$Draft; isCrossRepository = [bool]$Fork
        headRefName = $Head; headRefOid = $Sha; baseRefName = $BaseRef
    }
}

## Runs one of the skill's scripts with $Parameters; returns its exit code and parsed JSON.
function Invoke-IntegrateScript([string]$Name, [hashtable]$Parameters) {
    $scriptPath = Join-Path $root "skills/ba-integrate/scripts/$Name.ps1"
    $output = & (Join-Path $PSHOME 'pwsh') -NoProfile -File $scriptPath @Parameters 2>&1
    $code = $LASTEXITCODE
    try { $result = ($output -join "`n") | ConvertFrom-Json }
    catch { throw "$Name output was not JSON (exit $code): $output" }
    return [pscustomobject]@{ Code = $code; Result = $result }
}

## Runs the survey on $Repository with $PullRequests against base main; returns the exit
## code and the parsed JSON.
function Invoke-Survey([string]$Repository, [object[]]$PullRequests) {
    $records = Join-Path $sandbox ('prs-' + [guid]::NewGuid().ToString('N') + '.json')
    Write-FixtureText $records (ConvertTo-Json -InputObject @($PullRequests) -Depth 5)
    return Invoke-IntegrateScript 'survey' @{ Repository = $Repository; Base = 'main'; PullRequestsJson = $records }
}

## A fixture repository with a bare repository as its origin, standing in for GitHub;
## main is pushed.
function New-RemoteFixture([hashtable]$Files) {
    $remote = Join-Path $sandbox ('remote-' + [guid]::NewGuid().ToString('N') + '.git')
    Invoke-FixtureGit $sandbox @('init', '--quiet', '--bare', '--initial-branch=main', $remote) | Out-Null
    $repo = New-FixtureRepository $Files
    Invoke-FixtureGit $repo @('remote', 'add', 'origin', $remote) | Out-Null
    Invoke-FixtureGit $repo @('push', '--quiet', 'origin', 'main') | Out-Null
    return $repo
}

## A rehearsal worktree of $Repository, detached at $Base.
function New-Rehearsal([string]$Repository, [string]$Base) {
    $path = Join-Path $sandbox ('rehearsal-' + [guid]::NewGuid().ToString('N'))
    Invoke-FixtureGit $Repository @('worktree', 'add', '--quiet', '--detach', $path, $Base) | Out-Null
    return $path
}

## Merges $Head into the rehearsal as one step, resolving each path in $Resolutions to the
## given text, or deleting it when the text is $null, and returns the step's commit.
function Add-RehearsalStep([string]$Rehearsal, [string]$Head, [hashtable]$Resolutions = @{}) {
    & git -C $Rehearsal merge --no-ff --no-commit $Head 2>&1 | Out-Null
    foreach ($path in $Resolutions.Keys) {
        if ($null -eq $Resolutions[$path]) { Invoke-FixtureGit $Rehearsal @('rm', '--quiet', '--force', '--', $path) | Out-Null }
        else { Write-FixtureText (Join-Path $Rehearsal $path) $Resolutions[$path]; Invoke-FixtureGit $Rehearsal @('add', '--', $path) | Out-Null }
    }
    Invoke-FixtureGit $Rehearsal @('commit', '--quiet', '--no-edit') | Out-Null
    return (Invoke-FixtureGit $Rehearsal @('rev-parse', 'HEAD')).Trim()
}

## The commit a ref names in $Repository, or '' when it does not exist.
function Get-FixtureRef([string]$Repository, [string]$Ref) {
    $sha = & git -C $Repository rev-parse --verify --quiet $Ref 2>$null; $null = $LASTEXITCODE
    return "$sha".Trim()
}

## The commit a branch points at in the bare origin of $Repository, or '' when absent.
function Get-OriginBranch([string]$Repository, [string]$Branch) {
    $line = Invoke-FixtureGit $Repository @('ls-remote', '--heads', 'origin', "refs/heads/$Branch")
    if (-not $line) { return '' }
    return ($line -split '\s+')[0]
}

## Pushes a new commit onto $Branch in the origin of $Repository from a separate clone,
## as another session would, and returns it.
function Push-ElsewhereCommit([string]$Repository, [string]$Branch) {
    $remote = (Invoke-FixtureGit $Repository @('remote', 'get-url', 'origin')).Trim()
    $other = Join-Path $sandbox ('other-' + [guid]::NewGuid().ToString('N'))
    Invoke-FixtureGit $sandbox @('clone', '--quiet', '--branch', $Branch, $remote, $other) | Out-Null
    Invoke-FixtureGit $other @('config', 'user.name', 'Other') | Out-Null
    Invoke-FixtureGit $other @('config', 'user.email', 'other@example.invalid') | Out-Null
    Write-FixtureText (Join-Path $other "elsewhere-$([guid]::NewGuid().ToString('N')).txt") "elsewhere`n"
    Invoke-FixtureGit $other @('add', '-A') | Out-Null
    Invoke-FixtureGit $other @('commit', '--quiet', '-m', 'Pushed elsewhere') | Out-Null
    Invoke-FixtureGit $other @('push', '--quiet', 'origin', $Branch) | Out-Null
    Invoke-FixtureGit $Repository @('fetch', '--quiet', 'origin') | Out-Null
    return (Invoke-FixtureGit $other @('rev-parse', 'HEAD')).Trim()
}

## Lands $Head as step $Rehearsed in $Rehearsal: updates it against $Base, then lands it
## on origin's main; returns both scripts' results.
function Invoke-Step([string]$Rehearsal, [string]$Branch, [string]$Head, [string]$Base, [string]$Rehearsed) {
    $update = Invoke-IntegrateScript 'update' @{ Worktree = $Rehearsal; Head = $Head; Base = $Base; Rehearsed = $Rehearsed }
    if ($update.Code -ne 0) { return [pscustomobject]@{ Update = $update; Land = $null } }
    $land = Invoke-IntegrateScript 'land' @{
        Worktree = $Rehearsal; Branch = $Branch; ApprovedHead = $Head; Updated = $update.Result.commit
        BaseBranch = 'main'; ExpectedBase = $Base; Rehearsed = $Rehearsed; Message = "Merge pull request from $Branch`n`n$Branch"
    }
    return [pscustomobject]@{ Update = $update; Land = $land }
}

## The survey's record for PR $Number.
function Get-SurveyPullRequest($Result, [int]$Number) {
    return @($Result.pullRequests | Where-Object number -EQ $Number)[0]
}

Test 'independent pull requests keep number order and report their files' {
    $repo = New-FixtureRepository @{ 'a.txt' = "a`n"; 'b.txt' = "b`n" }
    $one = Add-FixtureCommit $repo 'one' 'main' @{ 'a.txt' = "a changed`n" }
    $two = Add-FixtureCommit $repo 'two' 'main' @{ 'b.txt' = "b changed`n" }
    $run = Invoke-Survey $repo @((New-PullRequest 2 'two' $two), (New-PullRequest 1 'one' $one))
    Assert ($run.Code -eq 0) "Survey failed: $($run.Result.error)"
    Assert ((@($run.Result.order) -join ',') -eq '1,2') "Order was $(@($run.Result.order) -join ',')."
    Assert (@($run.Result.conflicts).Count -eq 0) 'Independent PRs were reported as conflicting.'
    $first = Get-SurveyPullRequest $run.Result 1
    Assert ((@($first.files) -join ',') -eq 'a.txt' -and $first.commits -eq 1 -and $first.behindBase -eq 0) "Wrong facts for #1: $($first | ConvertTo-Json -Compress)"
    Assert ($first.reason -match 'conflicts with no other') "Wrong reason: $($first.reason)"
}

Test 'two appends to one log conflict, and the conflict-free PR goes first' {
    $repo = New-FixtureRepository @{ 'log.md' = "entry 0`n"; 'other.txt' = "x`n" }
    $one = Add-FixtureCommit $repo 'one' 'main' @{ 'log.md' = "entry 0`nentry 1`n" }
    $two = Add-FixtureCommit $repo 'two' 'main' @{ 'log.md' = "entry 0`nentry 2`n" }
    $three = Add-FixtureCommit $repo 'three' 'main' @{ 'other.txt' = "y`n" }
    $run = Invoke-Survey $repo @((New-PullRequest 1 'one' $one), (New-PullRequest 2 'two' $two), (New-PullRequest 3 'three' $three))
    Assert ($run.Code -eq 0) "Survey failed: $($run.Result.error)"
    Assert ((@($run.Result.order) -join ',') -eq '3,1,2') "Order was $(@($run.Result.order) -join ',')."
    $conflict = @($run.Result.conflicts)
    Assert ($conflict.Count -eq 1 -and (@($conflict[0].between) -join ',') -eq '1,2' -and (@($conflict[0].files) -join ',') -eq 'log.md') "Wrong conflicts: $($run.Result.conflicts | ConvertTo-Json -Compress)"
    Assert ((Get-SurveyPullRequest $run.Result 2).reason -match 'conflicts with #1') 'Reason does not name the conflicting PR.'
}

Test 'a stacked pull request follows the one it builds on, whatever their numbers' {
    $repo = New-FixtureRepository @{ 'a.txt' = "a`n" }
    $lower = Add-FixtureCommit $repo 'feature-a' 'main' @{ 'a.txt' = "a1`n" }
    $upper = Add-FixtureCommit $repo 'feature-b' 'feature-a' @{ 'b.txt' = "b`n" }
    $run = Invoke-Survey $repo @((New-PullRequest 4 'feature-b' $upper 'feature-a'), (New-PullRequest 5 'feature-a' $lower))
    Assert ($run.Code -eq 0) "Survey failed: $($run.Result.error)"
    Assert ((@($run.Result.order) -join ',') -eq '5,4') "Order was $(@($run.Result.order) -join ',')."
    $stacked = Get-SurveyPullRequest $run.Result 4
    Assert ((@($stacked.dependsOn) -join ',') -eq '5' -and $stacked.reason -match 'after #5') "Wrong dependency: $($stacked | ConvertTo-Json -Compress)"
    Assert (@($run.Result.conflicts).Count -eq 0) 'A stacked pair was checked for conflicts with itself.'
}

Test 'a pull request that only contains another one still waits for it' {
    $repo = New-FixtureRepository @{ 'a.txt' = "a`n" }
    $lower = Add-FixtureCommit $repo 'base-work' 'main' @{ 'a.txt' = "a1`n" }
    $upper = Add-FixtureCommit $repo 'more-work' 'base-work' @{ 'b.txt' = "b`n" }
    $run = Invoke-Survey $repo @((New-PullRequest 1 'more-work' $upper), (New-PullRequest 2 'base-work' $lower))
    Assert ($run.Code -eq 0) "Survey failed: $($run.Result.error)"
    Assert ((@($run.Result.order) -join ',') -eq '2,1') "Order was $(@($run.Result.order) -join ',')."
}

Test 'drafts, forks and pull requests stacked on a skipped one are skipped with reasons' {
    $repo = New-FixtureRepository @{ 'a.txt' = "a`n" }
    $draft = Add-FixtureCommit $repo 'draft-work' 'main' @{ 'a.txt' = "draft`n" }
    $fork = Add-FixtureCommit $repo 'fork-work' 'main' @{ 'f.txt' = "fork`n" }
    $onDraft = Add-FixtureCommit $repo 'on-draft' 'draft-work' @{ 'c.txt' = "c`n" }
    $ready = Add-FixtureCommit $repo 'ready-work' 'main' @{ 'r.txt' = "r`n" }
    $run = Invoke-Survey $repo @(
        (New-PullRequest 1 'draft-work' $draft -Draft), (New-PullRequest 2 'fork-work' $fork -Fork),
        (New-PullRequest 3 'on-draft' $onDraft 'draft-work'), (New-PullRequest 4 'ready-work' $ready))
    Assert ($run.Code -eq 0) "Survey failed: $($run.Result.error)"
    Assert ((@($run.Result.order) -join ',') -eq '4') "Order was $(@($run.Result.order) -join ',')."
    $reasons = @{}; foreach ($s in @($run.Result.skipped)) { $reasons[[int]$s.number] = $s.reason }
    Assert ($reasons[1] -eq 'draft' -and $reasons[2] -eq 'from a fork' -and $reasons[3] -match '^targets draft-work') "Wrong skip reasons: $($run.Result.skipped | ConvertTo-Json -Compress)"
}

Test 'a conflict with the base branch and an empty pull request are reported' {
    $repo = New-FixtureRepository @{ 'a.txt' = "a`n" }
    $stale = Add-FixtureCommit $repo 'stale' 'main' @{ 'a.txt' = "from the PR`n" }
    Add-FixtureCommit $repo 'main' 'main' @{ 'a.txt' = "from main`n" } | Out-Null
    $empty = (Invoke-FixtureGit $repo @('rev-parse', 'main~1')).Trim()
    Invoke-FixtureGit $repo @('branch', 'empty', $empty) | Out-Null
    $run = Invoke-Survey $repo @((New-PullRequest 1 'stale' $stale), (New-PullRequest 2 'empty' $empty))
    Assert ($run.Code -eq 0) "Survey failed: $($run.Result.error)"
    $first = Get-SurveyPullRequest $run.Result 1
    Assert ((@($first.conflictsWithBase) -join ',') -eq 'a.txt' -and $first.behindBase -eq 1 -and $first.reason -match 'conflicts with main in 1') "Base conflict not reported: $($first | ConvertTo-Json -Compress)"
    $second = Get-SurveyPullRequest $run.Result 2
    Assert ($second.commits -eq 0 -and $second.reason -match 'no commits') "Empty PR not flagged: $($second | ConvertTo-Json -Compress)"
}

Test 'paths with spaces are reported as written' {
    $repo = New-FixtureRepository @{ 'Design Notes.md' = "x`n" }
    $sha = Add-FixtureCommit $repo 'notes' 'main' @{ 'Design Notes.md' = "y`n" }
    $run = Invoke-Survey $repo @((New-PullRequest 1 'notes' $sha))
    Assert ($run.Code -eq 0) "Survey failed: $($run.Result.error)"
    Assert ((@((Get-SurveyPullRequest $run.Result 1).files) -join ',') -eq 'Design Notes.md') 'Path was quoted or mangled.'
}

Test 'an unknown head commit fails with JSON naming the pull request' {
    $repo = New-FixtureRepository @{ 'a.txt' = "a`n" }
    $run = Invoke-Survey $repo @((New-PullRequest 7 'gone' '0123456789abcdef0123456789abcdef01234567'))
    Assert ($run.Code -eq 1 -and $run.Result.error -match 'PR #7') "Expected a failure naming #7, got exit $($run.Code): $($run.Result | ConvertTo-Json -Compress)"
}

Test 'a ready pull request built on a draft names the draft work it contains' {
    # The reviewer's case for #16: the draft is skipped, but its commit would land inside
    # the ready pull request built on it.
    $repo = New-FixtureRepository @{ 'a.txt' = "a`n" }
    $draft = Add-FixtureCommit $repo 'draft-work' 'main' @{ 'unreviewed.txt' = "u`n" }
    $ready = Add-FixtureCommit $repo 'ready-work' 'draft-work' @{ 'ready.txt' = "r`n" }
    $run = Invoke-Survey $repo @((New-PullRequest 1 'draft-work' $draft -Draft), (New-PullRequest 2 'ready-work' $ready))
    Assert ($run.Code -eq 0) "Survey failed: $($run.Result.error)"
    $pr = Get-SurveyPullRequest $run.Result 2
    $included = @($pr.includesUnready)
    Assert ($included.Count -eq 1 -and $included[0].number -eq 1 -and $included[0].reason -eq 'draft') "Draft work not named: $($pr | ConvertTo-Json -Compress)"
    Assert ($pr.reason -match 'unmerged work of #1 \(draft\)') "Reason does not say so: $($pr.reason)"
}

Test 'unready work already in the base is not reported' {
    $repo = New-FixtureRepository @{ 'a.txt' = "a`n" }
    $draft = Add-FixtureCommit $repo 'draft-work' 'main' @{ 'early.txt' = "e`n" }
    $ready = Add-FixtureCommit $repo 'ready-work' 'draft-work' @{ 'ready.txt' = "r`n" }
    Invoke-FixtureGit $repo @('merge', '--quiet', '--no-ff', '--no-edit', $draft) | Out-Null
    $run = Invoke-Survey $repo @((New-PullRequest 1 'draft-work' $draft -Draft), (New-PullRequest 2 'ready-work' $ready))
    Assert ($run.Code -eq 0 -and @((Get-SurveyPullRequest $run.Result 2).includesUnready).Count -eq 0) "Merged draft work was reported: $($run.Result | ConvertTo-Json -Compress -Depth 6)"
}

Test 'unready work is found through a chain of drafts' {
    $repo = New-FixtureRepository @{ 'a.txt' = "a`n" }
    $first = Add-FixtureCommit $repo 'first' 'main' @{ 'one.txt' = "1`n" }
    $second = Add-FixtureCommit $repo 'second' 'first' @{ 'two.txt' = "2`n" }
    $ready = Add-FixtureCommit $repo 'ready-work' 'second' @{ 'three.txt' = "3`n" }
    $run = Invoke-Survey $repo @((New-PullRequest 1 'first' $first -Draft), (New-PullRequest 2 'second' $second 'first' -Draft), (New-PullRequest 3 'ready-work' $ready))
    Assert ($run.Code -eq 0) "Survey failed: $($run.Result.error)"
    Assert ((@((Get-SurveyPullRequest $run.Result 3).includesUnready | ForEach-Object number) -join ',') -eq '1,2') "Chain not found: $($run.Result | ConvertTo-Json -Compress -Depth 6)"
}

## A stand-in for the GitHub CLI that serves $PullRequests (number, isDraft, head, sha and
## a threads list of isResolved values) the way GitHub's GraphQL API pages them, $PageSize
## at a time, with cursors.
function New-FakeGitHub([object[]]$PullRequests, [int]$PageSize = 2) {
    $data = Join-Path $sandbox ('github-' + [guid]::NewGuid().ToString('N') + '.json')
    Write-FixtureText $data (ConvertTo-Json -InputObject @($PullRequests) -Depth 5)
    $fake = Join-Path $sandbox ('gh-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $text = @'
$data = @(Get-Content -LiteralPath '__DATA__' -Raw | ConvertFrom-Json)
$size = __SIZE__
if ($args[0] -eq 'repo') { '{"owner":{"login":"fixture"},"name":"repo"}'; exit 0 }
$fields = @{}
for ($i = 2; $i + 1 -lt $args.Count; $i += 2) { $pair = "$($args[$i + 1])" -split '=', 2; $fields[$pair[0]] = $pair[1] }
$start = if ($fields.after) { [int]$fields.after } else { 0 }
function Get-Page($Items, [int]$From) {
    $all = @($Items)
    return @{ pageInfo = @{ hasNextPage = ($From + $size -lt $all.Count); endCursor = "$($From + $size)" }; slice = @($all | Select-Object -Skip $From -First $size) }
}
function Get-Threads($Items, [int]$From) {
    $page = Get-Page $Items $From
    return @{ pageInfo = $page.pageInfo; nodes = @($page.slice | ForEach-Object { @{ isResolved = $_ } }) }
}
if ($fields.number) {
    $pr = $data | Where-Object { $_.number -eq [int]$fields.number }
    @{ data = @{ repository = @{ pullRequest = @{ reviewThreads = (Get-Threads $pr.threads $start) } } } } | ConvertTo-Json -Depth 10
} else {
    $page = Get-Page $data $start
    $nodes = @($page.slice | ForEach-Object {
        @{ number = $_.number; title = "PR $($_.number)"; url = "https://example.invalid/pull/$($_.number)"
           isDraft = $_.isDraft; isCrossRepository = $false; createdAt = '2026-10-14T00:00:00Z'
           headRefName = $_.head; headRefOid = $_.sha; baseRefName = 'main'; mergeable = 'MERGEABLE'; reviewDecision = $null
           reviewThreads = (Get-Threads $_.threads 0) }
    })
    @{ data = @{ repository = @{ pullRequests = @{ pageInfo = $page.pageInfo; nodes = $nodes } } } } | ConvertTo-Json -Depth 10
}
exit 0
'@
    Write-FixtureText $fake ($text.Replace('__DATA__', $data.Replace("'", "''")).Replace('__SIZE__', "$PageSize"))
    return $fake
}

## Commits a new file onto a new branch of $Repository and publishes it on the bare
## origin as pull request $Number's head, the way GitHub keeps refs/pull/<n>/head.
function Publish-PullRequest([string]$Repository, [int]$Number, [string]$From = 'main') {
    $sha = Add-FixtureCommit $Repository "work-$Number" $From @{ "file-$Number.txt" = "$Number`n" }
    Invoke-FixtureGit $Repository @('push', '--quiet', 'origin', "${sha}:refs/pull/$Number/head") | Out-Null
    return $sha
}

Test 'every page of pull requests is read, so a ready one after many drafts is found' {
    # #15: with pages of two, the only ready pull request is on the third page.
    $repo = New-RemoteFixture @{ 'a.txt' = "a`n" }
    $records = foreach ($n in 1..5) { [ordered]@{ number = $n; isDraft = ($n -lt 5); head = "work-$n"; sha = (Publish-PullRequest $repo $n); threads = @() } }
    $run = Invoke-IntegrateScript 'survey' @{ Repository = $repo; GitHubCli = (New-FakeGitHub @($records)) }
    Assert ($run.Code -eq 0) "Survey failed: $($run.Result.error)"
    Assert ((@($run.Result.order) -join ',') -eq '5' -and @($run.Result.skipped).Count -eq 4) "Pages were missed: $($run.Result | ConvertTo-Json -Compress -Depth 6)"
}

Test 'unresolved review threads are counted across every page' {
    $repo = New-RemoteFixture @{ 'a.txt' = "a`n" }
    $sha = Publish-PullRequest $repo 1
    $records = @([ordered]@{ number = 1; isDraft = $false; head = 'work-1'; sha = $sha; threads = @($true, $true, $false, $true, $false) })
    $run = Invoke-IntegrateScript 'survey' @{ Repository = $repo; GitHubCli = (New-FakeGitHub $records) }
    Assert ($run.Code -eq 0) "Survey failed: $($run.Result.error)"
    $count = (Get-SurveyPullRequest $run.Result 1).unresolvedReviewThreads
    Assert ($count -eq 2) "Counted $count unresolved threads, not 2."
}

## Rehearses two pull requests on main in $Repository, lands the first on main locally as
## a merge commit, and returns the heads, both steps and main's new commit.
function New-TwoStepFixture([string]$Repository, [string]$One, [string]$Two, [hashtable]$Resolutions = @{}) {
    $base = Get-FixtureRef $Repository 'main'
    $rehearsal = New-Rehearsal $Repository $base
    $stepOne = Add-RehearsalStep $rehearsal $One
    $stepTwo = Add-RehearsalStep $rehearsal $Two $Resolutions
    Invoke-FixtureGit $Repository @('merge', '--quiet', '--no-ff', '--no-edit', $One) | Out-Null
    return [pscustomobject]@{ Rehearsal = $rehearsal; Base = $base; StepOne = $stepOne; StepTwo = $stepTwo; Main = (Get-FixtureRef $Repository 'main') }
}

Test 'a clean update commits the pending merge once and matches the rehearsal' {
    $repo = New-FixtureRepository @{ 'a.txt' = "a`n"; 'b.txt' = "b`n" }
    $one = Add-FixtureCommit $repo 'one' 'main' @{ 'a.txt' = "a1`n" }
    $two = Add-FixtureCommit $repo 'two' 'main' @{ 'b.txt' = "b1`n" }
    $f = New-TwoStepFixture $repo $one $two
    $run = Invoke-IntegrateScript 'update' @{ Worktree = $f.Rehearsal; Head = $two; Base = $f.Main; Rehearsed = $f.StepTwo }
    Assert ($run.Code -eq 0) "Update failed: $($run.Result.error)"
    Assert ($run.Result.matches -and -not $run.Result.upToDate -and @($run.Result.replayed).Count -eq 0) "Wrong result: $($run.Result | ConvertTo-Json -Compress)"
    $parents = (Invoke-FixtureGit $f.Rehearsal @('rev-list', '--parents', '-n', '1', $run.Result.commit)).Trim() -split ' '
    Assert ($parents.Count -eq 3 -and $parents[1] -eq $two -and $parents[2] -eq $f.Main) "Not one merge of main into the head: $($parents -join ' ')"
}

Test 'an up-to-date head needs no merge' {
    $repo = New-FixtureRepository @{ 'a.txt' = "a`n" }
    $one = Add-FixtureCommit $repo 'one' 'main' @{ 'a.txt' = "a1`n" }
    $rehearsal = New-Rehearsal $repo (Get-FixtureRef $repo 'main')
    $step = Add-RehearsalStep $rehearsal $one
    $run = Invoke-IntegrateScript 'update' @{ Worktree = $rehearsal; Head = $one; Base = (Get-FixtureRef $repo 'main'); Rehearsed = $step }
    Assert ($run.Code -eq 0 -and $run.Result.upToDate -and $run.Result.commit -eq $one -and $run.Result.matches) "Wrong result: $($run.Result | ConvertTo-Json -Compress)"
}

Test 'a textual conflict replays from the rehearsed step, whatever its path' {
    $path = 'Pack [Patreon]/log.md'
    $repo = New-FixtureRepository @{ $path = "entry 0`n" }
    $one = Add-FixtureCommit $repo 'one' 'main' @{ $path = "entry 0`nentry 1`n" }
    $two = Add-FixtureCommit $repo 'two' 'main' @{ $path = "entry 0`nentry 2`n" }
    $f = New-TwoStepFixture $repo $one $two @{ $path = "entry 0`nentry 1`nentry 2`n" }
    $run = Invoke-IntegrateScript 'update' @{ Worktree = $f.Rehearsal; Head = $two; Base = $f.Main; Rehearsed = $f.StepTwo }
    Assert ($run.Code -eq 0 -and $run.Result.matches) "Update failed: $($run.Result | ConvertTo-Json -Compress)"
    Assert ((@($run.Result.replayed) -join ',') -eq $path) "Wrong replayed paths: $(@($run.Result.replayed) -join ',')"
}

Test 'a kept file the other side deleted replays from the rehearsed step' {
    # The reviewer's case for rerere: #1 deletes a file that #2 modifies, and the
    # rehearsal keeps #2's version. rerere leaves that conflict unmerged.
    $repo = New-FixtureRepository @{ 'f.txt' = "original`n"; 'a.txt' = "a`n" }
    $one = Add-FixtureCommit $repo 'one' 'main' @{ 'a.txt' = "a1`n" } -Remove @('f.txt')
    $two = Add-FixtureCommit $repo 'two' 'main' @{ 'f.txt' = "modified`n" }
    $f = New-TwoStepFixture $repo $one $two @{ 'f.txt' = "modified`n" }
    $run = Invoke-IntegrateScript 'update' @{ Worktree = $f.Rehearsal; Head = $two; Base = $f.Main; Rehearsed = $f.StepTwo }
    Assert ($run.Code -eq 0 -and $run.Result.matches -and (@($run.Result.replayed) -join ',') -eq 'f.txt') "Update failed: $($run.Result | ConvertTo-Json -Compress)"
    Assert ((Get-Content -LiteralPath (Join-Path $f.Rehearsal 'f.txt') -Raw) -eq "modified`n") 'The kept file is not the rehearsed version.'
}

Test 'a deletion the rehearsal chose replays too' {
    $repo = New-FixtureRepository @{ 'f.txt' = "original`n"; 'a.txt' = "a`n" }
    $one = Add-FixtureCommit $repo 'one' 'main' @{ 'a.txt' = "a1`n" } -Remove @('f.txt')
    $two = Add-FixtureCommit $repo 'two' 'main' @{ 'f.txt' = "modified`n" }
    $f = New-TwoStepFixture $repo $one $two @{ 'f.txt' = $null }
    $run = Invoke-IntegrateScript 'update' @{ Worktree = $f.Rehearsal; Head = $two; Base = $f.Main; Rehearsed = $f.StepTwo }
    Assert ($run.Code -eq 0 -and $run.Result.matches) "Update failed: $($run.Result | ConvertTo-Json -Compress)"
    Assert (-not (Test-Path -LiteralPath (Join-Path $f.Rehearsal 'f.txt'))) 'The deleted file came back.'
}

Test 'an update that differs from the rehearsal fails, names the paths and leaves no merge behind' {
    $repo = New-FixtureRepository @{ 'a.txt' = "a`n"; 'b.txt' = "b`n"; 'c.txt' = "c`n" }
    $one = Add-FixtureCommit $repo 'one' 'main' @{ 'a.txt' = "a1`n" }
    $two = Add-FixtureCommit $repo 'two' 'main' @{ 'b.txt' = "b1`n" }
    # The rehearsed step also edits a file no conflict touched, which the update cannot
    # reproduce.
    $f = New-TwoStepFixture $repo $one $two @{ 'c.txt' = "corrected`n" }
    $run = Invoke-IntegrateScript 'update' @{ Worktree = $f.Rehearsal; Head = $two; Base = $f.Main; Rehearsed = $f.StepTwo }
    Assert ($run.Code -eq 1 -and -not $run.Result.matches -and (@($run.Result.differences) -join ',') -eq 'c.txt') "Expected a mismatch on c.txt: $($run.Result | ConvertTo-Json -Compress)"
    Assert (-not (Get-FixtureRef $f.Rehearsal 'MERGE_HEAD')) 'A merge was left in progress.'
}

Test 'an update refuses a worktree with uncommitted changes' {
    $repo = New-FixtureRepository @{ 'a.txt' = "a`n" }
    $one = Add-FixtureCommit $repo 'one' 'main' @{ 'a.txt' = "a1`n" }
    $rehearsal = New-Rehearsal $repo (Get-FixtureRef $repo 'main')
    $step = Add-RehearsalStep $rehearsal $one
    Write-FixtureText (Join-Path $rehearsal 'a.txt') "dirty`n"
    $run = Invoke-IntegrateScript 'update' @{ Worktree = $rehearsal; Head = $one; Base = (Get-FixtureRef $repo 'main~0'); Rehearsed = $step }
    Assert ($run.Code -eq 1 -and $run.Result.error -match 'uncommitted') "Expected a refusal: $($run.Result | ConvertTo-Json -Compress)"
}

Test 'two pull requests land in order, each as a merge commit holding the rehearsed tree' {
    $repo = New-RemoteFixture @{ 'a.txt' = "a`n"; 'b.txt' = "b`n" }
    $one = Add-FixtureCommit $repo 'one' 'main' @{ 'a.txt' = "a1`n" }
    $two = Add-FixtureCommit $repo 'two' 'main' @{ 'b.txt' = "b1`n" }
    Invoke-FixtureGit $repo @('push', '--quiet', 'origin', 'one', 'two') | Out-Null
    $base = Get-FixtureRef $repo 'main'
    $rehearsal = New-Rehearsal $repo $base
    $stepOne = Add-RehearsalStep $rehearsal $one
    $stepTwo = Add-RehearsalStep $rehearsal $two

    $first = Invoke-Step $rehearsal 'one' $one $base $stepOne
    Assert ($first.Land.Code -eq 0 -and $first.Land.Result.landed -and -not $first.Land.Result.branchPushed) "First landing failed: $($first.Update.Result.error) $($first.Land.Result.error)"
    $mergeOne = $first.Land.Result.mergeCommit
    Assert ((Get-OriginBranch $repo 'main') -eq $mergeOne) 'Origin main is not the first merge commit.'
    $parents = (Invoke-FixtureGit $repo @('rev-list', '--parents', '-n', '1', $mergeOne)).Trim() -split ' '
    Assert ($parents[1] -eq $base -and $parents[2] -eq $one) "Wrong parents: $($parents -join ' ')"
    Assert ((Invoke-FixtureGit $repo @('log', '-1', '--format=%s', $mergeOne)).Trim() -eq 'Merge pull request from one') 'Wrong merge message.'

    $second = Invoke-Step $rehearsal 'two' $two $mergeOne $stepTwo
    Assert ($second.Land.Code -eq 0 -and $second.Land.Result.branchPushed) "Second landing failed: $($second.Update.Result.error) $($second.Land.Result.error)"
    Assert ((Get-OriginBranch $repo 'two') -eq $second.Update.Result.commit) 'The update was not pushed to the branch.'
    $tree = (Invoke-FixtureGit $repo @('rev-parse', "$(Get-OriginBranch $repo 'main')^{tree}")).Trim()
    Assert ($tree -eq (Invoke-FixtureGit $repo @('rev-parse', "$stepTwo^{tree}")).Trim()) 'Origin main does not hold the rehearsed tree.'
}

Test 'landing refuses a base that moved after the rehearsal and pushes nothing' {
    # The reviewer's P1: the approved head is unchanged, but main moved while the plan
    # waited for approval.
    $repo = New-RemoteFixture @{ 'a.txt' = "a`n" }
    $one = Add-FixtureCommit $repo 'one' 'main' @{ 'a.txt' = "a1`n" }
    Invoke-FixtureGit $repo @('push', '--quiet', 'origin', 'one') | Out-Null
    $base = Get-FixtureRef $repo 'main'
    $rehearsal = New-Rehearsal $repo $base
    $step = Add-RehearsalStep $rehearsal $one
    $moved = Push-ElsewhereCommit $repo 'main'
    $run = Invoke-Step $rehearsal 'one' $one $base $step
    Assert ($run.Land.Code -eq 1 -and $run.Land.Result.error -match 'main has moved' -and -not $run.Land.Result.branchPushed) "Expected a refusal: $($run.Land.Result | ConvertTo-Json -Compress)"
    Assert ((Get-OriginBranch $repo 'main') -eq $moved -and (Get-OriginBranch $repo 'one') -eq $one) 'Something was pushed.'
}

Test 'landing refuses a branch that moved after approval and pushes nothing' {
    $repo = New-RemoteFixture @{ 'a.txt' = "a`n" }
    $one = Add-FixtureCommit $repo 'one' 'main' @{ 'a.txt' = "a1`n" }
    Invoke-FixtureGit $repo @('push', '--quiet', 'origin', 'one') | Out-Null
    $base = Get-FixtureRef $repo 'main'
    $rehearsal = New-Rehearsal $repo $base
    $step = Add-RehearsalStep $rehearsal $one
    $moved = Push-ElsewhereCommit $repo 'one'
    $run = Invoke-Step $rehearsal 'one' $one $base $step
    Assert ($run.Land.Code -eq 1 -and $run.Land.Result.error -match 'one has moved') "Expected a refusal: $($run.Land.Result | ConvertTo-Json -Compress)"
    Assert ((Get-OriginBranch $repo 'main') -eq $base -and (Get-OriginBranch $repo 'one') -eq $moved) 'Something was pushed.'
}

Test 'a base push the remote rejects lands nothing and says the branch holds the update' {
    # Stands in for a ruleset or merge-queue requirement, and for a base that moves between
    # the check and the push: the remote refuses the push to main.
    $repo = New-RemoteFixture @{ 'a.txt' = "a`n"; 'b.txt' = "b`n" }
    $one = Add-FixtureCommit $repo 'one' 'main' @{ 'a.txt' = "a1`n" }
    Add-FixtureCommit $repo 'main' 'main' @{ 'b.txt' = "b1`n" } | Out-Null
    Invoke-FixtureGit $repo @('push', '--quiet', 'origin', 'main', 'one') | Out-Null
    $remote = (Invoke-FixtureGit $repo @('remote', 'get-url', 'origin')).Trim()
    Write-FixtureText (Join-Path $remote 'hooks/pre-receive') "#!/bin/sh`nwhile read old new ref; do`n  if [ `"`$ref`" = refs/heads/main ]; then echo 'main is protected' >&2; exit 1; fi`ndone`nexit 0`n"
    $base = Get-FixtureRef $repo 'main'
    $rehearsal = New-Rehearsal $repo $base
    $step = Add-RehearsalStep $rehearsal $one
    $run = Invoke-Step $rehearsal 'one' $one $base $step
    Assert ($run.Land.Code -eq 1 -and -not $run.Land.Result.landed -and $run.Land.Result.branchPushed) "Expected a rejected landing after the branch push: $($run.Land.Result | ConvertTo-Json -Compress)"
    Assert ($run.Land.Result.error -match 'Pushing main was rejected' -and $run.Land.Result.error -match 'now holds the update') "Unclear error: $($run.Land.Result.error)"
    Assert ((Get-OriginBranch $repo 'main') -eq $base -and (Get-OriginBranch $repo 'one') -eq $run.Update.Result.commit) 'Origin is not as reported.'
}

## Lands branch 'one' of a new remote fixture and returns the repository and its head.
function New-LandedFixture {
    $repo = New-RemoteFixture @{ 'a.txt' = "a`n" }
    $one = Add-FixtureCommit $repo 'one' 'main' @{ 'a.txt' = "a1`n" }
    Invoke-FixtureGit $repo @('push', '--quiet', 'origin', 'one') | Out-Null
    $base = Get-FixtureRef $repo 'main'
    $rehearsal = New-Rehearsal $repo $base
    $run = Invoke-Step $rehearsal 'one' $one $base (Add-RehearsalStep $rehearsal $one)
    if ($run.Land.Code -ne 0) { throw "Landing the fixture failed: $($run.Land.Result.error)" }
    return [pscustomobject]@{ Repository = $repo; Head = $one }
}

Test 'deleting a merged branch at its merged tip removes it' {
    $f = New-LandedFixture
    $run = Invoke-IntegrateScript 'delete-branch' @{ Repository = $f.Repository; Branch = 'one'; MergedTip = $f.Head; BaseBranch = 'main' }
    Assert ($run.Code -eq 0 -and $run.Result.outcome -eq 'deleted' -and -not (Get-OriginBranch $f.Repository 'one')) "Not deleted: $($run.Result | ConvertTo-Json -Compress)"
}

Test 'a branch pushed to after merging is preserved and reported' {
    # The reviewer's case: a session pushes to the branch after its approved head merged.
    $f = New-LandedFixture
    $moved = Push-ElsewhereCommit $f.Repository 'one'
    $run = Invoke-IntegrateScript 'delete-branch' @{ Repository = $f.Repository; Branch = 'one'; MergedTip = $f.Head; BaseBranch = 'main' }
    Assert ($run.Code -eq 0 -and $run.Result.outcome -eq 'moved' -and $run.Result.current -eq $moved) "Expected it preserved: $($run.Result | ConvertTo-Json -Compress)"
    Assert ((Get-OriginBranch $f.Repository 'one') -eq $moved) 'The newer commit was deleted.'
}

Test 'deleting an already deleted branch is a no-op' {
    $f = New-LandedFixture
    $parameters = @{ Repository = $f.Repository; Branch = 'one'; MergedTip = $f.Head; BaseBranch = 'main' }
    Invoke-IntegrateScript 'delete-branch' $parameters | Out-Null
    $run = Invoke-IntegrateScript 'delete-branch' $parameters
    Assert ($run.Code -eq 0 -and $run.Result.outcome -eq 'absent' -and -not $run.Result.deleted) "Expected a no-op: $($run.Result | ConvertTo-Json -Compress)"
}

Test 'a branch whose tip the base does not contain is not deleted' {
    $repo = New-RemoteFixture @{ 'a.txt' = "a`n" }
    $one = Add-FixtureCommit $repo 'one' 'main' @{ 'a.txt' = "a1`n" }
    Invoke-FixtureGit $repo @('push', '--quiet', 'origin', 'one') | Out-Null
    $run = Invoke-IntegrateScript 'delete-branch' @{ Repository = $repo; Branch = 'one'; MergedTip = $one; BaseBranch = 'main' }
    Assert ($run.Code -eq 1 -and $run.Result.error -match 'has not merged' -and (Get-OriginBranch $repo 'one') -eq $one) "Expected a refusal: $($run.Result | ConvertTo-Json -Compress)"
}

Write-Output "Integrate tests: $script:Passed passed, $script:Failed failed. Fixtures: $sandbox"
if ($script:Passed + $script:Failed -eq 0) { throw 'No tests matched Filter.' }
if ($script:Failed -gt 0) { exit 1 }
exit 0

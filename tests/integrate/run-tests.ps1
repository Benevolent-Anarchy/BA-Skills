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
## main is pushed. The origin is configured as https://github.com/fixture/repo.git, which
## the scripts read as its GitHub identity, and git's insteadOf sends that URL to the bare
## repository.
function New-RemoteFixture([hashtable]$Files) {
    $remote = Join-Path $sandbox ('remote-' + [guid]::NewGuid().ToString('N') + '.git')
    Invoke-FixtureGit $sandbox @('init', '--quiet', '--bare', '--initial-branch=main', $remote) | Out-Null
    $repo = New-FixtureRepository $Files
    Invoke-FixtureGit $repo @('remote', 'add', 'origin', 'https://github.com/fixture/repo.git') | Out-Null
    Invoke-FixtureGit $repo @('config', "url.$($remote.Replace('\', '/')).insteadOf", 'https://github.com/fixture/repo.git') | Out-Null
    Invoke-FixtureGit $repo @('push', '--quiet', 'origin', 'main') | Out-Null
    return $repo
}

## The stand-in GitHub CLIs' first line: it refuses any argument holding a double quote,
## which PowerShell before 7.3 strips from native arguments, so a script that passes one
## fails here instead of only on the oldest supported runtime.
$quoteGuard = 'if (@($args | Where-Object { "$_".Contains([char]34) }).Count -gt 0) { "argument holds a double quote: $($args -join " ")"; exit 1 }'

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

## A stand-in for the GitHub CLI's `gh pr view` of one pull request. Like GitHub, it
## reads the head from the branch on the fixture's bare origin, keeping the last one seen
## once the branch is gone, and reports MERGED once origin's main contains it. $State
## overrides its fields (isDraft, headRefName, baseRefName, closing, neverMerge,
## mergeDelayCalls, fail), and $Overrides changes them from a given call on, keyed by the
## call's number. Returns the script and its state file.
function New-FakePullRequest([string]$Repository, [string]$Branch, [hashtable]$State = @{}, [hashtable]$Overrides = @{}) {
    $remote = (Invoke-FixtureGit $Repository @('remote', 'get-url', 'origin')).Trim()
    $fields = @{
        remote = $remote; branch = $Branch; base = 'main'; headRefName = $Branch; baseRefName = 'main'
        isDraft = $false; closing = @(); neverMerge = $false; mergeDelayCalls = 0; fail = $false; warn = $false
        calls = 0; lastHead = $null; overrides = $Overrides
    }
    foreach ($key in $State.Keys) { $fields[$key] = $State[$key] }
    $statePath = Join-Path $sandbox ('pr-state-' + [guid]::NewGuid().ToString('N') + '.json')
    Write-FixtureText $statePath ($fields | ConvertTo-Json -Depth 8)
    $fake = Join-Path $sandbox ('gh-pr-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $text = $quoteGuard + "`n" + @'
$at = [array]::IndexOf([string[]]@($args | ForEach-Object { "$_" }), '--repo')
if ($at -lt 0 -or "$($args[$at + 1])" -ne 'fixture/repo') { "not asked about fixture/repo: $($args -join ' ')"; exit 1 }
$statePath = '__STATE__'
$s = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
$s.calls = [int]$s.calls + 1
$key = "$($s.calls)"
if ($s.overrides -and $s.overrides.ContainsKey($key)) { foreach ($k in @($s.overrides[$key].Keys)) { $s[$k] = $s.overrides[$key][$k] } }
$tip = & git -C $s.remote rev-parse --verify --quiet "refs/heads/$($s.branch)" 2>$null
if ($tip) { $s.lastHead = "$tip".Trim() }
$merged = $false
if ($s.lastHead) { & git -C $s.remote merge-base --is-ancestor $s.lastHead "refs/heads/$($s.base)" 2>$null; $merged = $LASTEXITCODE -eq 0 }
if ($s.neverMerge) { $merged = $false }
elseif ($merged -and [int]$s.mergeDelayCalls -gt 0) { $s.mergeDelayCalls = [int]$s.mergeDelayCalls - 1; $merged = $false }
Set-Content -LiteralPath $statePath -Value ($s | ConvertTo-Json -Depth 8)
if ($s.fail) { 'HTTP 502: Bad Gateway'; exit 1 }
if ($s.warn) { Write-Error -Message 'A new release of gh is available: 9.9.9' -ErrorAction Continue }
[ordered]@{
    state = if ($merged) { 'MERGED' } else { 'OPEN' }; isDraft = [bool]$s.isDraft
    headRefOid = $s.lastHead; headRefName = $s.headRefName; baseRefName = $s.baseRefName
    closingIssuesReferences = @($s.closing)
} | ConvertTo-Json -Depth 8
exit 0
'@
    Write-FixtureText $fake $text.Replace('__STATE__', $statePath.Replace("'", "''"))
    return [pscustomobject]@{ Path = $fake; State = $statePath }
}

## Changes fields of a stand-in pull request's state from now on.
function Set-FakePullRequest($Fake, [hashtable]$Fields) {
    $state = Get-Content -LiteralPath $Fake.State -Raw | ConvertFrom-Json -AsHashtable
    foreach ($key in $Fields.Keys) { $state[$key] = $Fields[$key] }
    Write-FixtureText $Fake.State ($state | ConvertTo-Json -Depth 8)
}

## The parameters landing $Head as step $Rehearsed of pull request $Number takes.
function Get-LandParameters([string]$Rehearsal, [string]$Branch, [string]$Head, [string]$Updated, [string]$Base, [string]$Rehearsed, $Fake, [int]$Number = 1) {
    return @{
        Worktree = $Rehearsal; PullRequest = $Number; Branch = $Branch; ApprovedHead = $Head; Updated = $Updated
        BaseBranch = 'main'; ExpectedBase = $Base; Rehearsed = $Rehearsed; Message = "Merge pull request #$Number from $Branch`n`n$Branch"
        GitHubCli = $Fake.Path; PollSeconds = 1; TimeoutSeconds = 6
    }
}

## Lands $Head as step $Rehearsed in $Rehearsal: updates it against $Base, then lands it
## on origin's main with $Fake standing in for GitHub; returns both scripts' results.
function Invoke-Step([string]$Rehearsal, [string]$Branch, [string]$Head, [string]$Base, [string]$Rehearsed, $Fake, [int]$Number = 1) {
    $update = Invoke-IntegrateScript 'update' @{ Worktree = $Rehearsal; Head = $Head; Base = $Base; Rehearsed = $Rehearsed }
    if ($update.Code -ne 0) { return [pscustomobject]@{ Update = $update; Land = $null } }
    $land = Invoke-IntegrateScript 'land' (Get-LandParameters $Rehearsal $Branch $Head $update.Result.commit $Base $Rehearsed $Fake $Number)
    return [pscustomobject]@{ Update = $update; Land = $land }
}

## Installs a pre-commit hook in $Repository, shared by its worktrees, that runs $Command
## there: a way to move a remote ref between landing's checks and its pushes, since
## landing makes its merge commit after checking and before pushing.
function Set-PreCommitHook([string]$Repository, [string]$Command) {
    $hooks = (Invoke-FixtureGit $Repository @('rev-parse', '--git-common-dir')).Trim()
    if (-not [IO.Path]::IsPathRooted($hooks)) { $hooks = Join-Path $Repository $hooks }
    Write-FixtureText (Join-Path $hooks 'hooks/pre-commit') "#!/bin/sh`n$Command`n"
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

Test 'draft work is found after the draft moves on past where the ready branch forked' {
    # The reviewer's re-review case: the draft's later commit is not in the ready branch,
    # but the commit the ready branch forked from still is.
    $repo = New-FixtureRepository @{ 'a.txt' = "a`n" }
    Add-FixtureCommit $repo 'draft-work' 'main' @{ 'unready.txt' = "u`n" } | Out-Null
    $ready = Add-FixtureCommit $repo 'ready-work' 'draft-work' @{ 'ready.txt' = "r`n" }
    $advanced = Add-FixtureCommit $repo 'draft-work' 'main' @{ 'unready.txt' = "u2`n" }
    $run = Invoke-Survey $repo @((New-PullRequest 1 'draft-work' $advanced -Draft), (New-PullRequest 2 'ready-work' $ready))
    Assert ($run.Code -eq 0) "Survey failed: $($run.Result.error)"
    $included = @((Get-SurveyPullRequest $run.Result 2).includesUnready)
    Assert ($included.Count -eq 1 -and $included[0].number -eq 1 -and $included[0].sharedCommits -eq 1) "Advanced draft missed: $($run.Result | ConvertTo-Json -Compress -Depth 6)"
}

Test 'a draft stacked on a ready pull request is not counted against it' {
    # The draft shares only the ready pull request's own commits, even after the ready one
    # moves on.
    $repo = New-FixtureRepository @{ 'a.txt' = "a`n" }
    Add-FixtureCommit $repo 'ready-work' 'main' @{ 'ready.txt' = "r`n" } | Out-Null
    $draft = Add-FixtureCommit $repo 'draft-work' 'ready-work' @{ 'later.txt' = "l`n" }
    $ready = Add-FixtureCommit $repo 'ready-work' 'main' @{ 'ready.txt' = "r2`n" }
    $run = Invoke-Survey $repo @((New-PullRequest 1 'ready-work' $ready), (New-PullRequest 2 'draft-work' $draft 'ready-work' -Draft))
    Assert ($run.Code -eq 0 -and @((Get-SurveyPullRequest $run.Result 1).includesUnready).Count -eq 0) "Stacked draft counted: $($run.Result | ConvertTo-Json -Compress -Depth 6)"
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
    $text = $quoteGuard + "`n" + @'
$data = @(Get-Content -LiteralPath '__DATA__' -Raw | ConvertFrom-Json)
$size = __SIZE__
$fields = @{}
for ($i = 2; $i + 1 -lt $args.Count; $i += 2) { $pair = "$($args[$i + 1])" -split '=', 2; $fields[$pair[0]] = $pair[1] }
if ($args[0] -ne 'api' -or $fields.owner -ne 'fixture' -or $fields.name -ne 'repo') { "not a query about fixture/repo: $($args -join ' ')"; exit 1 }
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

Test 'an update refuses a merge already in progress and keeps its resolution' {
    # The reviewer's case: someone's resolution of a conflicted merge, staged and not yet
    # committed, must survive an update that refuses to start.
    $repo = New-FixtureRepository @{ 'log.md' = "entry 0`n" }
    $one = Add-FixtureCommit $repo 'one' 'main' @{ 'log.md' = "entry 0`nentry 1`n" }
    $two = Add-FixtureCommit $repo 'two' 'main' @{ 'log.md' = "entry 0`nentry 2`n" }
    $rehearsal = New-Rehearsal $repo $one
    & git -C $rehearsal merge --no-ff --no-commit $two 2>&1 | Out-Null
    Write-FixtureText (Join-Path $rehearsal 'log.md') "careful manual resolution`n"
    Invoke-FixtureGit $rehearsal @('add', 'log.md') | Out-Null
    $run = Invoke-IntegrateScript 'update' @{ Worktree = $rehearsal; Head = $two; Base = $one; Rehearsed = $one }
    Assert ($run.Code -eq 1 -and $run.Result.error -match 'merge in progress') "Expected a refusal: $($run.Result | ConvertTo-Json -Compress)"
    Assert ((Get-FixtureRef $rehearsal 'MERGE_HEAD') -eq $two) 'The merge in progress was abandoned.'
    Assert ((Get-Content -LiteralPath (Join-Path $rehearsal 'log.md') -Raw) -eq "careful manual resolution`n") 'The resolution was lost.'
    Assert ((Invoke-FixtureGit $rehearsal @('show', ':log.md')).Trim() -eq 'careful manual resolution') 'The staged resolution was lost.'
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

    $first = Invoke-Step $rehearsal 'one' $one $base $stepOne (New-FakePullRequest $repo 'one') 1
    Assert ($first.Land.Code -eq 0 -and $first.Land.Result.landed -and $first.Land.Result.merged -and -not $first.Land.Result.branchPushed) "First landing failed: $($first.Update.Result.error) $($first.Land.Result.error)"
    $mergeOne = $first.Land.Result.mergeCommit
    Assert ((Get-OriginBranch $repo 'main') -eq $mergeOne) 'Origin main is not the first merge commit.'
    $parents = (Invoke-FixtureGit $repo @('rev-list', '--parents', '-n', '1', $mergeOne)).Trim() -split ' '
    Assert ($parents[1] -eq $base -and $parents[2] -eq $one) "Wrong parents: $($parents -join ' ')"
    Assert ((Invoke-FixtureGit $repo @('log', '-1', '--format=%s', $mergeOne)).Trim() -eq 'Merge pull request #1 from one') 'Wrong merge message.'

    $second = Invoke-Step $rehearsal 'two' $two $mergeOne $stepTwo (New-FakePullRequest $repo 'two') 2
    Assert ($second.Land.Code -eq 0 -and $second.Land.Result.branchPushed -and $second.Land.Result.merged) "Second landing failed: $($second.Update.Result.error) $($second.Land.Result.error)"
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
    $run = Invoke-Step $rehearsal 'one' $one $base $step (New-FakePullRequest $repo 'one')
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
    $run = Invoke-Step $rehearsal 'one' $one $base $step (New-FakePullRequest $repo 'one')
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
    $run = Invoke-Step $rehearsal 'one' $one $base $step (New-FakePullRequest $repo 'one')
    Assert ($run.Land.Code -eq 1 -and -not $run.Land.Result.landed -and $run.Land.Result.branchPushed) "Expected a refused landing after the branch push: $($run.Land.Result | ConvertTo-Json -Compress)"
    Assert ($run.Land.Result.error -match 'Pushing main was refused' -and $run.Land.Result.error -match 'now holds the update') "Unclear error: $($run.Land.Result.error)"
    Assert ((Get-OriginBranch $repo 'main') -eq $base -and (Get-OriginBranch $repo 'one') -eq $run.Update.Result.commit) 'Origin is not as reported.'
}

## A remote fixture with branch 'one' pushed and rehearsed on main; with -Behind, main
## moves on first, so landing must push an update to the branch.
function New-LandingFixture([switch]$Behind) {
    $repo = New-RemoteFixture @{ 'a.txt' = "a`n"; 'b.txt' = "b`n" }
    $one = Add-FixtureCommit $repo 'one' 'main' @{ 'a.txt' = "a1`n" }
    if ($Behind) { Add-FixtureCommit $repo 'main' 'main' @{ 'b.txt' = "b1`n" } | Out-Null }
    Invoke-FixtureGit $repo @('push', '--quiet', 'origin', 'main', 'one') | Out-Null
    $base = Get-FixtureRef $repo 'main'
    $rehearsal = New-Rehearsal $repo $base
    $step = Add-RehearsalStep $rehearsal $one
    return [pscustomobject]@{ Repository = $repo; Head = $one; Base = $base; Rehearsal = $rehearsal; Step = $step }
}

Test 'landing refuses a pull request turned back into a draft, pushing nothing' {
    # The reviewer's re-review case: the skill's own check passed, then the pull request
    # became a draft while its git branches stayed exactly as approved.
    $f = New-LandingFixture
    $run = Invoke-Step $f.Rehearsal 'one' $f.Head $f.Base $f.Step (New-FakePullRequest $f.Repository 'one' @{ isDraft = $true })
    Assert ($run.Land.Code -eq 1 -and $run.Land.Result.error -match 'draft again' -and $run.Land.Result.error -match 'nothing was pushed') "Expected a refusal: $($run.Land.Result | ConvertTo-Json -Compress)"
    Assert ((Get-OriginBranch $f.Repository 'main') -eq $f.Base -and -not $run.Land.Result.landed) 'Main changed.'
}

Test 'landing refuses a pull request retargeted to another base, pushing nothing' {
    $f = New-LandingFixture
    $run = Invoke-Step $f.Rehearsal 'one' $f.Head $f.Base $f.Step (New-FakePullRequest $f.Repository 'one' @{ baseRefName = 'release' })
    Assert ($run.Land.Code -eq 1 -and $run.Land.Result.error -match 'now targets release') "Expected a refusal: $($run.Land.Result | ConvertTo-Json -Compress)"
    Assert ((Get-OriginBranch $f.Repository 'main') -eq $f.Base) 'Main changed.'
}

Test 'a pull request turned into a draft after the branch push does not land' {
    # GitHub is read again just before the base push: the second read sees a draft.
    $f = New-LandingFixture -Behind
    $fake = New-FakePullRequest $f.Repository 'one' @{} @{ '2' = @{ isDraft = $true } }
    $run = Invoke-Step $f.Rehearsal 'one' $f.Head $f.Base $f.Step $fake
    Assert ($run.Land.Code -eq 1 -and $run.Land.Result.branchPushed -and -not $run.Land.Result.landed) "Expected the base push withheld: $($run.Land.Result | ConvertTo-Json -Compress)"
    Assert ($run.Land.Result.error -match 'draft again' -and $run.Land.Result.error -match 'now holds the update') "Unclear error: $($run.Land.Result.error)"
    Assert ((Get-OriginBranch $f.Repository 'main') -eq $f.Base) 'Main changed.'
}

Test 'a base moved back after the checks is not restored' {
    # #18: another session resets main to its parent after landing has checked it. A plain
    # push would fast-forward from the parent and restore the discarded commit.
    $f = New-LandingFixture -Behind
    $update = Invoke-IntegrateScript 'update' @{ Worktree = $f.Rehearsal; Head = $f.Head; Base = $f.Base; Rehearsed = $f.Step }
    $parent = (Invoke-FixtureGit $f.Repository @('rev-parse', "$($f.Base)~1")).Trim()
    Set-PreCommitHook $f.Repository "git push --quiet --force origin ${parent}:refs/heads/main"
    $run = Invoke-IntegrateScript 'land' (Get-LandParameters $f.Rehearsal 'one' $f.Head $update.Result.commit $f.Base $f.Step (New-FakePullRequest $f.Repository 'one'))
    Assert ($run.Code -eq 1 -and $run.Result.error -match 'Pushing main was refused' -and -not $run.Result.landed) "Expected the base push refused: $($run.Result | ConvertTo-Json -Compress)"
    Assert ((Get-OriginBranch $f.Repository 'main') -eq $parent) 'The discarded commit was restored to main.'
}

Test 'a branch that vanishes after the checks is not recreated' {
    $f = New-LandingFixture -Behind
    $update = Invoke-IntegrateScript 'update' @{ Worktree = $f.Rehearsal; Head = $f.Head; Base = $f.Base; Rehearsed = $f.Step }
    Set-PreCommitHook $f.Repository 'git push --quiet origin :refs/heads/one'
    $run = Invoke-IntegrateScript 'land' (Get-LandParameters $f.Rehearsal 'one' $f.Head $update.Result.commit $f.Base $f.Step (New-FakePullRequest $f.Repository 'one'))
    Assert ($run.Code -eq 1 -and $run.Result.error -match 'Pushing one was refused' -and -not $run.Result.branchPushed) "Expected the branch push refused: $($run.Result | ConvertTo-Json -Compress)"
    Assert (-not (Get-OriginBranch $f.Repository 'one') -and (Get-OriginBranch $f.Repository 'main') -eq $f.Base) 'The branch was recreated or main changed.'
}

Test 'a merge commit that fails once can be retried with the same arguments' {
    # The reviewer's case: a commit hook fails transiently, after landing has started its
    # merge and before any push. The retry must not find that merge still pending.
    $f = New-LandingFixture
    $marker = Join-Path $sandbox ('fail-once-' + [guid]::NewGuid().ToString('N'))
    Write-FixtureText $marker 'fail'
    $shellMarker = $marker.Replace('\', '/')
    Set-PreCommitHook $f.Repository "if [ -f '$shellMarker' ]; then rm '$shellMarker'; echo 'transient hook failure' >&2; exit 1; fi"
    $parameters = Get-LandParameters $f.Rehearsal 'one' $f.Head $f.Head $f.Base $f.Step (New-FakePullRequest $f.Repository 'one')
    $first = Invoke-IntegrateScript 'land' $parameters
    Assert ($first.Code -eq 1 -and $first.Result.error -match 'merge commit failed, so nothing was pushed' -and -not $first.Result.branchPushed) "Expected the commit to fail: $($first.Result | ConvertTo-Json -Compress)"
    Assert (-not (Get-FixtureRef $f.Rehearsal 'MERGE_HEAD')) 'The failed merge was left pending.'
    Assert ((Get-OriginBranch $f.Repository 'main') -eq $f.Base) 'Main changed.'
    $again = Invoke-IntegrateScript 'land' $parameters
    Assert ($again.Code -eq 0 -and $again.Result.landed -and $again.Result.merged) "The retry failed: $($again.Result | ConvertTo-Json -Compress)"
}

Test 'landing refuses a worktree with a merge in progress and keeps it' {
    $f = New-LandingFixture
    $other = Add-FixtureCommit $f.Repository 'other' 'main' @{ 'other.txt' = "o`n" }
    & git -C $f.Rehearsal merge --no-ff --no-commit $other 2>&1 | Out-Null
    $run = Invoke-IntegrateScript 'land' (Get-LandParameters $f.Rehearsal 'one' $f.Head $f.Head $f.Base $f.Step (New-FakePullRequest $f.Repository 'one'))
    Assert ($run.Code -eq 1 -and $run.Result.error -match 'merge in progress') "Expected a refusal: $($run.Result | ConvertTo-Json -Compress)"
    Assert ((Get-FixtureRef $f.Rehearsal 'MERGE_HEAD') -eq $other) 'The merge that was in progress was abandoned.'
    Assert ((Get-OriginBranch $f.Repository 'main') -eq $f.Base) 'Main changed.'
}

Test 'a GitHub error before landing pushes nothing' {
    $f = New-LandingFixture -Behind
    $run = Invoke-Step $f.Rehearsal 'one' $f.Head $f.Base $f.Step (New-FakePullRequest $f.Repository 'one' @{ fail = $true })
    Assert ($run.Land.Code -eq 1 -and $run.Land.Result.error -match 'Could not read #1' -and -not $run.Land.Result.branchPushed) "Expected a refusal: $($run.Land.Result | ConvertTo-Json -Compress)"
    Assert ((Get-OriginBranch $f.Repository 'one') -eq $f.Head -and (Get-OriginBranch $f.Repository 'main') -eq $f.Base) 'Something was pushed.'
}

Test 'a merge GitHub reports late is waited for' {
    $f = New-LandingFixture
    $run = Invoke-Step $f.Rehearsal 'one' $f.Head $f.Base $f.Step (New-FakePullRequest $f.Repository 'one' @{ mergeDelayCalls = 2 })
    Assert ($run.Land.Code -eq 0 -and $run.Land.Result.merged -and $run.Land.Result.state -eq 'MERGED') "Expected the wait to succeed: $($run.Land.Result | ConvertTo-Json -Compress)"
}

Test 'GitHub not reporting the merge in time stops the run, and running again resumes' {
    $f = New-LandingFixture -Behind
    $fake = New-FakePullRequest $f.Repository 'one' @{ neverMerge = $true }
    $first = Invoke-Step $f.Rehearsal 'one' $f.Head $f.Base $f.Step $fake
    Assert ($first.Land.Code -eq 1 -and $first.Land.Result.landed -and -not $first.Land.Result.merged -and $first.Land.Result.error -match 'Run this again') "Expected a landed, unconfirmed stop: $($first.Land.Result | ConvertTo-Json -Compress)"
    $merge = $first.Land.Result.mergeCommit
    Set-FakePullRequest $fake @{ neverMerge = $false }
    $again = Invoke-IntegrateScript 'land' (Get-LandParameters $f.Rehearsal 'one' $f.Head $first.Update.Result.commit $f.Base $f.Step $fake)
    Assert ($again.Code -eq 0 -and $again.Result.resumed -and $again.Result.merged -and $again.Result.mergeCommit -eq $merge) "Expected a resumed confirmation: $($again.Result | ConvertTo-Json -Compress)"
    Assert ((Get-OriginBranch $f.Repository 'main') -eq $merge) 'Main changed on resuming.'
}

Test 'closing issues keep their repository and URL' {
    # The reviewer's case: two issues numbered 7 in different repositories.
    $f = New-LandingFixture
    $closing = @(
        @{ number = 7; url = 'https://github.com/fixture/project/issues/7'; repository = @{ name = 'project'; owner = @{ login = 'fixture' } } },
        @{ number = 7; url = 'https://github.com/fixture/public-issues/issues/7'; repository = @{ name = 'public-issues'; owner = @{ login = 'fixture' } } })
    $run = Invoke-Step $f.Rehearsal 'one' $f.Head $f.Base $f.Step (New-FakePullRequest $f.Repository 'one' @{ closing = $closing })
    Assert ($run.Land.Code -eq 0) "Landing failed: $($run.Land.Result.error)"
    $issues = @($run.Land.Result.closingIssues)
    Assert ($issues.Count -eq 2 -and (@($issues | ForEach-Object url) -join ' ') -eq 'https://github.com/fixture/project/issues/7 https://github.com/fixture/public-issues/issues/7' -and (@($issues | ForEach-Object repository) -join ' ') -eq 'fixture/project fixture/public-issues') "Identities lost: $($issues | ConvertTo-Json -Compress)"
}

## Lands branch 'one' of a new remote fixture and returns the repository and its head.
function New-LandedFixture {
    $f = New-LandingFixture
    $run = Invoke-Step $f.Rehearsal 'one' $f.Head $f.Base $f.Step (New-FakePullRequest $f.Repository 'one')
    if ($run.Land.Code -ne 0) { throw "Landing the fixture failed: $($run.Land.Result.error)" }
    return [pscustomobject]@{ Repository = $f.Repository; Head = $f.Head }
}

## A stand-in for the GitHub CLI that answers from $Responses: the longest key its joined
## arguments start with picks the response, printed as given. A request to render Markdown
## is keyed 'markdown <text>', exactly, and refused unless it asks for GitHub-flavoured
## Markdown in fixture/repo. A response starting with '!fail' makes it exit 1, printing
## that text; one starting with '!warn ' prints the rest after writing a warning to its
## error output, as gh does with an update notice.
function New-FakeGitHubCli([hashtable]$Responses) {
    $data = Join-Path $sandbox ('gh-responses-' + [guid]::NewGuid().ToString('N') + '.json')
    Write-FixtureText $data ($Responses | ConvertTo-Json -Depth 3)
    $fake = Join-Path $sandbox ('gh-table-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $text = $quoteGuard + "`n" + @'
$responses = Get-Content -LiteralPath '__DATA__' -Raw | ConvertFrom-Json -AsHashtable
$words = [string[]]@($args | ForEach-Object { "$_" })
$line = $words -join ' '
# A GraphQL call is keyed by its variables, in order, without the query text:
# 'graphql owner=fixture name=repo number=7 after=c2'.
if ($words[0] -eq 'api' -and $words[1] -eq 'graphql') {
    $variables = for ($i = 2; $i + 1 -lt $words.Count; $i += 2) { if (-not $words[$i + 1].StartsWith('query=')) { $words[$i + 1] } }
    $line = 'graphql ' + (@($variables) -join ' ')
}
if ($words[0] -eq 'api' -and $words -contains 'markdown') {
    $request = Get-Content -LiteralPath $words[[array]::IndexOf($words, '--input') + 1] -Raw | ConvertFrom-Json
    if ($request.mode -ne 'gfm' -or $request.context -ne 'fixture/repo') { "rendering outside fixture/repo: $($request | ConvertTo-Json -Compress)"; exit 1 }
    $line = 'markdown ' + $request.text
    if (-not $responses.ContainsKey($line)) { "no stand-in rendering for: $line"; exit 1 }
}
$key = if ($line.StartsWith('markdown ')) { $line } else { @($responses.Keys | Where-Object { $line.StartsWith($_) } | Sort-Object Length -Descending) | Select-Object -First 1 }
if (-not $key) { "no stand-in response for: $line"; exit 1 }
$value = "$($responses[$key])"
if ($value.StartsWith('!fail')) { $value; exit 1 }
if ($value.StartsWith('!warn ')) {
    Write-Error -Message 'A new release of gh is available: 9.9.9' -ErrorAction Continue
    $value = $value.Substring(6)
}
$value
exit 0
'@
    Write-FixtureText $fake $text.Replace('__DATA__', $data.Replace("'", "''"))
    return $fake
}

## A stand-in for the GitHub CLI over the open pull requests targeting a branch of
## fixture/repo. It pages $Dependents, $PageSize at a time, for the GraphQL query, answers
## a query about any other repository with none, and records which repositories were
## asked. `pr edit <n> --repo fixture/repo --base <base>` retargets one, so it stops being
## listed. $State can set fail (every call fails), failEdit (that pull request's edit
## fails) and warn. Returns the script and its state file.
function New-FakeDependents([object[]]$Dependents = @(), [int]$PageSize = 2, [hashtable]$State = @{}) {
    $fields = @{ dependents = @($Dependents); pageSize = $PageSize; edited = @(); asked = @(); fail = $false; failEdit = 0; warn = $false }
    foreach ($key in $State.Keys) { $fields[$key] = $State[$key] }
    $statePath = Join-Path $sandbox ('dependents-' + [guid]::NewGuid().ToString('N') + '.json')
    Write-FixtureText $statePath ($fields | ConvertTo-Json -Depth 6)
    $fake = Join-Path $sandbox ('gh-dependents-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $text = $quoteGuard + "`n" + @'
$statePath = '__STATE__'
$s = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
if ($s.fail) { 'HTTP 502: Bad Gateway'; exit 1 }
if ($s.warn) { Write-Error -Message 'A new release of gh is available: 9.9.9' -ErrorAction Continue }
$words = [string[]]@($args | ForEach-Object { "$_" })
if ($words[0] -eq 'pr' -and $words[1] -eq 'edit') {
    $number = [int]$words[2]
    $at = [array]::IndexOf($words, '--repo')
    if ($at -lt 0 -or $words[$at + 1] -ne 'fixture/repo') { "edit not in fixture/repo: $($words -join ' ')"; exit 1 }
    if ($number -eq [int]$s.failEdit) { "HTTP 422 retargeting #$number"; exit 1 }
    $s.edited = @($s.edited) + $number
    Set-Content -LiteralPath $statePath -Value ($s | ConvertTo-Json -Depth 6)
    exit 0
}
$fields = @{}
for ($i = 2; $i + 1 -lt $words.Count; $i += 2) { $pair = $words[$i + 1] -split '=', 2; $fields[$pair[0]] = $pair[1] }
$asked = "$($fields.owner)/$($fields.name)"
$s.asked = @($s.asked) + $asked
Set-Content -LiteralPath $statePath -Value ($s | ConvertTo-Json -Depth 6)
$open = @(if ($asked -eq 'fixture/repo') { $s.dependents | Where-Object { [int]$_.number -notin @($s.edited | ForEach-Object { [int]$_ }) } })
$start = if ($fields.after) { [int]$fields.after } else { 0 }
$size = [int]$s.pageSize
$slice = @($open | Select-Object -Skip $start -First $size)
@{ data = @{ repository = @{ pullRequests = @{ pageInfo = @{ hasNextPage = ($start + $size -lt $open.Count); endCursor = "$($start + $size)" }; nodes = $slice } } } } | ConvertTo-Json -Depth 8
exit 0
'@
    Write-FixtureText $fake $text.Replace('__STATE__', $statePath.Replace("'", "''"))
    return [pscustomobject]@{ Path = $fake; State = $statePath }
}

## What a stand-in from New-FakeDependents recorded.
function Get-FakeDependentsState($Fake) {
    return Get-Content -LiteralPath $Fake.State -Raw | ConvertFrom-Json
}

## $Count open pull requests numbered from 101, every other one a draft, as GitHub lists them.
function New-Dependents([int]$Count) {
    return @(1..$Count | ForEach-Object { @{ number = 100 + $_; url = "https://github.com/fixture/repo/pull/$(100 + $_)"; title = "PR $(100 + $_)"; isDraft = ($_ % 2 -eq 0) } })
}

## Runs delete-branch for branch 'one' of $Repository merged at $Tip, with GitHub listing
## $Dependents as the open pull requests targeting it; returns the run and the stand-in.
function Invoke-DeleteBranch([string]$Repository, [string]$Tip, [object[]]$Dependents = @(), [hashtable]$State = @{}) {
    $fake = New-FakeDependents $Dependents 2 $State
    $run = Invoke-IntegrateScript 'delete-branch' @{ Repository = $Repository; Branch = 'one'; MergedTip = $Tip; BaseBranch = 'main'; GitHubCli = $fake.Path }
    $run | Add-Member -NotePropertyName Fake -NotePropertyValue $fake
    return $run
}

Test 'deleting a merged branch at its merged tip removes it' {
    $f = New-LandedFixture
    $run = Invoke-DeleteBranch $f.Repository $f.Head
    Assert ($run.Code -eq 0 -and $run.Result.outcome -eq 'deleted' -and -not (Get-OriginBranch $f.Repository 'one')) "Not deleted: $($run.Result | ConvertTo-Json -Compress)"
}

Test 'a branch pushed to after merging is preserved and reported' {
    # The reviewer's case: a session pushes to the branch after its approved head merged.
    $f = New-LandedFixture
    $moved = Push-ElsewhereCommit $f.Repository 'one'
    $run = Invoke-DeleteBranch $f.Repository $f.Head
    Assert ($run.Code -eq 0 -and $run.Result.outcome -eq 'moved' -and $run.Result.current -eq $moved) "Expected it preserved: $($run.Result | ConvertTo-Json -Compress)"
    Assert ((Get-OriginBranch $f.Repository 'one') -eq $moved) 'The newer commit was deleted.'
}

Test 'deleting an already deleted branch is a no-op' {
    $f = New-LandedFixture
    Invoke-DeleteBranch $f.Repository $f.Head | Out-Null
    $run = Invoke-DeleteBranch $f.Repository $f.Head
    Assert ($run.Code -eq 0 -and $run.Result.outcome -eq 'absent' -and -not $run.Result.deleted) "Expected a no-op: $($run.Result | ConvertTo-Json -Compress)"
}

Test 'a branch whose tip the base does not contain is not deleted' {
    $repo = New-RemoteFixture @{ 'a.txt' = "a`n" }
    $one = Add-FixtureCommit $repo 'one' 'main' @{ 'a.txt' = "a1`n" }
    Invoke-FixtureGit $repo @('push', '--quiet', 'origin', 'one') | Out-Null
    $run = Invoke-DeleteBranch $repo $one
    Assert ($run.Code -eq 1 -and $run.Result.error -match 'has not merged' -and (Get-OriginBranch $repo 'one') -eq $one) "Expected a refusal: $($run.Result | ConvertTo-Json -Compress)"
}

Test 'a branch other open pull requests still target is not deleted, however many pages they fill' {
    # The DRRD pilot's case: #231 targeted #226's branch, and deleting that branch first
    # could have closed it. Three dependents fill two pages of two.
    $f = New-LandedFixture
    $run = Invoke-DeleteBranch $f.Repository $f.Head (New-Dependents 3)
    Assert ($run.Code -eq 1 -and $run.Result.error -match 'Retarget them to main' -and (@($run.Result.dependents | ForEach-Object number) -join ',') -eq '101,102,103') "Expected a refusal naming all three: $($run.Result | ConvertTo-Json -Compress)"
    Assert ((Get-OriginBranch $f.Repository 'one') -eq $f.Head) 'The branch was deleted.'
}

Test 'dependents are looked up in the repository the remote names, whatever GH_REPO says' {
    # The reviewer's P1: gh left to choose would ask GH_REPO's repository and miss the
    # dependents of the one being pushed to.
    $f = New-LandedFixture
    $saved = $env:GH_REPO
    try { $env:GH_REPO = 'cli/cli'; $run = Invoke-DeleteBranch $f.Repository $f.Head (New-Dependents 1) }
    finally { $env:GH_REPO = $saved }
    $asked = @((Get-FakeDependentsState $run.Fake).asked)
    Assert ($run.Code -eq 1 -and $run.Result.repository -eq 'fixture/repo' -and ($asked -join ',') -eq 'fixture/repo') "Asked the wrong repository: $($asked -join ',') $($run.Result | ConvertTo-Json -Compress)"
    Assert ((Get-OriginBranch $f.Repository 'one') -eq $f.Head) 'The branch was deleted.'
}

Test 'a remote that is not on GitHub is refused before anything is deleted' {
    $f = New-LandedFixture
    $bare = (Invoke-FixtureGit $f.Repository @('remote', 'get-url', 'origin')).Trim()
    Invoke-FixtureGit $f.Repository @('remote', 'set-url', 'origin', $bare) | Out-Null
    $run = Invoke-DeleteBranch $f.Repository $f.Head
    Assert ($run.Code -eq 1 -and $run.Result.error -match 'not a github.com repository' -and (Get-OriginBranch $f.Repository 'one') -eq $f.Head) "Expected a refusal: $($run.Result | ConvertTo-Json -Compress)"
}

## Gives the fixture's origin a second destination, as $Kind says: a second push URL, or
## a second URL with no push URLs, either one the bare repository at $Other.
function Add-SecondDestination([string]$Repository, [string]$Kind, [string]$Other) {
    if ($Kind -eq 'pushurl') {
        Invoke-FixtureGit $Repository @('config', '--add', 'remote.origin.pushurl', 'https://github.com/fixture/repo.git') | Out-Null
        Invoke-FixtureGit $Repository @('config', '--add', 'remote.origin.pushurl', $Other) | Out-Null
    } else {
        Invoke-FixtureGit $Repository @('config', '--add', 'remote.origin.url', $Other) | Out-Null
    }
}

foreach ($kind in @('pushurl', 'url')) {
    Test "a remote with a second $kind destination is refused before anything is deleted" {
        # The reviewer's re-review case: git would delete the branch from both
        # destinations while the checks read only the first.
        $f = New-LandedFixture
        $mirror = Join-Path $sandbox ('mirror-' + [guid]::NewGuid().ToString('N') + '.git')
        Invoke-FixtureGit $sandbox @('init', '--quiet', '--bare', '--initial-branch=main', $mirror) | Out-Null
        Invoke-FixtureGit $f.Repository @('push', '--quiet', $mirror, "$($f.Head):refs/heads/one") | Out-Null
        Add-SecondDestination $f.Repository $kind $mirror.Replace('\', '/')
        $run = Invoke-DeleteBranch $f.Repository $f.Head
        Assert ($run.Code -eq 1 -and $run.Result.error -match 'pushes to 2 destinations') "Expected a refusal: $($run.Result | ConvertTo-Json -Compress)"
        Assert ((Get-OriginBranch $f.Repository 'one') -eq $f.Head) 'The branch was deleted from origin.'
        Assert ((Invoke-FixtureGit $sandbox @('--git-dir', $mirror, 'rev-parse', 'refs/heads/one')).Trim() -eq $f.Head) 'The branch was deleted from the second destination.'
    }
}

Test 'a push rewrite to another GitHub repository is refused before anything is deleted' {
    $f = New-LandedFixture
    # A dead proxy, so a regression fails here instead of reaching GitHub.
    Invoke-FixtureGit $f.Repository @('config', 'http.proxy', 'http://127.0.0.1:9') | Out-Null
    Invoke-FixtureGit $f.Repository @('config', 'url.https://github.com/mirror/repo.git.pushInsteadOf', 'https://github.com/fixture/repo.git') | Out-Null
    $run = Invoke-DeleteBranch $f.Repository $f.Head
    Assert ($run.Code -eq 1 -and $run.Result.error -match 'rewrite sends its pushes to mirror/repo') "Expected a refusal: $($run.Result | ConvertTo-Json -Compress)"
    Assert ((Get-OriginBranch $f.Repository 'one') -eq $f.Head) 'The branch was deleted.'
}

Test 'landing refuses a remote with two push destinations, pushing nothing' {
    $f = New-LandingFixture
    $mirror = Join-Path $sandbox ('mirror-' + [guid]::NewGuid().ToString('N') + '.git')
    Invoke-FixtureGit $sandbox @('init', '--quiet', '--bare', '--initial-branch=main', $mirror) | Out-Null
    Add-SecondDestination $f.Repository 'pushurl' $mirror.Replace('\', '/')
    $run = Invoke-Step $f.Rehearsal 'one' $f.Head $f.Base $f.Step (New-FakePullRequest $f.Repository 'one')
    Assert ($run.Land.Code -eq 1 -and $run.Land.Result.error -match 'pushes to 2 destinations' -and -not $run.Land.Result.branchPushed) "Expected a refusal: $($run.Land.Result | ConvertTo-Json -Compress)"
    Assert ((Get-OriginBranch $f.Repository 'main') -eq $f.Base) 'Main changed.'
}

Test 'a GitHub error while listing dependents deletes nothing' {
    $f = New-LandedFixture
    $run = Invoke-DeleteBranch $f.Repository $f.Head @() @{ fail = $true }
    Assert ($run.Code -eq 1 -and $run.Result.error -match 'Could not ask GitHub' -and (Get-OriginBranch $f.Repository 'one') -eq $f.Head) "Expected a refusal: $($run.Result | ConvertTo-Json -Compress)"
}

## Runs retarget for branch 'one' of a fixture with a GitHub remote, its open pull requests
## served by $Fake; with -List it only lists them, otherwise it retargets $Approved.
function Invoke-Retarget($Fake, [switch]$List, [int[]]$Approved = @()) {
    $repo = New-RemoteFixture @{ 'a.txt' = "a`n" }
    $parameters = @{ Repository = $repo; Branch = 'one'; BaseBranch = 'main'; GitHubCli = $Fake.Path }
    if ($List) { $parameters.List = $true } else { $parameters.Approved = if ($Approved.Count) { $Approved -join ',' } else { 'none' } }
    return Invoke-IntegrateScript 'retarget' $parameters
}

Test 'every open pull request targeting a branch is listed, past gh''s default of 30' {
    # The reviewer's case: 31 dependents, in pages of 30.
    $fake = New-FakeDependents (New-Dependents 31) 30
    $run = Invoke-Retarget $fake -List
    Assert ($run.Code -eq 0 -and @($run.Result.targeting).Count -eq 31 -and @($run.Result.targeting | Where-Object isDraft).Count -eq 15) "Wrong listing: $(@($run.Result.targeting).Count) listed"
    Assert (@((Get-FakeDependentsState $fake).edited).Count -eq 0) 'Listing retargeted something.'
}

Test 'retargeting moves every approved one and confirms none is left' {
    $fake = New-FakeDependents (New-Dependents 31) 30
    $run = Invoke-Retarget $fake -Approved (101..131)
    Assert ($run.Code -eq 0 -and @($run.Result.retargeted).Count -eq 31 -and @($run.Result.remaining).Count -eq 0) "Not all retargeted: $($run.Result | ConvertTo-Json -Compress -Depth 4)"
    Assert (@((Get-FakeDependentsState $fake).edited).Count -eq 31) 'GitHub did not see 31 retargets.'
}

Test 'a pull request the plan did not approve stops retargeting before any is moved' {
    # A dependent opened after the plan was approved needs a new approval.
    $fake = New-FakeDependents (New-Dependents 3) 2
    $run = Invoke-Retarget $fake -Approved @(101, 102)
    Assert ($run.Code -eq 1 -and $run.Result.error -match 'not approved: #103' -and (@($run.Result.unexpected) -join ',') -eq '103') "Expected a refusal naming #103: $($run.Result | ConvertTo-Json -Compress -Depth 4)"
    Assert (@((Get-FakeDependentsState $fake).edited).Count -eq 0) 'Something was retargeted.'
}

Test 'nothing targeting the branch is a no-op when none were approved' {
    $run = Invoke-Retarget (New-FakeDependents @() 2) -Approved @()
    Assert ($run.Code -eq 0 -and @($run.Result.retargeted).Count -eq 0) "Expected a no-op: $($run.Result | ConvertTo-Json -Compress -Depth 4)"
}

Test 'a retarget that fails stops and says which were already retargeted' {
    $fake = New-FakeDependents (New-Dependents 4) 2 @{ failEdit = 103 }
    $run = Invoke-Retarget $fake -Approved (101..104)
    Assert ($run.Code -eq 1 -and $run.Result.error -match 'Retargeting #103' -and (@($run.Result.retargeted) -join ',') -eq '101,102') "Wrong report: $($run.Result | ConvertTo-Json -Compress -Depth 4)"
}

## A repository whose origin is https://github.com/fixture/repo.git, never pushed to: all
## the issue check needs to know which GitHub repository it is about.
function New-GitHubCheckout {
    $repo = New-FixtureRepository @{ 'a.txt' = "a`n" }
    Invoke-FixtureGit $repo @('remote', 'add', 'origin', 'https://github.com/fixture/repo.git') | Out-Null
    return $repo
}

## The merge commit every page from New-CommitPage reports, unless told otherwise.
$mergeOid = 'feedface' + ('0' * 32)

## One page of a pull request's commits as GitHub's GraphQL API returns it: $Messages are
## the commits' messages, $Total is the pull request's total, and $Next the cursor of the
## following page, if any. The pull request's merge commit, $mergeOid, has $MergeMessage;
## -NoMergeCommit leaves it out, as GitHub does for one not merged. $Closing are the issues
## GitHub lists as closing it, $ClosingTotal its count of them, and $Manual those of them
## linked by hand.
function New-CommitPage([string[]]$Messages = @(), [int]$Total = -1, [string]$Next, [string]$MergeMessage = 'Merge pull request #7 from fixture/topic', [switch]$NoMergeCommit, [object[]]$Closing = @(), [int]$ClosingTotal = -1, [object[]]$Manual = @()) {
    if ($Total -lt 0) { $Total = $Messages.Count }
    if ($ClosingTotal -lt 0) { $ClosingTotal = $Closing.Count }
    $nodes = @($Messages | ForEach-Object { @{ commit = @{ oid = ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')).Substring(0, 40); message = $_ } } })
    $merge = if ($NoMergeCommit) { $null } else { @{ oid = $mergeOid; message = $MergeMessage } }
    $pullRequest = @{
        closing = @{ totalCount = $ClosingTotal; nodes = @($Closing) }
        manual = @{ totalCount = $Manual.Count; nodes = @($Manual | ForEach-Object { @{ url = $_.url } }) }
        mergeCommit = $merge
        commits = @{ totalCount = $Total; pageInfo = @{ hasNextPage = [bool]$Next; endCursor = $(if ($Next) { $Next } else { $null }) }; nodes = $nodes }
    }
    return ConvertTo-Json -Compress -Depth 8 -InputObject @{ data = @{ repository = @{ pullRequest = $pullRequest } } }
}

## A closing reference to issue $Number of $Owner/$Name, as GitHub lists it.
function New-ClosingReference([int]$Number, [string]$Owner = 'fixture', [string]$Name = 'repo') {
    return @{ number = $Number; url = "https://github.com/$Owner/$Name/issues/$Number"; repository = @{ nameWithOwner = "$Owner/$Name" } }
}

## A reference as GitHub's Markdown renderer links it, in the shape it was seen to return:
## to issue $Number of $Repository, or with -PullRequest to that pull request, showing $Text.
function New-RenderedReference([string]$Repository, [int]$Number, [string]$Text = "#$Number", [switch]$PullRequest) {
    $type, $path = if ($PullRequest) { 'pull_request', 'pull' } else { 'issue', 'issues' }
    return "<a class=`"issue-link js-issue-link`" data-error-text=`"Failed to load title`" data-id=`"$(5000000000 + $Number)`" data-permission-text=`"Title is private`" data-url=`"https://github.com/$Repository/issues/$Number`" data-hovercard-type=`"$type`" data-hovercard-url=`"/$Repository/$path/$Number/hovercard`" href=`"https://github.com/$Repository/$path/$Number`">$Text</a>"
}

## Runs check-issues for pull request 7 of fixture/repo, whose default branch is main.
## $PullRequest overrides the pull request's fields; its `closing` and `manual` give the
## issues GitHub lists as closing it, and those linked by hand. $Issues gives each issue
## URL its `gh issue view` JSON, and $Timelines gives an issue URL the pages of its
## timeline, each a JSON array; a missing timeline is one empty page. $Commits are the
## pages of the pull request's commits, keyed by the cursor that reads them ('' for the
## first), in place of one page from `closing` and `manual`. $Renderings give a commit
## message the HTML GitHub renders it as.
function Invoke-CheckIssues([hashtable]$PullRequest, [hashtable]$Issues, [hashtable]$Timelines = @{}, [hashtable]$Commits, [hashtable]$Renderings = @{}) {
    $pr = [ordered]@{ number = 7; url = 'https://github.com/fixture/repo/pull/7'; state = 'MERGED'; mergedAt = '2026-01-01T00:00:00Z'; baseRefName = 'main' }
    foreach ($key in @($PullRequest.Keys | Where-Object { $_ -notin @('closing', 'manual') })) { $pr[$key] = $PullRequest[$key] }
    if (-not $Commits) { $Commits = @{ '' = (New-CommitPage -Closing @($PullRequest.closing | Where-Object { $_ }) -Manual @($PullRequest.manual | Where-Object { $_ })) } }
    $responses = @{
        'repo view fixture/repo' = '{"nameWithOwner":"fixture/repo","defaultBranchRef":{"name":"main"}}'
        'pr view 7 --repo fixture/repo' = ($pr | ConvertTo-Json -Depth 6 -Compress)
    }
    foreach ($cursor in $Commits.Keys) {
        $key = 'graphql owner=fixture name=repo number=7' + $(if ($cursor) { " after=$cursor" })
        $responses[$key] = $Commits[$cursor]
    }
    foreach ($text in $Renderings.Keys) { $responses["markdown $text"] = $Renderings[$text] }
    foreach ($url in $Issues.Keys) {
        $responses["issue view $url"] = $Issues[$url]
        $pages = @(if ($Timelines.ContainsKey($url)) { $Timelines[$url] } else { '[]' })
        for ($page = 1; $page -le $pages.Count; $page++) {
            $responses["api repos/$($url -replace '^https://github.com/', '')/timeline?per_page=100&page=$page"] = $pages[$page - 1]
        }
    }
    return Invoke-IntegrateScript 'check-issues' @{ Repository = (New-GitHubCheckout); PullRequest = 7; GitHubCli = (New-FakeGitHubCli $responses) }
}

## A timeline event as GitHub's REST API returns it.
function New-TimelineEvent([string]$Event, [string]$At, [string]$Actor) {
    return @{ event = $Event; created_at = $At; actor = @{ login = $Actor } }
}

$closedIssue = '{"state":"CLOSED","stateReason":"COMPLETED","closedAt":"2026-01-01T00:00:03Z"}'
$openIssue = '{"state":"OPEN","stateReason":null,"closedAt":null}'
$issue5 = 'https://github.com/fixture/repo/issues/5'
$fixes5 = "<p dir=`"auto`">Fixes $(New-RenderedReference 'fixture/repo' 5)</p>"

Test 'issues GitHub closed are reported closed with nothing to investigate' {
    $run = Invoke-CheckIssues @{ closing = @(New-ClosingReference 5) } @{ $issue5 = $closedIssue }
    Assert ($run.Code -eq 0 -and $run.Result.allClosed) "Expected all closed: $($run.Result | ConvertTo-Json -Compress -Depth 6)"
    $issue = @($run.Result.issues)[0]
    Assert ($issue.linkedBy -eq 'description keyword' -and -not $issue.manualLink -and @($issue.findings).Count -eq 0) "Wrong report: $($issue | ConvertTo-Json -Compress)"
}

Test 'a description keyword GitHub does not list closes nothing' {
    # The integration run's case: #24's description says a deletion "could have closed
    # #231", meaning another repository's pull request. GitHub listed no #231, so nothing
    # is expected of it; the description itself is never read here.
    $run = Invoke-CheckIssues @{ body = 'Deleting that branch first could have closed #231. Closes #5' } @{}
    Assert ($run.Code -eq 0 -and $run.Result.allClosed -and @($run.Result.issues).Count -eq 0) "Expected nothing to audit: $($run.Result | ConvertTo-Json -Compress -Depth 6)"
}

Test 'an issue a commit names, left open by a merge into another branch, says why' {
    # GitHub lists no closing issues for a pull request targeting another branch, so only
    # the commit's keyword names the issue.
    $run = Invoke-CheckIssues @{ baseRefName = 'release' } @{ $issue5 = $openIssue } @{} @{ '' = (New-CommitPage @('Fixes #5')) } @{ 'Fixes #5' = $fixes5 }
    Assert ($run.Code -eq 0 -and -not $run.Result.allClosed) "Expected an open issue: $($run.Result | ConvertTo-Json -Compress -Depth 6)"
    $issue = @($run.Result.issues)[0]
    $text = @($issue.findings) -join ' | '
    Assert ($issue.linkedBy -eq 'commit keyword' -and $text -match 'not the default branch main') "Wrong findings: $text"
}

Test 'an issue reopened after the merge says who reopened it and when' {
    $timeline = ConvertTo-Json -Compress -Depth 4 -InputObject @(
        (New-TimelineEvent 'closed' '2026-01-01T00:00:03Z' 'github'),
        (New-TimelineEvent 'reopened' '2026-01-02T09:00:00Z' 'someone'))
    $run = Invoke-CheckIssues @{ closing = @(New-ClosingReference 5) } @{ $issue5 = $openIssue } @{ $issue5 = $timeline }
    $text = @(@($run.Result.issues)[0].findings) -join ' | '
    Assert ($run.Code -eq 0 -and $text -match 'closed at 2026-01-01T00:00:03Z, after this merge, and reopened by someone at 2026-01-02T09:00:00Z') "Wrong findings: $text"
}

Test 'a reopening from before the merge is not taken as the cause' {
    # The reviewer's case: the issue was reopened a year before this merge, which then
    # failed to close it for some other reason that must still be reported as unknown.
    $timeline = ConvertTo-Json -Compress -Depth 4 -InputObject @(
        (New-TimelineEvent 'closed' '2025-01-01T00:00:00Z' 'github'),
        (New-TimelineEvent 'reopened' '2025-01-02T00:00:00Z' 'someone'))
    $run = Invoke-CheckIssues @{ closing = @(New-ClosingReference 5) } @{ $issue5 = $openIssue } @{ $issue5 = $timeline }
    $text = @(@($run.Result.issues)[0].findings) -join ' | '
    Assert ($run.Code -eq 0 -and $text -match 'No cause found' -and $text -notmatch 'reopened') "Wrong findings: $text"
}

Test 'a reopening on the timeline''s second page is found' {
    $first = ConvertTo-Json -Compress -Depth 4 -InputObject @(1..100 | ForEach-Object { New-TimelineEvent 'labeled' '2025-06-01T00:00:00Z' 'someone' })
    $second = ConvertTo-Json -Compress -Depth 4 -InputObject @((New-TimelineEvent 'reopened' '2026-01-03T00:00:00Z' 'late'))
    $run = Invoke-CheckIssues @{ closing = @(New-ClosingReference 5) } @{ $issue5 = $openIssue } @{ $issue5 = @($first, $second) }
    $text = @(@($run.Result.issues)[0].findings) -join ' | '
    Assert ($run.Code -eq 0 -and $text -match 'reopened by late at 2026-01-03T00:00:00Z, after this merge') "Wrong findings: $text"
}

Test 'a merge moments ago is reported as possibly still processing' {
    $now = (Get-Date).ToUniversalTime().AddSeconds(-10).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $run = Invoke-CheckIssues @{ mergedAt = $now; closing = @(New-ClosingReference 5) } @{ $issue5 = $openIssue }
    $text = @(@($run.Result.issues)[0].findings) -join ' | '
    Assert ($run.Code -eq 0 -and $text -match 'may still be processing') "Wrong findings: $text"
}

Test 'an issue in another repository is kept apart from one with the same number here' {
    $run = Invoke-CheckIssues @{ closing = @((New-ClosingReference 7), (New-ClosingReference 7 'other' 'place')) } @{
        'https://github.com/fixture/repo/issues/7' = $closedIssue
        'https://github.com/other/place/issues/7' = $openIssue
    }
    $issues = @($run.Result.issues)
    $there = $issues | Where-Object url -EQ 'https://github.com/other/place/issues/7'
    Assert ($run.Code -eq 0 -and $issues.Count -eq 2 -and $there.state -eq 'OPEN' -and $there.repository -eq 'other/place' -and (@($there.findings) -join ' ') -match 'lives in other/place') "Wrong report: $($run.Result | ConvertTo-Json -Compress -Depth 6)"
    Assert (($issues | Where-Object url -EQ 'https://github.com/fixture/repo/issues/7').state -eq 'CLOSED') 'The local #7 was confused with the other repository''s.'
}

Test 'a pull request that has not merged is reported' {
    $run = Invoke-CheckIssues @{ state = 'OPEN'; mergedAt = $null; closing = @(New-ClosingReference 5) } @{ $issue5 = $openIssue }
    $text = @(@($run.Result.issues)[0].findings) -join ' | '
    Assert ($run.Code -eq 0 -and $text -match 'has not merged; it is OPEN') "Wrong findings: $text"
}

Test 'an open issue with no cause found says to look by hand' {
    $run = Invoke-CheckIssues @{ closing = @(New-ClosingReference 5); manual = @(New-ClosingReference 5) } @{ $issue5 = $openIssue }
    $issue = @($run.Result.issues)[0]
    Assert ($run.Code -eq 0 -and $issue.linkedBy -eq 'manual link' -and $issue.manualLink -and (@($issue.findings) -join ' ') -match 'No cause found') "Wrong report: $($issue | ConvertTo-Json -Compress)"
}

Test 'a warning from gh does not stop landing' {
    $f = New-LandingFixture
    $run = Invoke-Step $f.Rehearsal 'one' $f.Head $f.Base $f.Step (New-FakePullRequest $f.Repository 'one' @{ warn = $true })
    Assert ($run.Land.Code -eq 0 -and $run.Land.Result.merged) "A gh warning broke landing: $($run.Land.Result | ConvertTo-Json -Compress)"
}

Test 'a warning from gh does not stop the dependents check' {
    $f = New-LandedFixture
    $run = Invoke-DeleteBranch $f.Repository $f.Head @() @{ warn = $true }
    Assert ($run.Code -eq 0 -and $run.Result.outcome -eq 'deleted') "A gh warning broke deletion: $($run.Result | ConvertTo-Json -Compress)"
}

Test 'a warning from gh does not stop the issue check' {
    $fake = New-FakeGitHubCli @{
        'repo view fixture/repo' = '!warn {"nameWithOwner":"fixture/repo","defaultBranchRef":{"name":"main"}}'
        'pr view 7 --repo fixture/repo' = '{"number":7,"url":"https://github.com/fixture/repo/pull/7","state":"MERGED","mergedAt":"2026-01-01T00:00:00Z","baseRefName":"main"}'
        'issue view https://github.com/fixture/repo/issues/5' = $closedIssue
        'graphql owner=fixture name=repo number=7' = (New-CommitPage -Closing @(New-ClosingReference 5))
    }
    $run = Invoke-IntegrateScript 'check-issues' @{ Repository = (New-GitHubCheckout); PullRequest = 7; GitHubCli = $fake }
    Assert ($run.Code -eq 0 -and $run.Result.allClosed -and @($run.Result.issues).Count -eq 1) "A gh warning broke the issue check: $($run.Result | ConvertTo-Json -Compress -Depth 6)"
}

Test 'an issue named only in a merged commit''s message is audited, and its reopening found' {
    # #26: GitHub lists no closing issues; only the commit says Fixes #5. The message with
    # no keyword is never sent to be rendered: the stand-in has no rendering for it.
    $timeline = ConvertTo-Json -Compress -Depth 4 -InputObject @(
        (New-TimelineEvent 'closed' '2026-01-01T00:00:02Z' 'github'),
        (New-TimelineEvent 'reopened' '2026-01-05T00:00:00Z' 'someone'))
    $message = "Light the lamp`n`nFixes #5"
    $run = Invoke-CheckIssues @{} @{ $issue5 = $openIssue } @{ $issue5 = $timeline } @{ '' = (New-CommitPage @('Tidy the cell', $message)) } @{ $message = "<p dir=`"auto`">Light the lamp</p>`n$fixes5" }
    $issues = @($run.Result.issues)
    Assert ($run.Code -eq 0 -and $issues.Count -eq 1 -and $issues[0].linkedBy -eq 'commit keyword' -and @($issues[0].commits).Count -eq 1) "Commit reference missed: $($run.Result | ConvertTo-Json -Compress -Depth 6)"
    Assert ((@($issues[0].findings) -join ' ') -match 'reopened by someone at 2026-01-05') "Reopening not reported: $(@($issues[0].findings) -join ' | ')"
}

Test 'only references GitHub resolves to an issue, right after a closing keyword, close it' {
    # The integration run's case, in a commit: GitHub leaves "closed #231" unlinked, as this
    # repository has no #231, and leaves code alone; #24 is a pull request; only the first
    # of "#6, #8" has a keyword; another repository's issue keeps its repository.
    $message = "Deleting it first could have closed #231. A title such as ``Fixes #5: implement retry``. Fixes #24, and fixes #6, #8.`n`nResolves other/place#229"
    $html = "<p dir=`"auto`">Deleting it first could have closed #231. A title such as <code class=`"notranslate`">Fixes #5: implement retry</code>. Fixes $(New-RenderedReference 'fixture/repo' 24 -PullRequest), and fixes $(New-RenderedReference 'fixture/repo' 6), $(New-RenderedReference 'fixture/repo' 8).</p>`n<p dir=`"auto`">Resolves $(New-RenderedReference 'other/place' 229 'other/place#229')</p>"
    $run = Invoke-CheckIssues @{} @{
        'https://github.com/fixture/repo/issues/6' = $closedIssue
        'https://github.com/other/place/issues/229' = $closedIssue
    } @{} @{ '' = (New-CommitPage @($message)) } @{ $message = $html }
    $found = @($run.Result.issues | ForEach-Object { "$($_.repository)#$($_.number)" }) -join ','
    Assert ($run.Code -eq 0 -and $found -eq 'fixture/repo#6,other/place#229') "Expected only #6 and other/place#229: $($run.Result | ConvertTo-Json -Compress -Depth 6)"
}

Test 'a commit message GitHub could not render fails the audit' {
    $run = Invoke-CheckIssues @{} @{} @{} @{ '' = (New-CommitPage @('Fixes #5')) } @{ 'Fixes #5' = '!fail HTTP 502' }
    Assert ($run.Code -eq 1 -and $run.Result.error -match 'Could not have GitHub read the references in the message of commit') "Expected a failure: $($run.Result | ConvertTo-Json -Compress)"
}

Test 'references GitHub lists and commits name are merged, and other repositories kept apart' {
    $run = Invoke-CheckIssues @{} @{
        $issue5 = $closedIssue
        'https://github.com/other/place/issues/5' = $openIssue
    } @{} @{ '' = (New-CommitPage @('Fixes #5', 'Resolves other/place#5') -Closing @(New-ClosingReference 5)) } @{
        'Fixes #5' = $fixes5
        'Resolves other/place#5' = "<p dir=`"auto`">Resolves $(New-RenderedReference 'other/place' 5 'other/place#5')</p>"
    }
    $issues = @($run.Result.issues)
    $here = $issues | Where-Object url -EQ $issue5
    $there = $issues | Where-Object url -EQ 'https://github.com/other/place/issues/5'
    Assert ($run.Code -eq 0 -and $issues.Count -eq 2 -and $here.linkedBy -eq 'description keyword' -and $here.linked -and @($here.commits).Count -eq 1) "Duplicates not merged: $($run.Result | ConvertTo-Json -Compress -Depth 6)"
    Assert ($there.linkedBy -eq 'commit keyword' -and (@($there.findings) -join ' ') -match 'lives in other/place') "Other repository mishandled: $($there | ConvertTo-Json -Compress)"
}

Test 'an issue named only in the merge commit''s message is audited, and its reopening found' {
    # #31: landing writes the title into the merge commit, which GitHub lists apart from
    # the pull request's commits; nothing else names #5.
    $timeline = ConvertTo-Json -Compress -Depth 4 -InputObject @(
        (New-TimelineEvent 'closed' '2026-01-01T00:00:02Z' 'github'),
        (New-TimelineEvent 'reopened' '2026-01-05T00:00:00Z' 'someone'))
    $message = "Merge pull request #7 from fixture/fix`n`nFixes #5: implement retry"
    $html = "<p dir=`"auto`">Merge pull request $(New-RenderedReference 'fixture/repo' 7 -PullRequest) from fixture/fix</p>`n<p dir=`"auto`">Fixes $(New-RenderedReference 'fixture/repo' 5): implement retry</p>"
    $run = Invoke-CheckIssues @{} @{ $issue5 = $openIssue } @{ $issue5 = $timeline } @{ '' = (New-CommitPage @('Implement retry') -MergeMessage $message) } @{ $message = $html }
    $issues = @($run.Result.issues)
    Assert ($run.Code -eq 0 -and -not $run.Result.allClosed -and $run.Result.mergeCommit -eq $mergeOid -and $issues.Count -eq 1) "Merge commit reference missed: $($run.Result | ConvertTo-Json -Compress -Depth 6)"
    Assert ($issues[0].linkedBy -eq 'merge commit keyword' -and $issues[0].inMergeCommit -and @($issues[0].commits).Count -eq 0) "Not attributed to the merge commit: $($issues[0] | ConvertTo-Json -Compress)"
    Assert ((@($issues[0].findings) -join ' ') -match 'reopened by someone at 2026-01-05') "Reopening not reported: $(@($issues[0].findings) -join ' | ')"
}

Test 'an issue GitHub lists, a commit names and the merge commit names is reported once' {
    $message = "Merge pull request #7 from fixture/fix`n`nFixes #5: implement retry"
    $html = "<p dir=`"auto`">Merge pull request $(New-RenderedReference 'fixture/repo' 7 -PullRequest) from fixture/fix</p>`n<p dir=`"auto`">Fixes $(New-RenderedReference 'fixture/repo' 5): implement retry</p>"
    $run = Invoke-CheckIssues @{} @{ $issue5 = $closedIssue } @{} @{ '' = (New-CommitPage @('Fixes #5') -MergeMessage $message -Closing @(New-ClosingReference 5)) } @{ 'Fixes #5' = $fixes5; $message = $html }
    $issues = @($run.Result.issues)
    Assert ($run.Code -eq 0 -and $issues.Count -eq 1 -and $issues[0].linkedBy -eq 'description keyword' -and $issues[0].linked -and $issues[0].inMergeCommit -and @($issues[0].commits).Count -eq 1) "Not reported once with every source: $($run.Result | ConvertTo-Json -Compress -Depth 6)"
}

Test 'a merged pull request whose merge commit GitHub does not give fails the audit' {
    $run = Invoke-CheckIssues @{} @{} @{} @{ '' = (New-CommitPage -NoMergeCommit) }
    Assert ($run.Code -eq 1 -and $run.Result.error -match 'not the commit that merged it') "Expected a failure: $($run.Result | ConvertTo-Json -Compress)"
}

Test 'commits on a second page are read' {
    $run = Invoke-CheckIssues @{} @{ 'https://github.com/fixture/repo/issues/9' = $closedIssue } @{} @{
        '' = (New-CommitPage @('First half') 2 'c2')
        'c2' = (New-CommitPage @('Closes #9') 2)
    } @{ 'Closes #9' = "<p dir=`"auto`">Closes $(New-RenderedReference 'fixture/repo' 9)</p>" }
    Assert ($run.Code -eq 0 -and (@($run.Result.issues | ForEach-Object number) -join ',') -eq '9') "Second page missed: $($run.Result | ConvertTo-Json -Compress -Depth 6)"
}

Test 'commits GitHub could not list fail the audit instead of passing it empty' {
    $run = Invoke-CheckIssues @{} @{} @{} @{ '' = '!fail HTTP 502' }
    Assert ($run.Code -eq 1 -and $run.Result.error -match 'Could not read the commits of #7') "Expected a failure: $($run.Result | ConvertTo-Json -Compress)"
}

Test 'fewer commits than GitHub counts fail the audit' {
    $run = Invoke-CheckIssues @{} @{} @{} @{ '' = (New-CommitPage @('Only one') 3) }
    Assert ($run.Code -eq 1 -and $run.Result.error -match 'Read 1 of the 3 commits') "Expected a failure: $($run.Result | ConvertTo-Json -Compress)"
}

Test 'fewer closing issues than GitHub counts fail the audit' {
    $run = Invoke-CheckIssues @{} @{} @{} @{ '' = (New-CommitPage -Closing @(New-ClosingReference 5) -ClosingTotal 2) }
    Assert ($run.Code -eq 1 -and $run.Result.error -match 'Read 1 of the 2 issues GitHub lists') "Expected a failure: $($run.Result | ConvertTo-Json -Compress)"
}

Test 'a credential in a refused remote URL never reaches the output' {
    # The reviewer's case: the refusal stays, but its message must not carry the secret.
    $repo = New-GitHubCheckout
    # The password holds an @, so a scrubber stopping at the first one would leak its end.
    Invoke-FixtureGit $repo @('remote', 'set-url', 'origin', 'https://user:REVIEW_SENTINEL@NOT_A_CREDENTIAL@gitlab.example/fixture/repo.git') | Out-Null
    $run = Invoke-IntegrateScript 'check-issues' @{ Repository = $repo; PullRequest = 7; GitHubCli = (New-FakeGitHubCli @{}) }
    $text = $run.Result | ConvertTo-Json -Compress
    Assert ($run.Code -eq 1 -and $run.Result.error -match 'not a github.com repository' -and $text -match '\*\*\*@gitlab.example' -and $text -notmatch 'REVIEW_SENTINEL|NOT_A_CREDENTIAL') "The secret leaked or the refusal is unclear: $text"
}

Test 'a credential in a GitHub remote URL is accepted and never reaches the output' {
    $repo = New-GitHubCheckout
    Invoke-FixtureGit $repo @('remote', 'set-url', 'origin', 'https://REVIEW_SENTINEL_NOT_A_CREDENTIAL@github.com/fixture/repo.git') | Out-Null
    Invoke-FixtureGit $repo @('config', '--add', 'remote.origin.pushurl', 'https://REVIEW_SENTINEL_NOT_A_CREDENTIAL@github.com/fixture/repo.git') | Out-Null
    Invoke-FixtureGit $repo @('config', '--add', 'remote.origin.pushurl', 'https://REVIEW_SENTINEL_NOT_A_CREDENTIAL@github.com/fixture/other.git') | Out-Null
    $run = Invoke-IntegrateScript 'check-issues' @{ Repository = $repo; PullRequest = 7; GitHubCli = (New-FakeGitHubCli @{}) }
    $text = $run.Result | ConvertTo-Json -Compress
    Assert ($run.Code -eq 1 -and $run.Result.error -match 'pushes to 2 destinations' -and $text -match '\*\*\*@github.com' -and $text -notmatch 'REVIEW_SENTINEL') "The secret leaked: $text"
}

Test 'a GitHub error while checking issues fails without guessing' {
    $fake = New-FakeGitHubCli @{ 'repo view fixture/repo' = '!fail HTTP 502' }
    $run = Invoke-IntegrateScript 'check-issues' @{ Repository = (New-GitHubCheckout); PullRequest = 7; GitHubCli = $fake }
    Assert ($run.Code -eq 1 -and $run.Result.error -match 'Could not read fixture/repo') "Expected an error: $($run.Result | ConvertTo-Json -Compress)"
}

Write-Output "Integrate tests: $script:Passed passed, $script:Failed failed. Fixtures: $sandbox"
if ($script:Passed + $script:Failed -eq 0) { throw 'No tests matched Filter.' }
if ($script:Failed -gt 0) { exit 1 }
exit 0

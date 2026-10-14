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

## Commits $Files onto branch $Name, created from $From if it does not exist yet, and
## returns the new commit; the checkout is left on main.
function Add-FixtureCommit([string]$Repository, [string]$Name, [string]$From, [hashtable]$Files) {
    $exists = (& git -C $Repository rev-parse --verify --quiet "refs/heads/$Name"); $null = $LASTEXITCODE
    if ($exists) { Invoke-FixtureGit $Repository @('checkout', '--quiet', $Name) | Out-Null }
    else { Invoke-FixtureGit $Repository @('checkout', '--quiet', '-b', $Name, $From) | Out-Null }
    foreach ($file in $Files.Keys) { Write-FixtureText (Join-Path $Repository $file) $Files[$file] }
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

## Runs the survey on $Repository with $PullRequests against base main; returns the exit
## code and the parsed JSON.
function Invoke-Survey([string]$Repository, [object[]]$PullRequests) {
    $records = Join-Path $sandbox ('prs-' + [guid]::NewGuid().ToString('N') + '.json')
    Write-FixtureText $records (ConvertTo-Json -InputObject @($PullRequests) -Depth 5)
    $output = & (Join-Path $PSHOME 'pwsh') -NoProfile -File $survey -Repository $Repository -Base main -PullRequestsJson $records 2>&1
    $code = $LASTEXITCODE
    try { $result = ($output -join "`n") | ConvertFrom-Json }
    catch { throw "Survey output was not JSON (exit $code): $output" }
    return [pscustomobject]@{ Code = $code; Result = $result }
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

Test 'a rehearsed resolution replays when the base is merged into the later pull request' {
    # The skill's merge step relies on this: resolve once while rehearsing, merging the
    # pull request into the base, and the same resolution comes back when the base is
    # merged into the pull request, the other way round, giving the rehearsed tree.
    $repo = New-FixtureRepository @{ 'log.md' = "entry 0`n" }
    $one = Add-FixtureCommit $repo 'one' 'main' @{ 'log.md' = "entry 0`nentry 1`n" }
    $two = Add-FixtureCommit $repo 'two' 'main' @{ 'log.md' = "entry 0`nentry 2`n" }
    $rehearsal = Join-Path $sandbox ('rehearsal-' + [guid]::NewGuid().ToString('N'))
    Invoke-FixtureGit $repo @('worktree', 'add', '--quiet', '--detach', $rehearsal, 'main') | Out-Null
    Invoke-FixtureGit $rehearsal @('-c', 'rerere.enabled=true', 'merge', '--no-ff', '--no-edit', $one) | Out-Null
    $stepOne = (Invoke-FixtureGit $rehearsal @('rev-parse', 'HEAD^{tree}')).Trim()
    & git -C $rehearsal -c rerere.enabled=true merge --no-ff --no-edit $two 2>&1 | Out-Null
    Assert ($LASTEXITCODE -ne 0) 'The two appends did not conflict in the rehearsal.'
    Write-FixtureText (Join-Path $rehearsal 'log.md') "entry 0`nentry 1`nentry 2`n"
    Invoke-FixtureGit $rehearsal @('add', 'log.md') | Out-Null
    Invoke-FixtureGit $rehearsal @('-c', 'rerere.enabled=true', 'commit', '--quiet', '--no-edit') | Out-Null
    $stepTwo = (Invoke-FixtureGit $rehearsal @('rev-parse', 'HEAD^{tree}')).Trim()

    # Merging: #1 lands on main, then main is merged into #2's head.
    Invoke-FixtureGit $repo @('merge', '--quiet', '--no-ff', '--no-edit', $one) | Out-Null
    Assert ((Invoke-FixtureGit $repo @('rev-parse', 'HEAD^{tree}')).Trim() -eq $stepOne) "Main after #1 differs from the rehearsed first step."
    Invoke-FixtureGit $rehearsal @('checkout', '--quiet', '--detach', $two) | Out-Null
    & git -C $rehearsal -c rerere.enabled=true -c rerere.autoUpdate=true merge --no-ff --no-edit main 2>&1 | Out-Null
    $unmerged = (Invoke-FixtureGit $rehearsal @('diff', '--name-only', '--diff-filter=U')).Trim()
    Assert ($unmerged -eq '') "Resolution did not replay; still unmerged: $unmerged"
    Invoke-FixtureGit $rehearsal @('-c', 'rerere.enabled=true', 'commit', '--quiet', '--no-edit') | Out-Null
    $replayed = (Invoke-FixtureGit $rehearsal @('rev-parse', 'HEAD^{tree}')).Trim()
    Assert ($replayed -eq $stepTwo) 'The replayed merge gave a different tree from the rehearsal.'
}

Write-Output "Integrate tests: $script:Passed passed, $script:Failed failed. Fixtures: $sandbox"
if ($script:Passed + $script:Failed -eq 0) { throw 'No tests matched Filter.' }
if ($script:Failed -gt 0) { exit 1 }
exit 0

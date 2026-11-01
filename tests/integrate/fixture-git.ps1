# Test-only transport: validation reads the real configured and effective URLs. Only
# commands that contact a remote receive a temporary rewrite to the fixture's bare repo.
$global:FixtureGitExecutable = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
function global:git {
    $arguments = [string[]]$args
    $repository = '.'
    $command = ''
    for ($i = 0; $i -lt $arguments.Count; $i++) {
        if ($arguments[$i] -eq '-C') { $repository = $arguments[++$i]; continue }
        if ($arguments[$i] -in @('-c', '--git-dir', '--work-tree', '--namespace', '--config-env')) { $i++; continue }
        if ($arguments[$i].StartsWith('-')) { continue }
        $command = $arguments[$i]; break
    }
    $transport = @()
    if ($command -in @('push', 'fetch', 'ls-remote')) {
        $remote = & $global:FixtureGitExecutable -C $repository config --get fixture.remote 2>$null
        if ($LASTEXITCODE -eq 0 -and $remote) {
            $transport = @('-c', "url.$($remote.Replace('\', '/')).insteadOf=https://github.com/fixture/repo.git")
            if ($command -eq 'push') { $transport += @('-c', "url.$($remote.Replace('\', '/')).pushInsteadOf=https://github.com/fixture/repo.git") }
        }
    }
    & $global:FixtureGitExecutable @transport @arguments
    $global:LASTEXITCODE = $LASTEXITCODE
}

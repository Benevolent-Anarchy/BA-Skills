Test 'CLI subprocesses retain literal inputs and isolate plan status resume and clone setup' {
    $fixture=Join-Path $sandbox 'cli'
    New-Item -ItemType Directory -Path $fixture | Out-Null
    $output=& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File "$PSScriptRoot/fixtures/cli-driver.ps1" -SkillRoot $skillRoot -Sandbox $fixture 2>&1
    Assert ($LASTEXITCODE -eq 0) ($output -join "`n")
    $receipt=($output -join "`n") | ConvertFrom-Json -AsHashtable
    Assert ($receipt.creates -eq 2 -and $receipt.boundaryCalls -gt 0 -and $receipt.local.report.plugins.Count -eq 4) 'Incomplete CLI fixture receipt.'
}
Test 'aggregate gate preserves failed stages and rejects syntax errors' {
    $fixture=New-BootstrapFixture 'aggregate gate'
    $gate=Join-Path $root 'tools/verify.ps1'
    Assert (Test-Path $gate) 'Aggregate gate is missing.'
    Write-FixtureText "$fixture/tools/verify.ps1" ([IO.File]::ReadAllText($gate))
    Write-FixtureText "$fixture/tests/run-tests.ps1" "Write-Output 'deliberate stage failure'; exit 1"
    Write-FixtureText "$fixture/tests/bootstrap/run-tests.ps1" "Write-Output 'later stage passed'; exit 0"
    Write-FixtureText "$fixture/tests/integrate/run-tests.ps1" "Write-Output 'integrate stage passed'; exit 0"
    $output=& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File "$fixture/tools/verify.ps1" 2>&1
    Assert ($LASTEXITCODE -eq 1 -and ($output -join "`n") -match 'later stage passed') "Later success hid earlier failure (exit $LASTEXITCODE): $($output -join ' | ')"
    Write-FixtureText "$fixture/tests/run-tests.ps1" "Write-Output 'first stage passed'; exit 0"
    Write-FixtureText "$fixture/tests/integrate/run-tests.ps1" "throw 'integrate stage crashed'"
    $output=& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File "$fixture/tools/verify.ps1" 2>&1
    Assert ($LASTEXITCODE -eq 1 -and ($output -join "`n") -match 'integrate stage crashed') "Earlier successes hid a later crash or lost its error output (exit $LASTEXITCODE): $($output -join ' | ')"
    Write-FixtureText "$fixture/tests/integrate/run-tests.ps1" "Write-Output 'integrate stage passed'; exit 0"
    $output=& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File "$fixture/tools/verify.ps1" 2>&1
    Assert ($LASTEXITCODE -eq 0 -and ($output -join "`n") -match 'Verification passed') "Both passing stages failed (exit $LASTEXITCODE): $($output -join ' | ')"
    Write-FixtureText "$fixture/broken.psm1" 'function Broken {'
    $output=& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File "$fixture/tools/verify.ps1" 2>&1
    Assert ($LASTEXITCODE -eq 1 -and ($output -join "`n") -match 'broken.psm1:1') "Syntax error escaped gate (exit $LASTEXITCODE): $($output -join ' | ')"
    Assert (($output -join "`n") -notmatch 'stage passed') 'Suites ran despite a syntax error.'
    Write-FixtureText "$fixture/broken.psm1" ''
    Write-FixtureText "$fixture/.test-results/broken.ps1" 'function Broken {'
    $output=& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File "$fixture/tools/verify.ps1" 2>&1
    Assert ($LASTEXITCODE -eq 0) 'Ignored temporary fixtures entered syntax gate.'
}
Test 'aggregate gate runs suites together and prints each one whole in suite order' {
    $fixture=New-BootstrapFixture 'parallel gate'
    Write-FixtureText "$fixture/tools/verify.ps1" ([IO.File]::ReadAllText((Join-Path $root 'tools/verify.ps1')))
    # Release finishes last because it waits for integrate to finish; run one at a time, it would wait alone.
    Write-FixtureText "$fixture/tests/run-tests.ps1" @'
Write-Output 'release begins'
$marker=Join-Path $PSScriptRoot 'integrate/finished'
$deadline=[DateTime]::UtcNow.AddSeconds(30)
while (-not (Test-Path -LiteralPath $marker) -and [DateTime]::UtcNow -lt $deadline) {Start-Sleep -Milliseconds 100}
if (-not (Test-Path -LiteralPath $marker)) {Write-Output 'release waited alone'; exit 1}
Start-Sleep -Milliseconds 500
Write-Output 'release ends'
'@
    Write-FixtureText "$fixture/tests/bootstrap/run-tests.ps1" @'
Write-Output 'bootstrap begins'
[Console]::Error.WriteLine('bootstrap warning')
Start-Sleep -Milliseconds 300
Write-Output 'bootstrap ends'
'@
    Write-FixtureText "$fixture/tests/integrate/run-tests.ps1" @'
Write-Output 'integrate begins'
Start-Sleep -Milliseconds 300
Write-Output 'integrate ends'
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'finished'),'')
'@
    $output=@(& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File "$fixture/tools/verify.ps1" 2>&1 | ForEach-Object {"$_"})
    Assert ($LASTEXITCODE -eq 0) "Gate failed: $($output -join ' | ')"
    $expected=@('release begins','release ends','bootstrap begins','bootstrap ends','integrate begins','integrate ends','Verification passed: BA-Skills.')
    Assert ((@($output | Where-Object {$_ -cne 'bootstrap warning'}) -join ' | ') -ceq ($expected -join ' | ')) "Suite output was reordered or interleaved: $($output -join ' | ')"
    $warning=[Array]::IndexOf($output,'bootstrap warning')
    Assert ($warning -gt [Array]::IndexOf($output,'release ends') -and $warning -lt [Array]::IndexOf($output,'integrate begins')) "Error output left its suite: $($output -join ' | ')"
}
Test 'aggregate gate keeps non-ASCII suite output under a non-UTF-8 console code page' {
    $fixture=New-BootstrapFixture 'unicode gate'
    Write-FixtureText "$fixture/tools/verify.ps1" ([IO.File]::ReadAllText((Join-Path $root 'tools/verify.ps1')))
    $text='[char]0x96EA+[char]::ConvertFromUtf32(0x1F600)'
    Write-FixtureText "$fixture/tests/run-tests.ps1" "Write-Output ('unicode:'+$text); [Console]::Error.WriteLine('error:'+$text)"
    Write-FixtureText "$fixture/tests/bootstrap/run-tests.ps1" "Write-Output 'bootstrap passed'"
    Write-FixtureText "$fixture/tests/integrate/run-tests.ps1" "Write-Output 'integrate passed'"
    # The probe gets a console of its own, so code page 850 does not reach suites running alongside this one,
    # and it runs the gate in its own process, so the gate's output reaches it as strings rather than encoded.
    Write-FixtureText "$fixture/probe.ps1" @'
param([string]$Gate,[string]$Result)
[Console]::OutputEncoding=[Text.Encoding]::GetEncoding(850)
$pipeline=[PowerShell]::Create()
$output=@($pipeline.AddScript('param($Gate) & $Gate; "exit $LASTEXITCODE"').AddArgument($Gate).Invoke() | ForEach-Object {"$_"})
$state=@{codePage=[Console]::OutputEncoding.CodePage;output=$output;errors=@($pipeline.Streams.Error | ForEach-Object {"$_"})}
[IO.File]::WriteAllText($Result,(ConvertTo-Json $state),[Text.UTF8Encoding]::new($false))
'@
    $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    foreach ($argument in '-NoProfile','-File',"$fixture/probe.ps1",'-Gate',"$fixture/tools/verify.ps1",'-Result',"$fixture/result.json") {$start.ArgumentList.Add($argument)}
    $start.CreateNoWindow=$true
    $probe=[Diagnostics.Process]::Start($start)
    try {Assert ($probe.WaitForExit(60000) -and $probe.ExitCode -eq 0 -and (Test-Path -LiteralPath "$fixture/result.json")) 'The code page probe did not finish.'}
    finally {if (-not $probe.HasExited) {$probe.Kill($true)}}
    $result=[IO.File]::ReadAllText("$fixture/result.json") | ConvertFrom-Json
    $lines=@($result.output);$snow=[string][char]0x96EA+[char]::ConvertFromUtf32(0x1F600)
    # Shows non-ASCII as code points, so the message reads the same through any console code page.
    $shown=@($lines+$result.errors | ForEach-Object {-join @($_.ToCharArray() | ForEach-Object {if ($_ -lt [char]128) {$_} else {'\u{0:X4}' -f [int]$_}})}) -join ' | '
    Assert ("unicode:$snow" -cin $lines -and "error:$snow" -cin $lines -and 'exit 0' -cin $lines) "Suite output lost characters under code page 850: $shown"
    Assert ($result.codePage -eq 850) "The gate left the console code page at $($result.codePage)."
}
Test 'aggregate gate stops its suites and removes only its own jobs when its host cancels it' {
    $fixture=New-BootstrapFixture 'cancelled gate'
    Write-FixtureText "$fixture/tools/verify.ps1" ([IO.File]::ReadAllText((Join-Path $root 'tools/verify.ps1')))
    # Each stub records its process ID and beats for 30 seconds; integrate's first starts a 30-second child
    # that shares its output, so a gate waiting for that output to close would take as long to stop.
    $stub=@'
$marker=Join-Path $PSScriptRoot 'started.pid'
[IO.File]::WriteAllText("$marker.tmp",[string]$PID); [IO.File]::Move("$marker.tmp",$marker)
for ($beat=1; $beat -le 300; $beat++) {[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'heartbeat'),[string]$beat); Start-Sleep -Milliseconds 100}
'@
    $child=@'
$start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
foreach ($argument in '-NoProfile','-File',(Join-Path $PSScriptRoot 'child.ps1')) {$start.ArgumentList.Add($argument)}
$null=[Diagnostics.Process]::Start($start)
'@
    foreach ($suite in 'tests','tests/bootstrap') {Write-FixtureText "$fixture/$suite/run-tests.ps1" $stub}
    Write-FixtureText "$fixture/tests/integrate/run-tests.ps1" ($child+"`n"+$stub)
    Write-FixtureText "$fixture/tests/integrate/child.ps1" @'
$marker=Join-Path $PSScriptRoot 'child.pid'
[IO.File]::WriteAllText("$marker.tmp",[string]$PID); [IO.File]::Move("$marker.tmp",$marker)
Start-Sleep -Seconds 30
'@
    $suites=@('tests','tests/bootstrap','tests/integrate' | ForEach-Object {Join-Path $fixture $_})
    $markers=@($suites | ForEach-Object {Join-Path $_ 'started.pid'})+(Join-Path $fixture 'tests/integrate/child.pid')
    $beats={@($suites | ForEach-Object {[IO.File]::ReadAllText((Join-Path $_ 'heartbeat'))}) -join ','}
    $runspace=[RunspaceFactory]::CreateRunspace();$runspace.Open()
    function Invoke-InRunspace([string]$Script) {$shell=[PowerShell]::Create();$shell.Runspace=$runspace;try {@($shell.AddScript($Script).Invoke())} finally {$shell.Dispose()}}
    $processes=@();$pipeline=$null
    try {
        $null=Invoke-InRunspace 'Start-ThreadJob -Name unrelated -ScriptBlock {Start-Sleep -Seconds 60}'
        $pipeline=[PowerShell]::Create();$pipeline.Runspace=$runspace
        $null=$pipeline.AddCommand("$fixture/tools/verify.ps1").BeginInvoke()
        $waiting={@($markers+@($suites | ForEach-Object {Join-Path $_ 'heartbeat'}) | Where-Object {-not (Test-Path -LiteralPath $_)})}
        $deadline=[DateTime]::UtcNow.AddSeconds(30)
        while ((& $waiting).Count -and [DateTime]::UtcNow -lt $deadline) {Start-Sleep -Milliseconds 100}
        Assert ((& $waiting).Count -eq 0) "The suites did not all start: $((& $waiting) -join ', ')"
        $processes=@(foreach ($marker in $markers) {[Diagnostics.Process]::GetProcessById([int][IO.File]::ReadAllText($marker))})
        $watch=[Diagnostics.Stopwatch]::StartNew();$pipeline.Stop();$watch.Stop()
        Assert ($watch.Elapsed.TotalSeconds -lt 10) "Cancelling the gate took $($watch.Elapsed.TotalSeconds) seconds."
        Assert (@($processes | Where-Object {-not $_.WaitForExit(10000)}).Count -eq 0) 'A suite or a process it started kept running after the gate was cancelled.'
        $before=& $beats;Start-Sleep -Milliseconds 300
        Assert ((& $beats) -eq $before) 'Suite heartbeats continued after the gate was cancelled.'
        $left=@(Invoke-InRunspace 'Get-Job | ForEach-Object Name')
        Assert (($left -join ',') -eq 'unrelated') "The gate left the wrong jobs in its session: $($left -join ', ')"
    } finally {
        foreach ($process in $processes) {if (-not $process.HasExited) {$process.Kill($true)}}
        if ($pipeline) {$pipeline.Dispose()}
        $null=Invoke-InRunspace 'Get-Job | Remove-Job -Force'
        $runspace.Dispose()
    }
}

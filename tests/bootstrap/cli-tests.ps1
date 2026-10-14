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

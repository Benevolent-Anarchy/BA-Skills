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
    $output=& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File "$fixture/tools/verify.ps1" 2>&1
    Assert ($LASTEXITCODE -eq 1 -and ($output -join "`n") -match 'later stage passed') 'Later success hid earlier failure.'
    Write-FixtureText "$fixture/tests/run-tests.ps1" "Write-Output 'first stage passed'; exit 0"
    $output=& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File "$fixture/tools/verify.ps1" 2>&1
    Assert ($LASTEXITCODE -eq 0 -and ($output -join "`n") -match 'Verification passed') 'Both passing stages failed.'
    Write-FixtureText "$fixture/broken.psm1" 'function Broken {'
    $output=& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File "$fixture/tools/verify.ps1" 2>&1
    Assert ($LASTEXITCODE -eq 1 -and ($output -join "`n") -match 'broken.psm1:1') 'Syntax error escaped gate.'
    Write-FixtureText "$fixture/broken.psm1" ''
    Write-FixtureText "$fixture/.test-results/broken.ps1" 'function Broken {'
    $output=& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File "$fixture/tools/verify.ps1" 2>&1
    Assert ($LASTEXITCODE -eq 0) 'Ignored temporary fixtures entered syntax gate.'
}

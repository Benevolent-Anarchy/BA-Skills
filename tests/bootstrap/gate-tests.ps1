if (Test-Path "$assetRoot/tools/Verification.psm1") {Import-Module "$assetRoot/tools/Verification.psm1" -Force}
Test 'gate rejects missing malformed and downgraded configuration' {
    $path=New-BootstrapFixture 'gate config'
    Expect-Error {Read-ProjectVerificationConfig -Repository $path} 'config'
    foreach ($text in @('{bad','{"schemaVersion":9,"preset":"foundation","requiredChecks":["documentation"]}','{"schemaVersion":1,"preset":"godot","requiredChecks":["documentation"]}','{"schemaVersion":1,"preset":"unknown","requiredChecks":["documentation"]}')) {
        Write-FixtureText "$path/tools/verify.json" $text
        Expect-Error {Read-ProjectVerificationConfig -Repository $path} 'config|required|preset|schema'
    }
    Write-FixtureText "$path/tools/verify.json" '{"schemaVersion":1,"preset":"foundation","requiredChecks":["documentation"]}'
    Assert ((Read-ProjectVerificationConfig $path).preset -ceq 'foundation') 'Valid foundation rejected.'
}
Test 'gate foundation validates docs and fails when its config disappears' {
    $id=New-BootstrapIdentity -Name 'Gate Foundation' -Description 'Purpose' -Parent (New-BootstrapFixture 'gate parent')
    Write-ProjectFoundation $id | Out-Null
    $result=Invoke-ProjectVerification -Repository $id.projectPath
    Assert ($result.Passed -and $result.Stages[0].Name -eq 'documentation') 'Foundation gate failed.'
    Write-FixtureText "$($id.projectPath)/docs/design/broken.md" '[[missing]]'
    Assert (-not (Invoke-ProjectVerification $id.projectPath).Passed) 'Broken docs passed.'
    Remove-Item -LiteralPath "$($id.projectPath)/tools/verify.json"
    Assert (-not (Invoke-ProjectVerification $id.projectPath).Passed) 'Missing config passed.'
}
Test 'gate cannot pass when an engine helper omits required stage results' {
    $id=New-BootstrapIdentity -Name 'Incomplete Engine Results' -Description 'Purpose' -Parent (New-BootstrapFixture 'missing stages')
    Write-ProjectFoundation $id | Out-Null
    Write-FixtureText "$($id.projectPath)/tools/verify.json" '{"schemaVersion":1,"preset":"godot","requiredChecks":["documentation","godot-import","godot-compile","gut-headless"]}'
    Write-FixtureText "$($id.projectPath)/tools/GodotVerification.psm1" 'function Invoke-GodotVerification { @{Passed=$true;Stages=@();Diagnostics=@()} }; Export-ModuleMember -Function Invoke-GodotVerification'
    Assert (-not (Invoke-ProjectVerification $id.projectPath).Passed) 'Missing engine stages passed.'
}

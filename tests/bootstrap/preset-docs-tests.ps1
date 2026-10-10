Import-Module "$skillRoot/scripts/Project.psm1" -Force
Import-Module "$skillRoot/scripts/Presets.psm1" -Force
Test 'preset docs describe selected setup complete gates exports and session readiness' {
    $contract=[IO.File]::ReadAllText("$assetRoot/AGENTS.md.template")
    Assert ($contract.Contains('tools/verify.ps1') -and $contract -match 'fresh session' -and $contract.Contains('dist/')) 'Gate, exports or session-ready PR contract missing.'
    $id=New-BootstrapIdentity -Name 'Documentation Probe' -Description 'Purpose' -Parent $sandbox
    foreach($kind in @('foundation','godot','tauri')) {
        $selection=Resolve-BootstrapPreset $id -Preset $kind
        $manifest=@(Get-ProjectManifest $id -PresetSelection $selection)
        $readme=($manifest | Where-Object path -ceq 'README.md').text
        $agents=($manifest | Where-Object path -ceq 'AGENTS.md').text
        Assert ($readme -notmatch '\{\{PRESET_' -and $agents -notmatch '\{\{PRESET_') 'Unexpanded preset guidance.'
        foreach($text in @($readme,$agents)) {
            Assert ($text.Contains('tools/verify.ps1')) "Missing complete $kind gate command."
            switch($kind) {
                godot {Assert ($text.Contains('Godot 4.7.x') -and $text.Contains('GUT 9.7.1') -and $text.Contains('compilation')) 'Godot setup or native checks omitted.'}
                tauri {Assert ($text.Contains('npm ci') -and $text.Contains('Clippy') -and $text.Contains('native')) 'Tauri setup or native checks omitted.'}
                foundation {Assert ($text.Contains('documentation') -and -not $text.Contains('npm ci')) 'Foundation acquired engine setup.'}
            }
        }
    }
}

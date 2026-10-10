if (Test-Path "$skillRoot/scripts/Presets.psm1") {Import-Module "$skillRoot/scripts/Presets.psm1" -Force}
. "$PSScriptRoot/PresetFixture.ps1"
Test 'preset prerequisite finds godot4 and preserves an explicit executable choice' {
    $old=$env:GODOT;$env:GODOT=$null
    $module=Import-Module "$skillRoot/scripts/Presets.psm1" -Force -PassThru
    try {
        $fixture=@{lookups=[Collections.Generic.List[string]]::new();processCalls=[Collections.Generic.List[string]]::new()}
        $result=& $module {
            param($fixture)
            $script:toolLookupFixture=$fixture
            function script:Get-BootstrapToolPath([string]$Name) {$script:toolLookupFixture.lookups.Add($Name);if($Name -ceq 'godot4'){return 'fixture-godot4.exe'};return $null}
            function script:Invoke-VerificationProcess($Executable,$Arguments,$Directory) {$script:toolLookupFixture.processCalls.Add($Executable);return @{ExitCode=0;Output='4.7.2.stable.official';Executable=$Executable}}
            Get-BootstrapPrerequisites @{name='godot'}
        } $fixture
        Assert ($result.passed -and $result.checks[0].executable -ceq 'fixture-godot4.exe') 'Supported godot4-only installation was rejected.'
        $env:GODOT='missing-selected-godot.exe';$fixture.lookups.Clear()
        $explicit=& $module {Get-BootstrapPrerequisites @{name='godot'}}
        Assert (-not $explicit.passed -and 'godot4' -notin $fixture.lookups) 'Missing explicit executable silently fell back.'
    } finally {$env:GODOT=$old;Import-Module "$skillRoot/scripts/Presets.psm1" -Force}
}
Test 'preset override detection accepts the actual CLI bound-parameter dictionary' {
    function Invoke-BoundPresetProbe([string]$Preset) {Assert-BootstrapPresetOverride @{name='foundation';renderer=$null;appIdentifier=$null} $PSBoundParameters}
    Invoke-BoundPresetProbe -Preset foundation
}
Test 'preset defaults to Godot and validates engine-specific options' {
    $id=New-BootstrapIdentity -Name 'Foo Bar Baz' -Description 'Purpose' -Parent $sandbox
    $default=Resolve-BootstrapPreset $id
    Assert ($default.name -ceq 'godot' -and $default.renderer -ceq 'compatibility') 'Wrong defaults.'
    foreach ($renderer in @('compatibility','forward-plus','mobile')) {Assert ((Resolve-BootstrapPreset $id -Renderer $renderer).renderer -ceq $renderer) 'Renderer ignored.'}
    $foundation=Resolve-BootstrapPreset $id -Preset foundation
    Assert ($null -eq $foundation.renderer -and $null -eq $foundation.appIdentifier) 'Foundation has engine options.'
    Expect-Error {Resolve-BootstrapPreset $id -Preset invalid} 'preset'
    Expect-Error {Resolve-BootstrapPreset $id -Renderer invalid} 'renderer'
    Expect-Error {Resolve-BootstrapPreset $id -Preset tauri -Renderer mobile} 'renderer|Godot'
    Expect-Error {Resolve-BootstrapPreset $id -AppIdentifier 'com.example.app'} 'identifier|Tauri'
    Expect-Error {Resolve-BootstrapPreset $id -Preset foundation -Renderer ''} 'renderer|Godot'
}
Test 'preset derives legal deterministic tool names without changing repository names' {
    foreach ($case in @(@('Foo_Bar','foo-bar'),@('Foo.Bar','foo-bar'),@('1 Project','project-1-project'),@('fn','project-fn'),@('Build','project-build'),@('Deps','project-deps'),@('Examples','project-examples'),@('Incremental','project-incremental'),@('---','project'))) {
        $id=New-BootstrapIdentity -Name $case[0] -Description 'Purpose' -Parent $sandbox
        $selection=Resolve-BootstrapPreset $id -Preset tauri
        Assert ($selection.packageName -ceq $case[1] -and $selection.crateName -ceq $case[1]) 'Illegal tool name.'
        Assert ($selection.appIdentifier -ceq "org.benevolent-anarchy.$($case[1])") 'Wrong suggested identifier.'
        Assert ($id.title -ceq $case[0]) 'Human title changed.'
    }
    $id=New-BootstrapIdentity -Name 'Personal App' -Description 'Purpose' -Parent $sandbox -Owner cicely-f
    Assert ((Resolve-BootstrapPreset $id -Preset tauri).appIdentifier -ceq 'com.cicely-f.personal-app') 'Personal owner ignored.'
    foreach ($bad in @('','one','com..app','com.1app','com.bad_app','com.app!')) {Expect-Error {Resolve-BootstrapPreset $id -Preset tauri -AppIdentifier $bad} 'identifier'}
    Assert ((Resolve-BootstrapPreset $id -Preset tauri -AppIdentifier 'org.example.custom-app').appIdentifier -ceq 'org.example.custom-app') 'Valid override ignored.'
}
Test 'preset resume ignores omitted options and rejects explicit conflicts' {
    $id=New-BootstrapIdentity -Name 'Stored App' -Description 'Purpose' -Parent $sandbox
    $stored=Resolve-BootstrapPreset $id -Preset tauri
    Assert-BootstrapPresetOverride $stored @{}
    Assert-BootstrapPresetOverride $stored @{Preset='TAURI';AppIdentifier=$stored.appIdentifier}
    foreach ($override in @(@{Preset='godot'},@{Renderer='compatibility'},@{AppIdentifier='com.other.app'},@{Preset=''})) {Expect-Error {Assert-BootstrapPresetOverride $stored $override} 'conflict|stored'}
}
Test 'preset prerequisite inspection reports missing tools without installing' {
    $id=New-BootstrapIdentity -Name 'Prerequisites' -Description 'Purpose' -Parent $sandbox
    $fixture=New-PresetPrerequisiteFixture -Missing clippy
    $result=Get-BootstrapPrerequisites (Resolve-BootstrapPreset $id -Preset tauri) $fixture.probe
    Assert (-not $result.passed -and @($result.checks | Where-Object {-not $_.passed}).Count -eq 1) 'Missing Clippy hidden.'
    Assert ($fixture.calls.Count -eq 9 -and $fixture.calls -contains 'msvc' -and $fixture.calls -contains 'windows-sdk' -and $fixture.calls -contains 'webview2') 'Prerequisite checks incomplete.'
    $fixture.calls.Clear()
    Assert ((Get-BootstrapPrerequisites (Resolve-BootstrapPreset $id -Preset foundation) $fixture.probe).passed -and $fixture.calls.Count -eq 0) 'Foundation inspects engine dependencies.'
    $badEngine={param($name) @{passed=$true;version='4.8.0';executable='fixture';message=''}}
    Assert (-not (Get-BootstrapPrerequisites (Resolve-BootstrapPreset $id) $badEngine).passed) 'Unsupported Godot accepted.'
}
Test 'preset prerequisites reject preview Godot before preparation' {
    foreach ($version in @('4.7.2.rc1.official','4.7.3.beta.official','4.7.2','4.8.0.stable.official')) {
        $fixture=New-PresetPrerequisiteFixture -GodotVersion $version
        Assert (-not (Get-BootstrapPrerequisites @{name='godot'} $fixture.probe).passed) "Unsupported preview/version accepted: $version"
    }
    foreach ($version in @('4.7.stable.official','4.7.2.stable.official')) {
        $fixture=New-PresetPrerequisiteFixture -GodotVersion $version
        Assert ((Get-BootstrapPrerequisites @{name='godot'} $fixture.probe).passed) "Supported stable version rejected: $version"
    }
}
Test 'preset Windows SDK probe requires a real x64 import library' {
    $module=Import-Module "$skillRoot/scripts/Presets.psm1" -Force -PassThru
    $root=New-BootstrapFixture 'Windows SDK'
    $fixture=@{root=$null;registryReads=[Collections.Generic.List[string]]::new()}
    try {
        $probe=& $module {
            param($fixture)
            $script:sdkProbeFixture=$fixture
            function script:Get-ItemProperty([string]$LiteralPath,[string]$Name) {
                if ($LiteralPath -cne 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -or $Name -cne 'KitsRoot10') {throw 'Unexpected SDK registry query.'}
                $script:sdkProbeFixture.registryReads.Add($LiteralPath)
                return @{KitsRoot10=$script:sdkProbeFixture.root}
            }
        } $fixture
        $probe={& $module {Invoke-BootstrapPrerequisiteProbe 'windows-sdk'}}.GetNewClosure()
        Assert (-not (& $probe).passed) 'SDK accepted with no registered root.'
        $fixture.root=$root
        Assert (-not (& $probe).passed) 'SDK accepted without libraries.'
        Write-FixtureText "$root/Lib/10.0.26100.0/um/x86/kernel32.lib" 'x86 library'
        Assert (-not (& $probe).passed) 'SDK accepted an x86-only installation.'
        Write-FixtureText "$root/Lib/10.0.26100.0/um/x64/kernel32.lib" 'x64 library'
        $result=& $probe
        Assert ($result.passed -and $result.version -ceq '10.0.26100.0' -and $fixture.registryReads.Count -eq 4) 'Complete registered x64 SDK rejected.'
    } finally {Import-Module "$skillRoot/scripts/Presets.psm1" -Force}
}

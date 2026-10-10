Import-Module "$assetRoot/tools/Verification.psm1" -Force
if (Test-Path "$skillRoot/assets/presets/godot/tools/GodotVerification.psm1") {Import-Module "$skillRoot/assets/presets/godot/tools/GodotVerification.psm1" -Force}
if (Test-Path "$skillRoot/scripts/GodotPreset.psm1") {Import-Module "$skillRoot/scripts/GodotPreset.psm1" -Force}
Import-Module "$skillRoot/scripts/Project.psm1" -Force
function New-GodotGateFixture {
    $f=@{root=(New-BootstrapFixture 'Godot gate');mode='pass';calls=[Collections.Generic.List[object]]::new();config=@{preset='godot';godot=@{versionFamily='4.7';renderedTests=$false}}}
    foreach ($path in @('project.godot','addons/gut/gut_cmdln.gd','addons/gut/plugin.cfg','tools/check_scripts.gd','tools/verify_pre_run.gd','tools/verify_post_run.gd','test/test_main.gd')) {Write-FixtureText "$($f.root)/$path" 'fixture'}
    $f.process={param($exe,$arguments,$cwd,$environment)
        $f.calls.Add(@{arguments=$arguments;environment=$environment})
        if ($arguments -contains '--version') {return @{ExitCode=0;Output=$(if($f.mode -eq 'version'){'4.8.0.stable'}else{'4.7.2.stable.official'});Executable=$exe}}
        if ($f.mode -eq 'import' -and $arguments -contains '--import') {Write-FixtureText "$cwd/bad.svg.import" 'valid=false'}
        if ($environment.ContainsKey('BA_VERIFY_RESULTS')) {
            if ($f.mode -ne 'missing-xml') {Write-FixtureText $environment.BA_VERIFY_RESULTS $(if($f.mode -eq 'zero'){'<testsuites tests="0" failures="0" />'}elseif($f.mode -eq 'malformed'){'broken xml'}else{'<testsuites name="GutTests" tests="1" failures="0" />'})}
            if ($f.mode -ne 'missing-totals') {Write-FixtureText $environment.BA_VERIFY_TOTALS (@{scripts=1;tests=1;asserts=1;seconds=0;hookComplete=($f.mode -ne 'hook');failed=($f.mode -eq 'orphan')} | ConvertTo-Json)}
        }
        $failed=($f.mode -eq 'compile' -and $arguments -contains 'res://tools/check_scripts.gd') -or ($f.mode -eq 'gut' -and $arguments -contains 'res://addons/gut/gut_cmdln.gd') -or ($f.mode -eq 'renderer' -and $arguments -contains '--windowed')
        return @{ExitCode=$(if($failed){1}else{0});Output=$(if($failed){'native failure'}else{''});Executable=$exe}
    }.GetNewClosure()
    return $f
}
Test 'Godot gate rejects incomplete or failed runs even with zero process exit' {
    foreach ($mode in @('version','import','compile','gut','missing-xml','missing-totals','zero','malformed','hook','orphan')) {
        $f=New-GodotGateFixture;$f.mode=$mode
        $r=Invoke-GodotVerification $f.root $f.config $f.process
        Assert (-not $r.Passed -and $r.Diagnostics.Count -gt 0) "Godot gate accepted $mode."
        if ($mode -eq 'zero') {Assert (($r.Diagnostics -join ' ') -match 'no tests|zero tests') 'Missing concrete zero-tests diagnostic.'}
    }
    $f=New-GodotGateFixture
    $r=Invoke-GodotVerification $f.root $f.config $f.process
    Assert ($r.Passed -and $r.Stages.Count -eq 3) 'Clean headless starter required an empty rendered suite.'
    $old=$env:GODOT;try {$env:GODOT='missing-bootstrap-Godot.exe';$r=Invoke-GodotVerification $f.root $f.config $f.process;Assert (-not $r.Passed) 'Missing executable passed.'} finally {$env:GODOT=$old}
}
Test 'Godot gate discovers rendered tests and uses a real renderer' {
    $f=New-GodotGateFixture
    Write-FixtureText "$($f.root)/test/rendered/test_window.gd" 'extends GutTest'
    $r=Invoke-GodotVerification $f.root $f.config $f.process
    Assert ($r.Passed -and 'gut-rendered' -in $r.Stages.Name) 'Rendered tests omitted.'
    $window=@($f.calls | Where-Object {$_.arguments -contains '--windowed'})
    Assert ($window.Count -eq 1 -and '--headless' -notin $window[0].arguments) 'Rendered suite used headless rendering.'
    $f.mode='renderer';Assert (-not (Invoke-GodotVerification $f.root $f.config $f.process).Passed) 'Unavailable renderer passed.'
    $f=New-GodotGateFixture;$f.config.godot.renderedTests=$true
    Assert (-not (Invoke-GodotVerification $f.root $f.config $f.process).Passed) 'Configured empty rendered suite passed.'
}
Test 'Godot starter records renderer title engine source and effective ignores' {
    $id=New-BootstrapIdentity -Name 'Escaped Title' -Description 'Purpose' -Parent $sandbox
    $id.title='Quote " and slash \\ title'
    $selection=Resolve-BootstrapPreset $id -Renderer mobile
    $dir=New-BootstrapFixture 'Godot starter';$id.projectPath=$dir
    Write-ProjectFoundation $id | Out-Null
    $zip="$dir.gut.zip"
    New-DependencyZip $zip @{'gut/addons/gut/plugin.cfg'="[plugin]`nversion=`"9.7.1`"";'gut/addons/gut/LICENSE.md'='licence';'gut/addons/gut/gut_cmdln.gd'='extends SceneTree'}
    $resolution=@{selections=@{gut='9.7.1'};artifacts=@(@{name='gut';uri='https://example.invalid/gut.zip';proof='immutable-commit-no-published-digest'})}
    $download={param($uri,$path) [IO.File]::Copy($zip,$path)}.GetNewClosure()
    $process={param($exe,$arguments,$cwd,$environment)
        foreach ($gd in Get-ChildItem $cwd -Recurse -File -Filter '*.gd' | Where-Object {$_.FullName -notmatch 'verify_probes'}) {Write-FixtureText ($gd.FullName+'.uid') 'uid://fixture'}
        return @{ExitCode=0;Output='';Executable=$exe}
    }
    $result=Initialize-GodotPreset $id $selection $resolution $dir $download $process
    Assert (-not [IO.File]::ReadAllText("$dir/tools/verify.json").Contains("`r")) 'Godot config changes bytes when Git normalizes its newlines.'
    $settings=[IO.File]::ReadAllText("$dir/project.godot")
    Assert ($settings -match '1280' -and $settings -match '800' -and $settings -match '0.0.1' -and $settings -match 'rendering_method="mobile"') 'Starter settings missing.'
    Assert ($settings.Contains('config/name='+($id.title | ConvertTo-Json -Compress))) 'Title not escaped for Godot.'
    Assert ('test/test_main.gd.uid' -in $result.trackedPaths -and 'addons/gut/LICENSE.md' -in $result.trackedPaths -and 'docs/.gdignore' -in $result.trackedPaths) 'Required source missing.'
    Invoke-FixtureGit $dir @('init','-b','main') | Out-Null
    foreach ($path in @('.godot/cache','assets/name.translation','export_credentials.cfg','nested/dist/export','dist/export')) {
        Write-FixtureText "$dir/$path" 'generated';Invoke-FixtureGit $dir @('check-ignore','--no-index','--',$path) | Out-Null
    }
    foreach ($path in @('test/test_main.gd.uid','assets/source.svg.import','export_presets.cfg','app/source.gd')) {
        Write-FixtureText "$dir/$path" 'source';Invoke-FixtureGit $dir @('add','--',$path) | Out-Null
    }
}

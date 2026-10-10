Import-Module "$assetRoot/tools/Verification.psm1" -Force
if (Test-Path "$skillRoot/assets/presets/godot/tools/GodotVerification.psm1") {Import-Module "$skillRoot/assets/presets/godot/tools/GodotVerification.psm1" -Force}
if (Test-Path "$skillRoot/scripts/GodotPreset.psm1") {Import-Module "$skillRoot/scripts/GodotPreset.psm1" -Force}
Import-Module "$skillRoot/scripts/Project.psm1" -Force
function New-GodotGateFixture {
    $f=@{root=(New-BootstrapFixture 'Godot gate');mode='pass';version='4.7.2.stable.official';renderedMode='';calls=[Collections.Generic.List[object]]::new();config=@{preset='godot';godot=@{versionFamily='4.7';renderedTests=$false}}}
    foreach ($path in @('project.godot','addons/gut/gut_cmdln.gd','addons/gut/plugin.cfg','tools/check_scripts.gd','tools/verify_pre_run.gd','tools/verify_post_run.gd','test/test_main.gd')) {Write-FixtureText "$($f.root)/$path" 'fixture'}
    $f.process={param($exe,$arguments,$cwd,$environment)
        $f.calls.Add(@{arguments=$arguments;environment=$environment})
        if ($arguments -contains '--version') {return @{ExitCode=0;Output=$(if($f.mode -eq 'version'){'4.8.0.stable'}else{$f.version});Executable=$exe}}
        if ($f.mode -eq 'import' -and $arguments -contains '--import') {Write-FixtureText "$cwd/bad.svg.import" 'valid=false'}
        if ($environment.ContainsKey('BA_VERIFY_RESULTS')) {
            $reportMode=if($arguments -contains '--windowed' -and $f.renderedMode){$f.renderedMode}else{$f.mode}
            $xml=switch ($reportMode) {
                zero {'<testsuites tests="0" failures="0" />'}
                malformed {'broken xml'}
                empty {'<testsuites name="GutTests" tests="1" failures="0" />'}
                mismatch {'<testsuites name="GutTests" tests="2" failures="0"><testsuite tests="1" failures="0"><testcase name="passes" assertions="1" status="pass" /></testsuite></testsuites>'}
                skipped {'<testsuites name="GutTests" tests="1" failures="0"><testsuite tests="1" failures="0" skipped="1"><testcase name="pending" assertions="0"><skipped message="pending" /></testcase></testsuite></testsuites>'}
                pending {'<testsuites name="GutTests" tests="1" failures="0"><testsuite tests="1" failures="0" skipped="1"><testcase name="pending" assertions="0" status="pending" /></testsuite></testsuites>'}
                no-assertions {'<testsuites name="GutTests" tests="1" failures="0"><testsuite tests="1" failures="0"><testcase name="risky" assertions="0" status="risky" /></testsuite></testsuites>'}
                mixed {'<testsuites name="GutTests" tests="2" failures="0"><testsuite tests="2" failures="0" skipped="1"><testcase name="passes" assertions="1" status="pass" /><testcase name="pending" assertions="0" status="pending"><skipped message="pending" /></testcase></testsuite></testsuites>'}
                default {'<testsuites name="GutTests" tests="1" failures="0"><testsuite tests="1" failures="0"><testcase name="passes" assertions="1" status="pass" /></testsuite></testsuites>'}
            }
            $tests=if($reportMode -in @('mixed','mismatch')){2}else{1}
            $asserts=if($reportMode -in @('skipped','pending','no-assertions')){0}else{1}
            if ($f.mode -ne 'missing-xml') {Write-FixtureText $environment.BA_VERIFY_RESULTS $xml}
            if ($f.mode -ne 'missing-totals') {Write-FixtureText $environment.BA_VERIFY_TOTALS (@{scripts=1;tests=$tests;asserts=$asserts;seconds=0;hookComplete=($f.mode -ne 'hook');failed=($f.mode -eq 'orphan')} | ConvertTo-Json)}
        }
        $failed=($f.mode -eq 'compile' -and $arguments -contains 'res://tools/check_scripts.gd') -or ($f.mode -eq 'gut' -and $arguments -contains 'res://addons/gut/gut_cmdln.gd') -or ($f.mode -eq 'renderer' -and $arguments -contains '--windowed')
        return @{ExitCode=$(if($failed){1}else{0});Output=$(if($failed){'native failure'}else{''});Executable=$exe}
    }.GetNewClosure()
    return $f
}
Test 'Godot gate accepts stable zero-patch and patch versions and rejects prereleases' {
    foreach ($case in @(
        @{version='4.7.stable.official.e6aa06d3b';passed=$true},
        @{version='4.7.stable';passed=$true},
        @{version='4.7.0.stable.official';passed=$true},
        @{version=" 4.7.2.stable.mono.official.71f334935`n";passed=$true},
        @{version='4.7.rc2.official.abc';passed=$false},
        @{version='4.7.1.beta1.official.abc';passed=$false},
        @{version='4.7.2.stableish.official';passed=$false},
        @{version='4.8.stable.official';passed=$false}
    )) {
        $f=New-GodotGateFixture;$f.version=$case.version
        $r=Invoke-GodotVerification $f.root $f.config $f.process
        Assert ($r.Passed -eq $case.passed) "Wrong gate decision for $($case.version): $($r.Diagnostics -join ' ')"
    }
}
Test 'Godot gate rejects missing testcase records and inconsistent reported counts' {
    foreach ($mode in @('empty','mismatch')) {
        $f=New-GodotGateFixture;$f.mode=$mode
        $r=Invoke-GodotVerification $f.root $f.config $f.process
        Assert (-not $r.Passed -and ($r.Diagnostics -join ' ') -match 'testcase|test counts') "Godot gate accepted $mode report."
    }
}
Test 'Godot gate requires an executed test and a real assertion in each suite' {
    foreach ($mode in @('skipped','pending','no-assertions')) {
        $f=New-GodotGateFixture;$f.mode=$mode
        $r=Invoke-GodotVerification $f.root $f.config $f.process
        Assert (-not $r.Passed) "Godot gate accepted $mode suite."
        $diagnostic=if($mode -eq 'no-assertions'){'zero assertions'}else{'zero executed non-skipped tests'}
        Assert (($r.Diagnostics -join ' ') -match $diagnostic) "Missing diagnostic for $mode."
    }
    $f=New-GodotGateFixture;$f.mode='mixed'
    Assert (Invoke-GodotVerification $f.root $f.config $f.process).Passed 'Real assertions mixed with pending tests were rejected.'
    $f=New-GodotGateFixture;$f.renderedMode='pending'
    Write-FixtureText "$($f.root)/test/rendered/test_window.gd" 'extends GutTest'
    $r=Invoke-GodotVerification $f.root $f.config $f.process
    Assert (-not $r.Passed -and ($r.Diagnostics -join ' ') -match 'gut-rendered.*zero executed non-skipped tests') 'Pending-only rendered suite passed.'
}
function New-GodotPresetFixture([string]$Renderer='compatibility') {
    $id=New-BootstrapIdentity -Name 'Godot source' -Description 'Purpose' -Parent $sandbox
    $dir=New-BootstrapFixture 'Godot source';$id.projectPath=$dir
    Write-ProjectFoundation $id | Out-Null
    $zip="$dir.gut.zip"
    New-DependencyZip $zip @{'gut/addons/gut/plugin.cfg'="[plugin]`nversion=`"9.7.1`"";'gut/addons/gut/LICENSE.md'='licence';'gut/addons/gut/gut_cmdln.gd'='extends SceneTree'}
    $f=@{id=$id;root=$dir;selection=(Resolve-BootstrapPreset $id -Renderer $Renderer);zip=$zip;downloads=0;failDownload=$false;checkpoints=@{};saved=[Collections.Generic.List[string]]::new();resolution=@{selections=@{gut='9.7.1'};artifacts=@(@{name='gut';uri='https://example.invalid/gut.zip';proof='immutable-commit-no-published-digest'})}}
    $f.download={param($uri,$path) $f.downloads++;if($f.failDownload){[IO.File]::WriteAllText($path,'partial download');throw 'Transient GUT download failure'};[IO.File]::Copy($f.zip,$path)}.GetNewClosure()
    $f.process={param($exe,$arguments,$cwd,$environment)
        foreach ($gd in Get-ChildItem $cwd -Recurse -File -Filter '*.gd' | Where-Object {$_.FullName -notmatch 'verify_probes'}) {Write-FixtureText ($gd.FullName+'.uid') 'uid://fixture'}
        return @{ExitCode=0;Output='';Executable=$exe}
    }
    $f.checkpoint={param($phase,$value) $f.saved.Add($phase)}.GetNewClosure()
    return $f
}
Test 'Godot renderer settings preserve the upstream mobile defaults' {
    foreach ($renderer in @('compatibility','forward-plus','mobile')) {
        $f=New-GodotPresetFixture $renderer
        Initialize-GodotPreset $f.id $f.selection $f.resolution $f.root $f.download $f.process | Out-Null
        $settings=[IO.File]::ReadAllText("$($f.root)/project.godot")
        $desktop=[regex]::Match($settings,'(?m)^renderer/rendering_method="([a-z_]+)"').Groups[1].Value
        $mobile=[regex]::Match($settings,'(?m)^renderer/rendering_method\.mobile="([a-z_]+)"').Groups[1].Value
        if ($renderer -eq 'compatibility') {Assert ($desktop -ceq 'gl_compatibility' -and $mobile -ceq 'gl_compatibility') 'Compatibility did not select its renderer on both device families.'}
        elseif ($renderer -eq 'mobile') {Assert ($desktop -ceq 'mobile' -and $mobile -ceq '') 'Mobile preset replaced the native mobile default.'}
        else {Assert ($desktop -ceq '' -and $mobile -ceq '') 'Forward Plus replaced the native desktop/mobile defaults.'}
    }
}
Test 'Godot source rollback restores foundation bytes and retries a failed download' {
    $f=New-GodotPresetFixture;$f.failDownload=$true
    $before=@{};foreach($path in @('.gitignore','tools/verify.json')){$before[$path]=[Convert]::ToBase64String([IO.File]::ReadAllBytes("$($f.root)/$path"))}
    Expect-Error {Initialize-GodotPreset $f.id $f.selection $f.resolution $f.root $f.download $f.process -Checkpoints $f.checkpoints -Checkpoint $f.checkpoint} 'Transient GUT download failure'
    foreach($path in $before.Keys){Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes("$($f.root)/$path")) -ceq $before[$path]) "Source failure changed foundation $path."}
    Assert (-not (Test-Path "$($f.root)/project.godot") -and -not (Test-Path "$($f.root)/addons/gut")) 'Failed source step left recipe files.'
    Assert (@(Get-ChildItem "$($f.root).dependencies" -File -Filter '*.partial').Count -eq 0) 'Failed download retained a partial artifact.'
    Assert (-not $f.checkpoints.ContainsKey('godot-source-started') -and $f.checkpoints.ContainsKey('godot-source-failed') -and 'godot-source-failed' -in $f.saved) 'Failed source step did not persist a retryable outcome.'
    $f.failDownload=$false
    $result=Initialize-GodotPreset $f.id $f.selection $f.resolution $f.root $f.download $f.process -Checkpoints $f.checkpoints -Checkpoint $f.checkpoint
    Assert ($f.downloads -eq 2 -and 'test/test_main.gd.uid' -in $result.trackedPaths -and $f.checkpoints.ContainsKey('godot-ready')) 'Failed download could not resume the same source preparation.'
}
Test 'Godot source rollback retains acquired bytes for retry after expansion fails' {
    $f=New-GodotPresetFixture
    $fixture=$f
    $checkpoint={param($phase,$value)
        $fixture.saved.Add($phase)
        if($phase -ceq 'gut-acquired') {Write-FixtureText "$($fixture.root).dependencies/gut/partial.txt" 'Partial extraction'}
    }.GetNewClosure()
    Expect-Error {Initialize-GodotPreset $f.id $f.selection $f.resolution $f.root $f.download $f.process -Checkpoints $f.checkpoints -Checkpoint $checkpoint} 'destination already exists'
    Assert ($f.checkpoints.ContainsKey('gut-acquired') -and (Test-Path "$($f.root).dependencies/gut.zip")) 'Rollback discarded verified GUT bytes.'
    Assert (-not (Test-Path "$($f.root).dependencies/gut") -and -not $f.checkpoints.ContainsKey('godot-source-started')) 'Expansion failure retained an incomplete source step.'
    $digest=(Get-FileHash "$($f.root).dependencies/gut.zip" -Algorithm SHA256).Hash
    Initialize-GodotPreset $f.id $f.selection $f.resolution $f.root $f.download $f.process -Checkpoints $f.checkpoints -Checkpoint $f.checkpoint | Out-Null
    Assert ($f.downloads -eq 1 -and (Get-FileHash "$($f.root).dependencies/gut.zip" -Algorithm SHA256).Hash -ceq $digest -and $f.checkpoints.ContainsKey('godot-ready')) 'Retry reacquired GUT instead of reusing verified bytes.'
}
Test 'Godot source rollback preserves a GUT expansion that predates the attempt' {
    $f=New-GodotPresetFixture;$f.failDownload=$true
    $sentinel="$($f.root).dependencies/gut/unresolved-evidence.txt"
    Write-FixtureText $sentinel 'Unresolved expansion evidence'
    Expect-Error {Initialize-GodotPreset $f.id $f.selection $f.resolution $f.root $f.download $f.process -Checkpoints $f.checkpoints -Checkpoint $f.checkpoint} 'Transient GUT download failure|expansion.*exists'
    Assert ((Test-Path -LiteralPath $sentinel) -and [IO.File]::ReadAllText($sentinel) -ceq 'Unresolved expansion evidence') 'Source rollback deleted an expansion from before the attempt.'
    Assert (-not $f.checkpoints.ContainsKey('godot-source-started')) 'Preserving unknown expansion left a new source-started marker.'
}
Test 'Godot source rollback preserves retained archive digest mismatch evidence' {
    $f=New-GodotPresetFixture
    $archive="$($f.root).dependencies/gut.zip"
    $receipt=Receive-BootstrapArtifact $f.resolution.artifacts[0] $archive $f.download
    $f.checkpoints['gut-acquired']=$receipt
    [byte[]]$corrupted=@(1,255,0,128,17)
    [IO.File]::WriteAllBytes($archive,$corrupted)
    Expect-Error {Initialize-GodotPreset $f.id $f.selection $f.resolution $f.root $f.download $f.process -Checkpoints $f.checkpoints -Checkpoint $f.checkpoint} 'retained digest mismatch'
    Assert ((Test-Path -LiteralPath $archive) -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($archive)) -ceq 'Af8AgBE=') 'Source rollback deleted or changed the archive with a digest mismatch.'
    Assert ($f.downloads -eq 1 -and $f.checkpoints['gut-acquired'].sha256 -ceq $receipt.sha256) 'Source rollback replaced the retained acquisition receipt or redownloaded mismatching bytes.'
}
Test 'Godot source rollback preserves an unreceipted archive from before the attempt' {
    $f=New-GodotPresetFixture
    $archive="$($f.root).dependencies/gut.zip"
    Write-FixtureText $archive 'Unresolved acquisition evidence'
    Expect-Error {Initialize-GodotPreset $f.id $f.selection $f.resolution $f.root $f.download $f.process -Checkpoints $f.checkpoints -Checkpoint $f.checkpoint} 'Existing artifact has no retained digest'
    Assert ((Test-Path -LiteralPath $archive) -and [IO.File]::ReadAllText($archive) -ceq 'Unresolved acquisition evidence') 'Source rollback deleted an archive from before the attempt.'
    Assert ($f.downloads -eq 0 -and -not $f.checkpoints.ContainsKey('gut-acquired')) 'Unknown archive was downloaded again or accepted without proof.'
}
Test 'Godot source preserves completed output when its completion checkpoint fails' {
    $f=New-GodotPresetFixture
    $checkpoint={param($phase,$value) if($phase -ceq 'godot-source'){throw 'Checkpoint storage failure'}}
    Expect-Error {Initialize-GodotPreset $f.id $f.selection $f.resolution $f.root $f.download $f.process -Checkpoints $f.checkpoints -Checkpoint $checkpoint} 'Checkpoint storage failure'
    Assert ($f.checkpoints.ContainsKey('godot-source') -and (Test-Path "$($f.root)/project.godot") -and (Test-Path "$($f.root)/addons/gut/gut_cmdln.gd")) 'Completed source was rolled back on checkpoint failure.'
    $f=New-GodotPresetFixture;$f.checkpoints['godot-source-started']=@{startedAt='unknown'}
    Expect-Error {Initialize-GodotPreset $f.id $f.selection $f.resolution $f.root $f.download $f.process -Checkpoints $f.checkpoints -Checkpoint $f.checkpoint} 'no completion receipt'
    Assert ($f.downloads -eq 0 -and $f.checkpoints.ContainsKey('godot-source-started')) 'Unknown interrupted source was rerun or discarded.'
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
    Write-FixtureText "$dir/.git/empty-excludes" ''
    Invoke-FixtureGit $dir @('config','core.excludesFile',"$dir/.git/empty-excludes") | Out-Null
    foreach ($path in @('.godot/cache','assets/name.translation','export_credentials.cfg','nested/dist/export','dist/export')) {
        Write-FixtureText "$dir/$path" 'generated';Invoke-FixtureGit $dir @('check-ignore','--no-index','--',$path) | Out-Null
    }
    foreach ($path in @('test/test_main.gd.uid','assets/source.svg.import','assets/obj/ship.obj.import','addons/x/bin/lib.dll','export_presets.cfg','app/source.gd','bin/source.gd','obj/source.gd')) {
        Write-FixtureText "$dir/$path" 'source';Invoke-FixtureGit $dir @('add','--',$path) | Out-Null
    }
}

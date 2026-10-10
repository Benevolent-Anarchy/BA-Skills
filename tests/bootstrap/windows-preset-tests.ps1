. "$PSScriptRoot/PresetFixture.ps1"
Import-Module "$skillRoot/scripts/Project.psm1" -Force
Import-Module "$skillRoot/scripts/Presets.psm1" -Force

foreach($recipePreset in @('godot','tauri')) {
Test "preset $recipePreset preserves source and clone bytes from a Windows CRLF skill checkout" {
    $seed=New-BootstrapFixture 'recipe Git seed'
    $clone=Join-Path $sandbox ('recipe CRLF clone '+[guid]::NewGuid().ToString('N'))
    $empty=Join-Path $sandbox 'empty-review-attributes';Write-FixtureText $empty ''
    [IO.Directory]::CreateDirectory("$seed/skills") | Out-Null
    Copy-Item -LiteralPath $skillRoot -Destination "$seed/skills/ba-bootstrap" -Recurse
    Invoke-FixtureGit $seed @('init','--quiet','-b','main') | Out-Null
    Invoke-FixtureGit $seed @('-c',"core.attributesFile=$empty",'-c','core.autocrlf=true','add','--all') | Out-Null
    Invoke-FixtureGit $seed @('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','-c','commit.gpgsign=false','commit','--quiet','-m','Recipe source') | Out-Null
    Invoke-FixtureGit $sandbox @('-c',"core.attributesFile=$empty",'-c','core.autocrlf=true','clone','--quiet',$seed,$clone) | Out-Null
    $clonedSkill="$clone/skills/ba-bootstrap"
    Assert ([IO.File]::ReadAllText("$clonedSkill/assets/presets/godot/project.godot.template").Contains("`r`n")) 'Fixture did not exercise a CRLF recipe checkout.'
    foreach($preset in @($recipePreset)) {
        $id=New-BootstrapIdentity -Name "CRLF $preset" -Description 'Purpose' -Parent $sandbox
        $id.projectPath=New-BootstrapFixture "CRLF $preset project"
        $selection=Resolve-BootstrapPreset $id -Preset $preset
        Write-ProjectFoundation $id -PresetSelection $selection | Out-Null
        $module=Import-Module "$clonedSkill/scripts/$((Get-Culture).TextInfo.ToTitleCase($preset))Preset.psm1" -Force -PassThru
        try {
            if($preset -eq 'godot') {
                $zip="$($id.projectPath).gut.zip"
                New-DependencyZip $zip @{'gut/addons/gut/plugin.cfg'="[plugin]`nversion=`"9.7.1`"";'gut/addons/gut/LICENSE.md'='licence';'gut/addons/gut/gut_cmdln.gd'='extends SceneTree'}
                $resolution=@{selections=@{gut='9.7.1'};artifacts=@(@{name='gut';uri='https://example.invalid/gut.zip';proof='immutable-commit-no-published-digest'})}
                $download={param($uri,$path) [IO.File]::Copy($zip,$path)}.GetNewClosure()
                $process={param($exe,$arguments,$cwd,$environment)
                    foreach($gd in Get-ChildItem $cwd -Recurse -File -Filter '*.gd' | Where-Object {$_.FullName -notmatch 'verify_probes'}) {Write-FixtureText ($gd.FullName+'.uid') 'uid://fixture'}
                    return @{ExitCode=0;Output='';Executable=$exe}
                }
                $result=& $module {param($id,$selection,$resolution,$download,$process) Initialize-GodotPreset $id $selection $resolution $id.projectPath $download $process} $id $selection $resolution $download $process
            } else {
                $f=New-TauriProcessFixture
                $resolution=@{preset='tauri';selections=@{tauri='3.0.0';generator='4.0.0'};artifacts=@(@{name='generator';version='4.0.0';uri='https://example.invalid/generator.tgz';proof='published-integrity';integrity=('sha512-'+[Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData([byte[]]@(1,2,3))))})}
                $download={param($uri,$path) [IO.File]::WriteAllBytes($path,[byte[]]@(1,2,3))}
                $result=& $module {param($id,$selection,$resolution,$process,$download) Initialize-TauriPreset $id $selection $resolution $id.projectPath $process $download} $id $selection $resolution $f.process $download
            }
            $repo=$id.projectPath
            Invoke-FixtureGit $repo @('init','--quiet','-b','main') | Out-Null
            Invoke-FixtureGit $repo @('config','core.autocrlf','true') | Out-Null
            Invoke-FixtureGit $repo @('config','core.attributesFile',$empty) | Out-Null
            Invoke-FixtureGit $repo @('add','--all') | Out-Null
            foreach($path in $result.trackedPaths) {
                Assert ((Invoke-FixtureGit $repo @('rev-parse',":$path")) -ceq (Invoke-FixtureGit $repo @('hash-object','--no-filters',$path))) "CRLF recipe changed initial Git bytes: $preset/$path"
            }
            Invoke-FixtureGit $repo @('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','-c','commit.gpgsign=false','commit','--quiet','-m','Starter') | Out-Null
            $fresh="$repo fresh clone"
            Invoke-FixtureGit $sandbox @('-c',"core.attributesFile=$empty",'-c','core.autocrlf=true','clone','--quiet',$repo,$fresh) | Out-Null
            foreach($path in $result.trackedPaths) {Assert ((Get-FileHash -LiteralPath "$repo/$path").Hash -ceq (Get-FileHash -LiteralPath "$fresh/$path").Hash) "Fresh clone bytes differ: $preset/$path"}
        } finally {
            Remove-Module $module
            Import-Module "$skillRoot/scripts/$((Get-Culture).TextInfo.ToTitleCase($preset))Preset.psm1" -Force
        }
    }
}
}

Test 'Tauri preparation preserves unknown binary assets through frozen replay and Git' {
    $f=New-TauriPreparationFixture
    $base=$f.process
    [byte[]]$bytes=@(0,255,128,13,10,129)
    $paths=@('src/assets.dat','src/assets/payload','src/assets/font.ttf','src/assets/module.wasm','src-tauri/icons/extra.bmp')
    $process={param($exe,$arguments,$cwd,$environment)
        $result=& $base $exe $arguments $cwd $environment
        if($arguments -contains 'create-tauri-app' -and $arguments -contains '.') {foreach($path in $paths) {[IO.Directory]::CreateDirectory((Split-Path "$cwd/$path" -Parent)) | Out-Null;[IO.File]::WriteAllBytes("$cwd/$path",$bytes)}}
        return $result
    }.GetNewClosure()
    $checkpoints=@{}
    $result=Initialize-TauriPreset $f.identity $f.selection $f.resolution $f.root $process $f.download -Checkpoints $checkpoints
    $expected=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    foreach($path in $paths) {Assert ((Get-FileHash -LiteralPath "$($f.root)/$path").Hash -ceq $expected) "Generator binary bytes changed: $path";Assert ($path -in $result.trackedPaths) "Binary source omitted: $path"}
    Initialize-TauriPreset $f.identity $f.selection $f.resolution $f.root $process $f.download -Checkpoints $checkpoints | Out-Null
    Invoke-FixtureGit $f.root @('init','--quiet','-b','main') | Out-Null
    Invoke-FixtureGit $f.root @('add','--all') | Out-Null
    foreach($path in $paths) {Assert ((Invoke-FixtureGit $f.root @('rev-parse',":$path")) -ceq (Invoke-FixtureGit $f.root @('hash-object','--no-filters',$path))) "Binary Git bytes changed: $path"}
}

foreach($reportCase in @(
    @{name='skipped-only';xml='<testsuites tests="1" skipped="1" failures="0" errors="0"><testsuite tests="1" skipped="1"><testcase name="skipped"><skipped /></testcase></testsuite></testsuites>'},
    @{name='empty-body';xml='<testsuites tests="1" failures="0" errors="0" />'},
    @{name='inconsistent-count';xml='<testsuites tests="2" failures="0" errors="0"><testsuite tests="1"><testcase name="only one" /></testsuite></testsuites>'}
)) {
Test "Tauri gate rejects $($reportCase.name) frontend test evidence" {
    $f=New-TauriPreparationFixture
    Initialize-TauriPreset $f.identity $f.selection $f.resolution $f.root $f.process $f.download | Out-Null
    $config=Read-ProjectVerificationConfig $f.root
    $base=$f.process
    foreach($report in @($reportCase.xml)) {
        $process={param($exe,$arguments,$cwd,$environment)
            $result=& $base $exe $arguments $cwd $environment
            if($environment.ContainsKey('BA_TAURI_RESULTS')) {Write-FixtureText $environment.BA_TAURI_RESULTS $report}
            return $result
        }.GetNewClosure()
        $result=Invoke-TauriVerification $f.root $config $process
        Assert (-not $result.Passed -and ($result.Diagnostics -join ' ') -match 'test|report') 'Frontend gate accepted skipped or incomplete evidence.'
    }
}
}

Test 'Tauri gate permits skipped tests when an actual test also executed' {
    $f=New-TauriPreparationFixture
    Initialize-TauriPreset $f.identity $f.selection $f.resolution $f.root $f.process $f.download | Out-Null
    $base=$f.process
    $process={param($exe,$arguments,$cwd,$environment)
        $result=& $base $exe $arguments $cwd $environment
        if($environment.ContainsKey('BA_TAURI_RESULTS')) {Write-FixtureText $environment.BA_TAURI_RESULTS '<testsuites tests="2" failures="0" errors="0"><testsuite tests="2" skipped="1"><testcase name="executed" /><testcase name="skipped"><skipped /></testcase></testsuite></testsuites>'}
        return $result
    }.GetNewClosure()
    Assert ((Invoke-TauriVerification $f.root (Read-ProjectVerificationConfig $f.root) $process).Passed) 'Skipped tests prevented a genuinely executed passing test.'
}

Test 'Tauri preparation rejects invalid UTF8 in supported generator text' {
    $f=New-TauriPreparationFixture;$base=$f.process
    $process={param($exe,$arguments,$cwd,$environment)
        $result=& $base $exe $arguments $cwd $environment
        if($arguments -contains 'create-tauri-app' -and $arguments -contains '.') {[IO.File]::WriteAllBytes("$cwd/src/retained.ts",[byte[]]@(255,128,13,10))}
        return $result
    }.GetNewClosure()
    Expect-Error {Initialize-TauriPreset $f.identity $f.selection $f.resolution $f.root $process $f.download} 'UTF|decode|invalid|translate'
}

Test 'preset creation rejects filtered initial commit blobs before recording or pushing' {
    $f=New-PresetRecoveryFixture
    $gitBase=$f.api.git
    $git={param($repository,$arguments)
        if($repository -eq $f.identity.projectPath -and $arguments[0] -eq 'add') {
            Write-FixtureText "$repository/.git/info/attributes" "README.md filter=review`n"
            Invoke-FixtureGit $repository @('config','filter.review.clean','echo review-filter-changed-source') | Out-Null
        }
        & $gitBase $repository $arguments
    }.GetNewClosure()
    $result=Invoke-Bootstrap $f.identity $f.api.stateRoot $f.api.request $git $f.api.obsidianSetup -PresetSelection $f.selection -Prepare $f.prepare -Process $f.process -PrerequisiteProbe $f.probe
    Assert (($result.pending -join ' ') -match 'blob differs') 'Filtered initial bytes were accepted.'
    Assert (@($f.api.gitCalls | Where-Object {$_.arguments[0] -eq 'push'}).Count -eq 0) 'Pushed a filtered initial commit.'
    $journal=Read-BootstrapJournal $result.journalPath
    Assert (-not $journal.refs.ContainsKey('privateMain')) 'Recorded an initial ref before exact-blob validation.'
}

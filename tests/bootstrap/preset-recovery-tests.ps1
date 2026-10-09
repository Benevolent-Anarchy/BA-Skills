Import-Module "$skillRoot/scripts/Bootstrap.psm1" -Force
Import-Module "$skillRoot/scripts/Preparation.psm1" -Force
Import-Module "$skillRoot/scripts/Presets.psm1" -Force
Import-Module "$skillRoot/scripts/Project.psm1" -Force
. "$PSScriptRoot/GitHubFixture.ps1"
. "$PSScriptRoot/PresetFixture.ps1"
Test 'preset recovery native preparation failure prevents both repository POSTs' {
    $api=New-GitHubFixture
    $id=New-BootstrapIdentity -Name 'Fail Before Repos' -Description 'Purpose' -Parent $sandbox
    $selection=Resolve-BootstrapPreset $id -Preset tauri
    $prepare={param($identity,$selection,$journal,$stateRoot,$checkpoint) throw 'Native Tauri build failed: unsupported schema'}
    $probe=(New-PresetPrerequisiteFixture).probe
    $report=Invoke-Bootstrap -Identity $id -PresetSelection $selection -StateRoot $api.stateRoot -Request $api.request -Git $api.git -Prepare $prepare -PrerequisiteProbe $probe
    Assert ($report.status -in @('blocked','partial') -and ($report.pending -join ' ') -match 'unsupported schema') 'Native preparation diagnostic lost.'
    Assert (@($api.calls | Where-Object isRepositoryCreate).Count -eq 0) 'Repositories created before native validation.'
}
Test 'preset recovery plan is read only and defaults to Godot without preparing' {
    $api=New-GitHubFixture;$probe=New-PresetPrerequisiteFixture
    $id=New-BootstrapIdentity -Name 'Readonly New Plan' -Description 'Purpose' -Parent $sandbox
    $report=Get-BootstrapPlan -Identity $id -StateRoot $api.stateRoot -Request $api.request -Git $api.git -PrerequisiteProbe $probe.probe
    Assert ($report.status -eq 'ready' -and $report.preset.name -ceq 'godot') 'New plan did not default to Godot.'
    Assert (-not (Test-Path $id.projectPath) -and -not (Test-Path $report.journalPath)) 'Plan wrote persistent files.'
    Assert (@($api.calls | Where-Object method -ne 'GET').Count -eq 0 -and $probe.calls.Count -eq 1) 'Plan mutated GitHub or omitted prerequisites.'
}
Test 'preset recovery completed literal v1 state reports foundation without new prerequisites' {
    $api=New-GitHubFixture
    $legacy=Read-BootstrapJournal "$PSScriptRoot/fixtures/legacy-foundation-journal.json"
    $legacy.phases.complete='verified';$path=Get-BootstrapJournalPath $legacy.identity $api.stateRoot
    Write-BootstrapJournal $path $legacy
    $before=[IO.File]::ReadAllText($path)
    $result=Invoke-Bootstrap -Identity $legacy.identity -StateRoot $api.stateRoot -Request $api.request -PrerequisiteProbe {throw 'must not inspect SDKs'}
    Assert ($result.status -eq 'complete' -and $result.preset.name -ceq 'foundation') 'Completed v1 became implicit Godot.'
    Assert ([IO.File]::ReadAllText($path) -ceq $before) 'Completed v1 rewritten.'
}
function New-PresetRecoveryFixture([string]$Owner='Benevolent-Anarchy') {
    $f=New-TauriProcessFixture
    $f.api=New-GitHubFixture -Owner $Owner -FailPhase labels
    $f.api.appEnabled=$true;$f.api.supportsPullRequests=$true
    $parent=New-BootstrapFixture 'recovery project parent with spaces'
    $f.identity=New-BootstrapIdentity -Name 'Starter' -Description 'Purpose' -Parent $parent -Owner $Owner
    $f.selection=Resolve-BootstrapPreset $f.identity -Preset tauri
    $f.metadataFixture=New-PresetMetadataFixture
    $f.metadataFixture.npm.versions['4.0.0'].dist.integrity='sha512-'+[Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData([byte[]]@(1,2,3)))
    $f.download={param($uri,$path) [IO.File]::WriteAllBytes($path,[byte[]]@(1,2,3))}
    $f.prepare={param($identity,$selection,$journal,$stateRoot,$checkpoint)
        Initialize-BootstrapPreparation $identity $selection $journal $stateRoot $checkpoint -MetadataRequest $f.metadataFixture.request -Download $f.download -Process $f.process
    }.GetNewClosure()
    $f.probe=(New-PresetPrerequisiteFixture).probe
    return $f
}
Test 'preset recovery freezes Tauri source and resumes without resolver or generator' {
    $f=New-PresetRecoveryFixture -Owner cicely-f
    $first=Invoke-Bootstrap $f.identity $f.api.stateRoot $f.api.request $f.api.git $f.api.obsidianSetup -PresetSelection $f.selection -Prepare $f.prepare -Process $f.process -PrerequisiteProbe $f.probe
    Assert ($first.phases.privateContent -eq 'verified' -and $first.verification.staging.Passed -and $first.verification.checkout.Passed) ($first | ConvertTo-Json -Depth 10)
    $queries=$f.metadataFixture.calls.Count
    $generators=@($f.calls | Where-Object {$_.arguments -contains 'create-tauri-app' -and $_.arguments -contains '.'}).Count
    $f.api.failPhase=''
    $second=Invoke-Bootstrap $f.identity $f.api.stateRoot $f.api.request $f.api.git $f.api.obsidianSetup -Prepare {throw 'must reuse snapshot'} -Process $f.process -PrerequisiteProbe $f.probe
    Assert ($second.status -eq 'complete' -and $second.preset.appIdentifier -ceq 'com.cicely-f.starter') ($second | ConvertTo-Json -Depth 10)
    Assert ($f.metadataFixture.calls.Count -eq $queries -and @($f.calls | Where-Object {$_.arguments -contains 'create-tauri-app' -and $_.arguments -contains '.'}).Count -eq $generators) 'Resume reselected upstream.'
    Assert (@($f.api.calls | Where-Object isRepositoryCreate).Count -eq 2) 'Resume created extra repos.'
    Write-FixtureText "$($f.identity.projectPath)/src/later.ts" 'later project work'
    $before=[IO.File]::ReadAllText($second.journalPath)
    $complete=Invoke-Bootstrap $f.identity $f.api.stateRoot $f.api.request $f.api.git $f.api.obsidianSetup -Prepare {throw 'no prep'} -Process {throw 'no build'} -PrerequisiteProbe {throw 'no SDKs'}
    Assert ($complete.status -eq 'complete' -and [IO.File]::ReadAllText($second.journalPath) -ceq $before) 'Completed invocation rebuilt or rewrote development.'
    $different=Resolve-BootstrapPreset $f.identity -Preset godot
    $conflict=Invoke-Bootstrap $f.identity $f.api.stateRoot $f.api.request $f.api.git $f.api.obsidianSetup -PresetSelection $different
    Assert ($conflict.status -eq 'blocked') 'Conflicting explicit preset replaced stored Tauri.'
}
Test 'preset recovery corrupted snapshot and failed checkout never report complete' {
    $f=New-PresetRecoveryFixture
    $first=Invoke-Bootstrap $f.identity $f.api.stateRoot $f.api.request $f.api.git $f.api.obsidianSetup -PresetSelection $f.selection -Prepare $f.prepare -Process $f.process -PrerequisiteProbe $f.probe
    $journal=Read-BootstrapJournal $first.journalPath
    Assert ($journal.schemaVersion -eq 2 -and $journal.preparation.phase -ceq 'frozen') 'Corruption fixture did not freeze a preset.'
    $snapshot=Join-Path $f.api.stateRoot $journal.preparation.snapshot
    Write-FixtureText "$snapshot/src/main.ts" 'corrupt evidence'
    $mutations=@($f.api.calls | Where-Object method -ne 'GET').Count
    $result=Invoke-Bootstrap $f.identity $f.api.stateRoot $f.api.request $f.api.git $f.api.obsidianSetup -Process $f.process -PrerequisiteProbe $f.probe
    Assert ($result.status -in @('blocked','partial') -and @($f.api.calls | Where-Object method -ne 'GET').Count -eq $mutations) 'Corrupt snapshot accepted or mutations made.'
    $f=New-PresetRecoveryFixture;$firstPass=$true
    $process={param($exe,$arguments,$cwd,$environment)
        if ($cwd -eq $f.identity.projectPath -and $environment.ContainsKey('BA_TAURI_STAGE') -and $environment.BA_TAURI_STAGE -ceq 'tauri-build') {return @{ExitCode=1;Output='checkout native build failure';Executable=$exe}}
        & $f.process $exe $arguments $cwd $environment
    }.GetNewClosure()
    $result=Invoke-Bootstrap $f.identity $f.api.stateRoot $f.api.request $f.api.git $f.api.obsidianSetup -PresetSelection $f.selection -Prepare $f.prepare -Process $process -PrerequisiteProbe $f.probe
    Assert ($result.status -eq 'partial' -and $result.verification.checkout -is [hashtable] -and -not $result.verification.checkout.Passed -and -not $result.phases.ContainsKey('complete')) 'Failed checkout gate claimed complete.'
}
Test 'preset recovery staging ignore failure stays failed on repeat before any POST' {
    $api=New-GitHubFixture;$id=New-BootstrapIdentity -Name 'Unsafe Ignore' -Description 'Purpose' -Parent $sandbox
    $selection=Resolve-BootstrapPreset $id -Preset foundation
    $prepare={param($identity,$preset,$journal,$stateRoot,$checkpoint)
        $prepared=Initialize-BootstrapPreparation $identity $preset $journal $stateRoot $checkpoint
        [IO.File]::AppendAllText("$($prepared.sourcePath)/.gitignore","`nREADME.md`n")
        $prepared.manifest=@(Get-BootstrapPreparedManifest $prepared.sourcePath @($prepared.manifest.path))
        return $prepared
    }
    $first=Invoke-Bootstrap $id $api.stateRoot $api.request $api.git $api.obsidianSetup -PresetSelection $selection -Prepare $prepare
    Assert (@($api.calls | Where-Object isRepositoryCreate).Count -eq 0) 'Ignore conflict mutated GitHub on first run.'
    $second=Invoke-Bootstrap $id $api.stateRoot $api.request $api.git $api.obsidianSetup
    Assert (@($api.calls | Where-Object isRepositoryCreate).Count -eq 0 -and -not $second.verification.staging.Passed) 'Repeat bypassed a failed staging integrity/ignore check.'
}
Test 'preset recovery retains every durable preparation checkpoint across interruption' {
    foreach ($boundary in @('resolution','foundation','generator-acquired','generator','overlay','locks','source-ready')) {
        $f=New-PresetRecoveryFixture
        $prepare={param($identity,$selection,$journal,$stateRoot,$checkpoint)
            $interruptBoundary=$boundary
            $intercept={param($phase,$value) & $checkpoint $phase $value;if($phase -ceq $interruptBoundary){throw "interrupted after $interruptBoundary"}}.GetNewClosure()
            Initialize-BootstrapPreparation $identity $selection $journal $stateRoot $intercept -MetadataRequest $f.metadataFixture.request -Download $f.download -Process $f.process
        }.GetNewClosure()
        $first=Invoke-Bootstrap $f.identity $f.api.stateRoot $f.api.request $f.api.git $f.api.obsidianSetup -PresetSelection $f.selection -Prepare $prepare -Process $f.process -PrerequisiteProbe $f.probe
        Assert (($first.pending -join ' ') -match "interrupted after $boundary" -and @($f.api.calls | Where-Object isRepositoryCreate).Count -eq 0) "Checkpoint $boundary did not stop before POST: $($first.pending -join '; ') $($first.conflicts -join '; ')"
        $f.metadataFixture.fail=$true
        $second=Invoke-Bootstrap $f.identity $f.api.stateRoot $f.api.request $f.api.git $f.api.obsidianSetup -Prepare $f.prepare -Process $f.process -PrerequisiteProbe $f.probe
        Assert ($second.phases.privateContent -eq 'verified') "$boundary resume failed: $($second.pending -join '; ') $($second.conflicts -join '; ')"
        Assert (@($f.calls | Where-Object {$_.arguments -contains 'create-tauri-app' -and $_.arguments -contains '.'}).Count -eq 1) "$boundary reran generator."
        Assert (@($f.calls | Where-Object {$_.arguments -contains 'generate-lockfile'}).Count -eq 1) "$boundary regenerated locks."
    }
}
Test 'preset recovery publishes retained source after interruption before snapshot promotion' {
    $api=New-GitHubFixture;$api.appEnabled=$true;$api.supportsPullRequests=$true
    $id=New-BootstrapIdentity -Name 'Before Promotion' -Description 'Purpose' -Parent $sandbox
    $selection=Resolve-BootstrapPreset $id -Preset foundation
    $journal=New-BootstrapJournal $id @() $selection
    $path=Get-BootstrapJournalPath $id $api.stateRoot
    $save={param($phase,$value) $journal.preparation.checkpoints[$phase]=$value;Write-BootstrapJournal $path $journal}.GetNewClosure()
    $prepared=Initialize-BootstrapPreparation $id $selection $journal $api.stateRoot $save
    $journal.manifest=@($prepared.manifest | ForEach-Object {@{path=$_.path;sha256=$_.sha256}})
    $journal.templateVersion=Get-BootstrapTemplateVersion $prepared.manifest
    $journal.preparation.phase='snapshotting';$journal.preparation.snapshot="prepared/$($journal.invocationId)/source";$journal.preparation.manifestHash=$journal.templateVersion
    Write-BootstrapJournal $path $journal
    $report=Invoke-Bootstrap $id $api.stateRoot $api.request $api.git $api.obsidianSetup -Prepare {throw 'must replay retained source'}
    Assert ($report.status -eq 'complete' -and (Test-Path (Join-Path $api.stateRoot $journal.preparation.snapshot))) "Interrupted publication blocked or regenerated: $($report.pending -join '; ') $($report.conflicts -join '; ')"
}

Import-Module "$skillRoot/scripts/Bootstrap.psm1" -Force
Import-Module "$skillRoot/scripts/Preparation.psm1" -Force
Test 'review recovery resumes after a reported generator or lock failure' {
    foreach ($failure in @('generator','npm-lock','cargo-lock')) {
        $f=New-PresetRecoveryFixture;$f.api.failPhase=''
        $fault=@{remaining=1}
        $process={param($exe,$arguments,$cwd,$environment)
            $matchesFailure=switch ($failure) {
                generator {$arguments -contains 'create-tauri-app' -and $arguments -contains '.'}
                npm-lock {$arguments -contains '--package-lock-only'}
                cargo-lock {$arguments -contains 'generate-lockfile'}
            }
            if ($fault.remaining -gt 0 -and $matchesFailure) {$fault.remaining--;return @{ExitCode=1;Output='transient network outage';Executable=$exe}}
            & $f.process $exe $arguments $cwd $environment
        }.GetNewClosure()
        $prepare={param($identity,$selection,$journal,$stateRoot,$checkpoint)
            Initialize-BootstrapPreparation $identity $selection $journal $stateRoot $checkpoint -MetadataRequest $f.metadataFixture.request -Download $f.download -Process $process
        }.GetNewClosure()
        $first=Invoke-Bootstrap $f.identity $f.api.stateRoot $f.api.request $f.api.git $f.api.obsidianSetup -PresetSelection $f.selection -Prepare $prepare -Process $process -PrerequisiteProbe $f.probe
        Assert ($first.status -eq 'partial' -and @($f.api.calls | Where-Object isRepositoryCreate).Count -eq 0) "$failure failure did not stop before repository creation."
        $second=Invoke-Bootstrap $f.identity $f.api.stateRoot $f.api.request $f.api.git $f.api.obsidianSetup -Prepare $prepare -Process $process -PrerequisiteProbe $f.probe
        Assert ($second.status -eq 'complete' -and $second.phases.privateContent -eq 'verified') "$failure recovery wedged: $($second.pending -join '; ') $($second.conflicts -join '; ')"
    }
}
Test 'review recovery resumes a reported GUT download failure through private verification' {
    $api=New-GitHubFixture;$api.appEnabled=$true;$api.supportsPullRequests=$true
    $id=New-BootstrapIdentity -Name 'GUT retry' -Description 'Purpose' -Parent $sandbox
    $selection=Resolve-BootstrapPreset $id
    $metadata=New-PresetMetadataFixture;$gate=New-GodotGateFixture
    $zip=Join-Path $sandbox 'gut-retry.zip'
    New-DependencyZip $zip @{'gut/addons/gut/plugin.cfg'="[plugin]`nversion=`"9.7.1`"";'gut/addons/gut/LICENSE.md'='licence';'gut/addons/gut/gut_cmdln.gd'='extends SceneTree'}
    $fault=@{remaining=1}
    $download={param($uri,$path)
        if ($fault.remaining -gt 0) {$fault.remaining--;[IO.File]::WriteAllText($path,'partial');throw 'GUT transient 502'}
        [IO.File]::Copy($zip,$path)
    }.GetNewClosure()
    $process={param($exe,$arguments,$cwd,$environment)
        if ($arguments -contains '--import') {
            foreach ($gd in Get-GodotSourceFiles $cwd | Where-Object Extension -eq '.gd') {Write-FixtureText ($gd.FullName+'.uid') 'uid://fixture'}
        }
        & $gate.process $exe $arguments $cwd $environment
    }.GetNewClosure()
    $prepare={param($identity,$preset,$journal,$stateRoot,$checkpoint)
        Initialize-BootstrapPreparation $identity $preset $journal $stateRoot $checkpoint -MetadataRequest $metadata.request -Download $download -Process $process
    }.GetNewClosure()
    $probe=(New-PresetPrerequisiteFixture).probe
    $first=Invoke-Bootstrap $id $api.stateRoot $api.request $api.git $api.obsidianSetup -PresetSelection $selection -Prepare $prepare -Process $process -PrerequisiteProbe $probe
    Assert ($first.status -eq 'partial' -and @($api.calls | Where-Object isRepositoryCreate).Count -eq 0) 'GUT failure created a repository.'
    $second=Invoke-Bootstrap $id $api.stateRoot $api.request $api.git $api.obsidianSetup -Prepare $prepare -Process $process -PrerequisiteProbe $probe
    Assert ($second.status -eq 'complete' -and $second.phases.privateContent -eq 'verified') "GUT retry wedged: $($second.pending -join '; ') $($second.conflicts -join '; ')"
}
Test 'review recovery discard releases an unpublished failed project name locally' {
    $f=New-PresetRecoveryFixture
    $first=Invoke-Bootstrap $f.identity $f.api.stateRoot $f.api.request $f.api.git $f.api.obsidianSetup -PresetSelection $f.selection -Prepare {throw 'incompatible native starter'} -PrerequisiteProbe $f.probe
    $journal=Read-BootstrapJournal $first.journalPath
    $staging=Join-Path $f.api.stateRoot "preparing/$($journal.invocationId)"
    $prepared=Join-Path $f.api.stateRoot "prepared/$($journal.invocationId)"
    $partial=Join-Path $f.api.stateRoot "prepared/.$($journal.invocationId).abc.partial"
    foreach ($path in @($staging,$prepared,$partial)) {Write-FixtureText "$path/owned.txt" 'owned preparation'}
    $other=Join-Path $f.api.stateRoot 'prepared/unrelated/keep.txt';Write-FixtureText $other 'unrelated'
    $calls=$f.api.calls.Count
    $result=Remove-BootstrapInvocation -Identity $f.identity -StateRoot $f.api.stateRoot
    Assert ($result.status -eq 'discarded' -and -not (Test-Path $first.journalPath)) 'Discard did not remove the failed journal.'
    Assert (-not (Test-Path $staging) -and -not (Test-Path $prepared) -and -not (Test-Path $partial) -and (Test-Path $other)) 'Discard touched the wrong preparation trees.'
    Assert ($f.api.calls.Count -eq $calls -and -not (Test-Path $f.identity.projectPath)) 'Discard contacted GitHub or created a checkout.'
    $next=Resolve-BootstrapPreset $f.identity -Preset foundation
    $plan=Get-BootstrapPlan $f.identity $f.api.request $f.api.stateRoot $f.api.git -PresetSelection $next
    Assert ($plan.status -eq 'ready') 'Discarded project name remains reserved.'
}
Test 'review recovery discard refuses every recorded repository attempt' {
    foreach ($phase in @('creating','failed','verified')) {
        $f=New-PresetRecoveryFixture
        $journal=New-BootstrapJournal $f.identity @() $f.selection
        $journal.phases.privateRepository=$phase
        $path=Get-BootstrapJournalPath $f.identity $f.api.stateRoot;Write-BootstrapJournal $path $journal
        $tree=Join-Path $f.api.stateRoot "preparing/$($journal.invocationId)/source/keep.txt";Write-FixtureText $tree 'keep'
        $before=[IO.File]::ReadAllBytes($path)
        Expect-Error {Remove-BootstrapInvocation $f.identity $f.api.stateRoot} 'repository.*attempt|remote'
        Assert ((Test-Path $tree) -and [Convert]::ToHexString([IO.File]::ReadAllBytes($path)) -ceq [Convert]::ToHexString($before)) 'Refused discard removed evidence.'
    }
}
Test 'review recovery completion removes staging while retaining frozen resume evidence' {
    $f=New-PresetRecoveryFixture
    $first=Invoke-Bootstrap $f.identity $f.api.stateRoot $f.api.request $f.api.git $f.api.obsidianSetup -PresetSelection $f.selection -Prepare $f.prepare -Process $f.process -PrerequisiteProbe $f.probe
    $journal=Read-BootstrapJournal $first.journalPath
    $staging=Join-Path $f.api.stateRoot "preparing/$($journal.invocationId)"
    Assert ((Test-Path $staging) -and $first.status -eq 'partial') 'Incomplete invocation lost its staging.'
    $partial=Join-Path $f.api.stateRoot "prepared/.$($journal.invocationId).abc.partial";Write-FixtureText "$partial/owned.txt" 'incomplete publication'
    $f.api.failPhase=''
    $complete=Invoke-Bootstrap $f.identity $f.api.stateRoot $f.api.request $f.api.git $f.api.obsidianSetup -Prepare {throw 'must reuse frozen source'} -Process $f.process -PrerequisiteProbe $f.probe
    Assert ($complete.status -eq 'complete' -and -not (Test-Path $staging) -and -not (Test-Path $partial)) 'Completed invocation retains disposable staging.'
    $retained=Read-BootstrapPreparedProject (Read-BootstrapJournal $first.journalPath) $f.api.stateRoot
    Assert ($retained.manifest.Count -gt 0) 'Cleanup removed frozen recovery bytes.'
    $again=Invoke-Bootstrap $f.identity $f.api.stateRoot $f.api.request $f.api.git $f.api.obsidianSetup -Process {throw 'no rebuild'} -PrerequisiteProbe {throw 'no SDKs'}
    Assert ($again.status -eq 'complete') 'Completed resume needs removed staging.'
}
Test 'review recovery bootstrap staging still enforces its exact Tauri release' {
    $f=New-PresetRecoveryFixture
    $prepare={param($identity,$selection,$journal,$stateRoot,$checkpoint)
        $source=Initialize-BootstrapPreparation $identity $selection $journal $stateRoot $checkpoint -MetadataRequest $f.metadataFixture.request -Download $f.download -Process $f.process
        $f.version='3.0.1'
        return $source
    }.GetNewClosure()
    $result=Invoke-Bootstrap $f.identity $f.api.stateRoot $f.api.request $f.api.git $f.api.obsidianSetup -PresetSelection $f.selection -Prepare $prepare -Process $f.process -PrerequisiteProbe $f.probe
    Assert ($result.status -eq 'partial' -and ($result.pending -join ' ') -match 'selected Tauri release' -and @($f.api.calls | Where-Object isRepositoryCreate).Count -eq 0) 'Bootstrap staging accepted a different compatible release.'
}
Test 'review recovery owned cleanup validates the whole batch before deletion' {
    $owned=New-BootstrapFixture 'owned cleanup';$outside=New-BootstrapFixture 'outside cleanup'
    Write-FixtureText "$owned/keep.txt" 'keep';Write-FixtureText "$outside/keep.txt" 'outside'
    Expect-Error {Remove-BootstrapOwnedItems $owned @("$owned/keep.txt","$outside/keep.txt")} 'escapes|outside'
    Assert ((Test-Path "$owned/keep.txt") -and (Test-Path "$outside/keep.txt")) 'Cleanup deleted before validating all paths.'
    New-Item -ItemType Junction -Path "$owned/link" -Target $outside | Out-Null
    Expect-Error {Remove-BootstrapOwnedItems $owned @("$owned/keep.txt","$owned/link")} 'link'
    Assert ((Test-Path "$owned/keep.txt") -and (Test-Path "$outside/keep.txt")) 'Cleanup followed a linked path.'
    Expect-Error {Remove-BootstrapOwnedItems $owned @($owned)} 'root'
    Write-FixtureText "$owned/tree/file.txt" 'owned'
    New-Item -ItemType Junction -Path "$owned/tree/nested-link" -Target $outside | Out-Null
    Expect-Error {Remove-BootstrapOwnedItems $owned @("$owned/keep.txt","$owned/tree")} 'link'
    Assert ((Test-Path "$owned/keep.txt") -and (Test-Path "$owned/tree/file.txt") -and (Test-Path "$outside/keep.txt")) 'Cleanup ignored a descendant link.'
}
Test 'review cleanup held file does not undo completion and retries after release' {
    $api=New-GitHubFixture -FailPhase labels;$api.appEnabled=$true;$api.supportsPullRequests=$true
    $id=New-BootstrapIdentity -Name 'Held staging cleanup' -Description 'Purpose' -Parent $sandbox
    $selection=Resolve-BootstrapPreset $id -Preset foundation
    $first=Invoke-Bootstrap $id $api.stateRoot $api.request $api.git $api.obsidianSetup -PresetSelection $selection
    Assert ($first.status -eq 'partial' -and $first.phases.privateContent -eq 'verified') 'Fixture did not reach labels.'
    $journal=Read-BootstrapJournal $first.journalPath
    $staging=Join-Path $api.stateRoot "preparing/$($journal.invocationId)"
    $heldPath=Join-Path $staging 'source/node_modules/held.bin';Write-FixtureText $heldPath 'held cache'
    $held=[IO.File]::Open($heldPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $api.failPhase=''
        $complete=Invoke-Bootstrap $id $api.stateRoot $api.request $api.git $api.obsidianSetup
        Assert ($complete.status -eq 'complete' -and $complete.pending.Count -eq 0) "Cleanup undid completion: $($complete.status); $($complete.pending -join '; ')"
        Assert ($complete.cleanup.status -eq 'deferred' -and $complete.cleanup.reason -match 'held.bin|access|process') 'Locked cleanup has no separate diagnostic.'
        Assert ((Test-Path $staging) -and (Test-Path $heldPath)) 'Failed cleanup lost its held tree.'
        $recorded=[IO.File]::ReadAllText($first.journalPath)
        $status=Get-BootstrapStatus $id $api.stateRoot $api.request
        Assert ($status.status -eq 'complete' -and [IO.File]::ReadAllText($first.journalPath) -ceq $recorded) 'Status changed completion or its journal.'
        $again=Invoke-Bootstrap $id $api.stateRoot $api.request $api.git $api.obsidianSetup -Prepare {throw 'no preparation'} -Process {throw 'no rebuild'} -PrerequisiteProbe {throw 'no SDKs'}
        Assert ($again.status -eq 'complete' -and $again.cleanup.status -eq 'deferred' -and $again.pending.Count -eq 0) 'Repeated locked cleanup reports unfinished bootstrap.'
        Assert ([IO.File]::ReadAllText($first.journalPath) -ceq $recorded) 'Cleanup retry changed the completed journal.'
    } finally {$held.Dispose()}
    $cleared=Invoke-Bootstrap $id $api.stateRoot $api.request $api.git $api.obsidianSetup -Prepare {throw 'no preparation'} -Process {throw 'no rebuild'} -PrerequisiteProbe {throw 'no SDKs'}
    Assert ($cleared.status -eq 'complete' -and $cleared.cleanup.status -eq 'removed' -and -not (Test-Path $staging)) 'Released cache was not cleaned on resume.'
    Assert ([IO.File]::ReadAllText($first.journalPath) -ceq $recorded) 'Successful cleanup rewrote completion evidence.'
    $frozen=Read-BootstrapPreparedProject (Read-BootstrapJournal $first.journalPath) $api.stateRoot
    Assert ($frozen.manifest.Count -gt 0) 'Cleanup lost frozen recovery bytes.'
}
Test 'review cleanup junction remains refused without changing completed status' {
    $api=New-GitHubFixture -FailPhase labels;$api.appEnabled=$true;$api.supportsPullRequests=$true
    $id=New-BootstrapIdentity -Name 'Linked staging cleanup' -Description 'Purpose' -Parent $sandbox
    $first=Invoke-Bootstrap $id $api.stateRoot $api.request $api.git $api.obsidianSetup -PresetSelection (Resolve-BootstrapPreset $id -Preset foundation)
    Assert ($first.status -eq 'partial' -and $first.phases.privateContent -eq 'verified') 'Fixture did not reach labels.'
    $journal=Read-BootstrapJournal $first.journalPath
    $staging=Join-Path $api.stateRoot "preparing/$($journal.invocationId)"
    $outside=New-BootstrapFixture 'cleanup junction target';Write-FixtureText "$outside/keep.txt" 'outside proof'
    New-Item -ItemType Directory -Path "$staging/source/node_modules" -Force | Out-Null
    New-Item -ItemType Junction -Path "$staging/source/node_modules/linked" -Target $outside | Out-Null
    $before=(Get-FileHash -LiteralPath "$staging/source/README.md").Hash
    $api.failPhase=''
    $complete=Invoke-Bootstrap $id $api.stateRoot $api.request $api.git $api.obsidianSetup
    Assert ($complete.status -eq 'complete' -and $complete.pending.Count -eq 0) "Junction cleanup undid completion: $($complete.status); $($complete.pending -join '; ')"
    Assert ($complete.cleanup.status -eq 'deferred' -and $complete.cleanup.reason -match 'link') 'Junction refusal is not a separate cleanup diagnostic.'
    $recorded=[IO.File]::ReadAllText($first.journalPath)
    $again=Invoke-Bootstrap $id $api.stateRoot $api.request $api.git $api.obsidianSetup -Prepare {throw 'no preparation'} -Process {throw 'no rebuild'} -PrerequisiteProbe {throw 'no SDKs'}
    Assert ($again.status -eq 'complete' -and $again.cleanup.status -eq 'deferred' -and $again.pending.Count -eq 0) 'Junction permanently blocks completed resume.'
    Assert ((Get-FileHash -LiteralPath "$staging/source/README.md").Hash -ceq $before -and [IO.File]::ReadAllText("$outside/keep.txt") -ceq 'outside proof') 'Cleanup mutated staging or the linked target.'
    Assert ([IO.File]::ReadAllText($first.journalPath) -ceq $recorded -and (Get-BootstrapStatus $id $api.stateRoot $api.request).status -eq 'complete') 'Cleanup changed durable completion.'
    Assert ((Read-BootstrapPreparedProject (Read-BootstrapJournal $first.journalPath) $api.stateRoot).manifest.Count -gt 0) 'Cleanup lost the frozen snapshot.'
}

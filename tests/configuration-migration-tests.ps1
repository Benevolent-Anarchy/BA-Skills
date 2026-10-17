# Adopts stores configured after preparation through the explicit migration path, using the real setup writer.

# Answers setup as the noninteractive flow does: the full retained store list plus inspected Steam facts.
function Add-MigrationSteam([string]$Repo, $Baseline='v1.2.2') {
    $answers=Join-Path $sandbox ('steam-answers-'+[guid]::NewGuid().ToString('N')+'.json')
    Write-Json $answers ([ordered]@{stores=@('itch','steam','notes');'distributions.steam.appId'=100;'distributions.steam.branch'='default';'distributions.steam.exclude'=@('*.pdb');'distributions.steam.depots'=[ordered]@{'101'='windows';'102'='linux'};'distributions.steam.previousRelease'=$Baseline})
    Set-ReleaseSetup $Repo $answers (Get-ReleaseSetup $Repo).configSha256 | Out-Null
}
function Save-MigrationCommit([string]$Repo, [string]$Message) {
    Invoke-FixtureGit $Repo @('add','--all') | Out-Null
    Invoke-FixtureGit $Repo @('commit','--quiet','-m',$Message) | Out-Null
}
# Runs $Inject once inside the release module, just before it plans $Selection against a baseline snapshot naming every
# selected destination, as the plan an extension or migration saves does. Earlier plans freeze only the release's own.
function Set-PlannerCommitProbe([string]$Selection, [scriptblock]$Inject) {
    & (Get-Module Release) {param($selection,$inject)
        $script:PlannerProbe=@{planner=${function:Get-ReleasePlan};selection=$selection;inject=$inject}
        function script:Get-ReleasePlan([string]$Repository, [string[]]$Destination=@(), $BaselineSnapshot=$null, [string]$StateRoot, [string]$VersionChange='current', $FrozenPrevious, [string]$ReleaseVersion) {
            $probe=$script:PlannerProbe
            $complete=$null -ne $BaselineSnapshot -and -not @($Destination | Where-Object {$_ -cne 'notes' -and -not $BaselineSnapshot.Contains($_)}).Count
            if ($probe.inject -and $complete -and ($Destination -join ',') -ceq $probe.selection) {$run=$probe.inject;$probe.inject=$null;& $run}
            # Passes on exactly what it was given, so an omitted frozen boundary stays omitted.
            & $probe.planner @PSBoundParameters
        }
    } $Selection $Inject
}
function Clear-PlannerCommitProbe {
    & (Get-Module Release) {Set-Item function:script:Get-ReleasePlan $script:PlannerProbe.planner}
}

Test 'itch-only release adds Steam configured later through an explicit, resumable migration without repeating itch work' {
    $repo=New-Fixture 'migration-steam'
    $env:BA_FIXTURE_EXPORT_LOG=Join-Path $sandbox 'migration-steam-exports.txt'
    try {
        $prepared=Invoke-ReleasePrepare $repo @('itch-windows') (Join-Path $sandbox 'migration-steam-state') $engine
        $stateFile=Join-Path $prepared.statePath 'state.json'
        $state=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
        $published=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan)
        Assert ($published.destinations['itch-windows'].status -eq 'succeeded') 'Itch-only release did not publish.'
        $before=Get-Content $stateFile -Raw
        $original=$before | ConvertFrom-Json -AsHashtable
        $notesHash=(Get-FileHash (Join-Path $prepared.statePath 'notes.md')).Hash
        Add-MigrationSteam $repo
        Expect-Error {Expand-ReleaseDestinations $prepared.statePath @('steam') $engine -MigrateConfiguration} 'Commit the reviewed release.json'
        Save-MigrationCommit $repo 'Configure Steam'
        Expect-Error {Expand-ReleaseDestinations $prepared.statePath @('steam') $engine} 'adding steam.*-MigrateConfiguration'
        Assert ((Get-Content $stateFile -Raw) -ceq $before) 'Refused migration changed the prepared release.'
        $env:BA_FIXTURE_EXPORT_FAIL='Linux existing'
        try {$interrupted=Expand-ReleaseDestinations $prepared.statePath @('steam') $engine -MigrateConfiguration}
        finally {Remove-Item Env:BA_FIXTURE_EXPORT_FAIL}
        $state=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
        Assert ($interrupted.status -eq 'preparation-failed' -and $interrupted.configurationMigration.addedDestinations -contains 'steam') 'Interrupted migration was not reported.'
        Assert ($state.history[0].plan.planId -ceq $original.plan.planId -and $state.history[0].approval.planId -ceq $original.approval.planId -and $state.history[0].configurationMigration.fromConfigSha256 -ceq $original.plan.configSha256) 'Migration lost the original plan or approval history.'
        Assert ((ConvertTo-Json $state.artifacts[0] -Depth 20 -Compress) -ceq (ConvertTo-Json $original.artifacts[0] -Depth 20 -Compress) -and $state.destinations['itch-windows'].status -eq 'succeeded') 'Interrupted migration lost the original release.'
        $cli=Join-Path $root 'skills/ba-release/scripts/release.ps1'
        $resumed=(& pwsh -NoProfile -File $cli -Mode extend -StatePath $prepared.statePath -Destination steam -MigrateConfiguration -GodotExecutable $engine) -join "`n" | ConvertFrom-Json -AsHashtable
        Assert ($LASTEXITCODE -eq 0 -and $resumed.status -eq 'prepared') "Migration did not resume: $($resumed | ConvertTo-Json -Compress)"
        $state=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
        Assert ((@(Get-Content $env:BA_FIXTURE_EXPORT_LOG) -join ',') -ceq 'Windows existing,Linux existing') 'Migration rebuilt the existing Windows export.'
        $windows=@($state.artifacts | Where-Object preset -EQ 'Windows existing')[0];$linux=@($state.artifacts | Where-Object preset -EQ 'Linux existing')[0]
        Assert ((ConvertTo-Json $windows -Depth 20 -Compress) -ceq (ConvertTo-Json $original.artifacts[0] -Depth 20 -Compress) -and $windows.sourceCommit -ceq $original.plan.head -and $linux.sourceCommit -ceq $state.plan.head) 'Migration changed artifact provenance.'
        Assert ($notesHash -eq (Get-FileHash (Join-Path $prepared.statePath 'notes.md')).Hash -and $state.plan.baselines['itch-windows'] -ceq $original.plan.baselines['itch-windows']) 'Migration rewrote canonical notes or the frozen itch baseline.'
        Expect-Error {Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -SteamCmdExecutable $steam} 'approval'
        $env:BA_STEAM_USERNAME='fixture'
        try {$result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -SteamCmdExecutable $steam -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan)}
        finally {Remove-Item Env:BA_STEAM_USERNAME}
        Assert ($result.destinations.steam.status -eq 'awaiting-store-action' -and $result.destinations.steam.attempts -eq 1 -and $result.destinations['itch-windows'].attempts -eq 1) 'Migrated release repeated itch or did not upload Steam.'
    } finally {Remove-Item Env:BA_FIXTURE_EXPORT_LOG}
}

Test 'configuration migration rejects unknown baselines, edits to existing settings, artifacts or notes and unrelated source' {
    $repo=New-Fixture 'migration-guards'
    $prepared=Invoke-ReleasePrepare $repo @('itch-windows') (Join-Path $sandbox 'migration-guards-state') $engine
    $stateFile=Join-Path $prepared.statePath 'state.json'
    $state=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan) | Out-Null
    $before=Get-Content $stateFile -Raw
    $preparedHead=Invoke-FixtureGit $repo @('rev-parse','HEAD')
    $cases=[ordered]@{
        'Confirm its last live'={Add-MigrationSteam $repo $null}
        'must precede'={Add-MigrationSteam $repo 'HEAD'}
        'existing destination itch-windows'={Add-MigrationSteam $repo;Change-Config $repo {param($c) $c.distributions.itch.ignore+='*.pdb'}}
        'previousRelease changed'={Add-MigrationSteam $repo;Change-Config $repo {param($c) $c.previousRelease='v1.2.2~0'}}
        'verification.gate changed'={Add-MigrationSteam $repo;Change-Config $repo {param($c) $c.verification.gate.arguments=@('-Fast')}}
        'standalone check for Windows existing'={Add-MigrationSteam $repo;Change-Config $repo {param($c) $c.verification.standalone.arguments=@('{artifact}','{platform}')}}
        'remove destination notes'={Add-MigrationSteam $repo;Change-Config $repo {param($c) $c.distributions.Remove('notes')}}
        'beyond release.json'={Add-MigrationSteam $repo;Add-Content (Join-Path $repo 'fix.txt') 'unrelated gameplay change'}
    }
    foreach ($pattern in $cases.Keys) {
        Invoke-FixtureGit $repo @('reset','--quiet','--hard',$preparedHead) | Out-Null
        & $cases[$pattern]
        Save-MigrationCommit $repo "Migration probe: $pattern"
        Expect-Error {Expand-ReleaseDestinations $prepared.statePath @('steam') $engine -MigrateConfiguration} $pattern
        Assert ((Get-Content $stateFile -Raw) -ceq $before) "Rejected migration changed the release: $pattern"
    }
    Invoke-FixtureGit $repo @('reset','--quiet','--hard',$preparedHead) | Out-Null
    Add-MigrationSteam $repo
    Save-MigrationCommit $repo 'Configure Steam'
    $artifact=Join-Path $prepared.statePath $state.artifacts[0].files[0].path;$artifactBytes=[IO.File]::ReadAllBytes($artifact)
    Add-Content $artifact 'tampered'
    Expect-Error {Expand-ReleaseDestinations $prepared.statePath @('steam') $engine -MigrateConfiguration} 'artifact changed'
    [IO.File]::WriteAllBytes($artifact,$artifactBytes)
    $notes=Join-Path $prepared.statePath 'notes.md';$notesBytes=[IO.File]::ReadAllBytes($notes)
    Add-Content $notes 'Claims added after publication'
    Expect-Error {Expand-ReleaseDestinations $prepared.statePath @('steam') $engine -MigrateConfiguration} 'Canonical notes changed'
    [IO.File]::WriteAllBytes($notes,$notesBytes)
    Assert ((Get-Content $stateFile -Raw) -ceq $before) 'Rejected artifact or notes edits changed the release.'
    $migrated=Expand-ReleaseDestinations $prepared.statePath @('steam') $engine -MigrateConfiguration
    Assert ($migrated.status -eq 'prepared') "Valid migration failed after earlier refusals: $($migrated.status)"
}

Test 'a store configured later with its own Android counter migrates once and resumes after the counter commit' {
    $repo=New-StoreFixture 'migration-play'
    Change-Config $repo {param($c) $c.distributions.Remove('google-play');$c.exports.Remove('aab');$c.androidVersionCodePolicy='increment-selected'}
    Save-MigrationCommit $repo 'Release on Steam only'
    $prepared=Invoke-ReleasePrepare $repo @('steam') (Join-Path $sandbox 'migration-play-state') $engine
    $stateFile=Join-Path $prepared.statePath 'state.json'
    $original=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    Change-Config $repo {param($c) $c.exports.aab='Android existing AAB';$c.distributions['google-play']=@{export='aab';track='production';releaseStatus='completed';language='en-US';retainVersionCodes=@('11')}}
    Save-MigrationCommit $repo 'Configure Google Play'
    $result=Expand-ReleaseDestinations $prepared.statePath @('google-play') $engine -MigrateConfiguration
    $state=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    Assert ($result.status -eq 'source-update-required' -and (Get-ReleaseConfiguration $repo).presets[2].versionCode -eq 13) 'Later Play configuration did not reserve its counter.'
    Assert ($state.history[0].plan.planId -ceq $original.plan.planId -and $state.history[0].configurationMigration.addedExports -contains 'Android existing AAB' -and $state.destinations['google-play'].status -eq 'not-selected') 'Migration was not recorded before the counter reservation.'
    $result=Expand-ReleaseDestinations $prepared.statePath @('google-play') $engine -MigrateConfiguration
    $state=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    Assert ($result.status -eq 'source-update-required' -and (Get-ReleaseConfiguration $repo).presets[2].versionCode -eq 13 -and @($state.history).Count -eq 1) 'Resumed migration reserved the counter or migrated again.'
    Save-MigrationCommit $repo 'Reserve Play code'
    $result=Expand-ReleaseDestinations $prepared.statePath @('google-play') $engine
    $state=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    $desktop=@($state.artifacts | Where-Object preset -NE 'Android existing AAB');$aab=@($state.artifacts | Where-Object preset -EQ 'Android existing AAB')[0]
    Assert ($result.status -eq 'prepared' -and (Get-ReleaseConfiguration $repo).version -eq '1.2.3') 'Migrated Play extension did not prepare at the same version.'
    Assert ((ConvertTo-Json $desktop -Depth 20 -Compress) -ceq (ConvertTo-Json @($original.artifacts) -Depth 20 -Compress) -and $aab.sourceCommit -ceq $state.plan.head -and $aab.sourceCommit -cne $original.plan.head) 'Later Play rebuilt desktops or concealed the AAB source commit.'
}

Test 'migration refuses an unselected added store until its baseline is confirmed, then lets it catch up' {
    $repo=New-StoreFixture 'migration-unselected'
    Change-Config $repo {param($c) $c.distributions.Remove('steam');$c.distributions.Remove('google-play');$c.exports.Remove('aab')}
    Save-MigrationCommit $repo 'Release on itch only'
    $prepared=Invoke-ReleasePrepare $repo @('itch-windows') (Join-Path $sandbox 'migration-unselected-state') $engine
    $stateFile=Join-Path $prepared.statePath 'state.json';$before=Get-Content $stateFile -Raw
    $itchOnly=Invoke-FixtureGit $repo @('rev-parse','HEAD')
    foreach ($case in @(@{baseline=$null;pattern='google-play: Confirm its last live'},@{baseline='HEAD';pattern='baseline for google-play must precede'},@{baseline='v1.2.2';pattern=$null})) {
        Invoke-FixtureGit $repo @('reset','--quiet','--hard',$itchOnly) | Out-Null
        Change-Config $repo {param($c)
            $c.exports.aab='Android existing AAB'
            $c.distributions.steam=@{appId=100;branch='default';exclude=@('*.pdb');depots=[ordered]@{'101'='windows';'102'='linux'}}
            $c.distributions['google-play']=@{export='aab';track='production';releaseStatus='completed';language='en-US';retainVersionCodes=@('11');previousRelease=$case.baseline}
        }
        Save-MigrationCommit $repo 'Configure Steam and Play, selecting only Steam'
        if ($case.pattern) {
            Expect-Error {Expand-ReleaseDestinations $prepared.statePath @('steam') $engine -MigrateConfiguration} $case.pattern
            Assert ((Get-Content $stateFile -Raw) -ceq $before) "An unready unselected store was adopted: $($case.pattern)"
        }
    }
    $migrated=Expand-ReleaseDestinations $prepared.statePath @('steam') $engine -MigrateConfiguration
    $state=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    Assert ($migrated.status -eq 'prepared' -and $state.history[0].configurationMigration.addedDestinations -contains 'google-play' -and $state.destinations['google-play'].status -eq 'not-selected') 'Confirmed unselected store was not adopted.'
    $play=Expand-ReleaseDestinations $prepared.statePath @('google-play') $engine
    Assert ($play.status -eq 'prepared') "Adopted store could not catch up through ordinary extend: $($play.status)"
}

Test 'extension saves nothing when a commit lands between validation and planning' {
    $repo=New-Fixture 'migration-concurrent'
    $prepared=Invoke-ReleasePrepare $repo @('itch-windows') (Join-Path $sandbox 'migration-concurrent-state') $engine
    $stateFile=Join-Path $prepared.statePath 'state.json'
    $state=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan) | Out-Null
    $before=Get-Content $stateFile -Raw
    Add-MigrationSteam $repo
    Save-MigrationCommit $repo 'Configure Steam'
    Set-PlannerCommitProbe 'itch-windows' {Change-Config $repo {param($c) $c.distributions.itch.game='example/other-game'};Save-MigrationCommit $repo 'Concurrent itch game change'}
    try {Expect-Error {Expand-ReleaseDestinations $prepared.statePath @('steam') $engine -MigrateConfiguration} 'changed during migration'}
    finally {Clear-PlannerCommitProbe}
    Assert ((Get-Content $stateFile -Raw) -ceq $before) 'A commit that skipped migration validation was saved.'
    $repo=New-StoreFixture 'extension-concurrent'
    $prepared=Invoke-ReleasePrepare $repo @('steam') (Join-Path $sandbox 'extension-concurrent-state') $engine
    $stateFile=Join-Path $prepared.statePath 'state.json';$before=Get-Content $stateFile -Raw
    Set-PlannerCommitProbe 'itch-windows,steam' {Change-Config $repo {param($c) $c.distributions.itch.game='example/other-game'};Save-MigrationCommit $repo 'Concurrent itch game change'}
    try {Expect-Error {Expand-ReleaseDestinations $prepared.statePath @('itch-windows') $engine} 'changed during extension'}
    finally {Clear-PlannerCommitProbe}
    Assert ((Get-Content $stateFile -Raw) -ceq $before) 'Ordinary extension saved a plan for a commit it never checked.'
}

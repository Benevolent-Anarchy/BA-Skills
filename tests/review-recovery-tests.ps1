# Reproduces PR 6 review findings using disposable journals and local store boundaries.

Test 'PR rereview credential words in itch identifiers remain valid structured data' {
    foreach ($slug in @('secret-agent','the-secret-agent','token-runner','password-puzzle','credential-quest','api-key-mystery','desk-organization','brisk-adventures2024','laughs_championship')) {
        $json=@{target="example/${slug}:windows";evidenceUrl="https://example.itch.io/$slug";displayName='Kiosk-Simulator2026 1.2.3 (Windows)'} | ConvertTo-Json -Compress
        & (Get-Module Release) {param($text)
            $document=[System.Text.Json.JsonDocument]::Parse($text)
            try {Assert-ReleaseJson $document.RootElement} finally {$document.Dispose()}
        } $json
    }
}

Test 'PR rereview itch games with credential words can configure publish and confirm their labels' {
    foreach ($slug in @('secret-agent','the-secret-agent','desk-organization','brisk-adventures2024','laughs_championship')) {
        $repo=New-Fixture "review-receipt-$slug"
        Change-Config $repo {param($c) $c.distributions.itch.game="example/$slug";$c.distributions.itch.displayNameTemplate='{title} {version} ({os})'}
        $projectPath=Join-Path $repo 'project.godot'
        [IO.File]::WriteAllText($projectPath,[IO.File]::ReadAllText($projectPath).Replace('config/name="Fixture"','config/name="Kiosk-Simulator2026"'),[Text.UTF8Encoding]::new($false))
        Get-ReleaseConfiguration $repo | Out-Null
        Invoke-FixtureGit $repo @('add','release.json','project.godot') | Out-Null
        Invoke-FixtureGit $repo @('commit','--quiet','-m','Configure the inspected itch game') | Out-Null
        $prepared=Invoke-ReleasePrepare $repo @('itch-windows') (Join-Path $sandbox "review-receipt-$slug-state") $engine
        $stateFile=Join-Path $prepared.statePath 'state.json';$state=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
        $notesHash=Get-ReleaseNotesHash $prepared.statePath $state.plan
        $uploaded=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 $notesHash
        Assert ($uploaded.destinations['itch-windows'].status -eq 'awaiting-store-action') 'Fixture did not wait for an itch display label.'
        $destination=@($state.plan.destinations | Where-Object id -EQ 'itch-windows')[0]
        Assert ($destination.displayName -ceq 'Kiosk-Simulator2026 1.2.3 (Windows)') 'Receipt fixture did not use the title that resembles an API-key prefix.'
        $receiptPath=Join-Path $prepared.statePath 'itch-receipt.json'
        Write-Json $receiptPath @{destination='itch-windows';planId=$state.plan.planId;notesSha256=$notesHash;observedAt=[DateTimeOffset]::UtcNow.ToString('o');live=$true;target=$destination.target;displayName=$destination.displayName;evidenceUrl="https://example.itch.io/$slug"}
        $confirmed=Confirm-ReleaseStoreCompletion $prepared.statePath $receiptPath
        Assert ($confirmed.status -eq 'published' -and $confirmed.destinations['itch-windows'].status -eq 'succeeded') 'A credential word in the game slug blocked its observed receipt.'
        $before=(Get-FileHash $stateFile).Hash
        Confirm-ReleaseStoreCompletion $prepared.statePath $receiptPath | Out-Null
        Assert ((Get-FileHash $stateFile).Hash -ceq $before) 'Repeating the same receipt rewrote completion.'
    }
}

Test 'PR followup API key prefixes remain rejected at token boundaries' {
    foreach ($keyPrefix in @('ghp_','gho_','ghu_','ghs_','ghr_','github_pat_','sk-')) {
        foreach ($separator in @('','value=','value: ',' ','"',"'")) {
            $text=$separator+$keyPrefix+'ABCDEFGHIJKLMNOPQRSTUVWXYZ012345'
            Expect-Error {& (Get-Module Release) {param($value) Assert-ReleaseHoldReason $value} $text} 'Credential-like'
            $json=@{arguments=@($text)} | ConvertTo-Json -Compress
            Expect-Error {& (Get-Module Release) {param($value)
                $document=[System.Text.Json.JsonDocument]::Parse($value)
                try {Assert-ReleaseJson $document.RootElement} finally {$document.Dispose()}
            } $json} 'Credential-like'
        }
    }
}

Test 'PR rereview a started Butler push persists progress before failure and cannot be hidden by a hold' {
    $repo=New-Fixture 'review-started-butler'
    $prepared=Invoke-ReleasePrepare $repo @('itch-linux') (Join-Path $sandbox 'review-started-butler-state') $engine
    $stateFile=Join-Path $prepared.statePath 'state.json';$state=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    $push=Join-Path $sandbox 'review-failed-push.ps1';$observation=Join-Path $sandbox 'review-push-observation.json'
    @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
$state=Get-Content -LiteralPath $env:BA_FIXTURE_PUSH_JOURNAL -Raw | ConvertFrom-Json -AsHashtable
$record=$state.destinations['itch-linux']
[ordered]@{status=$record.status;phase=$record.remote['phase'];attempts=$record.attempts} | ConvertTo-Json | Set-Content -LiteralPath $env:BA_FIXTURE_PUSH_OBSERVATION
exit 7
'@ | Set-Content -LiteralPath $push
    $priorJournal=$env:BA_FIXTURE_PUSH_JOURNAL;$priorObservation=$env:BA_FIXTURE_PUSH_OBSERVATION
    $env:BA_FIXTURE_PUSH_JOURNAL=$stateFile;$env:BA_FIXTURE_PUSH_OBSERVATION=$observation
    try {
        $failed=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $push -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan)
        $observed=Get-Content -LiteralPath $observation -Raw | ConvertFrom-Json -AsHashtable
        Assert ($observed.phase -eq 'pushing' -and $observed.status -eq 'in-progress' -and $observed.attempts -eq 1) 'Butler started before its progress was journaled.'
        Assert ($failed.destinations['itch-linux'].status -eq 'failed' -and $failed.destinations['itch-linux'].remote.phase -eq 'pushing') 'Failed push lost the evidence that it started.'
        $before=(Get-FileHash $stateFile).Hash
        Expect-Error {Set-ReleaseDestinationHold $prepared.statePath @('itch-linux') 'Wait for access repair.'} 'started|reconcil'
        Assert ((Get-FileHash $stateFile).Hash -ceq $before) 'Hold hid a Butler push that needs reconciliation.'
    } finally {$env:BA_FIXTURE_PUSH_JOURNAL=$priorJournal;$env:BA_FIXTURE_PUSH_OBSERVATION=$priorObservation}
}

Test 'PR review credential assignments and Basic authorization cannot become public hold text' {
    foreach ($reason in @('password=hunter2','BA_GOOGLE_PLAY_ACCESS_TOKEN=ya29.fixtureaccesstoken','Authorization: Basic Zml4dHVyZTpmaXh0dXJl','{"Authorization": "Basic Zml4dHVyZTpmaXh0dXJl"}','api_key: fixture-key','secret = fixture-secret')) {
        Expect-Error {& (Get-Module Release) {param($text) Assert-ReleaseHoldReason $text} $reason} 'Credential-like'
    }
    & (Get-Module Release) {Assert-ReleaseHoldReason 'Basic checks await repair; no password was supplied.'}
}

Test 'PR review pending work cannot mask another interrupted destination' {
    $state=@{plan=@{selectedDestinations=@('itch','play')};destinations=@{itch=@{status='in-progress'};play=@{status='pending'}}}
    Assert ((& (Get-Module Release) {param($value) Get-ReleaseOverallStatus $value} $state) -eq 'needs-reconciliation') 'Pending Play concealed an interrupted itch operation.'
}

Test 'PR review completed legacy Play unholds do not block independent retries' {
    $repo=New-StoreFixture 'review-completed-legacy-unhold'
    $prepared=Invoke-ReleasePrepare $repo @('itch-windows','google-play') (Join-Path $sandbox 'review-completed-legacy-unhold-state') $engine
    $stateFile=Join-Path $prepared.statePath 'state.json';$state=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    Set-ReleaseDestinationHold $prepared.statePath @('itch-windows') 'Wait for the desktop release.' | Out-Null
    $api=New-PlayServer
    Invoke-ReleasePublish -StatePath $prepared.statePath -PlayTransport $api.handler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan) | Out-Null
    $state=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    $state.destinations['google-play'].hold=@{reason='Previous review cleared.';heldAt='2026-10-01T00:00:00Z';releasedAt='2026-10-02T00:00:00Z'}
    Write-Json $stateFile $state
    Set-ReleaseDestinationHold $prepared.statePath @('itch-windows') -Release | Out-Null
    $before=$api.server.calls.Count
    $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -PlayTransport $api.handler
    Assert ($result.destinations['itch-windows'].status -eq 'succeeded' -and $result.destinations['google-play'].status -eq 'submitted' -and $api.server.calls.Count -eq $before) 'Completed legacy Play blocked an independent store or repeated remote operations.'
}

Test 'PR review pending destinations are ready without hiding actual failures' {
    foreach ($other in @('succeeded','awaiting-release','held','awaiting-store-action','submitted')) {
        $state=@{plan=@{selectedDestinations=@('other','play')};destinations=@{other=@{status=$other};play=@{status='pending'}}}
        Assert ((& (Get-Module Release) {param($value) Get-ReleaseOverallStatus $value} $state) -eq 'prepared') "Pending Play was reported as a failure beside $other."
        $state.destinations.other.status='failed'
        Assert ((& (Get-Module Release) {param($value) Get-ReleaseOverallStatus $value} $state) -eq 'publication-failed') 'Pending Play concealed a real failure.'
        $state.destinations.other.status='uncertain'
        Assert ((& (Get-Module Release) {param($value) Get-ReleaseOverallStatus $value} $state) -eq 'needs-reconciliation') 'Pending Play concealed an uncertain outcome.'
    }
}

Test 'PR review rejects private or multiline hold reasons before any journal write' {
    $repo=New-Fixture 'review-hold-reason'
    $prepared=Invoke-ReleasePrepare $repo @('itch-windows') (Join-Path $sandbox 'review-hold-reason-state') $engine
    $stateFile=Join-Path $prepared.statePath 'state.json';$before=(Get-FileHash $stateFile).Hash
    foreach ($reason in @('ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345','Authorization: Bearer ya29.fixturetoken','https://user:password@example.invalid/path','password=hunter2','BA_GOOGLE_PLAY_ACCESS_TOKEN=ya29.fixtureaccesstoken','Authorization: Basic Zml4dHVyZTpmaXh0dXJl')) {
        Expect-Error {Set-ReleaseDestinationHold $prepared.statePath @('itch-windows') $reason} 'Credential-like'
    }
    foreach ($reason in @(('x'*1001),"First line`nSecond line","Status`rreturn",("Status"+[char]0+'null'))) {
        Expect-Error {Set-ReleaseDestinationHold $prepared.statePath @('itch-windows') $reason} 'reason|single.line'
    }
    Assert ((Get-FileHash $stateFile).Hash -ceq $before) 'Rejected public reason changed the journal.'
}

Test 'PR review held notes still preflight before any selected store upload' {
    $repo=New-Fixture 'review-held-notes'
    $prepared=Invoke-ReleasePrepare $repo @('itch-windows','notes') (Join-Path $sandbox 'review-held-notes-state') $engine
    $stateFile=Join-Path $prepared.statePath 'state.json';$state=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    Set-ReleaseDestinationHold $prepared.statePath @('notes') 'Public notes await the announcement.' | Out-Null
    $env:BA_FIXTURE_NOTE_STORE=Join-Path $sandbox 'review-held-notes.md';$env:BA_FIXTURE_NO_PUSH='1'
    try {
        $failed=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -GhExecutable $gh -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan)
        Assert ($failed.status -eq 'publication-failed' -and $failed.destinations.notes.status -eq 'held' -and $failed.destinations['itch-windows'].attempts -eq 0) 'Held notes skipped permissions preflight, lost their hold or shipped a store.'
        Remove-Item Env:BA_FIXTURE_NO_PUSH
        'Conflicting published notes' | Set-Content $env:BA_FIXTURE_NOTE_STORE
        $conflict=(Get-FileHash $env:BA_FIXTURE_NOTE_STORE).Hash
        $failed=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -GhExecutable $gh
        Assert ($failed.status -eq 'publication-failed' -and $failed.destinations['itch-windows'].attempts -eq 0 -and (Get-FileHash $env:BA_FIXTURE_NOTE_STORE).Hash -ceq $conflict) 'Held notes bypassed conflicting canonical content.'
        Remove-Item -LiteralPath $env:BA_FIXTURE_NOTE_STORE
        $shipped=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -GhExecutable $gh
        Assert ($shipped.status -eq 'on-hold' -and $shipped.destinations['itch-windows'].status -eq 'succeeded' -and $shipped.destinations.notes.status -eq 'held' -and -not (Test-Path $env:BA_FIXTURE_NOTE_STORE)) 'Successful preflight did not preserve deferred note publication.'
        Set-ReleaseDestinationHold $prepared.statePath @('notes') -Release | Out-Null
        $complete=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -GhExecutable $gh
        Assert ($complete.status -eq 'published' -and $complete.destinations['itch-windows'].attempts -eq 1) 'Notes resume repeated a successful upload or retained a resolved preflight failure.'
    } finally {Remove-Item Env:BA_FIXTURE_NOTE_STORE;Remove-Item Env:BA_FIXTURE_NO_PUSH -ErrorAction SilentlyContinue}
}

Test 'PR review refused legacy metadata completion leaves the journal unchanged' {
    $repo=New-StoreFixture 'review-legacy-refusal'
    $prepared=Invoke-ReleasePrepare $repo @('itch-windows','google-play') (Join-Path $sandbox 'review-legacy-refusal-state') $engine
    $stateFile=Join-Path $prepared.statePath 'state.json';$state=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    foreach ($collection in @('exports','requiredExports')) {foreach ($preset in $state.plan[$collection]) {if ($preset.Contains('useGradle')) {$preset.Remove('useGradle')}}}
    Write-Json $stateFile $state;$before=(Get-FileHash $stateFile).Hash
    Expect-Error {Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler} 'approval'
    Assert ((Get-FileHash $stateFile).Hash -ceq $before) 'Missing approval still persisted legacy metadata.'
    $file=Join-Path $prepared.statePath $state.artifacts[0].files[0].path
    'Changed prepared bytes' | Add-Content $file
    Expect-Error {Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan)} 'artifact changed'
    Assert ((Get-FileHash $stateFile).Hash -ceq $before) 'Rejected artifact still persisted legacy metadata or approval.'
}

Test 'PR review Play unhold requires fresh track review and reuses the same release' {
    $repo=New-StoreFixture 'review-play-track'
    $prepared=Invoke-ReleasePrepare $repo @('itch-windows','google-play') (Join-Path $sandbox 'review-play-track-state') $engine
    $stateFile=Join-Path $prepared.statePath 'state.json';$state=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    Set-ReleaseDestinationHold $prepared.statePath @('google-play') 'Wait for current review.' | Out-Null
    $api=New-PlayServer
    Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -PlayTransport $api.handler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan) | Out-Null
    $api.server.deployedTrack=@{track='production';releases=@(@{versionCodes=@('11');status='inProgress';userFraction=0.2},@{versionCodes=@('10');status='completed'})}
    $before=(Get-FileHash $stateFile).Hash
    Expect-Error {Set-ReleaseDestinationHold $prepared.statePath @('google-play') -Release} 'Play.*review|review.*Play'
    Assert ((Get-FileHash $stateFile).Hash -ceq $before) 'Unreviewed Play unhold changed the journal.'
    Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -PlayTransport $api.handler | Out-Null
    Assert ($api.server.calls.Count -eq 0) 'Changed held track received a store call before fresh review.'
    $released=Set-ReleaseDestinationHold $prepared.statePath @('google-play') -Release -PlayTrackReviewed
    Assert ($released.status -eq 'prepared') 'Freshly reviewed Play did not become ready to resume.'
    $approved=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    $releasedAt=$approved.destinations['google-play'].hold.releasedAt
    Set-ReleaseDestinationHold $prepared.statePath @('google-play') -Release -PlayTrackReviewed | Out-Null
    Assert ((Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable).destinations['google-play'].hold.releasedAt -ceq $releasedAt) 'Repeat unhold rewrote the release timestamp.'
    $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -PlayTransport $api.handler
    $after=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    Assert ($result.destinations['google-play'].status -eq 'submitted' -and $api.server.uploads -eq 1 -and $result.destinations['itch-windows'].attempts -eq 1) 'Reviewed Play resume rebuilt or republished completed stores.'
    Assert (($after.artifacts | ConvertTo-Json -Depth 20 -Compress) -ceq ($state.artifacts | ConvertTo-Json -Depth 20 -Compress) -and $after.approval.notesSha256 -ceq $approved.approval.notesSha256 -and (Get-ReleaseConfiguration $repo).presets[2].versionCode -eq 12) 'Reviewed resume changed artifacts, notes approval or Android counter.'
}

Test 'PR review definitive failures without remote progress can be held and resumed' {
    $repo=New-StoreFixture 'review-failed-hold'
    $prepared=Invoke-ReleasePrepare $repo @('itch-windows','steam','google-play') (Join-Path $sandbox 'review-failed-hold-state') $engine
    $stateFile=Join-Path $prepared.statePath 'state.json';$state=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    $missingTool=Join-Path $sandbox 'review-uninstalled-store.exe'
    $priorSteamUsername=$env:BA_STEAM_USERNAME;Remove-Item Env:BA_STEAM_USERNAME -ErrorAction SilentlyContinue
    try {
        $failed=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $missingTool -SteamCmdExecutable $missingTool -PlayTransport {throw 'No fixture credentials before edit creation.'} -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan)
        Assert ($failed.status -eq 'publication-failed' -and $failed.destinations['google-play'].remote.Contains('notesHashes')) 'Fixture did not record definitive failures with local bookkeeping.'
        Set-ReleaseDestinationHold $prepared.statePath @('itch-windows','steam','google-play') 'Store access awaits repair.' | Out-Null
        $api=New-PlayServer
        $held=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -SteamCmdExecutable $steam -PlayTransport $api.handler
        Assert ($held.status -eq 'on-hold' -and $api.server.calls.Count -eq 0 -and @($held.destinations.Values | Where-Object {$_.attempts -gt 1}).Count -eq 0) 'Held failed destination was attempted again.'
        Set-ReleaseDestinationHold $prepared.statePath @('itch-windows','steam','google-play') -Release -PlayTrackReviewed | Out-Null
        $env:BA_STEAM_USERNAME='fixture'
        $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -SteamCmdExecutable $steam -PlayTransport $api.handler
        Assert ($result.destinations['itch-windows'].status -eq 'succeeded' -and $result.destinations.steam.status -eq 'awaiting-store-action' -and $result.destinations['google-play'].status -eq 'submitted') 'Explicit unhold did not resume definitive failed destinations.'
    } finally {$env:BA_STEAM_USERNAME=$priorSteamUsername}
}

Test 'PR review holds still refuse remote evidence and uncertain operations' {
    $repo=New-StoreFixture 'review-remote-hold'
    $prepared=Invoke-ReleasePrepare $repo @('google-play') (Join-Path $sandbox 'review-remote-hold-state') $engine
    $stateFile=Join-Path $prepared.statePath 'state.json';$state=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    foreach ($key in @('editId','buildId','phase','live','ambiguous','unknownProgress')) {
        $state.destinations['google-play'].status='failed';$state.destinations['google-play'].attempts=1
        $state.destinations['google-play'].remote=@{sourceCommit=$state.plan.head};$state.destinations['google-play'].remote[$key]='fixture-progress'
        Write-Json $stateFile $state;$before=(Get-FileHash $stateFile).Hash
        Expect-Error {Set-ReleaseDestinationHold $prepared.statePath @('google-play') 'Wait.'} 'reconcil|started'
        Assert ((Get-FileHash $stateFile).Hash -ceq $before) "Hold concealed remote $key evidence."
    }
    foreach ($status in @('uncertain','in-progress')) {
        $state.destinations['google-play'].status=$status;$state.destinations['google-play'].remote=@{sourceCommit=$state.plan.head}
        Write-Json $stateFile $state
        Expect-Error {Set-ReleaseDestinationHold $prepared.statePath @('google-play') 'Wait.'} 'reconcil|started'
    }
}

Test 'PR review notes awaiting shipment can be held and unheld accurately' {
    $repo=New-Fixture 'review-awaiting-notes'
    $prepared=Invoke-ReleasePrepare $repo @('notes') (Join-Path $sandbox 'review-awaiting-notes-state')
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    $env:BA_FIXTURE_NOTE_STORE=Join-Path $sandbox 'review-awaiting-notes.md'
    try {
        Invoke-ReleasePublish -StatePath $prepared.statePath -GhExecutable $gh -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan) | Out-Null
        $held=Set-ReleaseDestinationHold $prepared.statePath @('notes') 'Wait for a store to ship.'
        Assert ($held.status -eq 'on-hold' -and $held.destinations.notes.status -eq 'held') 'Awaiting notes could not be deferred.'
        $released=Set-ReleaseDestinationHold $prepared.statePath @('notes') -Release
        Assert ($released.status -eq 'prepared' -and $released.destinations.notes.attempts -eq 0) 'Unhold invented a notes publication failure or attempt.'
    } finally {Remove-Item Env:BA_FIXTURE_NOTE_STORE}
}

Test 'PR review hold CLI validates reasons and comma separated destination IDs' {
    $repo=New-Fixture 'review-hold-cli'
    $prepared=Invoke-ReleasePrepare $repo @('itch-windows','itch-linux') (Join-Path $sandbox 'review-hold-cli-state') $engine
    $stateFile=Join-Path $prepared.statePath 'state.json';$cli=Join-Path $root 'skills/ba-release/scripts/release.ps1'
    $before=(Get-FileHash $stateFile).Hash
    $result=& pwsh -NoProfile -File $cli -Mode unhold -StatePath $prepared.statePath -Destination 'itch-windows,itch-linux' 2>&1
    Assert ($LASTEXITCODE -eq 1 -and ($result -join "`n") -match 'existing destination hold' -and (Get-FileHash $stateFile).Hash -ceq $before) 'CLI unhold without a previous hold was accepted.'
    $result=& pwsh -NoProfile -File $cli -Mode hold -StatePath $prepared.statePath -Destination 'itch-windows,itch-linux' -HoldReason 'Wait for approval.'
    Assert ($LASTEXITCODE -eq 0) 'CLI hold failed.'
    $held=$result | ConvertFrom-Json -AsHashtable
    Assert ($held.destinations['itch-windows'].status -eq 'held' -and $held.destinations['itch-linux'].status -eq 'held') 'CLI comma-separated selection missed a destination.'
    $before=(Get-FileHash $stateFile).Hash
    $result=& pwsh -NoProfile -File $cli -Mode unhold -StatePath $prepared.statePath -Destination 'itch-windows,itch-linux' -HoldReason 'Accidental extra option.'
    Assert ($LASTEXITCODE -eq 1 -and (Get-FileHash $stateFile).Hash -ceq $before) 'CLI unhold silently ignored HoldReason or changed the journal.'
    $result=& pwsh -NoProfile -File $cli -Mode unhold -StatePath $prepared.statePath -Destination 'itch-windows,itch-linux'
    Assert ($LASTEXITCODE -eq 0 -and ($result | ConvertFrom-Json -AsHashtable).status -eq 'prepared') 'CLI unhold did not report a ready release.'
    $before=(Get-FileHash $stateFile).Hash
    & pwsh -NoProfile -File $cli -Mode unhold -StatePath $prepared.statePath -Destination 'itch-windows,itch-linux' | Out-Null
    Assert ($LASTEXITCODE -eq 0 -and (Get-FileHash $stateFile).Hash -ceq $before) 'Repeat CLI unhold rewrote its timestamp or failed.'
}

Test 'PR review Play and unshipped notes unhold remain ready without inventing a failure' {
    $repo=New-StoreFixture 'review-play-awaiting-notes'
    $prepared=Invoke-ReleasePrepare $repo @('google-play','notes') (Join-Path $sandbox 'review-play-awaiting-notes-state') $engine
    $stateFile=Join-Path $prepared.statePath 'state.json';$state=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    Set-ReleaseDestinationHold $prepared.statePath @('google-play') 'Existing review pending.' | Out-Null
    $env:BA_FIXTURE_NOTE_STORE=Join-Path $sandbox 'review-play-awaiting-notes.md'
    try {
        $waiting=Invoke-ReleasePublish -StatePath $prepared.statePath -GhExecutable $gh -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan)
        Assert ($waiting.status -eq 'awaiting-release') 'Fixture did not defer notes until a store ships.'
        $released=Set-ReleaseDestinationHold $prepared.statePath @('google-play') -Release -PlayTrackReviewed
        Assert ($released.status -eq 'prepared' -and $released.destinations.notes.status -eq 'awaiting-release' -and $released.destinations['google-play'].attempts -eq 0) 'Unhold journalled a nonexistent failure beside unshipped notes.'
    } finally {Remove-Item Env:BA_FIXTURE_NOTE_STORE}
}

Test 'PR review older unreviewed Play unhold stops before publication or journal changes' {
    $repo=New-StoreFixture 'review-older-unhold'
    $prepared=Invoke-ReleasePrepare $repo @('google-play') (Join-Path $sandbox 'review-older-unhold-state') $engine
    $stateFile=Join-Path $prepared.statePath 'state.json';$state=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    $state.destinations['google-play'].hold=@{reason='Previous review cleared.';heldAt='2026-10-01T00:00:00Z';releasedAt='2026-10-02T00:00:00Z'}
    Write-Json $stateFile $state;$before=(Get-FileHash $stateFile).Hash;$api=New-PlayServer
    Expect-Error {Invoke-ReleasePublish -StatePath $prepared.statePath -PlayTransport $api.handler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan)} 'fresh track review'
    Assert ($api.server.calls.Count -eq 0 -and (Get-FileHash $stateFile).Hash -ceq $before) 'Older unreviewed unhold reached a store or rewrote the journal.'
    $cli=Join-Path $root 'skills/ba-release/scripts/release.ps1'
    $result=& pwsh -NoProfile -File $cli -Mode unhold -StatePath $prepared.statePath -Destination google-play
    Assert ($LASTEXITCODE -eq 1 -and (Get-FileHash $stateFile).Hash -ceq $before) 'CLI Play unhold bypassed fresh review.'
    $result=& pwsh -NoProfile -File $cli -Mode unhold -StatePath $prepared.statePath -Destination google-play -PlayTrackReviewed
    Assert ($LASTEXITCODE -eq 0) 'CLI could not record the freshly reviewed older unhold.'
    Invoke-ReleasePublish -StatePath $prepared.statePath -PlayTransport $api.handler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan) | Out-Null
    Assert ($api.server.uploads -eq 1 -and $api.server.commits -eq 1) 'Reviewed older unhold could not resume its original release.'
}

Test 'PR review started legacy Play unholds can record review without clearing reconciliation' {
    $repo=New-StoreFixture 'review-started-legacy-unhold'
    $prepared=Invoke-ReleasePrepare $repo @('google-play') (Join-Path $sandbox 'review-started-legacy-unhold-state') $engine
    $stateFile=Join-Path $prepared.statePath 'state.json';$state=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    Set-ReleaseDestinationHold $prepared.statePath @('google-play') 'Wait for review.' | Out-Null
    Set-ReleaseDestinationHold $prepared.statePath @('google-play') -Release -PlayTrackReviewed | Out-Null
    $api=New-PlayServer;$api.server.failCommit=$true
    $interrupted=Invoke-ReleasePublish -StatePath $prepared.statePath -PlayTransport $api.handler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan)
    Assert ($interrupted.status -eq 'needs-reconciliation') 'Fixture did not record an interrupted commit.'
    foreach ($status in @('failed','in-progress','uncertain')) {
        $state=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
        $state.destinations['google-play'].status=$status
        $state.destinations['google-play'].hold.Remove('playTrackReviewedAt')
        Write-Json $stateFile $state
        $before=(Get-FileHash $stateFile).Hash;$callCount=$api.server.calls.Count
        Expect-Error {Invoke-ReleasePublish -StatePath $prepared.statePath -PlayTransport $api.handler} 'fresh track review'
        Assert ((Get-FileHash $stateFile).Hash -ceq $before -and $api.server.calls.Count -eq $callCount) 'Unreviewed legacy attempt changed state or contacted Play.'
        $reviewed=Set-ReleaseDestinationHold $prepared.statePath @('google-play') -Release -PlayTrackReviewed
        $after=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
        Assert ($reviewed.destinations['google-play'].status -ceq $status -and $after.destinations['google-play'].attempts -eq $state.destinations['google-play'].attempts -and ($after.destinations['google-play'].remote | ConvertTo-Json -Depth 20 -Compress) -ceq ($state.destinations['google-play'].remote | ConvertTo-Json -Depth 20 -Compress)) 'Review acknowledgement cleared the existing failure, uncertainty or remote evidence.'
        Assert ($api.server.calls.Count -eq $callCount -and ($after.approval | ConvertTo-Json -Compress) -ceq ($state.approval | ConvertTo-Json -Compress)) 'Review acknowledgement contacted Play or changed approval.'
    }
    $waiting=Invoke-ReleasePublish -StatePath $prepared.statePath -PlayTransport $api.handler
    Assert ($waiting.status -eq 'needs-reconciliation' -and $api.server.calls.Count -eq $callCount) 'Acknowledgement silently retried an uncertain operation.'
    $complete=Invoke-ReleasePublish -StatePath $prepared.statePath -PlayTransport $api.handler -RetryUncertain
    Assert ($complete.destinations['google-play'].status -eq 'submitted' -and $api.server.uploads -eq 1 -and $api.server.creates -eq 1 -and (Get-ReleaseConfiguration $repo).presets[2].versionCode -eq 12) 'Explicitly reconciled legacy retry changed the bundle, edit or version code.'
}

Test 'PR review legacy unsafe hold text cannot enter public availability' {
    $repo=New-StoreFixture 'review-legacy-private-hold'
    $prepared=Invoke-ReleasePrepare $repo @('itch-windows','google-play','notes') (Join-Path $sandbox 'review-legacy-private-hold-state') $engine
    $stateFile=Join-Path $prepared.statePath 'state.json';$state=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    $state.destinations['google-play'].status='held';$state.destinations['google-play'].hold=@{reason='Authorization: Basic Zml4dHVyZTpmaXh0dXJl';heldAt='2026-10-01T00:00:00Z'}
    Write-Json $stateFile $state;$before=(Get-FileHash $stateFile).Hash
    Expect-Error {Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -GhExecutable $gh -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan)} 'Credential-like'
    Assert ((Get-FileHash $stateFile).Hash -ceq $before) 'Unsafe legacy reason reached publication or changed the journal.'
}

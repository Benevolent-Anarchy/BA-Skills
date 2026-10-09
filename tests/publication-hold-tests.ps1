# Verifies prepared-store holds survive retries without contacting held stores or rebuilding.

Test 'publication hold leaves prepared Play untouched across publication and retries' {
    $repo=New-StoreFixture 'prepared-play-hold'
    $prepared=Invoke-ReleasePrepare $repo @('itch-windows','steam','google-play','notes') (Join-Path $sandbox 'prepared-play-hold-state') $engine
    $stateFile=Join-Path $prepared.statePath 'state.json'
    $before=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    $manifest=$before.artifacts | ConvertTo-Json -Depth 20 -Compress
    $hash=Get-ReleaseNotesHash $prepared.statePath $before.plan
    Set-ReleaseDestinationHold -StatePath $prepared.statePath -Destination @('google-play') -Reason 'Existing review must clear before submission.' | Out-Null
    $held=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    Assert ($held.destinations['google-play'].status -eq 'held' -and $held.plan.planId -eq $before.plan.planId) 'Hold changed the approved plan or was not persisted.'
    $holdTime=$held.destinations['google-play'].hold.heldAt
    Set-ReleaseDestinationHold -StatePath $prepared.statePath -Destination @('google-play') -Reason 'Existing review must clear before submission.' | Out-Null
    Assert ((Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable).destinations['google-play'].hold.heldAt -eq $holdTime) 'Idempotent hold replaced its original timestamp.'
    $api=New-PlayServer
    $env:BA_STEAM_USERNAME='fixture';$env:BA_FIXTURE_NOTE_STORE=Join-Path $sandbox 'held-note.md'
    try {
        $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -SteamCmdExecutable $steam -GhExecutable $gh -PlayTransport $api.handler -ApprovedPlanId $before.plan.planId -ApprovedNotesSha256 $hash
        Assert ($result.destinations['itch-windows'].status -eq 'succeeded' -and $result.destinations.steam.status -eq 'awaiting-store-action' -and $result.destinations.notes.status -eq 'succeeded') 'Hold stopped approved independent destinations.'
        $again=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -SteamCmdExecutable $steam -GhExecutable $gh -PlayTransport $api.handler -RetryUncertain
        Assert ($api.server.calls.Count -eq 0 -and $again.destinations['google-play'].status -eq 'held' -and $again.destinations['google-play'].attempts -eq 0 -and $again.destinations['google-play'].remote.Count -eq 0) 'Publication or retry contacted held Play.'
        Assert ($again.destinations.steam.attempts -eq 1 -and $again.destinations['itch-windows'].attempts -eq 1) 'Retry repeated completed store uploads.'
        $availability=Get-Content ($env:BA_FIXTURE_NOTE_STORE+'.availability') -Raw | ConvertFrom-Json -AsHashtable
        Assert ($availability.destinations['google-play'].status -eq 'held' -and -not $availability.destinations['google-play'].live -and $availability.destinations['google-play'].holdReason -eq 'Existing review must clear before submission.') 'Public availability lost the hold or claimed Play live.'
        Set-ReleaseDestinationHold -StatePath $prepared.statePath -Destination @('google-play') -Release | Out-Null
        $resumed=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -SteamCmdExecutable $steam -GhExecutable $gh -PlayTransport $api.handler
        Assert ($resumed.destinations['google-play'].status -eq 'submitted' -and $api.server.uploads -eq 1 -and $resumed.destinations.steam.attempts -eq 1) 'Explicit unhold did not reuse the same release and completed destinations.'
        $after=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
        Assert (($after.artifacts | ConvertTo-Json -Depth 20 -Compress) -ceq $manifest -and (Get-ReleaseNotesHash $prepared.statePath $after.plan) -ceq $hash -and (Get-ReleaseConfiguration $repo).presets[2].versionCode -eq 12) 'Hold/resume changed artifacts, notes or Android code.'
    } finally {Remove-Item Env:BA_STEAM_USERNAME;Remove-Item Env:BA_FIXTURE_NOTE_STORE}
}

Test 'publication hold validates all destinations before journal writes and refuses started operations' {
    $repo=New-StoreFixture 'hold-validation'
    $prepared=Invoke-ReleasePrepare $repo @('itch-windows','google-play') (Join-Path $sandbox 'hold-validation-state') $engine
    $stateFile=Join-Path $prepared.statePath 'state.json';$hash=(Get-FileHash $stateFile).Hash
    Expect-Error {Set-ReleaseDestinationHold $prepared.statePath @('google-play','steam') 'Wait for review.'} 'selected'
    Expect-Error {Set-ReleaseDestinationHold $prepared.statePath @() 'Wait for review.'} 'destination'
    Expect-Error {Set-ReleaseDestinationHold $prepared.statePath @('google-play') ''} 'reason'
    Assert ((Get-FileHash $stateFile).Hash -eq $hash) 'Rejected hold changed the journal.'
    $state=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan) -PlayTransport {throw 'Keep fixture Play unsubmitted.'} | Out-Null
    $hash=(Get-FileHash $stateFile).Hash
    Expect-Error {Set-ReleaseDestinationHold $prepared.statePath @('google-play') 'Wait for review.'} 'started'
    Expect-Error {Set-ReleaseDestinationHold $prepared.statePath @('itch-windows') 'Wait for review.'} 'started'
    Assert ((Get-FileHash $stateFile).Hash -eq $hash) 'Hold rewrote a started store operation.'
}

Test 'publication hold is reported independently from failures and store actions' {
    $state=@{plan=@{selectedDestinations=@('itch','play')};destinations=@{itch=@{status='succeeded'};play=@{status='held'}}}
    Assert ((& (Get-Module Release) {param($value) Get-ReleaseOverallStatus $value} $state) -eq 'on-hold') 'Held destination was treated as failure or complete publication.'
    $state.destinations.itch.status='failed'
    Assert ((& (Get-Module Release) {param($value) Get-ReleaseOverallStatus $value} $state) -eq 'publication-failed') 'Hold concealed an actual failure.'
    $state.destinations.itch.status='awaiting-store-action'
    Assert ((& (Get-Module Release) {param($value) Get-ReleaseOverallStatus $value} $state) -eq 'needs-store-action') 'Hold concealed pending store action.'
}

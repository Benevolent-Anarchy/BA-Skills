# Keeps exact approved public notes behind shipped-release evidence and a truthful separate availability record.

# Freezes each locale document once its store operation starts, including across later extensions.
function Assert-ReleaseSubmittedNotes($State, [string]$StatePath) {
    foreach ($record in $State.destinations.Values) {
        if (-not $record.remote.Contains('notesHashes')) {continue}
        foreach ($path in $record.remote.notesHashes.Keys) {
            $file=Resolve-ReleasePath $StatePath $path -Leaf
            if ((Get-FileHash $file).Hash.ToLowerInvariant() -cne $record.remote.notesHashes[$path]) {throw 'A previously submitted locale cannot change through approval of an extended release.'}
        }
    }
}

# Packages reviewed locale text for fastlane without uploading or changing the text.
function Export-ReleasePlayChangelogs([string]$StatePath) {
    $state=[IO.File]::ReadAllText((Join-Path $StatePath 'state.json')) | ConvertFrom-Json -AsHashtable
    Get-ReleaseNotesHash $StatePath $state.plan | Out-Null
    foreach ($destination in @($state.plan.destinations | Where-Object {$_.selected -and $_.type -eq 'google-play'})) {
        $path=Resolve-ReleasePath $StatePath "fastlane/metadata/android/$($destination.language)/changelogs/$($destination.versionCode).txt"
        New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($path,[IO.File]::ReadAllText((Join-Path $StatePath "notes.$($destination.id).txt")),[Text.UTF8Encoding]::new($false))
        $path
    }
}

# Checks public visibility, write access and existing notes before starting any selected store writes.
function Assert-ReleaseNotesDestination($Plan, [string]$Notes, [string]$StatePath, [string]$GhExecutable) {
    if (-not $Notes.Contains("[Release availability](../availability/$($Plan.version).json)")) {throw (New-ReleaseDiagnosticError 'Approved canonical notes require the predictable availability link.')}
    $response=Invoke-ReleaseTool $GhExecutable @('api','--hostname','github.com',"repos/$($Plan.notesRepository)") $StatePath
    if ($response.exitCode -ne 0) {throw (New-ReleaseDiagnosticError 'Public notes repository is unavailable.')}
    $metadata=$response.text | ConvertFrom-Json -AsHashtable
    if (-not $metadata.Contains('private') -or $metadata.private -ne $false -or -not $metadata.Contains('permissions') -or $metadata.permissions['push'] -ne $true) {throw (New-ReleaseDiagnosticError 'Public notes require a public repository and verified write permission.')}
    $existing=Invoke-ReleaseTool $GhExecutable @('api','--hostname','github.com',"repos/$($Plan.notesRepository)/contents/releases/$($Plan.version).md") $StatePath
    if ($existing.exitCode -eq 0) {
        $entry=$existing.text | ConvertFrom-Json -AsHashtable
        if ($entry.encoding -ne 'base64' -or [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($entry.content)) -cne $Notes) {throw (New-ReleaseDiagnosticError 'Existing public canonical notes conflict with the approved content.')}
    } elseif ($existing.text -notmatch '(?i)HTTP 404|Not Found') {throw (New-ReleaseDiagnosticError 'Cannot verify existing public notes.')}
}

# Requires actual live evidence for this release; an uploaded Steam build or submitted Play edit is insufficient.
function Test-ReleaseShipped($State, [string]$StatePath) {
    foreach ($destination in $State.plan.destinations) {
        if ($destination.selected -and $destination.type -ne 'notes' -and $State.destinations[$destination.id].remote.Contains('live') -and $State.destinations[$destination.id].remote.live -eq $true) {return $true}
    }
    if (@(Get-ReleaseShipmentReceipts $State $StatePath).Count) {return $true}
    foreach ($other in @(Get-ReleaseRelatedStates $State $StatePath)) {
        foreach ($destination in $other.plan.destinations) {
            if ($destination.selected -and $destination.type -ne 'notes' -and $other.destinations[$destination.id].remote.Contains('live') -and $other.destinations[$destination.id].remote.live -eq $true) {return $true}
        }
    }
    return $false
}

# Lists every live receipt any checkout of the game recorded for this release's version, current and kept in history.
function Get-ReleaseVersionReceipts($State, [string]$StatePath) {
    $repositoryState=Split-Path $StatePath -Parent
    $records=Get-ReleaseLiveRecords (Get-ReleasePlanSourceRepository $State.plan) (Split-Path $repositoryState -Parent) (Split-Path $repositoryState -Leaf)
    return @(Get-ReleaseLiveReceipts $records | Where-Object {$_.entry.version -ceq $State.plan.version})
}

# Lists the live receipts any checkout of the game recorded for this exact release: its version, from its source.
function Get-ReleaseShipmentReceipts($State, [string]$StatePath) {
    return @(Get-ReleaseVersionReceipts $State $StatePath | Where-Object {$_.entry.sourceCommit -ceq $State.plan.head})
}

# Reads the other journals of this same release that live receipts point to: the same version, now at the same source.
# An extended release keeps each artifact's own source, so a channel's receipt can name an older commit than the release;
# the journal it points to, not that commit, says which release it belongs to. Other same-version journals are ignored.
function Get-ReleaseRelatedStates($State, [string]$StatePath) {
    $own=[IO.Path]::GetFullPath($StatePath).TrimEnd('\','/')
    $paths=@(Get-ReleaseVersionReceipts $State $StatePath | Where-Object {$_.entry.statePath} | ForEach-Object {[IO.Path]::GetFullPath([string]$_.entry.statePath).TrimEnd('\','/')} | Sort-Object -Unique)
    foreach ($path in $paths) {
        if ($path -eq $own) {continue}
        $file=Join-Path $path 'state.json'
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {continue}
        $other=[IO.File]::ReadAllText($file) | ConvertFrom-Json -AsHashtable
        if ($other.plan.version -ceq $State.plan.version -and $other.plan.head -ceq $State.plan.head) {$other}
    }
}

# Finds how another journal of this release records destination $Id: a live record first; then, where this checkout did
# not select the destination itself ($AnyStatus), whatever a journal that selected it records, pending or held work included.
function Find-ReleaseRelatedDestinationRecord($Related, [string]$Id, [bool]$AnyStatus) {
    foreach ($liveOnly in @($true,$false)) {
        if (-not $liveOnly -and -not $AnyStatus) {break}
        foreach ($other in $Related) {
            if (-not @($other.plan.destinations | Where-Object {$_.id -ceq $Id -and $_.selected}).Count -or -not $other.destinations.Contains($Id)) {continue}
            $record=$other.destinations[$Id]
            if (-not $liveOnly -or ($record.remote.Contains('live') -and $record.remote.live -eq $true)) {return $record}
        }
    }
    return $null
}

# Writes changing factual availability with ordinary subsequent GitHub commits while preserving canonical notes.
# A store another journal of this same release made live, or selected where this one did not, is reported as that journal
# records it, so a checkout that did not publish there reports it as the publishing one does; this selection is unchanged.
function Publish-ReleaseAvailability($State, [string]$StatePath, [string]$GhExecutable) {
    $destinations=[ordered]@{}
    $related=@(Get-ReleaseRelatedStates $State $StatePath)
    foreach ($destination in $State.plan.destinations) {
        if ($destination.type -eq 'notes') {continue}
        $record=$State.destinations[$destination.id];$selected=$destination.selected
        if (-not ($record.remote.Contains('live') -and $record.remote.live -eq $true)) {
            $shared=Find-ReleaseRelatedDestinationRecord $related $destination.id (-not $destination.selected)
            if ($shared) {$record=$shared;$selected=$true}
        }
        $destinations[$destination.id]=[ordered]@{type=$destination.type;selected=$selected;status=$record.status;live=($record.remote.Contains('live') -and $record.remote.live -eq $true)}
        if ($record.status -eq 'held') {Assert-ReleaseHoldReason $record.hold.reason;$destinations[$destination.id].holdReason=$record.hold.reason}
        if ($record.remote.Contains('buildId')) {$destinations[$destination.id].buildId=$record.remote.buildId}
        if ($destination.Contains('versionCode')) {$destinations[$destination.id].versionCode=$destination.versionCode}
    }
    $content=([ordered]@{schemaVersion=1;generator='ba-release';version=$State.plan.version;sourceCommit=$State.plan.head;destinations=$destinations} | ConvertTo-Json -Depth 15)+"`n"
    $path="repos/$($State.plan.notesRepository)/contents/availability/$($State.plan.version).json"
    $existing=Invoke-ReleaseTool $GhExecutable @('api','--hostname','github.com',$path) $StatePath
    $sha=$null
    if ($existing.exitCode -eq 0) {
        $entry=$existing.text | ConvertFrom-Json -AsHashtable
        if ($entry.encoding -ne 'base64' -or -not $entry.sha) {throw 'Cannot verify public availability content.'}
        $previous=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($entry.content))
        if ($previous -ceq $content) {return}
        $old=$previous | ConvertFrom-Json -AsHashtable
        if ($old -isnot [Collections.IDictionary] -or $old['generator'] -cne 'ba-release' -or $old['version'] -cne $State.plan.version) {throw 'Conflicting availability file is not an owned record for this release.'}
        $sha=$entry.sha
    } elseif ($existing.text -notmatch '(?i)HTTP 404|Not Found') {throw 'Cannot verify existing availability record.'}
    $body=[ordered]@{message="Release $($State.plan.version) availability";content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))}
    if ($sha) {$body.sha=$sha}
    $requestPath=Join-Path $StatePath 'availability-request.json';Write-ReleaseJson $requestPath $body
    $result=Invoke-ReleaseTool $GhExecutable @('api','--hostname','github.com','--method','PUT',$path,'--input',$requestPath) $StatePath
    if ($result.exitCode -ne 0) {throw 'Public availability update failed.'}
}

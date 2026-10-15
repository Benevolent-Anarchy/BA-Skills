# Uploads approved Steam snapshots and Google Play bundles while retaining remote progress.
#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ProcessTools.psm1') -Force

# Quotes VDF data without allowing config strings to introduce new VDF keys.
function ConvertTo-SteamVdfValue([string]$Value) {
    return '"' + $Value.Replace('\','\\').Replace('"','\"') + '"'
}

# Builds fresh VDFs from approved depot mappings; original SDK scripts and credentials stay untouched.
function Publish-SteamRelease($Plan, $Destination, $Artifacts, [string]$StatePath, [string]$SteamCmdExecutable, $Record, [scriptblock]$SaveState) {
    if ($Record.remote.Contains('phase') -and $Record.remote.phase -eq 'build-uploaded-with-error' -and $Record.remote.Contains('buildId')) {
        # A known completed upload needs branch/announcement work, not another upload.
        $Record.remote.phase='build-uploaded';$Record.remote.ambiguous=$false;& $SaveState
        return 'awaiting-store-action'
    }
    if ([string]::IsNullOrWhiteSpace($env:BA_STEAM_USERNAME) -or $env:BA_STEAM_USERNAME -notmatch '^[A-Za-z0-9_-]+$') { throw (New-ReleaseDiagnosticError 'Set BA_STEAM_USERNAME for the existing authenticated SteamCMD account; passwords are never script arguments.') }
    $directory=Join-Path $StatePath ("steam/"+$Destination.id+'/'+[guid]::NewGuid().ToString('N'))
    $output=Join-Path $directory 'output'
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    $depotLines=[Collections.Generic.List[string]]::new()
    foreach ($depot in $Destination.depots) {
        $artifact=@($Artifacts | Where-Object {$_.preset -ceq $depot.preset})
        if ($artifact.Count -ne 1) {throw (New-ReleaseDiagnosticError 'Steam depot artifact was not uniquely prepared.')}
        $contentRoot=[IO.Path]::GetFullPath((Join-Path $StatePath $artifact[0].directory))
        $depotPath=Join-Path $directory "depot_$($depot.id).vdf"
        $vdf='"DepotBuildConfig"' + "`n{`n" + '  "DepotID" '+(ConvertTo-SteamVdfValue $depot.id)+"`n" + '  "ContentRoot" '+(ConvertTo-SteamVdfValue $contentRoot)+"`n"
        $vdf += '  "FileMapping" { "LocalPath" "*" "DepotPath" "." "Recursive" "1" }' + "`n"
        foreach ($pattern in $depot.exclude) { $vdf += '  "FileExclusion" '+(ConvertTo-SteamVdfValue $pattern)+"`n" }
        $vdf += "}`n"
        [IO.File]::WriteAllText($depotPath,$vdf,[Text.UTF8Encoding]::new($false))
        $depotLines.Add('    '+(ConvertTo-SteamVdfValue $depot.id)+' '+(ConvertTo-SteamVdfValue $depotPath))
    }
    $setLive=if ($Destination.branch -eq 'default') {''} else {$Destination.branch}
    $appPath=Join-Path $directory "app_$($Destination.appId).vdf"
    $vdf='"AppBuild"' + "`n{`n" + '  "AppID" '+(ConvertTo-SteamVdfValue $Destination.appId)+"`n" + '  "Desc" '+(ConvertTo-SteamVdfValue "Version $($Plan.version)")+"`n" + '  "BuildOutput" '+(ConvertTo-SteamVdfValue $output)+"`n" + '  "SetLive" '+(ConvertTo-SteamVdfValue $setLive)+"`n" + '  "Preview" "0"'+"`n"+'  "Depots"'+"`n  {`n"+($depotLines -join "`n")+"`n  }`n}`n"
    [IO.File]::WriteAllText($appPath,$vdf,[Text.UTF8Encoding]::new($false))
    Push-Location -LiteralPath $StatePath
    try {$uploadExecutable=Find-ReleaseDoctorTool $SteamCmdExecutable} finally {Pop-Location}
    if (-not $uploadExecutable) {throw (New-ReleaseDiagnosticError 'SteamCMD executable is unavailable before upload.')}
    $Record.remote.phase='uploading'; $Record.remote.ambiguous=$false; & $SaveState
    $result=Invoke-ReleaseTool $uploadExecutable @('+login',$env:BA_STEAM_USERNAME,'+run_app_build',$appPath,'+quit') $StatePath
    # SteamCMD can exit zero on errors. Require the observed AppID/BuildID success record.
    $logPath=Join-Path $output "app_build_$($Destination.appId).log"
    $proof=$result.text
    if (Test-Path -LiteralPath $logPath) {$proof += "`n"+[IO.File]::ReadAllText($logPath)}
    $pattern='Successfully finished AppID\s+'+[regex]::Escape([string]$Destination.appId)+'\s+build\s+\(BuildID\s+(?<build>\d+)\)'
    if ($proof -notmatch $pattern) {
        if ($result.exitCode -eq 0) {$Record.remote.ambiguous=$true}
        if ($result.exitCode -ne 0) {throw (New-ReleaseDiagnosticError "SteamCMD upload failed (exit $([int]$result.exitCode)); no verifiable build-completion record.")}
        throw (New-ReleaseDiagnosticError 'SteamCMD did not provide a verifiable build-completion record.')
    }
    $Record.remote.buildId=$Matches.build; $Record.remote.phase='build-uploaded'
    $Record.remote.appId=$Destination.appId; $Record.remote.branch=$Destination.branch
    $Record.remote.portal="https://partner.steamgames.com/apps/builds/$($Destination.appId)"
    $Record.remote.requiredActions=@('Verify the uploaded build is live on the approved branch.','Publish the approved patch notes as a Steam announcement and verify its URL.')
    if ($result.exitCode -ne 0) {
        $Record.remote.phase='build-uploaded-with-error';$Record.remote.ambiguous=$true;& $SaveState
        throw (New-ReleaseDiagnosticError "SteamCMD reported completion followed by an error (exit $([int]$result.exitCode)); reconcile the saved build ID.")
    }
    & $SaveState
    return 'awaiting-store-action'
}

# Sends one fixed-host API operation; credentials exist only in the request runtime, never in journals.
function Invoke-PlayRequest($Request, [scriptblock]$Transport) {
    if ($Transport) {return (& $Transport $Request)}
    if (-not $env:BA_GOOGLE_PLAY_ACCESS_TOKEN) {throw 'BA_GOOGLE_PLAY_ACCESS_TOKEN is required at publication; use an existing Android Publisher OAuth login.'}
    $parameters=@{Uri=$Request.uri;Method=$Request.method;Authentication='Bearer';Token=(ConvertTo-SecureString $env:BA_GOOGLE_PLAY_ACCESS_TOKEN -AsPlainText -Force);TimeoutSec=600;ErrorAction='Stop'}
    if ($Request.Contains('file')) {$parameters.InFile=$Request.file;$parameters.ContentType='application/octet-stream'}
    elseif ($Request.Contains('body')) {$parameters.Body=($Request.body | ConvertTo-Json -Depth 20 -Compress);$parameters.ContentType='application/json'}
    try {return (Invoke-RestMethod @parameters | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable)}
    catch {
        $safeError=[Exception]::new('Google Play API request failed; inspect the account permissions, edit and store state without recording credentials.')
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {$safeError.Data['statusCode']=[int]$_.Exception.Response.StatusCode}
        throw $safeError
    }
}

# Compares only approved release semantics against a fresh edit's deployed-state copy.
function Test-PlayTrackMatches($Track, $Release, [string]$Language, [string]$Notes) {
    if (-not $Track.Contains('releases') -or @($Track.releases).Count -ne 1) {return $false}
    $observed=$Track.releases[0]
    foreach ($key in @('name','status','versionCodes','releaseNotes')) {if (-not $observed.Contains($key)) {return $false}}
    if ($observed.name -cne $Release.name -or $observed.status -cne $Release.status) {return $false}
    if ((@($observed.versionCodes | ForEach-Object {[string]$_} | Sort-Object -Unique) -join ',') -cne (@($Release.versionCodes | Sort-Object -Unique) -join ',')) {return $false}
    if ($Release.status -eq 'inProgress' -and (-not $observed.Contains('userFraction') -or $observed.userFraction -ne $Release.userFraction)) {return $false}
    $locale=@($observed.releaseNotes | Where-Object {$_.language -ceq $Language})
    return ($locale.Count -eq 1 -and $locale[0].text -ceq $Notes)
}

# Reuses an edit and matching bundle on retry; a lost commit response stays uncertain.
function Publish-PlayRelease($Plan, $Destination, $Artifacts, [string]$StatePath, $Record, [scriptblock]$SaveState, [scriptblock]$Transport, [switch]$ReplacePlayEdit) {
    $artifact=@($Artifacts | Where-Object {$_.preset -ceq $Destination.preset})
    if ($artifact.Count -ne 1) {throw 'Google Play bundle was not uniquely prepared.'}
    $bundles=@($artifact[0].files | Where-Object {$_.path.EndsWith('.aab',[StringComparison]::OrdinalIgnoreCase)})
    if ($bundles.Count -ne 1) {throw 'Google Play needs exactly one staged Android App Bundle.'}
    $file=[IO.Path]::GetFullPath((Join-Path $StatePath $bundles[0].path))
    $notes=[IO.File]::ReadAllText((Join-Path $StatePath "notes.$($Destination.id).txt"))
    if ([string]::IsNullOrWhiteSpace($notes) -or $notes.Length -gt 500) {throw 'Google Play release notes must contain 1 to 500 characters.'}
    $base='https://androidpublisher.googleapis.com/androidpublisher/v3/applications/'+[Uri]::EscapeDataString($Destination.packageName)
    if ($Record.remote.Contains('phase') -and $Record.remote.phase -eq 'existing-track-matched' -and $Record.remote.Contains('bundleSha256') -and $Record.remote.bundleSha256.ToLowerInvariant() -ceq $bundles[0].sha256 -and $Record.remote.versionCode -eq $Destination.versionCode) {
        # A previously proven deployed match stays complete even if inspection-edit cleanup was interrupted.
        if (-not $Record.remote.Contains('cleanupStatus')) {$Record.remote.cleanupStatus='pending';& $SaveState}
        return $(if ($Destination.releaseStatus -eq 'draft') {'awaiting-store-action'} else {'submitted'})
    }
    $createdThisAttempt=$false
    if (-not $Record.remote.Contains('editId')) {
        $edit=Invoke-PlayRequest @{method='POST';uri="$base/edits";body=@{}} $Transport
        if (-not $edit.id -or $edit.id -notmatch '^[A-Za-z0-9_-]+$') {throw 'Google Play returned no valid edit ID.'}
        $Record.remote.editId=$edit.id; $Record.remote.phase='edit-created';$createdThisAttempt=$true; & $SaveState
    }
    $editBase="$base/edits/$($Record.remote.editId)"
    try {Invoke-PlayRequest @{method='GET';uri=$editBase} $Transport | Out-Null}
    catch {
        # Only a confirmed missing edit may be replaced, and only with explicit recovery authorization.
        if (-not $ReplacePlayEdit -or -not $_.Exception.Data.Contains('statusCode') -or $_.Exception.Data['statusCode'] -ne 404) {throw}
        $prior=@{id=$Record.remote.editId;phase=$Record.remote.phase;reason='not-found'}
        $edit=Invoke-PlayRequest @{method='POST';uri="$base/edits";body=@{}} $Transport
        if (-not $edit.id -or $edit.id -notmatch '^[A-Za-z0-9_-]+$') {throw 'Google Play returned no valid replacement edit ID.'}
        $history=if ($Record.remote.Contains('previousEdits')) {@($Record.remote.previousEdits)} else {@()}
        $Record.remote.previousEdits=$history+@($prior);$Record.remote.editId=$edit.id;$Record.remote.phase='replacement-edit-created';$createdThisAttempt=$true
        & $SaveState
        $editBase="$base/edits/$($Record.remote.editId)"
        Invoke-PlayRequest @{method='GET';uri=$editBase} $Transport | Out-Null
    }
    $existing=Invoke-PlayRequest @{method='GET';uri="$editBase/bundles"} $Transport
    $same=@(if ($existing.Contains('bundles')) {$existing.bundles | Where-Object {[string]$_.versionCode -eq [string]$Destination.versionCode}})
    if ($same.Count) {
        if ($same.Count -ne 1 -or $same[0].sha256.ToLowerInvariant() -cne $bundles[0].sha256) {throw 'The Android version code is already assigned to a different bundle; do not change it during a retry.'}
        $bundle=$same[0]
    } else {
        $uploadBase='https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/'+[Uri]::EscapeDataString($Destination.packageName)+"/edits/$($Record.remote.editId)/bundles?uploadType=media"
        $bundle=Invoke-PlayRequest @{method='POST';uri=$uploadBase;file=$file} $Transport
        if ([string]$bundle.versionCode -cne [string]$Destination.versionCode -or $bundle.sha256.ToLowerInvariant() -cne $bundles[0].sha256) {throw 'Uploaded bundle version code or SHA-256 differs from the approved snapshot.'}
    }
    $Record.remote.versionCode=$bundle.versionCode; $Record.remote.bundleSha256=$bundle.sha256
    $Record.remote.phase='bundle-uploaded'; & $SaveState
    $trackUrl="$editBase/tracks/$([Uri]::EscapeDataString($Destination.track))"
    $currentTrack=Invoke-PlayRequest @{method='GET';uri=$trackUrl} $Transport
    $release=[ordered]@{name=$Plan.version;versionCodes=@(@($Destination.retainVersionCodes)+@([string]$Destination.versionCode) | Sort-Object -Unique);releaseNotes=@(@{language=$Destination.language;text=$notes});status=$Destination.releaseStatus}
    if ($Destination.releaseStatus -eq 'inProgress') {$release.userFraction=$Destination.userFraction}
    if ($createdThisAttempt -and (Test-PlayTrackMatches $currentTrack $release $Destination.language $notes)) {
        # A fresh edit copies deployed state: identical bundle hash plus track proves no resubmission is needed.
        $Record.remote.phase='existing-track-matched';$Record.remote.track=$Destination.track;$Record.remote.releaseStatus=$Destination.releaseStatus;$Record.remote.portal='https://play.google.com/console'
        & $SaveState
        try {
            Invoke-PlayRequest @{method='DELETE';uri=$editBase} $Transport | Out-Null
            $Record.remote.cleanupStatus='succeeded'
        } catch {
            $Record.remote.cleanupStatus='failed'
            $Record.remote.cleanupError='Inspection edit cleanup failed; the approved deployed release remains matched and will not be resubmitted.'
        }
        & $SaveState
        return $(if ($Destination.releaseStatus -eq 'draft') {'awaiting-store-action'} else {'submitted'})
    }
    Invoke-PlayRequest @{method='PUT';uri=$trackUrl;body=@{track=$Destination.track;releases=@($release)}} $Transport | Out-Null
    $Record.remote.phase='track-updated'; & $SaveState
    Invoke-PlayRequest @{method='POST';uri="${editBase}:validate"} $Transport | Out-Null
    $Record.remote.phase='committing'; & $SaveState
    Invoke-PlayRequest @{method='POST';uri="${editBase}:commit?changesInReviewBehavior=ERROR_IF_IN_REVIEW"} $Transport | Out-Null
    $Record.remote.phase='edit-committed'; $Record.remote.track=$Destination.track
    $Record.remote.releaseStatus=$Destination.releaseStatus; $Record.remote.portal='https://play.google.com/console'
    & $SaveState
    return $(if ($Destination.releaseStatus -eq 'draft') {'awaiting-store-action'} else {'submitted'})
}
Export-ModuleMember -Function Publish-SteamRelease,Publish-PlayRelease

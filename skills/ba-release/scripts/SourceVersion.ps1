# Reserves release version settings once and requires their source commit before building binaries.

# Calculates explicit semantic-version operations without touching project files.
function Get-ReleaseVersion([string]$Current, [ValidateSet('current','patch','minor','major')][string]$Operation='current') {
    if ($Operation -eq 'current') {return $Current}
    if ($Current -notmatch '^(\d+)\.(\d+)\.(\d+)$') {throw 'Automatic bumps require a plain major.minor.patch version; select prerelease versions in the project explicitly.'}
    $parts=@([long]$Matches[1],[long]$Matches[2],[long]$Matches[3])
    switch ($Operation) {'major' {$parts[0]++;$parts[1]=0;$parts[2]=0} 'minor' {$parts[1]++;$parts[2]=0} 'patch' {$parts[2]++}}
    return $parts -join '.'
}

# Changes one scalar key in one existing Godot section, preserving all other text.
function Set-ReleaseGodotScalar([string]$Text, [string]$Section, [string]$Key, [string]$Value) {
    $sectionPattern='(?ms)(^\['+[regex]::Escape($Section)+'\]\s*\r?\n)(.*?)(?=^\[|\z)'
    $matchesForSection=[regex]::Matches($Text,$sectionPattern)
    if ($matchesForSection.Count -ne 1) {throw "Cannot uniquely update Godot section: $Section"}
    $match=$matchesForSection[0];$body=$match.Groups[2].Value
    $keyPattern='(?m)^('+[regex]::Escape($Key)+'\s*=)[^\r\n]*'
    if ([regex]::Matches($body,$keyPattern).Count -ne 1) {throw "Cannot uniquely update Godot key: $Key"}
    $replacement=[regex]::Replace($body,$keyPattern,[Text.RegularExpressions.MatchEvaluator]{param($m) $m.Groups[1].Value+$Value})
    return $Text.Substring(0,$match.Groups[2].Index)+$replacement+$Text.Substring($match.Groups[2].Index+$body.Length)
}

# Selects independent numeric counters from explicitly selected Android artifacts.
function Get-ReleaseAndroidCounterPresets($Settings, $Plan, [string[]]$Destination=@()) {
    $policy=if ($Settings.config.Contains('androidVersionCodePolicy')) {$Settings.config.androidVersionCodePolicy} else {'existing'}
    if ($policy -eq 'existing') {return @()}
    return @(@(foreach ($target in $Plan.destinations) {
        if (-not $target.selected -or ($Destination.Count -and $target.id -cnotin $Destination)) {continue}
        if ($target.type -eq 'google-play' -or ($policy -eq 'increment-selected' -and $target.type -eq 'itch')) {
            $preset=@($Settings.presets | Where-Object {$_.name -ceq $target.preset})[0]
            if ($preset.platform -eq 'Android') {$preset.name}
        }
    }) | Sort-Object -Unique -CaseSensitive)
}

# Journals intended edits before writing them; retries reuse the reservation rather than incrementing again.
function Initialize-ReleaseSource($Settings, $Plan, [string]$RepositoryState, [string]$VersionChange, [switch]$NewRelease, [string[]]$CounterPreset) {
    $pointer=Join-Path $RepositoryState 'active-source.json'
    $counterPresets=@(if ($PSBoundParameters.ContainsKey('CounterPreset')) {$CounterPreset} else {Get-ReleaseAndroidCounterPresets $Settings $Plan})
    $increment=$counterPresets.Count -gt 0
    $existing=Test-Path -LiteralPath $pointer -PathType Leaf
    if (-not $existing -and $VersionChange -eq 'current' -and -not $increment) {return $null}
    if (-not $existing -and -not $Plan.ready) {throw "Release plan is blocked: $($Plan.blockers -join ' ')"}
    New-Item -ItemType Directory -Path $RepositoryState -Force | Out-Null
    $lock=Lock-ReleaseState $RepositoryState
    try {
        $reservation=if (Test-Path -LiteralPath $pointer -PathType Leaf) {[IO.File]::ReadAllText($pointer) | ConvertFrom-Json -AsHashtable} else {$null}
        if ($reservation -and ($NewRelease -or ($reservation.status -eq 'committed' -and $Settings.version -cne $reservation.version))) {
            if ($reservation.status -ne 'committed' -or -not $Plan.ready) {throw 'Finish the existing source reservation before selecting a new release.'}
            $reservation=$null
        }
        if (-not $reservation) {
            if (-not $Plan.ready) {throw "Release plan is blocked: $($Plan.blockers -join ' ')"}
            if ($VersionChange -eq 'current' -and -not $increment) {return $null}
            $version=Get-ReleaseVersion $Settings.version $VersionChange
            $projectFile=Join-Path $Settings.projectPath 'project.godot';$presetFile=Join-Path $Settings.projectPath 'export_presets.cfg'
            $projectText=[IO.File]::ReadAllText($projectFile);$presetText=[IO.File]::ReadAllText($presetFile)
            $updatedProject=if ($version -cne $Settings.version) {Set-ReleaseGodotScalar $projectText 'application' 'config/version' ($version | ConvertTo-Json -Compress)} else {$projectText}
            $updatedPreset=$presetText;$sections=Read-GodotSections $presetFile;$codes=@()
            foreach ($section in $sections.Keys) {
                if ($section -notmatch '^preset\.\d+$') {continue}
                $optionsKey=$section+'.options'
                if (-not $sections.Contains($optionsKey)) {continue}
                $options=$sections[$optionsKey]
                # Explicit metadata already following the source version continues to follow it.
                foreach ($key in @('version/name','application/file_version','application/product_version')) {
                    if ($options.Contains($key) -and $options[$key] -ceq $Settings.version -and $version -cne $Settings.version) {$updatedPreset=Set-ReleaseGodotScalar $updatedPreset $optionsKey $key ($version | ConvertTo-Json -Compress)}
                    elseif ($options.Contains($key) -and $key -like 'application/*' -and $options[$key] -ceq "$($Settings.version).0" -and $version -cne $Settings.version) {$updatedPreset=Set-ReleaseGodotScalar $updatedPreset $optionsKey $key ("$version.0" | ConvertTo-Json -Compress)}
                }
                if ($increment -and $sections[$section]['name'] -cin $counterPresets) {
                    $before=[long]$options['version/code'];$after=$before+1
                    if ($after -gt 2100000000) {throw 'Android version code cannot be incremented beyond the Play limit.'}
                    $updatedPreset=Set-ReleaseGodotScalar $updatedPreset $optionsKey 'version/code' ([string]$after)
                    $codes+=@{preset=$sections[$section]['name'];before=$before;after=$after}
                }
            }
            $files=@(foreach ($entry in @(@{path=$projectFile;before=$projectText;after=$updatedProject},@{path=$presetFile;before=$presetText;after=$updatedPreset})) {
                if ($entry.before -ceq $entry.after) {continue}
                @{path=[IO.Path]::GetRelativePath($Settings.repository,$entry.path).Replace('\','/');beforeSha256=(Get-FileHash $entry.path).Hash.ToLowerInvariant();afterSha256=(Get-ReleaseTextHash $entry.after);content=$entry.after}
            })
            $statePath=Join-Path $RepositoryState $version
            if (Test-Path -LiteralPath (Join-Path $statePath 'state.json')) {throw 'This version already has a prepared release; resume or extend it rather than reserving new settings.'}
            $reservation=@{schemaVersion=1;status='reserved';repository=$Settings.repository;originalHead=$Plan.head;configSha256=$Plan.configSha256;version=$version;operation=$VersionChange;selection=$Plan.selectedDestinations;files=$files;androidCodes=$codes;statePath=$statePath}
            Write-ReleaseJson $pointer $reservation
        }
        if ($reservation.configSha256 -cne $Plan.configSha256 -or ($reservation.selection -join ',') -cne ($Plan.selectedDestinations -join ',')) {throw 'Source reservation selection/configuration changed; resume its original release.'}
        if ($VersionChange -ne 'current' -and $VersionChange -cne $reservation.operation) {throw 'Source reservation already has a different version operation.'}
        $ancestor=Invoke-ReleaseTool 'git' @('--no-optional-locks','-C',$Settings.repository,'merge-base','--is-ancestor',$reservation.originalHead,'HEAD') $Settings.repository
        if ($ancestor.exitCode -ne 0) {throw 'Source reservation no longer descends from its original source commit.'}
        foreach ($file in $reservation.files) {
            $path=Resolve-ReleasePath $Settings.repository $file.path -Leaf
            $hash=(Get-FileHash $path).Hash.ToLowerInvariant()
            if ($hash -cne $file.beforeSha256 -and $hash -cne $file.afterSha256) {throw 'Source settings changed outside the reservation; inspect before resuming.'}
            if ($hash -ceq $file.beforeSha256) {
                if ($reservation.status -eq 'committed') {throw 'Committed release settings were reverted; refusing to change source on retry.'}
                $tmp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
                [IO.File]::WriteAllText($tmp,$file.content,[Text.UTF8Encoding]::new($false));[IO.File]::Move($tmp,$path,$true)
            }
        }
        $dirty=Read-ReleaseGit $Settings.repository @('status','--porcelain=v1','--untracked-files=all')
        if ($dirty) {return @{status='source-update-required';statePath=$reservation.statePath;version=$reservation.version;androidCodes=$reservation.androidCodes;files=@($reservation.files | ForEach-Object {$_.path});nextAction='Review and commit the reserved version settings locally, then resume prepare with the same selection. No export has run.'}}
        if ((Get-ReleaseConfiguration $Settings.repository).version -cne $reservation.version) {throw 'Committed project version differs from the reserved release.'}
        $reservation.status='committed';$reservation.sourceCommit=Read-ReleaseGit $Settings.repository @('rev-parse','HEAD')
        Write-ReleaseJson $pointer $reservation
        New-Item -ItemType Directory -Path $reservation.statePath -Force | Out-Null
        Write-ReleaseJson (Join-Path $reservation.statePath 'source-update.json') $reservation
        return @{status='source-committed';statePath=$reservation.statePath}
    } finally {$lock.Dispose()}
}

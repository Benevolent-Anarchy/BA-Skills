# Validates the grouped public JSON schema and expands it into per-channel execution records.

# Resolves only declared aliases to actual preset names; null remains an unresolved setup fact.
function Resolve-ReleaseExportAlias($Exports, $Alias) {
    if ($null -eq $Alias) {return $null}
    if ($Alias -isnot [string] -or $Alias -cnotin @($Exports.Keys)) {
        throw 'Unknown or invalid export alias; declare it in exports using an existing Godot preset name.'
    }
    return $Exports[$Alias]
}

# Preserves explicit null and empty arrays instead of treating them as absent overrides.
function Get-ReleaseInheritedSetting($Object, [string]$Key, $Default) {
    if ($Object.Contains($Key)) {return ,$Object[$Key]}
    return ,$Default
}

# Validates even overridden baselines so malformed shared settings are never hidden.
function Assert-ReleaseBaselineSetting($Ref, [string]$Location) {
    if ($null -ne $Ref -and ($Ref -isnot [string] -or [string]::IsNullOrWhiteSpace($Ref) -or $Ref.StartsWith('-'))) {
        throw "$Location previousRelease must be null or a confirmed Git ref."
    }
}

# Checks shared pattern lists before applying overrides; shell command strings are never accepted.
function Assert-ReleasePatternList($Patterns, [string]$Location) {
    if ($Patterns -isnot [array] -or @($Patterns | Where-Object {$_ -isnot [string] -or $_ -match '[\\/"\r\n\[\]]|\*\*' -or [string]::IsNullOrWhiteSpace($_)}).Count) {
        throw "$Location patterns must be an array of basename globs using * and ?."
    }
}

# Expands shared configuration without changing the original document or its approval hash.
function ConvertTo-ReleaseRuntimeConfiguration($Document, [switch]$AllowIncomplete) {
    $fields=@('schemaVersion','project','previousRelease','exports','verification','distributions','androidVersionCodePolicy','sourceTag')
    Assert-ReleaseFields $Document $fields @('schemaVersion','project','previousRelease','exports','verification','distributions') 'release.json'
    if (($Document.schemaVersion -isnot [int] -and $Document.schemaVersion -isnot [long]) -or $Document.schemaVersion -ne 1) {
        throw 'Unsupported schemaVersion; expected integer 1.'
    }
    Assert-ReleaseBaselineSetting $Document.previousRelease 'Root'
    # Off unless set, so a game that leaves it out plans exactly as it did before the setting existed.
    $sourceTag=Get-ReleaseInheritedSetting $Document 'sourceTag' $false
    if ($sourceTag -isnot [bool]) {throw 'sourceTag must be a boolean; true tags each release on origin once a store is live.'}
    if ($Document.exports -isnot [Collections.IDictionary] -or (-not $AllowIncomplete -and $Document.exports.Count -eq 0)) {
        throw 'exports must map aliases to existing Godot preset names.'
    }
    foreach ($alias in $Document.exports.Keys) {
        if ($alias -isnot [string] -or $alias -cnotmatch '^[a-z][a-z0-9-]*$' -or $Document.exports[$alias] -isnot [string]) {
            throw 'Each export alias must be a lowercase identifier mapped to an existing preset name.'
        }
    }
    Assert-ReleaseFields $Document.verification @('gate','standalone') @('gate') 'verification'
    $gate=$Document.verification.gate
    Assert-ReleaseFields $gate @('script','arguments') @('script') 'verification.gate'
    $checks=[Collections.Generic.List[object]]::new()
    if ($Document.verification.Contains('standalone')) {
        $groups=$Document.verification.standalone
        if ($groups -is [Collections.IDictionary]) {$groups=@($groups)}
        if ($groups -isnot [array]) {throw 'verification.standalone must be a check object or array of check objects.'}
        foreach ($group in $groups) {
            Assert-ReleaseFields $group @('exports','script','arguments') @('exports','script') 'standalone check'
            if ($group.exports -isnot [array] -or $group.exports.Count -eq 0) {throw 'Standalone exports must be a nonempty array of export aliases.'}
            foreach ($alias in $group.exports) {
                $checks.Add([ordered]@{preset=(Resolve-ReleaseExportAlias $Document.exports $alias);script=$group.script;arguments=(Get-ReleaseInheritedSetting $group 'arguments' @())})
            }
        }
    }
    Assert-ReleaseFields $Document.distributions @('itch','steam','google-play','notes') @() 'distributions'
    $destinations=[Collections.Generic.List[object]]::new();$baselines=[ordered]@{}
    foreach ($store in $Document.distributions.Keys) {
        $settings=$Document.distributions[$store]
        if ($store -eq 'notes') {
            if ($settings -isnot [bool]) {throw 'distributions.notes must be a boolean; true makes notes available for explicit selection.'}
            if ($settings) {$destinations.Add([ordered]@{id='notes';type='notes'})}
            continue
        }
        if ($store -eq 'itch') {
            Assert-ReleaseFields $settings @('game','channels','ignore','displayNameTemplate','previousRelease') @('game','channels','ignore') 'distributions.itch'
            Assert-ReleasePatternList $settings.ignore 'Itch ignore'
            if ($settings.Contains('previousRelease')) {Assert-ReleaseBaselineSetting $settings.previousRelease 'Itch'}
            if ($settings.Contains('displayNameTemplate')) {Resolve-ReleaseDisplayName $settings.displayNameTemplate 'Template validation' '1.0.0' 'Windows Desktop' | Out-Null}
            if ($null -ne $settings.game -and ($settings.game -isnot [string] -or $settings.game -notmatch '^[A-Za-z0-9_-]+/[A-Za-z0-9_-]+$')) {throw 'Itch game must be null or an inspected Butler owner/game.'}
            if ($settings.channels -isnot [Collections.IDictionary] -or (-not $AllowIncomplete -and $settings.channels.Count -eq 0)) {throw 'Itch channels must map channel identifiers to export aliases.'}
            foreach ($name in $settings.channels.Keys) {
                if ($name -cnotmatch '^[a-z][a-z0-9-]*$') {throw 'Itch channel identifiers must be lowercase letters, numbers and hyphens; use channel for a different remote name.'}
                $channel=$settings.channels[$name]
                if ($channel -is [string]) {$channel=@{export=$channel}}
                Assert-ReleaseFields $channel @('export','channel','ignore','displayNameTemplate','previousRelease') @('export') 'itch channel'
                if ($channel.Contains('ignore')) {Assert-ReleasePatternList $channel.ignore 'Itch channel ignore'}
                if ($channel.Contains('previousRelease')) {Assert-ReleaseBaselineSetting $channel.previousRelease 'Itch channel'}
                $remoteChannel=Get-ReleaseInheritedSetting $channel 'channel' $name
                if ($remoteChannel -isnot [string] -or $remoteChannel -notmatch '^[A-Za-z0-9_.-]+$') {throw 'Butler channel must be an explicit channel name.'}
                $id='itch-'+$name
                $target=if ($null -eq $settings.game) {$null} else {$settings.game+':'+$remoteChannel}
                $destination=[ordered]@{id=$id;type='itch';preset=(Resolve-ReleaseExportAlias $Document.exports $channel.export);target=$target;ignore=(Get-ReleaseInheritedSetting $channel 'ignore' $settings.ignore)}
                if ($channel.Contains('displayNameTemplate') -or $settings.Contains('displayNameTemplate')) {
                    $template=Get-ReleaseInheritedSetting $settings 'displayNameTemplate' $null
                    $destination.displayNameTemplate=Get-ReleaseInheritedSetting $channel 'displayNameTemplate' $template
                }
                $baseline=Get-ReleaseInheritedSetting $settings 'previousRelease' $Document.previousRelease
                $baselines[$id]=Get-ReleaseInheritedSetting $channel 'previousRelease' $baseline
                $destinations.Add($destination)
            }
        } elseif ($store -eq 'steam') {
            Assert-ReleaseFields $settings @('appId','branch','depots','exclude','previousRelease') @('appId','branch','depots') 'distributions.steam'
            if ($settings.Contains('exclude')) {Assert-ReleasePatternList $settings.exclude 'Steam exclude'}
            if ($settings.Contains('previousRelease')) {Assert-ReleaseBaselineSetting $settings.previousRelease 'Steam'}
            if ($settings.depots -isnot [Collections.IDictionary]) {throw 'Steam depots must map inspected numeric depot IDs to export aliases.'}
            $depots=[Collections.Generic.List[object]]::new()
            foreach ($key in $settings.depots.Keys) {
                [uint32]$id=0
                if ($key -cnotmatch '^[1-9][0-9]*$' -or -not [uint32]::TryParse($key,[ref]$id)) {throw 'Steam depot IDs must be inspected positive integers.'}
                $depot=$settings.depots[$key]
                if ($depot -is [string]) {$depot=@{export=$depot}}
                Assert-ReleaseFields $depot @('export','exclude') @('export') 'Steam depot'
                $exclusions=Get-ReleaseInheritedSetting $settings 'exclude' @()
                $depots.Add([ordered]@{id=[long]$id;preset=(Resolve-ReleaseExportAlias $Document.exports $depot.export);exclude=(Get-ReleaseInheritedSetting $depot 'exclude' $exclusions)})
            }
            $destinations.Add([ordered]@{id='steam';type='steam';appId=$settings.appId;branch=$settings.branch;depots=$depots.ToArray()})
            $baselines.steam=Get-ReleaseInheritedSetting $settings 'previousRelease' $Document.previousRelease
        } elseif ($store -eq 'google-play') {
            $allowed=@('export','track','releaseStatus','userFraction','language','retainVersionCodes','previousRelease','baselineAdvancesOn')
            Assert-ReleaseFields $settings $allowed @('export','track','releaseStatus','language','retainVersionCodes') 'distributions.google-play'
            if ($settings.Contains('previousRelease')) {Assert-ReleaseBaselineSetting $settings.previousRelease 'Google Play'}
            $play=[ordered]@{id='google-play';type='google-play';preset=(Resolve-ReleaseExportAlias $Document.exports $settings.export);track=$settings.track;releaseStatus=$settings.releaseStatus;userFraction=(Get-ReleaseInheritedSetting $settings 'userFraction' $null);language=$settings.language;retainVersionCodes=$settings.retainVersionCodes}
            # Carried only when set, so a game that leaves it out plans exactly as it did before the setting existed.
            if ($settings.Contains('baselineAdvancesOn')) {$play.baselineAdvancesOn=$settings.baselineAdvancesOn}
            $destinations.Add($play)
            $baselines['google-play']=Get-ReleaseInheritedSetting $settings 'previousRelease' $Document.previousRelease
        }
    }
    $policy=Get-ReleaseInheritedSetting $Document 'androidVersionCodePolicy' 'increment-selected'
    if ($policy -cnotin @('increment-selected','existing')) {throw 'androidVersionCodePolicy must be increment-selected or existing.'}
    return [ordered]@{schemaVersion=1;project=$Document.project;previousReleaseRef=$Document.previousRelease;exports=@($Document.exports.Values);verification=[ordered]@{script=$gate.script;arguments=(Get-ReleaseInheritedSetting $gate 'arguments' @())};standalone=$checks.ToArray();destinations=$destinations.ToArray();destinationBaselines=$baselines;androidVersionCodePolicy=$policy;sourceTag=$sourceTag}
}

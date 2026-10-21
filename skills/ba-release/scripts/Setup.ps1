# Inspects real projects, reports missing release facts and validates explicitly supplied setup answers.
# Dot-sourced by Release.psm1 to share its path, JSON and Godot validation.
# Store choices belong to release.json; the destinations a particular release selects are chosen separately.
$script:SetupStores=@('itch','steam','google-play','notes')

# Reads project facts without executing scripts or changing source/configuration.
function Get-ReleaseSetupFacts([string]$Repository, [string]$Project = '.') {
    $Repository=(Get-Item -LiteralPath $Repository).FullName
    if ([IO.Path]::GetFullPath((Read-ReleaseGit $Repository @('rev-parse','--show-toplevel'))) -ne $Repository) {throw 'Repository must name the Git root.'}
    $projectPath=Resolve-ReleasePath $Repository $Project -MustExist
    $godot=Read-GodotSections (Join-Path $projectPath 'project.godot')
    $sections=Read-GodotSections (Join-Path $projectPath 'export_presets.cfg')
    $presets=@(foreach ($section in $sections.Keys) {
        if ($section -notmatch '^preset\.\d+$') {continue}
        $item=$sections[$section]
        $record=[ordered]@{name=$item['name'];platform=$item['platform'];exportPath=$item['export_path']}
        if ($item['platform'] -eq 'Android' -and $sections.Contains($section+'.options')) {
            $options=$sections[$section+'.options']
            $record.versionCode=$options['version/code'];$record.packageName=$options['package/unique_name']
            $record.signed=$options['package/signed'];$record.gradle=$options['gradle_build/use_gradle_build'];$record.format=$options['gradle_build/export_format']
        }
        $record
    })
    return [ordered]@{repository=$Repository;project=$Project;title=$godot['application']['config/name'];version=$godot['application']['config/version'];presets=$presets;origin=(Read-ReleaseGit $Repository @('remote','get-url','origin'))}
}

# Proposes aliases only for actual inspected exports, retaining existing user aliases when stores change.
function New-ReleaseSetupConfiguration($Facts, [string[]]$Stores, $ExistingExports=$null) {
    foreach ($store in $Stores) {if ($store -cnotin $script:SetupStores) {throw "Unsupported setup store: $store"}}
    $exports=[ordered]@{}
    if ($null -ne $ExistingExports) {foreach ($key in $ExistingExports.Keys) {$exports[$key]=$ExistingExports[$key]}}
    $desktop=@($Facts.presets | Where-Object {$_.platform -in @('Windows Desktop','Linux') -and $_.exportPath})
    $apks=@($Facts.presets | Where-Object {$_.platform -eq 'Android' -and $_.signed -eq $true -and ($_.gradle -eq $false -or $_.format -eq 0) -and $_.exportPath -like '*.apk'})
    $aabs=@($Facts.presets | Where-Object {$_.platform -eq 'Android' -and $_.signed -eq $true -and $_.gradle -eq $true -and $_.format -eq 1 -and $_.exportPath -like '*.aab'})
    foreach ($preset in @($desktop)+@($apks)+@($aabs)) {
        if ($preset.name -cin @($exports.Values)) {continue}
        $base=switch ($preset.platform) {'Windows Desktop' {'windows'} 'Linux' {'linux'} default {if ($preset.exportPath -like '*.apk') {'apk'} else {'aab'}}}
        $alias=$base;$index=2
        while ($exports.Contains($alias)) {$alias=$base+'-'+$index;$index++}
        $exports[$alias]=$preset.name
    }
    $distributions=[ordered]@{}
    foreach ($store in @($Stores | Select-Object -Unique)) {
        if ($store -eq 'itch') {
            $channels=[ordered]@{}
            foreach ($entry in @(@{channel='windows';presets=@($desktop | Where-Object platform -EQ 'Windows Desktop')},@{channel='linux';presets=@($desktop | Where-Object platform -EQ 'Linux')},@{channel='android';presets=$apks})) {
                if ($entry.presets.Count -eq 1) {$channels[$entry.channel]=@($exports.Keys | Where-Object {$exports[$_] -ceq $entry.presets[0].name})[0]}
            }
            $distributions.itch=[ordered]@{game=$null;previousRelease=$null;ignore=$script:SteamIgnore;channels=$channels}
        } elseif ($store -eq 'steam') {
            $distributions.steam=[ordered]@{appId=$null;branch=$null;previousRelease=$null;exclude=@();depots=[ordered]@{}}
        } elseif ($store -eq 'google-play') {
            $alias=if ($aabs.Count -eq 1) {@($exports.Keys | Where-Object {$exports[$_] -ceq $aabs[0].name})[0]} else {$null}
            $distributions['google-play']=[ordered]@{export=$alias;previousRelease=$null;track=$null;releaseStatus=$null;userFraction=$null;language=$null;retainVersionCodes=$null}
        } else {$distributions.notes=$true}
    }
    $verification=if (Test-Path -LiteralPath (Join-Path $Facts.repository 'tools/verify.ps1') -PathType Leaf) {'tools/verify.ps1'} else {$null}
    $standaloneScript=if (Test-Path -LiteralPath (Join-Path $Facts.repository 'tools/standalone.ps1') -PathType Leaf) {'tools/standalone.ps1'} else {$null}
    $standaloneAliases=@($exports.Keys | Where-Object {$exports[$_] -cin @($desktop | ForEach-Object {$_.name})})
    $verificationSettings=[ordered]@{gate=[ordered]@{script=$verification;arguments=@()}}
    if ($standaloneAliases.Count) {$verificationSettings.standalone=[ordered]@{exports=$standaloneAliases;script=$standaloneScript;arguments=@('{artifact}')}}
    # A new game tags its releases unless it turns that off; one already configured keeps what it has.
    return [ordered]@{schemaVersion=1;project=$Facts.project;previousRelease=$null;exports=$exports;verification=$verificationSettings;distributions=$distributions;androidVersionCodePolicy='increment-selected';sourceTag=$true}
}

# Lists the stores a configuration declares, in its order; notes counts only while true, as only then is it selectable.
function Get-ReleaseConfiguredStores($Configuration) {
    if ($null -eq $Configuration) {return @()}
    return @($Configuration.distributions.Keys | Where-Object {$_ -cne 'notes' -or $Configuration.distributions.notes -eq $true})
}

# Names the store that would provide a destination ID, or null when no store could.
function Get-ReleaseDestinationStore([string]$Id) {
    if ($Id -cmatch '^itch-[a-z][a-z0-9-]*$') {return 'itch'}
    if ($Id -cin @('steam','google-play','notes')) {return $Id}
    return $null
}

# Applies interactive store changes: a name adds that store and -name removes it, so adding never drops another.
function Update-ReleaseStoreSelection([string[]]$Configured, [string[]]$Changes) {
    $stores=[Collections.Generic.List[string]]::new($Configured)
    foreach ($change in $Changes) {
        $store=if ($change.StartsWith('-')) {$change.Substring(1).Trim()} else {$change}
        if ($store -cnotin $script:SetupStores) {throw "Unsupported setup store: $store"}
        if ($change.StartsWith('-')) {if (-not $stores.Remove($store)) {throw "Cannot remove $store; release.json does not configure it."}}
        elseif ($store -cnotin $stores) {$stores.Add($store)}
    }
    return ,$stores.ToArray()
}

# Resolves a display label from source metadata, rejecting unsupported template substitutions.
function Resolve-ReleaseDisplayName($Template, [string]$Title, [string]$Version, [string]$Platform) {
    if ($Template -isnot [string] -or [string]::IsNullOrWhiteSpace($Template) -or $Template -match '[\x00-\x1f]' -or ($Template -replace '\{(?:title|version|os)\}','') -match '[{}]') {throw 'displayNameTemplate supports only {title}, {version} and {os} with no control characters.'}
    if (-not $Title) {throw 'Godot config/name is required for display-name templates.'}
    $os=switch ($Platform) {'Windows Desktop' {'Windows'} 'Linux' {'Linux'} 'Android' {'Android'} default {throw 'Unsupported display-name platform.'}}
    return $Template.Replace('{title}',$Title).Replace('{version}',$Version).Replace('{os}',$os)
}

# Reports scoped questions using public configuration paths; no scripts, stores or writes are invoked.
function Get-ReleaseSetup([string]$Repository, [string[]]$Destination=@(), $Configuration=$null) {
    $path=Join-Path $Repository 'release.json'
    $hash=if (Test-Path -LiteralPath $path -PathType Leaf) {(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()} else {'missing'}
    if ($null -eq $Configuration -and $hash -ne 'missing') {
        $raw=[IO.File]::ReadAllText($path);$json=[System.Text.Json.JsonDocument]::Parse($raw)
        try {Assert-ReleaseJson $json.RootElement} finally {$json.Dispose()}
        $Configuration=$raw | ConvertFrom-Json -AsHashtable
    }
    $project=if ($null -ne $Configuration) {$Configuration.project} else {'.'}
    if ($null -eq $Configuration -and -not (Test-Path -LiteralPath (Join-Path $Repository 'project.godot') -PathType Leaf)) {
        $files=Read-ReleaseGit $Repository @('-c','core.quotepath=false','ls-files','--cached','--others','--exclude-standard','--','*project.godot')
        $projects=@($files.Split("`n") | Where-Object {$_ -match '(?:^|/)project\.godot$' -and (Test-Path -LiteralPath (Join-Path $Repository $_) -PathType Leaf)} | ForEach-Object {[IO.Path]::GetDirectoryName($_).Replace('\','/')} | Sort-Object -Unique)
        if ($projects.Count -eq 1) {$project=$projects[0]}
        else {return @{mode='setup';readOnly=$true;configSha256=$hash;facts=@{projects=$projects};configuration=$null;questions=@(@{key='project';prompt='Choose the actual Godot project directory inside this repository; no project has been guessed.';choices=$projects});stores=@{configured=@();choices=$script:SetupStores};selection=@{required=$true;choices=@();selected=@()}}}
    }
    $facts=Get-ReleaseSetupFacts $Repository $project
    $new=($null -eq $Configuration)
    if ($new) {
        $stores=if ($Destination.Count) {@($Destination | ForEach-Object {if ($_ -like 'itch-*') {'itch'} else {$_}} | Select-Object -Unique)} else {@('itch','notes')}
        $Configuration=New-ReleaseSetupConfiguration $facts $stores
    }
    $runtime=ConvertTo-ReleaseRuntimeConfiguration $Configuration -AllowIncomplete
    # Store choice belongs to the configuration; a requested destination of an undeclared store only prompts for it.
    $configured=@(Get-ReleaseConfiguredStores $Configuration)
    $undeclared=@($Destination | Where-Object {$_ -cnotin @($runtime.destinations | ForEach-Object {$_.id})} | ForEach-Object {Get-ReleaseDestinationStore $_} | Where-Object {$_ -and $_ -cnotin $configured} | Select-Object -Unique)
    $questions=[Collections.Generic.List[object]]::new()
    if ($new) {$questions.Add(@{key='stores';prompt='Which stores is this game published on? Select itch, steam, google-play and/or notes.';choices=$script:SetupStores})}
    elseif ($undeclared.Count) {$questions.Add(@{key='stores';configured=$configured;choices=$script:SetupStores;prompt="The selected destinations need $($undeclared -join ', '), which release.json does not configure; it configures $(if ($configured.Count) {$configured -join ', '} else {'no stores'}). To add a store, list every store to keep as well as the new ones: a configured store left out is removed with its settings."})}
    if ($null -eq $Configuration.previousRelease) {$questions.Add(@{key='previousRelease';prompt='What source commit/ref was used for the previous published release? A version-history candidate needs your confirmation.'})}
    if ($null -eq $Configuration.verification.gate.script) {$questions.Add(@{key='verification.gate.script';prompt='Which existing PowerShell script verifies this game? Inspect its contents and arguments before using it.'})}
    if ($Configuration.exports.Count -eq 0) {$questions.Add(@{key='exports';prompt='Supply aliases for actual configured Godot export presets after inspecting this project.'})}
    if ($Configuration.distributions.Contains('itch') -and $Configuration.distributions.itch.channels.Count -eq 0 -and ($Destination.Count -eq 0 -or @($Destination | Where-Object {$_ -like 'itch-*'}).Count)) {
        if ($null -eq $Configuration.distributions.itch.game) {$questions.Add(@{key='distributions.itch.game';prompt='What is the itch Butler owner/game? A page URL identifies this game, but not its channels.'})}
        $questions.Add(@{key='distributions.itch.channels';prompt='Supply explicit channel-to-export-alias mappings from the inspected presets. No ambiguous preset has been selected.'})
    }
    $pending=[Collections.Generic.List[object]]::new()
    foreach ($id in $Destination) {
        if ($id -cin @($runtime.destinations | ForEach-Object {$_.id})) {continue}
        $store=Get-ReleaseDestinationStore $id
        if ($store -and $store -cin $undeclared) {$pending.Add(@{id=$id;type=$store;preset=$null;storeRequired=$true});continue}
        if ($id -cmatch '^itch-[a-z][a-z0-9-]*$' -and $Configuration.distributions.Contains('itch') -and ($hash -eq 'missing' -or $Configuration.distributions.itch.channels.Count -eq 0)) {
            $pending.Add(@{id=$id;type='itch';preset=$null;mappingRequired=$true})
            $questions.Add(@{key='distributions.itch.channels';prompt="Supply an explicit channel-to-export-alias mapping for '$id' from the inspected presets. No ambiguous preset has been selected."})
            if ($null -eq $Configuration.distributions.itch.game) {$questions.Add(@{key='distributions.itch.game';prompt='What is the itch Butler owner/game? A page URL identifies this game, but not its channels.'})}
        } else {throw "Unknown destination: $id"}
    }
    foreach ($destinationRecord in $runtime.destinations) {
        if ($Destination.Count -and $destinationRecord.id -cnotin $Destination) {continue}
        $store=$destinationRecord.type
        if ($store -eq 'notes') {continue}
        $settings=$Configuration.distributions[$store]
        if ($null -eq $runtime.destinationBaselines[$destinationRecord.id]) {
            $baselinePath=if ($store -eq 'itch') {
                $name=$destinationRecord.id.Substring(5);$channel=$settings.channels[$name]
                if ($channel -is [Collections.IDictionary] -and $channel.Contains('previousRelease')) {"distributions.itch.channels.$name.previousRelease"}
                elseif ($settings.Contains('previousRelease')) {'distributions.itch.previousRelease'} else {'previousRelease'}
            } elseif ($settings.Contains('previousRelease')) {"distributions.$store.previousRelease"} else {'previousRelease'}
            $questions.Add(@{key=$baselinePath;prompt="What source commit/ref is last live on '$($destinationRecord.id)'? Confirm per-store history after skipped releases."})
        }
        if ($store -eq 'itch') {
            if ($null -eq $settings.game) {
                $questions.Add(@{key='distributions.itch.game';prompt='What is the itch Butler owner/game? A page URL identifies this game, but not its channels.'})
                $questions.Add(@{key='distributions.itch.channels';prompt='Confirm the proposed channel-to-export-alias mappings, or supply your existing Butler channels. Manual-upload migration requires explicit approval of new channels.'})
            }
            $preset=@($facts.presets | Where-Object {$_.name -ceq $destinationRecord.preset})
            $checks=@($runtime.standalone | Where-Object {$_.preset -ceq $destinationRecord.preset -and $null -ne $_.script})
            if ($preset.Count -eq 1 -and $preset[0].platform -ne 'Android' -and $checks.Count -ne 1) {$questions.Add(@{key='verification.standalone';prompt="Supply an existing standalone functionality-check hook and its export aliases for '$($destinationRecord.preset)'. It must check relevant functionality with excluded Steam files unavailable on each selected desktop."})}
        } else {
            $prompts=if ($store -eq 'steam') {@{appId='What is the inspected Steam app ID?';branch='Which Steam branch should receive this release (default for the public branch)?';depots='Supply a map of inspected depot IDs to export aliases, with any per-depot exclusions.'}}
            else {@{export='Which declared signed Gradle AAB export alias should Play use?';track='Which Play track: production, internal, alpha/beta or an existing custom track?';releaseStatus='Should this release be a draft, a full rollout (completed) or a staged rollout (inProgress)?';language='Which BCP-47 language should the Play release notes use?';retainVersionCodes='After inspecting the current track, which existing version codes should remain? [] explicitly retains none.'}}
            if ($store -eq 'google-play' -and $settings.releaseStatus -eq 'inProgress') {$prompts.userFraction='What fraction between 0 and 1 should receive this staged rollout?'}
            foreach ($key in @($prompts.Keys | Sort-Object)) {
                $value=Get-ReleaseInheritedSetting $settings $key $null
                if ($null -eq $value -or ($key -eq 'depots' -and $value.Count -eq 0)) {$questions.Add(@{key="distributions.$store.$key";prompt=$prompts[$key]})}
            }
        }
    }
    $unique=[ordered]@{}
    foreach ($question in $questions) {
        if ($unique.Contains($question.key)) {if ($unique[$question.key].prompt -cne $question.prompt) {$unique[$question.key].prompt+="`n"+$question.prompt}}
        else {$unique[$question.key]=$question}
    }
    return [ordered]@{mode='setup';readOnly=$true;configSha256=$hash;facts=$facts;configuration=$Configuration;questions=@($unique.Values);stores=@{configured=$configured;choices=$script:SetupStores};selection=@{required=($Destination.Count -eq 0);selected=@($Destination);choices=(@($runtime.destinations | ForEach-Object {@{id=$_.id;type=$_.type;preset=$_['preset']}})+$pending.ToArray())}}
}

# Sets public dotted paths, expanding a channel/depot shorthand only when an override is supplied.
function Set-ReleaseSetupAnswer($Configuration, [string]$Key, $Value) {
    $parts=$Key.Split('.')
    if ($parts[0] -cnotin @('project','previousRelease','exports','verification','distributions','androidVersionCodePolicy','sourceTag')) {throw "Unknown setup answer: $Key"}
    $cursor=$Configuration
    for ($i=0;$i -lt $parts.Count-1;$i++) {
        $part=$parts[$i]
        if (-not $cursor.Contains($part)) {$cursor[$part]=[ordered]@{}}
        if ($cursor[$part] -is [string] -and $i -gt 0 -and $parts[$i-1] -cin @('channels','depots')) {$cursor[$part]=[ordered]@{export=$cursor[$part]}}
        if ($cursor[$part] -isnot [Collections.IDictionary]) {throw "Setup answer cannot traverse a scalar: $Key"}
        $cursor=$cursor[$part]
    }
    $cursor[$parts[-1]]=$Value
}

# Retains configured aliases, verification and complete store objects while merging explicit answers.
function Merge-ReleaseSetupAnswers($report, $answers, [string]$Repository) {
    $report=($report | ConvertTo-Json -Depth 30) | ConvertFrom-Json -AsHashtable
    $config=$report.configuration
    if ($answers.Contains('project')) {
        $report.facts=Get-ReleaseSetupFacts $Repository $answers.project
        if ($null -eq $config) {$config=New-ReleaseSetupConfiguration $report.facts @('itch','notes')}
        $config.project=$answers.project
    }
    if ($null -eq $config) {throw 'Select the actual Godot project before applying other setup answers.'}
    if ($answers.Contains('stores')) {
        if ($answers.stores -isnot [array] -or @($answers.stores | Where-Object {$_ -isnot [string]}).Count) {throw 'stores must be an array of store types.'}
        # The list replaces the store choice: listed configured stores keep their place and settings, and new ones follow.
        $configured=@(Get-ReleaseConfiguredStores $config)
        $stores=@($configured | Where-Object {$_ -cin $answers.stores})+@($answers.stores | Where-Object {$_ -cnotin $configured})
        $candidate=New-ReleaseSetupConfiguration $report.facts $stores $config.exports
        $candidate.previousRelease=$config.previousRelease;$candidate.verification=$config.verification
        if ($config.Contains('androidVersionCodePolicy')) {$candidate.androidVersionCodePolicy=$config.androidVersionCodePolicy} else {$candidate.Remove('androidVersionCodePolicy')}
        if ($config.Contains('sourceTag')) {$candidate.sourceTag=$config.sourceTag} else {$candidate.Remove('sourceTag')}
        foreach ($store in @($candidate.distributions.Keys)) {if ($store -cne 'notes' -and $config.distributions.Contains($store)) {$candidate.distributions[$store]=$config.distributions[$store]}}
        $config=$candidate
    }
    foreach ($key in $answers.Keys) {if ($key -cin @('stores','project')) {continue};Set-ReleaseSetupAnswer $config $key $answers[$key]}
    return $config
}

# Iterates public-path questions so selecting a new store immediately exposes its missing facts.
function Invoke-ReleaseInteractiveSetup([string]$Repository, [string[]]$Destination=@(), [scriptblock]$Prompt) {
    $initial=Get-ReleaseSetup $Repository $Destination
    $report=$initial;$answers=[ordered]@{};$asked=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$scope=$Destination
    if (-not $Prompt) {$Prompt={param($question) Read-Host ($question.prompt+' Leave blank to defer')}}
    # An existing configuration first offers its stores as explicit changes, so adding one never drops another.
    $storeQuestion=$null
    if ($initial.configSha256 -ne 'missing') {
        $configured=[string[]]@($initial.stores.configured)
        $addable=@($initial.stores.choices | Where-Object {$_ -cnotin $configured})
        $storeQuestion=@{key='stores';configured=$configured;choices=$initial.stores.choices;prompt="Configured stores: $(if ($configured.Count) {$configured -join ', '} else {'none'}). Add stores by name ($(if ($addable.Count) {$addable -join ', '} else {'none left'})), or remove a configured store and its settings by entering it with a leading -."}
    }
    while ($true) {
        $questions=if ($storeQuestion) {@($storeQuestion)+@($report.questions | Where-Object {$_.key -ne 'stores'})} else {@($report.questions)}
        $unasked=@($questions | Where-Object {-not $asked.Contains($_.key)})
        if (-not $unasked.Count) {break}
        $question=$unasked[0];$asked.Add($question.key) | Out-Null
        $answer=& $Prompt $question
        if ([string]::IsNullOrWhiteSpace($answer)) {continue}
        if ($question.key -eq 'stores') {
            $stores=@($answer.Split(',') | ForEach-Object {$_.Trim()} | Where-Object {$_})
            if ($storeQuestion) {
                $stores=Update-ReleaseStoreSelection $storeQuestion.configured $stores
                if (($stores -join ',') -ceq ($storeQuestion.configured -join ',')) {continue}
                # Once the stores change, every missing fact is in scope, including the new stores' settings and baselines.
                $scope=@()
            }
            $answers[$question.key]=$stores
        }
        elseif ($question.key -cin @('exports','verification.standalone') -or $question.key -match '\.(channels|depots|retainVersionCodes|userFraction)$') {$answers[$question.key]=$answer | ConvertFrom-Json -AsHashtable -NoEnumerate}
        elseif ($question.key -match '\.appId$') {$answers[$question.key]=[long]$answer}
        else {$answers[$question.key]=$answer}
        $candidate=Merge-ReleaseSetupAnswers $initial $answers $Repository
        $report=Get-ReleaseSetup $Repository $scope $candidate
    }
    if (-not $answers.Count) {return @{written=$false;report=$report}}
    $path=Join-Path ([IO.Path]::GetTempPath()) ('ba-release-answers-'+[guid]::NewGuid().ToString('N')+'.json')
    try {
        [IO.File]::WriteAllText($path,($answers | ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
        Set-ReleaseSetup $Repository $path $initial.configSha256
    } finally {if (Test-Path -LiteralPath $path) {Remove-Item -LiteralPath $path}}
}

# Applies explicit answers after validating the complete candidate and checking for concurrent edits.
function Set-ReleaseSetup([string]$Repository, [string]$AnswersPath, [string]$ExpectedConfigSha256) {
    if (-not $ExpectedConfigSha256) {throw 'ExpectedConfigSha256 from setup is required before writing configuration.'}
    $report=Get-ReleaseSetup $Repository
    if ($report.configSha256 -cne $ExpectedConfigSha256) {throw 'release.json changed; inspect the conflict before applying setup answers.'}
    $raw=[IO.File]::ReadAllText($AnswersPath);$json=[System.Text.Json.JsonDocument]::Parse($raw)
    try {Assert-ReleaseJson $json.RootElement} finally {$json.Dispose()}
    $answers=$raw | ConvertFrom-Json -AsHashtable
    if ($answers -isnot [Collections.IDictionary]) {throw 'Setup answers must be a JSON object.'}
    $config=Merge-ReleaseSetupAnswers $report $answers $Repository
    $settings=Get-ReleaseConfiguration $Repository $config
    if ($config.distributions.Contains('itch') -and $null -ne $config.distributions.itch.game) {
        $confirmed=($report.configSha256 -ne 'missing' -and $report.configuration.distributions.Contains('itch') -and $report.configuration.distributions.itch.game -ceq $config.distributions.itch.game)
        $explicitChannels=($answers.Contains('distributions.itch.channels') -or $answers.Contains('distributions.itch') -or $answers.Contains('distributions'))
        if (-not $confirmed -and -not $explicitChannels) {throw 'Confirm Butler channel mappings explicitly before saving a newly configured itch game.'}
    }
    if ($null -ne $config.previousRelease) {
        $ref=Read-ReleaseGit $Repository @('rev-parse','--verify',"$($config.previousRelease)^{commit}")
        $ancestor=Invoke-ReleaseTool 'git' @('--no-optional-locks','-C',$Repository,'merge-base','--is-ancestor',$ref,'HEAD') $Repository
        if ($ancestor.exitCode -ne 0) {throw 'Previous release ref must be an ancestor of HEAD.'}
    }
    if ($settings.config.Contains('destinationBaselines')) {
        foreach ($ref in $settings.config.destinationBaselines.Values) {
            if ($null -eq $ref) {continue}
            $commit=Read-ReleaseGit $Repository @('rev-parse','--verify',"$ref^{commit}")
            $ancestor=Invoke-ReleaseTool 'git' @('--no-optional-locks','-C',$Repository,'merge-base','--is-ancestor',$commit,'HEAD') $Repository
            if ($ancestor.exitCode -ne 0) {throw 'Channel baseline must be an ancestor of HEAD.'}
        }
    }
    $path=Join-Path $settings.repository 'release.json'
    $temporary=Join-Path $settings.repository ('.release-setup-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try {
        [IO.File]::WriteAllText($temporary,($config | ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
        $current=if (Test-Path -LiteralPath $path -PathType Leaf) {(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()} else {'missing'}
        if ($current -cne $ExpectedConfigSha256) {throw 'release.json changed during setup; refusing to overwrite the conflict.'}
        if ($current -eq 'missing') {[IO.File]::Move($temporary,$path,$false)} else {[IO.File]::Move($temporary,$path,$true)}
    } finally {if (Test-Path -LiteralPath $temporary) {Remove-Item -LiteralPath $temporary}}
    return @{written=$true;report=(Get-ReleaseSetup $settings.repository)}
}

# Inspects real projects, reports missing release facts and validates explicitly supplied setup answers.
# Dot-sourced by Release.psm1 to share its path, JSON and Godot validation.

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

# Builds only mappings supported by inspected presets; unknown publication facts remain null.
function New-ReleaseSetupConfiguration($Facts, [string[]]$Stores) {
    foreach ($store in $Stores) {if ($store -cnotin @('itch','steam','google-play','notes')) {throw "Unsupported setup store: $store"}}
    $destinations=[Collections.Generic.List[object]]::new();$exports=[Collections.Generic.List[string]]::new()
    $desktop=@($Facts.presets | Where-Object {$_.platform -in @('Windows Desktop','Linux') -and $_.exportPath})
    if ($Stores -contains 'itch') {
        foreach ($platform in @('Windows Desktop','Linux')) {
            $matching=@($desktop | Where-Object {$_.platform -eq $platform})
            if ($matching.Count -eq 1) {
                $id=if ($platform -eq 'Windows Desktop') {'itch-windows'} else {'itch-linux'}
                $destinations.Add([ordered]@{id=$id;type='itch';preset=$matching[0].name;target=$null;ignore=$script:SteamIgnore})
                if (-not $exports.Contains($matching[0].name)) {$exports.Add($matching[0].name)}
            }
        }
        $apk=@($Facts.presets | Where-Object {$_.platform -eq 'Android' -and $_.signed -eq $true -and ($_.gradle -eq $false -or $_.format -eq 0) -and $_.exportPath -like '*.apk'})
        if ($apk.Count -eq 1) {
            $destinations.Add([ordered]@{id='itch-android';type='itch';preset=$apk[0].name;target=$null;ignore=$script:SteamIgnore})
            $exports.Add($apk[0].name)
        }
    }
    if ($Stores -contains 'steam') {
        $destinations.Add([ordered]@{id='steam';type='steam';appId=$null;branch=$null;depots=@()})
        foreach ($preset in $desktop) {if (-not $exports.Contains($preset.name)) {$exports.Add($preset.name)}}
    }
    if ($Stores -contains 'google-play') {
        $aab=@($Facts.presets | Where-Object {$_.platform -eq 'Android' -and $_.signed -eq $true -and $_.gradle -eq $true -and $_.format -eq 1 -and $_.exportPath -like '*.aab'})
        $preset=if ($aab.Count -eq 1) {$aab[0].name} else {$null}
        $destinations.Add([ordered]@{id='google-play';type='google-play';preset=$preset;track=$null;releaseStatus=$null;userFraction=$null;language=$null;retainVersionCodes=$null})
        if ($preset -and -not $exports.Contains($preset)) {$exports.Add($preset)}
    }
    if ($Stores -contains 'notes') {$destinations.Add([ordered]@{id='notes';type='notes'})}
    if ($exports.Count -eq 0) {foreach ($preset in $desktop) {$exports.Add($preset.name)}}
    $verification=if (Test-Path -LiteralPath (Join-Path $Facts.repository 'tools/verify.ps1') -PathType Leaf) {'tools/verify.ps1'} else {$null}
    $standaloneScript=if (Test-Path -LiteralPath (Join-Path $Facts.repository 'tools/standalone.ps1') -PathType Leaf) {'tools/standalone.ps1'} else {$null}
    $standalone=@($desktop | Where-Object {$_.name -cin $exports} | ForEach-Object {@{preset=$_.name;script=$standaloneScript;arguments=@('{artifact}')}})
    $baselines=[ordered]@{};foreach ($item in $destinations) {if ($item.type -ne 'notes') {$baselines[$item.id]=$null}}
    return [ordered]@{schemaVersion=1;project=$Facts.project;previousReleaseRef=$null;destinationBaselines=$baselines;androidVersionCodePolicy='increment-selected';exports=$exports.ToArray();verification=[ordered]@{script=$verification;arguments=@()};standalone=$standalone;destinations=$destinations.ToArray()}
}

# Resolves a display label from source metadata, rejecting unsupported template substitutions.
function Resolve-ReleaseDisplayName($Template, [string]$Title, [string]$Version, [string]$Platform) {
    if ($Template -isnot [string] -or [string]::IsNullOrWhiteSpace($Template) -or $Template -match '[\x00-\x1f]' -or ($Template -replace '\{(?:title|version|os)\}','') -match '[{}]') {throw 'displayNameTemplate supports only {title}, {version} and {os} with no control characters.'}
    if (-not $Title) {throw 'Godot config/name is required for display-name templates.'}
    $os=switch ($Platform) {'Windows Desktop' {'Windows'} 'Linux' {'Linux'} 'Android' {'Android'} default {throw 'Unsupported display-name platform.'}}
    return $Template.Replace('{title}',$Title).Replace('{version}',$Version).Replace('{os}',$os)
}

# Returns questions and an explicit per-release destination chooser; no files are written.
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
        else {return @{mode='setup';readOnly=$true;configSha256=$hash;facts=@{projects=$projects};configuration=$null;questions=@(@{key='project';prompt='Choose the actual Godot project directory inside this repository; no project has been guessed.';choices=$projects});selection=@{required=$true;choices=@();selected=@()}}}
    }
    $facts=Get-ReleaseSetupFacts $Repository $project
    $new=($null -eq $Configuration)
    if ($new) {$Configuration=New-ReleaseSetupConfiguration $facts @('itch','notes')}
    $questions=[Collections.Generic.List[object]]::new()
    if ($new) {$questions.Add(@{key='stores';prompt='Which stores is this game published on? Select itch, steam, google-play and/or notes.';choices=@('itch','steam','google-play','notes')})}
    if ($null -eq $Configuration.previousReleaseRef) {$questions.Add(@{key='previousReleaseRef';prompt='What source commit/ref was used for the previous published release? A version-history candidate needs your confirmation.'})}
    if ($null -eq $Configuration.verification.script) {$questions.Add(@{key='verification.script';prompt='Which existing PowerShell script verifies this game? Inspect its contents and arguments before using it.'})}
    foreach ($preset in $facts.presets) {
        if ($preset.platform -notin @('Windows Desktop','Linux')) {continue}
        $selectedItch=@($Configuration.destinations | Where-Object {$_.type -eq 'itch' -and $_.preset -ceq $preset.name -and ($Destination.Count -eq 0 -or $_.id -cin $Destination)})
        $checks=@(if ($Configuration.Contains('standalone')) {$Configuration.standalone | Where-Object {$_.preset -ceq $preset.name -and $null -ne $_.script}})
        if ($selectedItch.Count -and $checks.Count -eq 0) {$questions.Add(@{key='standalone';prompt="Supply an existing standalone functionality-check script for '$($preset.name)'. It will run with Butler-excluded files actually unavailable; a startup-only Windows check does not cover Linux or gameplay."})}
    }
    foreach ($id in $Destination) {if ($id -cnotin @($Configuration.destinations | ForEach-Object {$_.id})) {throw "Unknown destination: $id"}}
    foreach ($destinationRecord in $Configuration.destinations) {
        if ($Destination.Count -and $destinationRecord.id -cnotin $Destination) {continue}
        if ($Configuration.Contains('destinationBaselines') -and $Configuration.destinationBaselines.Contains($destinationRecord.id) -and $null -eq $Configuration.destinationBaselines[$destinationRecord.id]) {$questions.Add(@{key="baseline.$($destinationRecord.id)";prompt="What source commit/ref is last live on '$($destinationRecord.id)'? This may differ from other stores after skipped releases."})}
        $prompts=switch ($destinationRecord.type) {
            'itch' {@{target='What is the existing Butler owner/game:channel target? If uploads were manual, explicitly approve a new channel before first publication.'}}
            'steam' {@{appId='What is the inspected Steam app ID?';branch='Which Steam branch should receive this release (default for the public branch)?';depots='Supply inspected depot IDs, existing preset names and exclusion patterns from the Steamworks build scripts.'}}
            'google-play' {@{preset='Which existing signed Gradle AAB preset should Play use?';track='Which Play track: production, internal, alpha/beta or an existing custom track?';releaseStatus='Should this release be a draft, a full rollout (completed) or a staged rollout (inProgress)?';language='Which BCP-47 language should the Play release notes use (for example en-US)?';retainVersionCodes='After inspecting the current track, which existing version codes should remain? [] explicitly retains none.'}}
            default {@{}}
        }
        if ($destinationRecord.type -eq 'google-play' -and $destinationRecord.releaseStatus -eq 'inProgress') {$prompts.userFraction='What fraction between 0 and 1 should receive this staged rollout?'}
        foreach ($key in @($prompts.Keys | Sort-Object)) {
            if ($null -eq $destinationRecord[$key] -or ($key -eq 'depots' -and $destinationRecord[$key].Count -eq 0)) {$questions.Add(@{key="$($destinationRecord.id).$key";prompt=$prompts[$key]})}
        }
    }
    $unique=[ordered]@{}
    foreach ($question in $questions) {
        if ($unique.Contains($question.key)) {$unique[$question.key].prompt+="`n"+$question.prompt}
        else {$unique[$question.key]=$question}
    }
    return [ordered]@{mode='setup';readOnly=$true;configSha256=$hash;facts=$facts;configuration=$Configuration;questions=@($unique.Values);selection=@{required=($Destination.Count -eq 0);selected=@($Destination);choices=@($Configuration.destinations | ForEach-Object {@{id=$_.id;type=$_.type;preset=$_['preset']}})}}
}

# Merges only explicit answers into inspected facts, retaining configured policy and per-store history.
function Merge-ReleaseSetupAnswers($report, $answers, [string]$Repository) {
    $report=($report | ConvertTo-Json -Depth 30) | ConvertFrom-Json -AsHashtable
    $config=$report.configuration
    if ($answers.Contains('project')) {
        $facts=Get-ReleaseSetupFacts $Repository $answers.project
        $report.facts=$facts
        if ($null -eq $config) {$config=New-ReleaseSetupConfiguration $facts @('itch','notes')}
        $config.project=$answers.project
    }
    if ($null -eq $config) {throw 'Select the actual Godot project before applying other setup answers.'}
    if ($answers.Contains('stores')) {
        if ($answers.stores -isnot [array] -or @($answers.stores | Where-Object {$_ -isnot [string]}).Count) {throw 'stores must be an array of store types.'}
        $candidate=New-ReleaseSetupConfiguration $report.facts $answers.stores
        # Preserve existing per-store facts rather than replacing configured values with nulls.
        $candidate.previousReleaseRef=$config.previousReleaseRef;$candidate.verification=$config.verification
        if ($config.Contains('standalone')) {$candidate.standalone=$config.standalone}
        if ($config.Contains('androidVersionCodePolicy')) {$candidate.androidVersionCodePolicy=$config.androidVersionCodePolicy}
        if ($config.Contains('destinationBaselines')) {
            foreach ($id in $config.destinationBaselines.Keys) {
                if ($id -cin @($candidate.destinations | ForEach-Object {$_.id})) {$candidate.destinationBaselines[$id]=$config.destinationBaselines[$id]}
            }
        }
        foreach ($item in $candidate.destinations) {
            $existing=@($config.destinations | Where-Object {$_.id -ceq $item.id})
            if ($existing.Count -eq 1) {for ($i=0;$i -lt $candidate.destinations.Count;$i++) {if ($candidate.destinations[$i].id -ceq $item.id) {$candidate.destinations[$i]=$existing[0]}}}
        }
        $config=$candidate
    }
    foreach ($key in $answers.Keys) {
        if ($key -in @('stores','project')) {continue}
        if ($key -in @('previousReleaseRef','exports','androidVersionCodePolicy','standalone','destinationBaselines')) {$config[$key]=$answers[$key];continue}
        if ($key -eq 'verification.script') {$config.verification.script=$answers[$key];continue}
        if ($key -eq 'verification.arguments') {$config.verification.arguments=$answers[$key];continue}
        if ($key -eq 'destinations') {$config.destinations=$answers[$key];continue}
        if ($key -match '^baseline\.([a-z][a-z0-9-]*)$') {
            $id=$Matches[1]
            if ($id -cnotin @($config.destinations | Where-Object {$_.type -ne 'notes'} | ForEach-Object {$_.id})) {throw 'Unknown baseline destination.'}
            if (-not $config.Contains('destinationBaselines')) {$config.destinationBaselines=[ordered]@{}}
            $config.destinationBaselines[$id]=$answers[$key];continue
        }
        if ($key -match '^([a-z][a-z0-9-]*)\.([A-Za-z]+)$') {
            $id=$Matches[1];$field=$Matches[2];$matchesForId=@($config.destinations | Where-Object {$_.id -ceq $id})
            if ($matchesForId.Count -ne 1) {throw "Unknown setup destination: $id"}
            $matchesForId[0][$field]=$answers[$key];continue
        }
        throw "Unknown setup answer: $key"
    }
    return $config
}

# Gathers human answers iteratively so selecting a new store exposes its required questions immediately.
function Invoke-ReleaseInteractiveSetup([string]$Repository, [string[]]$Destination=@(), [scriptblock]$Prompt) {
    $initial=Get-ReleaseSetup $Repository $Destination
    $report=$initial;$answers=[ordered]@{};$asked=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if (-not $Prompt) {$Prompt={param($question) Read-Host ($question.prompt+' Leave blank to defer')}}
    while ($true) {
        $unasked=@($report.questions | Where-Object {-not $asked.Contains($_.key)})
        if (-not $unasked.Count) {break}
        $question=$unasked[0];$asked.Add($question.key) | Out-Null
        $answer=& $Prompt $question
        if ([string]::IsNullOrWhiteSpace($answer)) {continue}
        if ($question.key -eq 'stores') {$answers[$question.key]=@($answer.Split(',') | ForEach-Object {$_.Trim()})}
        elseif ($question.key -eq 'standalone' -or $question.key -match '\.(depots|retainVersionCodes|userFraction)$') {$answers[$question.key]=$answer | ConvertFrom-Json -AsHashtable -NoEnumerate}
        elseif ($question.key -match '\.appId$') {$answers[$question.key]=[long]$answer}
        else {$answers[$question.key]=$answer}
        $candidate=Merge-ReleaseSetupAnswers $initial $answers $Repository
        $report=Get-ReleaseSetup $Repository $Destination $candidate
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
    if ($null -ne $config.previousReleaseRef) {
        $ref=Read-ReleaseGit $Repository @('rev-parse','--verify',"$($config.previousReleaseRef)^{commit}")
        $ancestor=Invoke-ReleaseTool 'git' @('--no-optional-locks','-C',$Repository,'merge-base','--is-ancestor',$ref,'HEAD') $Repository
        if ($ancestor.exitCode -ne 0) {throw 'Previous release ref must be an ancestor of HEAD.'}
    }
    if ($config.Contains('destinationBaselines')) {
        foreach ($ref in $config.destinationBaselines.Values) {
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

# Owns deterministic release validation, read-only plans, local preparation and journaled publication.
#requires -Version 7.3
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:SteamIgnore = @('steam_api*.dll','libsteam_api.so','libgodotsteam.*','steam_appid.txt')
Import-Module (Join-Path $PSScriptRoot 'ProcessTools.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'HostPaths.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'StoreAdapters.psm1') -Force
. (Join-Path $PSScriptRoot 'Configuration.ps1')

# Uses only read-only Git commands here; release scripts do not create source commits or tags.
function Read-ReleaseGit([string]$Repository, [string[]]$Arguments) {
    $result = Invoke-ReleaseTool 'git' (@('--no-optional-locks','-C',$Repository) + $Arguments) $Repository
    if ($result.exitCode -ne 0) { throw "Git read failed: $($Arguments[0]). Check the repository or ref." }
    return $result.text.Trim()
}

# Hashes UTF-8 text without a BOM for stable identities across PowerShell platforms.
function Get-ReleaseTextHash([string]$Text) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

# Resolves relative paths and existing link ancestors, refusing paths outside the chosen root.
function Resolve-ReleasePath([string]$Root, [string]$Relative, [switch]$MustExist, [switch]$Leaf) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative)) { throw 'Configuration paths must be relative and inside the repository.' }
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $path = [IO.Path]::GetFullPath((Join-Path $rootPath $Relative))
    $comparison = if ($IsWindows) {[StringComparison]::OrdinalIgnoreCase} else {[StringComparison]::Ordinal}
    $prefix = $rootPath + [IO.Path]::DirectorySeparatorChar
    if (-not ($path.Equals($rootPath,$comparison) -or $path.StartsWith($prefix,$comparison))) { throw "Path must stay inside the repository: $Relative" }
    $cursor = $path
    while ($cursor -and $cursor.StartsWith($rootPath,$comparison)) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if ($item -and $item.LinkType) {
            $resolved = $item.ResolveLinkTarget($true)
            if (-not $resolved -or -not ($resolved.FullName.Equals($rootPath,$comparison) -or $resolved.FullName.StartsWith($prefix,$comparison))) { throw "Linked path must stay inside the repository: $Relative" }
        }
        if ($cursor.Equals($rootPath,$comparison)) { break }
        $cursor = Split-Path $cursor -Parent
    }
    if ($MustExist -and -not (Test-Path -LiteralPath $path)) { throw "Configured path does not exist: $Relative" }
    if ($Leaf -and -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Configured file does not exist: $Relative" }
    return $path
}

# Screens release text for credential-like values without echoing the input.
function Assert-ReleaseCredentialFreeText([string]$Text) {
    $patterns=@(
        '(?i)((?<![\w./-])--?(password|token|api.?key|secret|identity)\b|https?://[^/\s]+@|(?<![A-Za-z0-9])(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9]{12,}|Bearer\s+\S+)'
        '(?i)(?<![\w./-])[\w.-]*(?:password|passwd|pwd|token|api.?key|secret|credential)[\w.-]*[\x22\x27]?\s*[:=]\s*\S+'
        '(?i)Authorization[\x22\x27]?\s*[:=]\s*[\x22\x27]?\s*Basic\s+\S+'
    )
    foreach ($pattern in $patterns) {if ($Text -match $pattern) {throw 'Credential-like values are forbidden in release data.'}}
}

# Rejects credential-bearing configuration and duplicate JSON keys before interpreting settings.
function Assert-ReleaseJson([System.Text.Json.JsonElement]$Element) {
    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $seen.Add($property.Name)) { throw "Duplicate configuration key: $($property.Name)" }
            if ($property.Name -match '(?i)password|secret|credential|token|api.?key|authorization|identity') { throw 'Credentials must not be stored in release configuration.' }
            Assert-ReleaseJson $property.Value
        }
    } elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        foreach ($child in $Element.EnumerateArray()) { Assert-ReleaseJson $child }
    } elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::String) {
        Assert-ReleaseCredentialFreeText $Element.GetString()
    }
}

# Enforces exact supported keys; misspellings cannot silently change release behavior.
function Assert-ReleaseFields($Object, [string[]]$Allowed, [string[]]$Required, [string]$Location) {
    if ($Object -isnot [Collections.IDictionary]) { throw "$Location must be an object." }
    foreach ($key in $Object.Keys) { if ($key -cnotin $Allowed) { throw "Unknown $Location field: $key" } }
    foreach ($key in $Required) { if (-not $Object.Contains($key)) { throw "Missing $Location field: $key" } }
}

# Reads scalar Godot properties within actual INI sections, without executing project code.
function Read-GodotSections([string]$Path) {
    $sections = [ordered]@{}
    $section = $null
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*\[([^\]]+)\]\s*$') {
            $section = $Matches[1]
            if ($sections.Contains($section)) { throw "Duplicate Godot section: $section" }
            $sections[$section] = [ordered]@{}
        } elseif ($section -and $line -match '^\s*([^=;]+)\s*=\s*("(?:\\.|[^"\\])*"|-?\d+|true|false)\s*$') {
            $key = $Matches[1].Trim(); $value = $Matches[2] | ConvertFrom-Json
            if ($sections[$section].Contains($key)) { throw "Duplicate Godot property: $key" }
            $sections[$section][$key] = $value
        }
    }
    return $sections
}

# Validates settings against the game, existing desktop presets and signed Android AAB presets.
function Get-ReleaseConfiguration([string]$Repository, $Configuration = $null) {
    $Repository = (Get-Item -LiteralPath $Repository).FullName
    $gitRoot = Read-ReleaseGit $Repository @('rev-parse','--show-toplevel')
    if ([IO.Path]::GetFullPath($gitRoot) -ne $Repository) { throw 'Repository must name the Git root.' }
    $configPath = Join-Path $Repository 'release.json'
    if ($null -eq $Configuration -and -not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw 'Run setup to inspect the game and gather its missing release.json settings.' }
    # A string is exact release.json text, such as a committed copy; its hash then matches the file's.
    $raw = if ($Configuration -is [string]) {$Configuration} elseif ($null -ne $Configuration) {$Configuration | ConvertTo-Json -Depth 30} else {[IO.File]::ReadAllText($configPath)}
    $json = [System.Text.Json.JsonDocument]::Parse($raw)
    try { Assert-ReleaseJson $json.RootElement } finally { $json.Dispose() }
    $document = $raw | ConvertFrom-Json -AsHashtable
    $config = ConvertTo-ReleaseRuntimeConfiguration $document
    Assert-ReleaseFields $config @('schemaVersion','project','previousReleaseRef','exports','verification','destinations','androidVersionCodePolicy','standalone','destinationBaselines') @('schemaVersion','project','previousReleaseRef','exports','verification','destinations') 'release.json'
    if ($config.Contains('androidVersionCodePolicy') -and $config.androidVersionCodePolicy -cnotin @('existing','increment-selected')) {throw 'androidVersionCodePolicy must be existing or increment-selected.'}
    if ($config.schemaVersion -isnot [long] -and $config.schemaVersion -isnot [int]) { throw 'schemaVersion must be integer 1.' }
    if ($config.schemaVersion -ne 1) { throw 'Unsupported schemaVersion; expected 1.' }
    if ($config.project -isnot [string]) { throw 'project must be a relative directory.' }
    if ($null -ne $config.previousReleaseRef -and ($config.previousReleaseRef -isnot [string] -or [string]::IsNullOrWhiteSpace($config.previousReleaseRef) -or $config.previousReleaseRef.StartsWith('-'))) { throw 'previousRelease must be null or a Git ref.' }
    $project = Resolve-ReleasePath $Repository $config.project -MustExist
    $projectSections = Read-GodotSections (Join-Path $project 'project.godot')
    if (-not $projectSections.Contains('application') -or -not $projectSections.application.Contains('config/version')) { throw 'Godot application config/version is required as the version source.' }
    $version = $projectSections.application['config/version']
    if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$') { throw 'Godot config/version must be a release version such as 1.2.3.' }
    $title = if ($projectSections.application.Contains('config/name')) {$projectSections.application['config/name']} else {$null}
    $sections = Read-GodotSections (Join-Path $project 'export_presets.cfg')
    if ($config.exports -isnot [array] -or $config.exports.Count -eq 0) { throw 'exports must list existing export preset names.' }
    $presets = [Collections.Generic.List[object]]::new()
    $usedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $config.exports) {
        if ($name -isnot [string] -or -not $usedNames.Add($name)) { throw 'Duplicate or invalid export preset name.' }
        $matchesForName = @($sections.Keys | Where-Object {$_ -match '^preset\.\d+$' -and $sections[$_].Contains('name') -and $sections[$_].name -ceq $name})
        if ($matchesForName.Count -ne 1) { throw "Existing export preset not uniquely found: $name" }
        $preset = $sections[$matchesForName[0]]
        if (-not $preset.Contains('platform') -or $preset.platform -notin @('Windows Desktop','Linux','Android')) { throw "Unsupported export platform: $name" }
        if (-not $preset.Contains('export_path') -or [string]::IsNullOrWhiteSpace($preset.export_path)) { throw "Preset has no existing export_path: $name" }
        $output = [IO.Path]::GetFullPath((Join-Path $project $preset.export_path))
        $relativeOutput = [IO.Path]::GetRelativePath($Repository,$output)
        Resolve-ReleasePath $Repository $relativeOutput | Out-Null
        if (-not [IO.Path]::GetFileName($output)) { throw "Preset must have an export filename: $name" }
        $record=[ordered]@{name=$name; platform=$preset.platform; configuredPath=$relativeOutput.Replace('\','/'); filename=[IO.Path]::GetFileName($output)}
        $optionSection=$matchesForName[0]+'.options'
        if ($preset.platform -eq 'Windows Desktop' -and $sections.Contains($optionSection)) {
            $record.versionMetadata=[ordered]@{}
            foreach ($key in @('application/file_version','application/product_version')) {
                if (-not $sections[$optionSection].Contains($key)) {continue}
                $value=$sections[$optionSection][$key];$record.versionMetadata[$key]=$value
                if ($value -isnot [string] -or ($value -ne '' -and $value -cne $version -and $value -cne "$version.0")) {throw "Windows version metadata $key must be empty or follow Godot config/version."}
            }
        }
        if ($preset.platform -eq 'Android') {
            $optionSection=$matchesForName[0]+'.options'
            if (-not $sections.Contains($optionSection)) { throw "Missing Android options: $name" }
            $options=$sections[$optionSection]
            foreach ($key in @('gradle_build/use_gradle_build','gradle_build/export_format','version/code','version/name','package/unique_name','package/signed')) {
                if (-not $options.Contains($key)) { throw "Missing Android option '$key': $name" }
            }
            $aab=$options['gradle_build/use_gradle_build'] -is [bool] -and $options['gradle_build/use_gradle_build'] -eq $true -and ($options['gradle_build/export_format'] -is [int] -or $options['gradle_build/export_format'] -is [long]) -and $options['gradle_build/export_format'] -eq 1 -and $output.EndsWith('.aab',[StringComparison]::OrdinalIgnoreCase)
            $apk=$options['gradle_build/use_gradle_build'] -is [bool] -and ($options['gradle_build/use_gradle_build'] -eq $false -or $options['gradle_build/export_format'] -eq 0) -and $output.EndsWith('.apk',[StringComparison]::OrdinalIgnoreCase)
            if ($options['package/signed'] -isnot [bool] -or $options['package/signed'] -ne $true -or -not ($aab -or $apk)) {throw "Android requires an existing signed APK or signed Gradle AAB preset: $name"}
            if ($options['version/code'] -isnot [long] -and $options['version/code'] -isnot [int]) { throw 'Android version/code must be an integer.' }
            if ($options['version/code'] -lt 1 -or $options['version/code'] -gt 2100000000) { throw 'Android version/code is outside the Google Play range.' }
            if ($options['version/name'] -isnot [string] -or ($options['version/name'] -ne '' -and $options['version/name'] -cne $version)) { throw 'Android version/name must be empty (Godot fallback) or equal the Godot project version.' }
            if ($options['package/unique_name'] -isnot [string] -or $options['package/unique_name'] -notmatch '^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$') { throw 'Android package/unique_name must be an inspected literal package name.' }
            $record.packageName=$options['package/unique_name']; $record.versionCode=$options['version/code'];$record.format=if ($aab) {'aab'} else {'apk'}
            $record.useGradle=$options['gradle_build/use_gradle_build']
        }
        $presets.Add($record)
    }
    Assert-ReleaseFields $config.verification @('script','arguments') @('script','arguments') 'verification'
    if ($config.verification.script -isnot [string] -or -not $config.verification.script.EndsWith('.ps1')) { throw 'verification.script must name an inspected PowerShell script.' }
    $verificationPath = Resolve-ReleasePath $Repository $config.verification.script -Leaf
    if ($config.verification.arguments -isnot [array] -or @($config.verification.arguments | Where-Object {$_ -isnot [string]}).Count -gt 0) { throw 'verification.arguments must be an array of strings.' }
    if ($config.Contains('standalone')) {
        if ($config.standalone -isnot [array]) {throw 'standalone must be an array of inspected per-preset checks.'}
        $checked=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($check in $config.standalone) {
            Assert-ReleaseFields $check @('preset','script','arguments') @('preset','script','arguments') 'standalone check'
            if ($check.preset -cnotin $config.exports -or -not $checked.Add($check.preset)) {throw 'Standalone checks require distinct configured presets.'}
            if ($null -ne $check.script) {
                if ($check.script -isnot [string] -or -not $check.script.EndsWith('.ps1')) {throw 'Standalone script must name an inspected PowerShell script or remain null.'}
                Resolve-ReleasePath $Repository $check.script -Leaf | Out-Null
            }
            if ($check.arguments -isnot [array] -or @($check.arguments | Where-Object {$_ -isnot [string] -or ($_ -replace '\{(?:artifact|platform|repository|filename)\}','') -match '[{}]'}).Count) {throw 'Standalone arguments support only {artifact}, {platform}, {repository} and {filename} substitutions.'}
        }
    }
    if ($config.destinations -isnot [array] -or $config.destinations.Count -eq 0) { throw 'destinations must be a nonempty array.' }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $uploadTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($destination in $config.destinations) {
        Assert-ReleaseFields $destination @('id','type','preset','target','ignore','appId','branch','depots','track','releaseStatus','userFraction','language','retainVersionCodes','baselineAdvancesOn','displayNameTemplate') @('id','type') 'destination'
        if ($destination.id -isnot [string] -or $destination.id -notmatch '^[a-z][a-z0-9-]*$' -or -not $ids.Add($destination.id)) { throw 'Destination IDs must be distinct lowercase identifiers.' }
        if ($destination.type -eq 'itch') {
            Assert-ReleaseFields $destination @('id','type','preset','target','ignore','displayNameTemplate') @('id','type','preset','target','ignore') 'itch destination'
            if ($destination.preset -cnotin $config.exports) { throw "Destination preset is not a configured export: $($destination.id)" }
            $itchPreset=@($presets | Where-Object {$_.name -ceq $destination.preset})[0]
            if ($itchPreset.platform -eq 'Android' -and $itchPreset.format -ne 'apk') {throw 'Itch Android requires a signed APK preset.'}
            if ($destination.Contains('displayNameTemplate')) {Resolve-ReleaseDisplayName $destination.displayNameTemplate $title $version $itchPreset.platform | Out-Null}
            if ($null -ne $destination.target -and ($destination.target -isnot [string] -or $destination.target -notmatch '^[A-Za-z0-9_-]+/[A-Za-z0-9_-]+:[A-Za-z0-9_.-]+$' -or -not $uploadTargets.Add($destination.target))) { throw 'Butler target must be null or a distinct owner/game:channel.' }
            if ($destination.ignore -isnot [array] -or @($destination.ignore | Where-Object {$_ -isnot [string] -or $_ -match '[\\/\[\]]|\*\*' -or [string]::IsNullOrWhiteSpace($_)}).Count -gt 0) { throw 'Butler ignore patterns must be basename patterns using * and ?, without paths or **.' }
            foreach ($required in $script:SteamIgnore) { if ($required -cnotin $destination.ignore) { throw "Butler ignore list must include Steam pattern '$required'." } }
        } elseif ($destination.type -eq 'steam') {
            Assert-ReleaseFields $destination @('id','type','appId','branch','depots') @('id','type','appId','branch','depots') 'Steam destination'
            if (($destination.appId -isnot [long] -and $destination.appId -isnot [int]) -or $destination.appId -lt 1 -or $destination.appId -gt [uint32]::MaxValue) { throw 'Steam appId must be an inspected positive integer.' }
            if ($null -ne $destination.branch -and ($destination.branch -isnot [string] -or $destination.branch -notmatch '^[A-Za-z0-9_-]+$')) { throw 'Steam branch must be null or an explicit branch name.' }
            if ($destination.depots -isnot [array] -or $destination.depots.Count -eq 0) { throw 'Steam depots must list inspected depot mappings.' }
            $depotIds=[Collections.Generic.HashSet[long]]::new()
            foreach ($depot in $destination.depots) {
                Assert-ReleaseFields $depot @('id','preset','exclude') @('id','preset','exclude') 'Steam depot'
                if (($depot.id -isnot [long] -and $depot.id -isnot [int]) -or $depot.id -lt 1 -or $depot.id -gt [uint32]::MaxValue -or -not $depotIds.Add($depot.id)) { throw 'Steam depot IDs must be inspected distinct positive integers.' }
                if ($depot.preset -cnotin $config.exports -or @($presets | Where-Object {$_.name -ceq $depot.preset})[0].platform -eq 'Android') { throw 'Steam depot must use a configured desktop preset.' }
                if ($depot.exclude -isnot [array] -or @($depot.exclude | Where-Object {$_ -isnot [string] -or $_ -match '[\\/"\r\n\[\]]|\*\*' -or [string]::IsNullOrWhiteSpace($_)}).Count) { throw 'Steam exclusions must be inspected basename patterns.' }
            }
            if (-not $uploadTargets.Add("steam:$($destination.appId)")) { throw 'Duplicate Steam app destination.' }
        } elseif ($destination.type -eq 'google-play') {
            Assert-ReleaseFields $destination @('id','type','preset','track','releaseStatus','userFraction','language','retainVersionCodes','baselineAdvancesOn') @('id','type','preset','track','releaseStatus','userFraction','language','retainVersionCodes') 'Google Play destination'
            if ($destination.preset -cnotin $config.exports -or @($presets | Where-Object {$_.name -ceq $destination.preset})[0]['format'] -ne 'aab') { throw 'Google Play requires a configured Android AAB preset.' }
            if ($destination.Contains('baselineAdvancesOn') -and $destination.baselineAdvancesOn -cnotin @('live','submitted')) { throw 'Google Play baselineAdvancesOn must be live or submitted.' }
            if ($null -ne $destination.track -and ($destination.track -isnot [string] -or $destination.track -notmatch '^[A-Za-z0-9_.-]+$')) { throw 'Google Play track must be null or an explicit track name.' }
            if ($null -ne $destination.releaseStatus -and $destination.releaseStatus -cnotin @('draft','completed','inProgress')) { throw 'Google Play releaseStatus must be null, draft, completed or inProgress.' }
            if ($destination.releaseStatus -ceq 'inProgress') {
                if ($null -ne $destination.userFraction -and (($destination.userFraction -isnot [double] -and $destination.userFraction -isnot [decimal]) -or $destination.userFraction -le 0 -or $destination.userFraction -ge 1)) { throw 'Google Play userFraction must be null or a number between zero and one for inProgress.' }
            } elseif ($null -ne $destination.userFraction) { throw 'Google Play userFraction applies only to inProgress.' }
            if ($null -ne $destination.language -and ($destination.language -isnot [string] -or $destination.language -notmatch '^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$')) { throw 'Google Play language must be null or a BCP-47 language code.' }
            if ($null -ne $destination.retainVersionCodes -and ($destination.retainVersionCodes -isnot [array] -or @($destination.retainVersionCodes | Where-Object {$_ -isnot [string] -or $_ -notmatch '^[1-9][0-9]*$' -or $_.Length -gt 10 -or [long]$_ -gt 2100000000}).Count -or @($destination.retainVersionCodes | Sort-Object -Unique).Count -ne $destination.retainVersionCodes.Count)) { throw 'Google Play retainVersionCodes must be null or an explicit array of distinct version-code strings (empty means retain none).' }
            $android=@($presets | Where-Object {$_.name -ceq $destination.preset})[0]
            if (-not $uploadTargets.Add("play:$($android.packageName)")) { throw 'Use one Google Play edit/track destination per application per plan.' }
        } elseif ($destination.type -eq 'notes') {
            Assert-ReleaseFields $destination @('id','type') @('id','type') 'notes destination'
            if (@($config.destinations | Where-Object {$_.type -eq 'notes'}).Count -gt 1) { throw 'Only one public notes destination is supported.' }
        } else { throw "Unsupported destination type: $($destination.type). Add a tested adapter before using it." }
    }
    $origin = Read-ReleaseGit $Repository @('remote','get-url','origin')
    if ($config.Contains('destinationBaselines')) {
        if ($config.destinationBaselines -isnot [Collections.IDictionary]) {throw 'destinationBaselines must map destination IDs to confirmed Git refs or null.'}
        foreach ($id in $config.destinationBaselines.Keys) {
            $ref=$config.destinationBaselines[$id]
            if ($id -cnotin @($config.destinations | ForEach-Object {$_.id}) -or ($null -ne $ref -and ($ref -isnot [string] -or [string]::IsNullOrWhiteSpace($ref) -or $ref.StartsWith('-')))) {throw 'destinationBaselines requires known destination IDs and Git refs or null.'}
        }
    }
    $notesRepository = "$(ConvertTo-ReleaseSourceRepository $origin)-release-notes"
    return @{repository=$Repository; projectPath=$project; version=$version; title=$title; config=$config; document=$document; configHash=(Get-ReleaseTextHash $raw); presets=$presets.ToArray(); notesRepository=$notesRepository; verificationPath=$verificationPath}
}

# Names the github.com repository an origin URL points at as owner/name, whichever URL form a checkout uses.
function ConvertTo-ReleaseSourceRepository([string]$Origin) {
    if ($Origin -match '^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?$' -or $Origin -match '^(?:git@github\.com:|ssh://git@github\.com/)([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?$') {
        return "$($Matches[1])/$($Matches[2])"
    }
    throw 'A credential-free github.com origin is required to derive the public release-notes repository.'
}

# Names the github.com repository a checkout's origin points at; every checkout, worktree and clone of one game names the same one.
function Get-ReleaseSourceRepository([string]$Repository) {
    return ConvertTo-ReleaseSourceRepository (Read-ReleaseGit $Repository @('remote','get-url','origin'))
}

# Emits a reproducible plan without exports, checks, writes, Git mutations or network access. A prepared release passes its
# own canonical boundary as $FrozenPrevious, as it passes its baselines, so what later ships elsewhere never changes its plan.
# $ReleaseVersion names the version being released where it is not yet the plan's own, as before a bump is reserved, so the
# boundary leaves out only that release's receipts.
function Get-ReleasePlan([string]$Repository, [string[]]$Destination = @(), $BaselineSnapshot=$null, [string]$StateRoot, [ValidateSet('current','patch','minor','major')][string]$VersionChange='current', $FrozenPrevious, [string]$ReleaseVersion) {
    $settings = Get-ReleaseConfiguration $Repository
    $version = Get-ReleaseVersion $settings.version $VersionChange
    $Repository = $settings.repository
    $known = @($settings.config.destinations | ForEach-Object {$_.id})
    foreach ($id in $Destination) { if ($id -cnotin $known) { throw "Unknown destination: $id" } }
    $selected = @($Destination | Sort-Object -Unique -CaseSensitive)
    $blockers = [Collections.Generic.List[string]]::new()
    if ($selected.Count -eq 0) { $blockers.Add('Select release destinations explicitly; none are selected.') }
    $head = Read-ReleaseGit $Repository @('rev-parse','HEAD')
    $dirty = Read-ReleaseGit $Repository @('status','--porcelain=v1','--untracked-files=all')
    $shallow = Read-ReleaseGit $Repository @('rev-parse','--is-shallow-repository')
    if ($shallow -eq 'true') { $blockers.Add('Shallow history cannot establish a complete previous-release comparison.') }
    # Only a new plan reads previousRelease. A prepared release's saved boundary is checked instead, so its ref can move
    # or be deleted later without changing the release.
    $configured = $null
    if ($PSBoundParameters.ContainsKey('FrozenPrevious')) {
        if ($FrozenPrevious) {
            $saved = Invoke-ReleaseTool 'git' @('--no-optional-locks','-C',$Repository,'rev-parse','--verify','--quiet',"$FrozenPrevious^{commit}") $Repository
            $ancestor = if ($saved.exitCode -eq 0 -and $saved.text.Trim() -ceq $FrozenPrevious) {Invoke-ReleaseTool 'git' @('--no-optional-locks','-C',$Repository,'merge-base','--is-ancestor',$FrozenPrevious,$head) $Repository} else {$null}
            if (-not $ancestor -or $ancestor.exitCode -ne 0) { throw 'The prepared release''s previous-release commit must be an exact commit that is an ancestor of HEAD.' }
        }
    } elseif ($null -ne $settings.config.previousReleaseRef) {
        $configured = Read-ReleaseGit $Repository @('rev-parse','--verify',"$($settings.config.previousReleaseRef)^{commit}")
        $ancestor = Invoke-ReleaseTool 'git' @('--no-optional-locks','-C',$Repository,'merge-base','--is-ancestor',$configured,$head) $Repository
        if ($ancestor.exitCode -ne 0) { throw 'Previous release ref must be an ancestor of HEAD.' }
    }
    $destinations = @(foreach ($item in $settings.config.destinations) {
        $record = [ordered]@{id=$item.id; type=$item.type; selected=($item.id -cin $selected); status='not-selected'}
        if ($record.selected) { $record.status='planned' }
        if ($item.type -eq 'itch') {
            $record.preset=$item.preset; $record.target=$item.target; $record.ignore=$item.ignore
            if ($item.Contains('displayNameTemplate')) {
                $preset=@($settings.presets | Where-Object {$_.name -ceq $item.preset})[0]
                $record.displayName=Resolve-ReleaseDisplayName $item.displayNameTemplate $settings.title $version $preset.platform
                $record.requiredActions=@("Set the upload's display name to '$($record.displayName)' on itch.io's Edit game page; this does not control the downloaded archive filename.")
            }
            if ($record.selected -and $null -eq $item.target) { $record.status='blocked'; $blockers.Add("$($item.id): Butler target is unconfirmed.") }
            $preset=@($settings.presets | Where-Object {$_.name -ceq $item.preset})[0]
            if ($record.selected -and $preset.platform -ne 'Android') {
                $checks=@(if ($settings.config.Contains('standalone')) {$settings.config.standalone | Where-Object {$_.preset -ceq $item.preset -and $null -ne $_.script}})
                if ($checks.Count -ne 1) {$record.status='blocked';$blockers.Add("$($item.id): Configure a meaningful standalone check for $($preset.platform), with Steam files unavailable.")}
            }
        } elseif ($item.type -eq 'steam') {
            $record.appId=$item.appId; $record.branch=$item.branch; $record.depots=$item.depots
            $record.requiredActions=@('Verify build activation on the selected Steam branch in Steamworks.','Publish the approved notes as a Steam announcement.')
            if ($record.selected -and $null -eq $item.branch) { $record.status='blocked'; $blockers.Add("$($item.id): Steam branch is unconfirmed.") }
        } elseif ($item.type -eq 'google-play') {
            foreach ($key in @('preset','track','releaseStatus','userFraction','language','retainVersionCodes')) { $record[$key]=$item[$key] }
            if ($item.Contains('baselineAdvancesOn')) {$record.baselineAdvancesOn=$item.baselineAdvancesOn}
            $android=@($settings.presets | Where-Object {$_.name -ceq $item.preset})[0]
            $record.packageName=$android.packageName; $record.versionCode=$android.versionCode
            $record.requiredActions=@('Review all current Play track releases before approving retained version codes.')
            # A game whose baselines advance on submission ends its release work there, so no console check after it is owed.
            if ($item['baselineAdvancesOn'] -cne 'submitted') {$record.requiredActions+=@('Verify review, managed publishing and rollout state in Play Console after submission.')}
            if ($record.selected) {
                foreach ($key in @('track','releaseStatus','language','retainVersionCodes')) {
                    if ($null -eq $item[$key]) { $record.status='blocked'; $blockers.Add("$($item.id): Google Play $key is unconfirmed.") }
                }
                if ($item.releaseStatus -ceq 'inProgress' -and $null -eq $item.userFraction) { $record.status='blocked'; $blockers.Add("$($item.id): Google Play rollout fraction is unconfirmed.") }
            }
        } else {
            $record.repository=$settings.notesRepository
            $record.path="releases/$version.md"
        }
        $record
    })
    # The canonical notes count from the newest release of this game that went live anywhere, or from previousRelease.
    $previous = $null
    $changes = @()
    $changedFiles = @()
    $ambiguous = $null
    if ($PSBoundParameters.ContainsKey('FrozenPrevious')) { $previous = $FrozenPrevious }
    else {
        $boundary = Get-ReleasePublishedBoundary $settings $head $(if ($ReleaseVersion) {$ReleaseVersion} else {$version}) $configured $StateRoot
        $previous = $boundary.commit; $ambiguous = $boundary.ambiguous
    }
    if ($ambiguous) { $blockers.Add($ambiguous) }
    elseif (-not $previous) { $blockers.Add('previousRelease is unconfirmed; identify the previous published release source commit/ref.') }
    else {
        $log = Read-ReleaseGit $Repository @('log','--no-merges','--reverse','--format=%H%x1f%s',"$previous..$head")
        $changes = @(foreach ($line in $log.Split("`n")) {
            if (-not $line) {continue}
            $parts = $line.Split([char]31,2)
            [ordered]@{commit=$parts[0]; subject=$parts[1]}
        })
        $diff = Read-ReleaseGit $Repository @('diff','--name-only',$previous,$head,'--')
        $changedFiles = @($diff.Split("`n") | Where-Object {$_})
    }
    $baselines=Get-ReleaseDestinationBaselines $settings $destinations $head $BaselineSnapshot $StateRoot
    foreach ($record in $destinations) {
        if (-not $record.selected -or $record.type -eq 'notes') {continue}
        $record.previousCommit=$baselines[$record.id]
        $record.changes=@();$record.changedFiles=@()
        if ($null -eq $record.previousCommit) {$record.status='blocked';$blockers.Add("$($record.id): Confirm its last live source commit/ref for catch-up notes.");continue}
        $log=Read-ReleaseGit $Repository @('log','--no-merges','--reverse','--format=%H%x1f%s',"$($record.previousCommit)..$head")
        $record.changes=@(foreach ($line in $log.Split("`n")) {if ($line) {$parts=$line.Split([char]31,2);[ordered]@{commit=$parts[0];subject=$parts[1]}}})
        $record.changedFiles=@((Read-ReleaseGit $Repository @('diff','--name-only',$record.previousCommit,$head,'--')).Split("`n") | Where-Object {$_})
    }
    $needed = @(@(foreach ($target in $destinations) {
        if (-not $target.selected) {continue}
        if ($target.type -in @('itch','google-play')) {$target.preset}
        elseif ($target.type -eq 'steam') {$target.depots | ForEach-Object {$_.preset}}
    }) | Sort-Object -Unique -CaseSensitive)
    $requiredExports=@($settings.presets | Where-Object {$_.name -cin $needed})
    $identity = [ordered]@{schemaVersion=1; repository=$Repository; head=$head; configSha256=$settings.configHash; version=$version; previousCommit=$previous; selectedDestinations=$selected;baselines=$baselines;versionChange=$VersionChange}
    $planId = Get-ReleaseTextHash ($identity | ConvertTo-Json -Depth 10 -Compress)
    $draft = "# $($settings.title) $version`n`n<!-- sourceCommit: $head; previousCommit: $previous -->`n`n"
    if ($previous) {
        if ($changes.Count) { $draft += (($changes | ForEach-Object { "- $($_.subject)" }) -join "`n") + "`n" }
        else { $draft += "No commits since the confirmed previous release.`n" }
    } else { $draft += "Previous published release boundary is unconfirmed; release notes cannot yet be derived.`n" }
    $draft+="`n[Release availability](../availability/$version.json)`n"
    $configurationReady=($blockers.Count -eq 0)
    $sourceChanges=@($dirty.Split("`n") | Where-Object {$_})
    if ($dirty) { $blockers.Add('The source working tree contains uncommitted files; review and commit or resolve them before preparation.') }
    if ($VersionChange -ne 'current') {$blockers.Add('Projected source version must be reserved and committed by prepare before this becomes a buildable release plan.')}
    return [ordered]@{
        schemaVersion=1; mode='plan'; planId=$planId; repository=$Repository; head=$head
        version=$version; sourceVersion=$settings.version; versionChange=$VersionChange; preview=($VersionChange -ne 'current'); configSha256=$settings.configHash; previousCommit=$previous
        selectedDestinations=$selected; notesRepository=$settings.notesRepository;baselines=$baselines
        exports=$settings.presets; requiredExports=$requiredExports; destinations=$destinations; changes=$changes; changedFiles=$changedFiles
        notesDraft=$draft; configurationReady=$configurationReady; sourceChanges=$sourceChanges
        blockers=$blockers.ToArray(); ready=($blockers.Count -eq 0)
    }
}

# Writes only owned journal files through a same-directory atomic replacement.
function Write-ReleaseJson([string]$Path, $Value) {
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($temporary,($Value | ConvertTo-Json -Depth 60),[Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary,$Path,$true)
}

# Chooses a per-user state directory outside the source repository by default.
function Get-ReleaseStateRoot([string]$StateRoot) {
    if ($StateRoot) { return Resolve-ReleasePhysicalPath $StateRoot }
    if ($IsWindows) { return Resolve-ReleasePhysicalPath (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ba-release/releases') }
    $base = if ($env:XDG_STATE_HOME) {$env:XDG_STATE_HOME} else {Join-Path ([Environment]::GetFolderPath('UserProfile')) '.local/state'}
    return Join-Path $base 'ba-release/releases'
}

# Gives an existing release state's directory as a path inside its state root, whose shared ledger and store-write record
# sit two folders up: the given path where it is one, as through a link to the state root or a checkout folder linked into
# it from elsewhere; otherwise its physical location, as through a link to the state's own folder. A state inside a state
# root sits in a folder named for its version, under one named for its checkout. A journal that cannot be read is left
# for the mode to report.
function Resolve-ReleaseStatePath([string]$StatePath) {
    $given=(Get-Item -LiteralPath $StatePath).FullName.TrimEnd('\','/')
    $journal=Read-ReleaseStateObject (Join-Path $given 'state.json')
    $plan=if ($journal) {$journal['plan']} else {$null}
    if ($plan -isnot [Collections.IDictionary] -or $plan['repository'] -isnot [string] -or $plan['version'] -isnot [string]) {return $given}
    $checkout=(Get-ReleaseTextHash $plan['repository']).Substring(0,20)
    $comparison=if ($IsWindows) {[StringComparison]::OrdinalIgnoreCase} else {[StringComparison]::Ordinal}
    foreach ($path in @($given,(Resolve-ReleasePhysicalPath $given).TrimEnd('\','/'))) {
        if ((Split-Path $path -Leaf).Equals($plan['version'],$comparison) -and (Split-Path (Split-Path $path -Parent) -Leaf).Equals($checkout,$comparison)) {return $path}
    }
    throw 'This release state is not inside a state root, so its shared ledger cannot be found; pass the state path prepare returned.'
}

# Resolves linked ancestors even when the final staging directory does not exist yet.
function Resolve-ReleasePhysicalPath([string]$Path) {
    if ($IsWindows) {return Resolve-ReleaseWindowsPath $Path}
    $physical=[IO.Path]::GetFullPath($Path)
    $seen=[Collections.Generic.HashSet[string]]::new($(if ($IsWindows) {[StringComparer]::OrdinalIgnoreCase} else {[StringComparer]::Ordinal}))
    for ($iteration=0;$iteration -lt 64;$iteration++) {
        if (-not $seen.Add($physical)) {throw 'Linked staging path contains a cycle.'}
        $cursor=$physical;$changed=$false
        while ($cursor) {
            $item=Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
            if ($item -and $item.LinkType) {
                $target=$item.ResolveLinkTarget($true)
                if (-not $target) {throw 'Linked staging path cannot be resolved.'}
                $suffix=[IO.Path]::GetRelativePath($cursor,$physical)
                $physical=[IO.Path]::GetFullPath((Join-Path $target.FullName $suffix));$changed=$true;break
            }
            $parent=Split-Path $cursor -Parent
            if (-not $parent -or $parent -eq $cursor) {break}
            $cursor=$parent
        }
        if (-not $changed) {return $physical}
    }
    throw 'Linked staging path is too deeply nested.'
}

# Opens an exclusive process lock so preparation and publication cannot race on a journal.
function Lock-ReleaseState([string]$StatePath) {
    try { return [IO.File]::Open((Join-Path $StatePath '.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch { throw 'Release state is locked by another process.' }
}

# Enumerates complete staged artifacts and refuses links that could move outside the snapshot.
function Get-ReleaseArtifact([string]$StatePath, [string]$Directory, [string]$Preset, [string]$SourceCommit) {
    $items = @(Get-ChildItem -LiteralPath $Directory -Recurse -Force)
    if (@($items | Where-Object {$_.LinkType}).Count) { throw 'Staged artifact links are not supported; use regular exported files.' }
    $files = @($items | Where-Object {-not $_.PSIsContainer} | Sort-Object FullName -CaseSensitive | ForEach-Object {
        [ordered]@{path=[IO.Path]::GetRelativePath($StatePath,$_.FullName).Replace('\','/'); size=$_.Length; sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
    })
    if ($files.Count -eq 0) { throw 'Export produced no artifact files.' }
    $record=[ordered]@{preset=$Preset; directory=[IO.Path]::GetRelativePath($StatePath,$Directory).Replace('\','/'); files=$files}
    if ($SourceCommit) {$record.sourceCommit=$SourceCommit}
    return $record
}

# Checks hashes plus added/deleted files against the prepared snapshot before approval or retry.
function Assert-ReleaseArtifacts([string]$StatePath, $State) {
    foreach ($artifact in $State.artifacts) {
        $directory = Resolve-ReleasePath $StatePath $artifact.directory -MustExist
        $current = Get-ReleaseArtifact $StatePath $directory $artifact.preset $artifact['sourceCommit']
        if (($current | ConvertTo-Json -Depth 15 -Compress) -cne ($artifact | ConvertTo-Json -Depth 15 -Compress)) { throw "Prepared artifact changed: $($artifact.preset)." }
    }
}

# Finds an installed engine at runtime; host-specific executable paths do not enter release.json.
function Get-ReleaseEngine([string]$Executable) {
    if ($Executable) {
        $engine=Find-ReleaseDoctorTool $Executable
        if ($engine) {return $engine}
        throw 'Requested Godot executable was not found.'
    }
    foreach ($name in @('godot_console','godot4_console','godot','godot4')) {
        $engine=Find-ReleaseDoctorTool $name
        if ($engine) {return $engine}
    }
    throw 'No Godot executable found; supply -GodotExecutable for the inspected engine.'
}

# Runs verified local exports once per unchanged release and journals each preset for safe retries.
function Invoke-ReleasePrepare([string]$Repository, [string[]]$Destination, [string]$StateRoot, [string]$GodotExecutable, [ValidateSet('current','patch','minor','major')][string]$VersionChange='current', [switch]$NewRelease, [string]$ButlerExecutable='butler') {
    $settings = Get-ReleaseConfiguration $Repository
    $base = Get-ReleaseStateRoot $StateRoot
    $repositoryId = (Get-ReleaseTextHash $settings.repository).Substring(0,20)
    $repositoryState=Join-Path $base $repositoryId
    $statePath = Join-Path $repositoryState $settings.version
    # User state must stay outside the source tree, keeping Git and planning stable.
    $relativeState = [IO.Path]::GetRelativePath((Resolve-ReleasePhysicalPath $settings.repository),(Resolve-ReleasePhysicalPath $statePath))
    if (-not [IO.Path]::IsPathRooted($relativeState) -and $relativeState -notmatch '^\.\.(?:[\\/]|$)') { throw 'StateRoot must be outside the source repository.' }
    $priorState=if (Test-Path -LiteralPath (Join-Path $statePath 'state.json')) {[IO.File]::ReadAllText((Join-Path $statePath 'state.json')) | ConvertFrom-Json -AsHashtable} else {$null}
    # A prepared release keeps its frozen baselines and canonical boundary from the first plan on, however far another checkout
    # has since moved them. A new one is checked at the version it is about to reserve.
    $frozen=if ($priorState -and -not $NewRelease) {@{BaselineSnapshot=$priorState.plan.baselines;FrozenPrevious=$priorState.plan.previousCommit}} else {@{}}
    $releasing=if ($frozen.Count) {@{}} else {@{ReleaseVersion=(Get-ReleaseVersion $settings.version $VersionChange)}}
    $plan = Get-ReleasePlan -Repository $Repository -Destination $Destination -StateRoot $StateRoot @frozen @releasing
    if (-not $plan.configurationReady) { throw "Release plan is blocked: $($plan.blockers -join ' ')" }
    $sourceResult=if (-not $priorState -or $NewRelease) {Initialize-ReleaseSource $settings $plan $repositoryState $VersionChange -NewRelease:$NewRelease} else {$null}
    if ($sourceResult -and $sourceResult.status -eq 'source-update-required') {return $sourceResult}
    $plan=Get-ReleasePlan -Repository $Repository -Destination $Destination -StateRoot $StateRoot @frozen
    if (-not $plan.ready) {throw "Release plan is blocked: $($plan.blockers -join ' ')"}
    $settings=Get-ReleaseConfiguration $Repository
    $statePath=Join-Path $repositoryState $plan.version
    New-Item -ItemType Directory -Path $statePath -Force | Out-Null
    $lock = Lock-ReleaseState $statePath
    try {
        $stateFile = Join-Path $statePath 'state.json'
        if (Test-Path -LiteralPath $stateFile) {
            $state = [IO.File]::ReadAllText($stateFile) | ConvertFrom-Json -AsHashtable
            if ($state.plan.planId -cne $plan.planId) { throw 'This version already has a different release plan. Resume that snapshot; do not bump the version just to retry.' }
            if ($state.status -in @('prepared','published','submitted','needs-store-action','partial-failure','publication-failed','needs-reconciliation','on-hold','awaiting-release','abandoned')) {
                Assert-ReleaseArtifacts $statePath $state
                if ($state.status -eq 'prepared') {
                    try {Invoke-ReleaseDistributionChecks $settings $state $statePath $ButlerExecutable {Write-ReleaseJson $stateFile $state}}
                    catch {$state.status='preparation-failed';Write-ReleaseJson $stateFile $state}
                }
                return @{status=$state.status; statePath=$statePath; planId=$plan.planId}
            }
        } else {
            $state = [ordered]@{schemaVersion=1; plan=$plan; status='preparing'; verification='pending'; artifacts=@(); exports=[ordered]@{}; checks=[ordered]@{}; destinations=[ordered]@{}; approval=$null}
            foreach ($destinationRecord in $plan.destinations) {
                $state.destinations[$destinationRecord.id] = [ordered]@{status=$(if ($destinationRecord.selected) {'pending'} else {'not-selected'}); attempts=0; error=$null; remote=[ordered]@{}}
            }
            Write-ReleaseJson $stateFile $state
            [IO.File]::WriteAllText((Join-Path $statePath 'notes.md'),$plan.notesDraft,[Text.UTF8Encoding]::new($false))
        }
        foreach ($play in @($plan.destinations | Where-Object {$_.selected -and $_.type -eq 'google-play'})) {
            if (-not (Test-Path -LiteralPath (Join-Path $statePath "notes.$($play.id).txt"))) {
                $draft=($play.changes | ForEach-Object {$_.subject}) -join "`n"
                if (-not $draft) {$draft='No commits since the confirmed previous release.'}
                [IO.File]::WriteAllText((Join-Path $statePath "notes.$($play.id).txt"),$draft,[Text.UTF8Encoding]::new($false))
            }
        }
        if ($state.verification -ne 'succeeded') {
            $verification = Invoke-ReleaseTool $settings.verificationPath $settings.config.verification.arguments $settings.repository
            if ($verification.exitCode -ne 0) {
                $state.verification='failed'; $state.status='preparation-failed'; Write-ReleaseJson $stateFile $state
                throw "Local verification failed (exit $($verification.exitCode)); publication is unavailable."
            }
            $state.verification='succeeded'; Write-ReleaseJson $stateFile $state
        }
        $engine = if ($plan.requiredExports.Count) {Get-ReleaseEngine $GodotExecutable} else {$null}
        $index = 0
        foreach ($preset in $plan.requiredExports) {
            $index++
            if ($state.exports.Contains($preset.name) -and $state.exports[$preset.name].status -eq 'succeeded') { continue }
            $directory = Join-Path $statePath "builds/$index"
            # Refuse leftover failed output; preserve it for inspection rather than deleting or uploading it.
            if (Test-Path -LiteralPath $directory) { $directory = Join-Path $statePath "builds/$index-$([guid]::NewGuid().ToString('N'))" }
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            $output = Join-Path $directory $preset.filename
            $state.exports[$preset.name] = [ordered]@{status='in-progress'; error=$null}
            Write-ReleaseJson $stateFile $state
            try {
                $exportEnvironment=@{}
                if ($preset.platform -eq 'Android' -and $preset.useGradle) {
                    # A persistent child daemon keeps the Windows console wrapper alive.
                    $exportEnvironment.GRADLE_OPTS=($env:GRADLE_OPTS+' -Dorg.gradle.daemon=false').Trim()
                }
                $export = Invoke-ReleaseTool $engine @('--headless','--path',$settings.projectPath,'--export-release',$preset.name,$output) $settings.repository -Environment $exportEnvironment
                if ($export.exitCode -ne 0 -or -not (Test-Path -LiteralPath $output -PathType Leaf)) { throw "Export failed (exit $($export.exitCode)); expected export file is missing or incomplete." }
                $artifact = Get-ReleaseArtifact $statePath $directory $preset.name $plan.head
                $state.artifacts = @($state.artifacts | Where-Object {$_.preset -cne $preset.name}) + @($artifact)
                $state.exports[$preset.name].status='succeeded'
            } catch { $state.exports[$preset.name].status='failed'; $state.exports[$preset.name].error='Local export failed; inspect the engine and preset.' }
            Write-ReleaseJson $stateFile $state
        }
        $fresh = Get-ReleasePlan $settings.repository $plan.selectedDestinations $plan.baselines -FrozenPrevious $plan.previousCommit
        if (-not $fresh.ready -or $fresh.planId -cne $plan.planId) { $state.status='preparation-failed'; Write-ReleaseJson $stateFile $state; throw 'Source or configuration changed during preparation.' }
        $state.status = if (@($state.exports.Values | Where-Object {$_.status -ne 'succeeded'}).Count) {'preparation-failed'} else {'prepared'}
        if ($state.status -eq 'prepared') {
            try {Invoke-ReleaseDistributionChecks $settings $state $statePath $ButlerExecutable {Write-ReleaseJson $stateFile $state}}
            catch {$state.status='preparation-failed'}
        }
        Assert-ReleaseArtifacts $statePath $state
        Write-ReleaseJson $stateFile $state
        return @{status=$state.status; statePath=$statePath; planId=$plan.planId}
    } finally { $lock.Dispose() }
}

# Creates a new public note file, or recognizes identical content after an uncertain API response.
function Publish-ReleaseNotes($Plan, [string]$Content, [string]$StatePath, [string]$GhExecutable) {
    $repository = $Plan.notesRepository
    $visibility = Invoke-ReleaseTool $GhExecutable @('api','--hostname','github.com',"repos/$repository") $StatePath
    if ($visibility.exitCode -ne 0) { throw 'Public release-notes repository is unavailable; no repository was created.' }
    $metadata = $visibility.text | ConvertFrom-Json -AsHashtable
    if (-not $metadata.Contains('private') -or $metadata.private -ne $false) { throw 'Release-notes repository must be public.' }
    $path = "repos/$repository/contents/releases/$($Plan.version).md"
    $existing = Invoke-ReleaseTool $GhExecutable @('api','--hostname','github.com',$path) $StatePath
    if ($existing.exitCode -eq 0) {
        $entry = $existing.text | ConvertFrom-Json -AsHashtable
        if ($entry.encoding -ne 'base64' -or -not $entry.content) { throw 'Existing note file could not be verified.' }
        $published = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($entry.content))
        if ($published -cne $Content) { throw 'Existing release notes differ; refusing to overwrite published content.' }
        return
    }
    if ($existing.text -notmatch '(?i)HTTP 404|Not Found') { throw 'Cannot verify whether release notes already exist; refusing a write.' }
    $requestPath = Join-Path $StatePath 'notes-request.json'
    Write-ReleaseJson $requestPath ([ordered]@{message="Release $($Plan.version)"; content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Content))})
    $result = Invoke-ReleaseTool $GhExecutable @('api','--hostname','github.com','--method','PUT',$path,'--input',$requestPath) $StatePath
    if ($result.exitCode -ne 0) { throw 'GitHub note publication failed.' }
}

# Binds approval to the public/Steam notes and every selected Google Play locale text.
function Get-ReleaseNotesHash([string]$StatePath, $Plan) {
    $notesPath=Join-Path $StatePath 'notes.md'
    if ([string]::IsNullOrWhiteSpace([IO.File]::ReadAllText($notesPath))) {throw 'Release notes are empty.'}
    $baseHash=(Get-FileHash -LiteralPath $notesPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $play=@($Plan.destinations | Where-Object {$_.selected -and $_.type -eq 'google-play'} | Sort-Object id -CaseSensitive)
    if (-not $play.Count) {return $baseHash}
    $manifest=@([ordered]@{path='notes.md';sha256=$baseHash})
    foreach ($destination in $play) {
        $path="notes.$($destination.id).txt"
        $fullPath=Join-Path $StatePath $path
        $content=[IO.File]::ReadAllText($fullPath)
        if ([string]::IsNullOrWhiteSpace($content) -or $content.Length -gt 500) {throw 'Google Play release notes must contain 1 to 500 characters; edit the prepared locale text before approval.'}
        $manifest += [ordered]@{path=$path;sha256=(Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
    return Get-ReleaseTextHash ($manifest | ConvertTo-Json -Depth 10 -Compress)
}

# Summarizes progress without conflating uploaded/submitted artifacts with verified store publication. An abandoned
# destination has no more work, so only the others decide the status.
function Get-ReleaseOverallStatus($State) {
    $statuses=@($State.plan.selectedDestinations | ForEach-Object {$State.destinations[$_].status} | Where-Object {$_ -ne 'abandoned'})
    if (-not $statuses.Count) {return 'abandoned'}
    if ($statuses -contains 'uncertain' -or $statuses -contains 'in-progress') {return 'needs-reconciliation'}
    $complete=@($statuses | Where-Object {$_ -in @('succeeded','submitted','awaiting-store-action')})
    $failed=@($State.plan.selectedDestinations | Where-Object {$State.destinations[$_].status -eq 'failed' -or ($State.destinations[$_].Contains('preflightStatus') -and $State.destinations[$_].preflightStatus -eq 'failed')})
    if ($failed.Count) {return $(if ($complete.Count) {'partial-failure'} else {'publication-failed'})}
    if ($statuses -contains 'pending') {return 'prepared'}
    if (@($statuses | Where-Object {$_ -notin @('succeeded','submitted','awaiting-store-action','awaiting-release','held')}).Count -eq 0) {
        if ($statuses -contains 'awaiting-store-action') {return 'needs-store-action'}
        if ($statuses -contains 'submitted') {return 'submitted'}
        if ($statuses -contains 'awaiting-release') {return 'awaiting-release'}
        if ($statuses -contains 'held') {return 'on-hold'}
        return 'published'
    }
    if ($complete.Count) {return 'partial-failure'}
    return 'publication-failed'
}

# Completes only the inspected Gradle flag omitted by older planners, preserving every approved field.
function Update-ReleaseDerivedPlanMetadata($State, $Fresh) {
    $freshJson=Get-ReleaseComparablePlanJson ($Fresh | ConvertTo-Json -Depth 30 -Compress)
    $savedJson=Get-ReleaseComparablePlanJson ($State.plan | ConvertTo-Json -Depth 30 -Compress)
    if ($freshJson -ceq $savedJson) {return $false}
    $comparison=$freshJson | ConvertFrom-Json -AsHashtable
    $completed=$false
    foreach ($collection in @('exports','requiredExports')) {
        foreach ($preset in $comparison[$collection]) {
            $saved=@($State.plan[$collection] | Where-Object {$_.name -ceq $preset.name})
            if ($saved.Count -eq 1 -and $preset.platform -eq 'Android' -and $preset.Contains('useGradle') -and -not $saved[0].Contains('useGradle')) {
                $preset.Remove('useGradle');$completed=$true
            }
        }
    }
    if (-not $completed -or (Get-ReleaseComparablePlanJson ($comparison | ConvertTo-Json -Depth 30 -Compress)) -cne $savedJson) {throw 'Saved release plan differs from the current inspected plan.'}
    $State.plan=$Fresh
    return $true
}

# Publishes only approved snapshot destinations and retains successes through partial failures and retries.
function Invoke-ReleasePublish([string]$StatePath, [string]$ApprovedPlanId, [string]$ApprovedNotesSha256, [string]$ButlerExecutable='butler', [string]$GhExecutable='gh', [switch]$RetryUncertain, [string]$SteamCmdExecutable='steamcmd', [scriptblock]$PlayTransport, [switch]$ReplacePlayEdit) {
    $StatePath = Resolve-ReleaseStatePath $StatePath
    $lock = Lock-ReleaseState $StatePath
    $ledgerLock = $null
    try {
        $stateFile = Join-Path $StatePath 'state.json'
        $state = [IO.File]::ReadAllText($stateFile) | ConvertFrom-Json -AsHashtable
        if ($state.schemaVersion -ne 1 -or $state.status -in @('preparing','preparation-failed') -or $state.verification -ne 'succeeded') { throw 'Release has not been prepared successfully.' }
        $fresh = Get-ReleasePlan $state.plan.repository $state.plan.selectedDestinations $state.plan.baselines -FrozenPrevious $state.plan.previousCommit
        if (-not $fresh.ready -or $fresh.planId -cne $state.plan.planId) { throw 'Source or release configuration changed after preparation.' }
        foreach ($destination in $state.plan.destinations) {
            $record=$state.destinations[$destination.id]
            if ($record.status -eq 'held') {Assert-ReleaseHoldReason $record.hold.reason}
            if ($destination.selected -and $destination.type -eq 'google-play' -and $record.status -notin @('held','succeeded','submitted','awaiting-store-action') -and $record.Contains('hold') -and $record.hold.Contains('releasedAt') -and -not $record.hold.Contains('playTrackReviewedAt')) {throw 'Google Play released from hold requires a fresh track review through unhold -PlayTrackReviewed.'}
        }
        # Also bind the complete displayed plan, so a journal edit cannot change upload targets.
        Update-ReleaseDerivedPlanMetadata $state $fresh | Out-Null
        Assert-ReleaseArtifacts $StatePath $state
        $notesPath = Join-Path $StatePath 'notes.md'
        $notes = [IO.File]::ReadAllText($notesPath)
        if ([string]::IsNullOrWhiteSpace($notes)) { throw 'Release notes are empty.' }
        $canonicalHash=(Get-FileHash $notesPath).Hash.ToLowerInvariant()
        if ($state.Contains('canonicalNotesSha256') -and $state.canonicalNotesSha256 -cne $canonicalHash) {throw 'Canonical notes approval cannot change after publication has started.'}
        $notesHash = Get-ReleaseNotesHash $StatePath $state.plan
        Assert-ReleaseSubmittedNotes $state $StatePath
        $artifactHash = Get-ReleaseTextHash ($state.artifacts | ConvertTo-Json -Depth 20 -Compress)
        if ($ApprovedPlanId -or $ApprovedNotesSha256) {
            if ($ApprovedPlanId -cne $state.plan.planId -or $ApprovedNotesSha256 -cne $notesHash) { throw 'Exact plan and notes approval hashes are required.' }
            if (@($state.destinations.Values | Where-Object {$_.status -in @('succeeded','submitted','awaiting-store-action','uncertain','in-progress') -or ($_.Contains('remote') -and $_.remote.Count)}).Count -and $state.approval -and $state.approval.notesSha256 -cne $notesHash) { throw 'Approval cannot change notes after a destination has started publication.' }
            $state.approval = [ordered]@{planId=$ApprovedPlanId; notesSha256=$ApprovedNotesSha256; artifactsSha256=$artifactHash}
            Write-ReleaseJson $stateFile $state
        }
        if (-not $state.approval -or $state.approval.planId -cne $state.plan.planId -or $state.approval.notesSha256 -cne $notesHash -or $state.approval.artifactsSha256 -cne $artifactHash) { throw 'Publication requires approval of the exact release plan, notes and artifacts.' }
        $notesDestination=@($state.plan.destinations | Where-Object {$_.selected -and $_.type -eq 'notes'})
        if ($notesDestination.Count) {
            $notesRecord=$state.destinations[$notesDestination[0].id]
            try {
                Push-Location -LiteralPath $state.plan.repository
                try {$resolvedGh=Find-ReleaseDoctorTool $GhExecutable} finally {Pop-Location}
                if (-not $resolvedGh) {throw (New-ReleaseDiagnosticError 'GitHub CLI executable is missing or not runnable; supply -GhExecutable.')}
                $GhExecutable=$resolvedGh
                Assert-ReleaseNotesDestination $state.plan $notes $StatePath $GhExecutable
                if ($notesRecord.Contains('preflightStatus') -and $notesRecord.preflightStatus -eq 'failed') {$notesRecord.error=$null}
                $notesRecord.preflightStatus='succeeded'
            }
            catch {
                if ($notesRecord.status -ne 'held') {$notesRecord.status='failed'}
                $notesRecord.preflightStatus='failed'
                $notesRecord.error='Public notes preflight failed; check public visibility, write permissions, approved availability link and conflicting notes before any store publication.'
                if ($_.Exception.Data.Contains('releaseDiagnostic')) {$notesRecord.error += ' '+$_.Exception.Data['releaseDiagnostic']}
                $state.status=Get-ReleaseOverallStatus $state;Write-ReleaseJson $stateFile $state
                return @{status=$state.status;statePath=$StatePath;version=$state.plan.version;destinations=$state.destinations}
            }
        }
        # Hold the game's shared ledger from the first channel check to the last receipt: no other checkout under this state
        # root can change a channel between this one's check and its write, or check a channel before this one records it.
        $ledgerLock=Lock-ReleaseLiveLedger $StatePath $state
        # A game's first record of store writes is seeded from every journal, so builds sent before it existed still count.
        Initialize-ReleaseSentRecord $StatePath $state
        foreach ($destination in @($state.plan.destinations | Sort-Object { $_.type -eq 'notes' })) {
            if (-not $destination.selected) { continue }
            $record = $state.destinations[$destination.id]
            if ($record.status -in @('held','abandoned')) {continue}
            # A replay records a store write this release already made, without making it again.
            if ($destination.type -ne 'notes' -and (Test-ReleaseStoreWriteStarted $record)) {Add-ReleaseSentReceipt $StatePath $state $destination (Get-ReleaseRecordSource $state.plan $record) | Out-Null}
            if ($destination.type -eq 'google-play' -and $record.status -eq 'submitted') {Set-ReleaseSentSubmitted $StatePath $state $destination}
            if ($destination.type -eq 'notes') {
                if (-not (Test-ReleaseShipped $state $StatePath)) {$record.status='awaiting-release';$record.error=$null;Write-ReleaseJson $stateFile $state;continue}
                if ($record.status -eq 'succeeded') {
                    # A refresh that succeeds, writing or finding the record already right, clears any earlier refresh error.
                    try {Publish-ReleaseAvailability $state $StatePath $GhExecutable;$record.error=$null}
                    catch {
                        $record.error=if ($_.Exception.Data.Contains('releaseDiagnostic')) {'Public availability record was not updated. '+$_.Exception.Data['releaseDiagnostic']} else {'Public availability record update failed; rerun publication after inspecting GitHub access.'}
                        $state.status='partial-failure';Write-ReleaseJson $stateFile $state;return @{status=$state.status;statePath=$StatePath;version=$state.plan.version;destinations=$state.destinations}
                    }
                }
            }
            if ($record.status -in @('succeeded','submitted','awaiting-store-action')) { continue }
            if (-not $record.Contains('remote')) {$record.remote=[ordered]@{}}
            if ($record.status -eq 'in-progress') { $record.status='uncertain'; $record.error='Interrupted external operation; reconcile its remote result before retrying.'; Write-ReleaseJson $stateFile $state }
            if ($record.status -eq 'uncertain' -and -not $RetryUncertain) { continue }
            if ($destination.type -ne 'notes') {
                if (-not $record.remote.Contains('sourceCommit')) {
                    $preset=if ($destination.type -eq 'steam') {$destination.depots[0].preset} else {$destination.preset}
                    $artifact=@($state.artifacts | Where-Object {$_.preset -ceq $preset})[0]
                    $record.remote.sourceCommit=if ($artifact.Contains('sourceCommit')) {$artifact.sourceCommit} else {$state.plan.head}
                }
                # A newer release live on this channel, or sent there and not yet live, refuses the older build before any
                # store write, so nothing is sent or recorded; an interrupted earlier attempt stays uncertain.
                $source=if ($record.remote.sourceCommit) {$record.remote.sourceCommit} else {$state.plan.head}
                $conflict=Get-ReleaseChannelConflict $StatePath $state $destination $source
                if ($conflict) {
                    if ($record.status -ne 'uncertain') {$record.status='failed'}
                    $record.error=$conflict;Write-ReleaseJson $stateFile $state;continue
                }
            }
            $record.status='in-progress'; $record.attempts++; $record.error=$null
            $state.canonicalNotesSha256=$canonicalHash
            if ($destination.type -eq 'google-play') {
                $path="notes.$($destination.id).txt"
                $record.remote.notesHashes=@{$path=(Get-FileHash (Join-Path $StatePath $path)).Hash.ToLowerInvariant()}
            }
            Write-ReleaseJson $stateFile $state
            # Recorded before the store write, so the channel's check elsewhere sees this build even if this run stops.
            $sentNow=($destination.type -ne 'notes') -and (Add-ReleaseSentReceipt $StatePath $state $destination $source)
            try {
                $outcome='succeeded'
                if ($destination.type -eq 'itch') {
                    $artifacts = @($state.artifacts | Where-Object {$_.preset -ceq $destination.preset})
                    if ($artifacts.Count -ne 1) { throw (New-ReleaseDiagnosticError 'Prepared artifact not uniquely found.') }
                    $directory = Resolve-ReleasePath $StatePath $artifacts[0].directory -MustExist
                    $preset=@($state.plan.exports | Where-Object {$_.name -ceq $destination.preset})[0]
                    $inputPath=Get-ReleaseButlerInput $directory $preset $destination
                    if ($preset.platform -eq 'Android' -and (-not $state.checks[$destination.id].Contains('input') -or
                        $state.checks[$destination.id].input -cne [IO.Path]::GetRelativePath($StatePath,$inputPath).Replace('\','/'))) {throw (New-ReleaseDiagnosticError 'Resume prepare to verify the signed APK input before publication.')}
                    $arguments = @('push',$inputPath,$destination.target,'--userversion',$state.plan.version)
                    foreach ($pattern in $destination.ignore) { $arguments += @('--ignore',$pattern) }
                    Push-Location -LiteralPath $StatePath
                    try {$pushExecutable=Find-ReleaseDoctorTool $ButlerExecutable} finally {Pop-Location}
                    if (-not $pushExecutable) {throw (New-ReleaseDiagnosticError 'Butler executable is unavailable before upload.')}
                    $record.remote.phase='pushing';Write-ReleaseJson $stateFile $state
                    $upload = Invoke-ReleaseTool $pushExecutable $arguments $StatePath
                    if ($upload.exitCode -ne 0) { throw (New-ReleaseDiagnosticError "Butler upload failed (exit $([int]$upload.exitCode)).") }
                    $record.remote.phase='upload-complete';$record.remote.live=$true;$record.remote.target=$destination.target;$record.remote.sourceCommit=$artifacts[0]['sourceCommit']
                    if ($destination.Contains('displayName')) {$outcome='awaiting-store-action';$record.remote.displayNameRequired=$destination.displayName}
                } elseif ($destination.type -eq 'steam') {
                    $outcome=Publish-SteamRelease $state.plan $destination $state.artifacts $StatePath $SteamCmdExecutable $record {Write-ReleaseJson $stateFile $state}
                    if (-not $record.remote.Contains('sourceCommit')) {$record.remote.sourceCommit=@($state.artifacts | Where-Object {$_.preset -ceq $destination.depots[0].preset})[0]['sourceCommit']}
                } elseif ($destination.type -eq 'google-play') {
                    Export-ReleasePlayChangelogs $StatePath | Out-Null
                    $outcome=Publish-PlayRelease $state.plan $destination $state.artifacts $StatePath $record {Write-ReleaseJson $stateFile $state} $PlayTransport -ReplacePlayEdit:$ReplacePlayEdit
                    if (-not $record.remote.Contains('sourceCommit')) {$record.remote.sourceCommit=@($state.artifacts | Where-Object {$_.preset -ceq $destination.preset})[0]['sourceCommit']}
                } else {Publish-ReleaseAvailability $state $StatePath $GhExecutable; Publish-ReleaseNotes $state.plan $notes $StatePath $GhExecutable}
                $record.status=$outcome
            } catch {
                $record.status=if (($record.remote.Contains('phase') -and $record.remote.phase -eq 'committing') -or ($record.remote.Contains('ambiguous') -and $record.remote.ambiguous)) {'uncertain'} else {'failed'}
                # Do not persist arbitrary exception text/output: authentication tools can include secrets.
                $record.error = switch ($destination.type) {
                    'itch' {'Butler attempt failed; reconcile the remote channel before retrying if the result is ambiguous.'}
                    'steam' {'Steam attempt needs inspection; check authenticated SteamCMD access and the app build result before retrying.'}
                    'google-play' {'Play attempt needs inspection; check the saved edit, bundle version/hash, track and commit/review state before retrying.'}
                    default {'Public note attempt failed; check repository visibility, conflicting content and GitHub access.'}
                }
                if ($destination.type -in @('itch','steam','notes') -and $_.Exception.Data.Contains('releaseDiagnostic')) {
                    $record.error += ' '+$_.Exception.Data['releaseDiagnostic']
                }
            }
            Write-ReleaseJson $stateFile $state
            # An attempt that failed before its first store operation sent nothing, so it takes back its store-write entry.
            if ($sentNow -and $record.status -eq 'failed' -and -not (Test-ReleaseStoreWriteStarted $record)) {Remove-ReleaseSentReceipt $StatePath $state $destination}
            # A Play edit committed for review is recorded as submitted at once, for a store whose baselines advance on it.
            if ($destination.type -eq 'google-play' -and $record.status -eq 'submitted') {Set-ReleaseSentSubmitted $StatePath $state $destination}
            # A channel this upload made live is recorded at once, so a later check elsewhere sees it even if this run stops.
            if ($record.remote.Contains('live') -and $record.remote.live -eq $true) {Save-ReleaseLiveReceipts $StatePath $state @($destination.id)}
        }
        $state.status = Get-ReleaseOverallStatus $state
        Write-ReleaseJson $stateFile $state
        Save-ReleaseLiveReceipts $StatePath $state
        return @{status=$state.status; statePath=$StatePath; version=$state.plan.version; destinations=$state.destinations}
    } finally { if ($ledgerLock) {$ledgerLock.Dispose()}; $lock.Dispose() }
}
# Reads an observed store receipt, refusing credential-like values and duplicate keys, with its observation time kept as
# the original text.
function Read-ReleaseObservedReceipt([string]$ReceiptPath) {
    $raw=[IO.File]::ReadAllText($ReceiptPath)
    $json=[System.Text.Json.JsonDocument]::Parse($raw)
    try {
        Assert-ReleaseJson $json.RootElement
        $timestamp=$json.RootElement.GetProperty('observedAt')
        $timestampText=if ($timestamp.ValueKind -eq [System.Text.Json.JsonValueKind]::String) {$timestamp.GetString()} else {$null}
    } finally {$json.Dispose()}
    $receipt=$raw | ConvertFrom-Json -AsHashtable
    # Recent PowerShell versions convert ISO JSON strings to DateTime; retain the original offset text.
    if ($receipt -is [Collections.IDictionary] -and $receipt.Contains('observedAt')) {$receipt.observedAt=$timestampText}
    return $receipt
}

# Records only an explicitly observed, approval-bound store result; never invokes a store API.
function Confirm-ReleaseStoreCompletion([string]$StatePath, [string]$ReceiptPath) {
    $StatePath=Resolve-ReleaseStatePath $StatePath
    $lock=Lock-ReleaseState $StatePath
    try {
        $stateFile=Join-Path $StatePath 'state.json'
        $state=[IO.File]::ReadAllText($stateFile) | ConvertFrom-Json -AsHashtable
        $receipt=Read-ReleaseObservedReceipt $ReceiptPath
        $common=@('destination','planId','notesSha256','observedAt','live')
        Assert-ReleaseFields $receipt ($common+@('appId','buildId','branch','announcementUrl','packageName','versionCode','track','releaseStatus','userFraction','evidenceUrl','target','displayName')) $common 'store receipt'
        $destinations=@($state.plan.destinations | Where-Object {$_.id -ceq $receipt.destination -and $_.selected -and $_.type -in @('steam','google-play','itch')})
        if ($destinations.Count -ne 1) {throw 'Receipt must identify one selected store destination.'}
        $destination=$destinations[0];$record=$state.destinations[$destination.id]
        if ($record.status -notin @('submitted','awaiting-store-action','uncertain','succeeded')) {throw 'Receipt requires an uploaded, submitted or uncertain store operation.'}
        Assert-ReleaseArtifacts $StatePath $state
        $notesHash=Get-ReleaseNotesHash $StatePath $state.plan
        $artifactHash=Get-ReleaseTextHash ($state.artifacts | ConvertTo-Json -Depth 20 -Compress)
        if (-not $state.approval -or $receipt.planId -cne $state.plan.planId -or $receipt.planId -cne $state.approval.planId -or $receipt.notesSha256 -cne $notesHash -or $notesHash -cne $state.approval.notesSha256 -or $artifactHash -cne $state.approval.artifactsSha256) {throw 'Receipt requires the unchanged approved plan, notes and artifacts.'}
        $observed=[DateTimeOffset]::MinValue
        if ($receipt.observedAt -isnot [string] -or $receipt.observedAt -notmatch '(Z|[+-]\d{2}:\d{2})$' -or -not [DateTimeOffset]::TryParse($receipt.observedAt,[ref]$observed) -or $observed -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {throw 'observedAt must be the actual observation timestamp with timezone, not a future time.'}
        if ($receipt.live -isnot [bool] -or $receipt.live -ne $true) {throw 'Store live state must have been explicitly observed.'}
        if (-not $record.remote.Contains('sourceCommit')) {
            $preset=if ($destination.type -eq 'steam') {$destination.depots[0].preset} else {$destination.preset}
            $artifact=@($state.artifacts | Where-Object {$_.preset -ceq $preset})[0]
            if (-not $artifact.Contains('sourceCommit')) {throw 'Artifact source provenance must be reconciled before confirming a legacy store record.'}
            $record.remote.sourceCommit=$artifact.sourceCommit
        }
        if ($destination.type -eq 'steam') {
            Assert-ReleaseFields $receipt ($common+@('appId','buildId','branch','announcementUrl')) ($common+@('appId','buildId','branch','announcementUrl')) 'Steam receipt'
            if (($receipt.appId -isnot [long] -and $receipt.appId -isnot [int]) -or $receipt.appId -ne $destination.appId) {throw 'Receipt appId differs from the approved Steam app.'}
            if ($receipt.buildId -isnot [string] -or $receipt.buildId -notmatch '^[1-9][0-9]*$' -or -not $record.remote.Contains('buildId') -or $receipt.buildId -cne $record.remote.buildId) {throw 'Receipt buildId requires matching recorded proof of the uploaded Steam build.'}
            if ($receipt.branch -cne $destination.branch) {throw 'Receipt branch differs from the approved Steam branch.'}
            $appId=[regex]::Escape([string]$destination.appId)
            if ($receipt.announcementUrl -isnot [string] -or $receipt.announcementUrl -notmatch "^https://(?:store\.steampowered\.com/news/app/$appId/view/[1-9][0-9]*|steamcommunity\.com/games/$appId/announcements/detail/[1-9][0-9]*)/?$") {throw 'Receipt announcementUrl must be the observed announcement for the approved Steam app.'}
            $record.remote.buildId=$receipt.buildId
        } elseif ($destination.type -eq 'google-play') {
            Assert-ReleaseFields $receipt ($common+@('packageName','versionCode','track','releaseStatus','userFraction','evidenceUrl')) ($common+@('packageName','versionCode','track','releaseStatus','userFraction','evidenceUrl')) 'Play receipt'
            if ($receipt.packageName -cne $destination.packageName) {throw 'Receipt packageName differs from the approved Play app.'}
            if (($receipt.versionCode -isnot [long] -and $receipt.versionCode -isnot [int]) -or $receipt.versionCode -ne $destination.versionCode) {throw 'Receipt versionCode differs from the approved bundle.'}
            $bundles=@($state.artifacts | Where-Object {$_.preset -ceq $destination.preset} | ForEach-Object {$_.files} | Where-Object {$_.path.EndsWith('.aab',[StringComparison]::OrdinalIgnoreCase)})
            if ($bundles.Count -ne 1 -or -not $record.remote.Contains('bundleSha256') -or -not $record.remote.Contains('versionCode') -or $record.remote.bundleSha256.ToLowerInvariant() -cne $bundles[0].sha256 -or $record.remote.versionCode -ne $destination.versionCode -or $record.remote.phase -notin @('committing','edit-committed','existing-track-matched','store-verified')) {throw 'Play completion requires recorded matching bundle hash/code and commit or deployed-track evidence; reconcile early interruptions through the store adapter.'}
            if ($receipt.track -cne $destination.track -or $receipt.releaseStatus -cne $destination.releaseStatus -or $receipt.userFraction -ne $destination.userFraction -or $destination.releaseStatus -eq 'draft') {throw 'Receipt track/rollout must match the approved non-draft publication.'}
            if ($receipt.evidenceUrl -isnot [string] -or $receipt.evidenceUrl -notmatch '^https://play\.google\.com/console(?:[/?][^\s]*)?$') {throw 'Receipt evidenceUrl must identify the observed Play Console page.'}
        } else {
            Assert-ReleaseFields $receipt ($common+@('target','displayName','evidenceUrl')) ($common+@('target','displayName','evidenceUrl')) 'itch receipt'
            if (-not $record.remote.Contains('live') -or -not $record.remote.live -or $receipt.target -cne $destination.target -or -not $destination.Contains('displayName') -or $receipt.displayName -cne $destination.displayName) {throw 'Itch receipt requires the recorded live upload and its approved target/display name.'}
            $game=$destination.target.Split(':')[0].Split('/')
            if ($receipt.evidenceUrl -cne "https://$($game[0]).itch.io/$($game[1])") {throw 'Itch receipt evidenceUrl must be the inspected game page.'}
        }
        if ($record.status -ne 'succeeded') {
            $record.remote.completion=$receipt; $record.remote.phase='store-verified';$record.remote.live=$true;$record.status='succeeded';$record.error=$null
            $state.status=Get-ReleaseOverallStatus $state
            Write-ReleaseJson $stateFile $state
        }
        # Recording again on a repeated confirmation repairs a ledger write interrupted after the first one was saved.
        Update-ReleaseLiveLedger $StatePath $state
        return @{status=$state.status;statePath=$StatePath;version=$state.plan.version;destinations=$state.destinations}
    } finally {$lock.Dispose()}
}
. (Join-Path $PSScriptRoot 'Setup.ps1')
. (Join-Path $PSScriptRoot 'SourceVersion.ps1')
. (Join-Path $PSScriptRoot 'DistributionChecks.ps1')
. (Join-Path $PSScriptRoot 'ReleaseRecord.ps1')
. (Join-Path $PSScriptRoot 'SentRecord.ps1')
. (Join-Path $PSScriptRoot 'PublicNotes.ps1')
. (Join-Path $PSScriptRoot 'Doctor.ps1')
. (Join-Path $PSScriptRoot 'PublicationHold.ps1')
. (Join-Path $PSScriptRoot 'PlanComparison.ps1')
Export-ModuleMember -Function Set-ReleaseDestinationHold,Get-ReleaseDoctor,Get-ReleaseConfiguration,Get-ReleasePlan,Get-ReleaseSetup,Set-ReleaseSetup,Invoke-ReleaseInteractiveSetup,Get-ReleaseVersion,Get-ReleaseLiveLedger,Expand-ReleaseDestinations,Export-ReleasePlayChangelogs,Invoke-ReleasePrepare,Invoke-ReleasePublish,Get-ReleaseNotesHash,Confirm-ReleaseStoreCompletion,Confirm-ReleaseAbandonment

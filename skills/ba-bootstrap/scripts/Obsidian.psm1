#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Project.psm1')
Import-Module (Join-Path $PSScriptRoot 'State.psm1')
Import-Module (Join-Path $PSScriptRoot 'GitHub.psm1')
$script:RegistryUrl='https://raw.githubusercontent.com/obsidianmd/obsidian-releases/master/community-plugins.json'
function Invoke-ObsidianRequest([string]$Method,[string]$Endpoint,[hashtable]$Body) {
    if ($Endpoint.StartsWith('/')) {return Invoke-GitHubRequest $Method $Endpoint $Body}
    if ($Method -ne 'GET' -or -not $Endpoint.StartsWith('https://')) {throw 'Plugin requests require HTTPS GET.'}
    try {
        $content=(Invoke-WebRequest -Uri $Endpoint).Content
        if ($content -is [byte[]]) {$content=[Text.Encoding]::UTF8.GetString($content)}
        return @{StatusCode=200;Data=(ConvertFrom-BootstrapJson $content)}
    }
    catch {return @{StatusCode=0;Data=@{message='Public plugin metadata download failed.'}}}
}
function Get-ObsidianPluginRelease([string]$Id,[object[]]$Registry,[scriptblock]$Request) {
    $entries=@($Registry | Where-Object id -ceq $Id)
    if ($entries.Count -ne 1 -or $entries[0].repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {throw "Plugin '$Id' has no unique canonical registry repository."}
    $repo=$entries[0].repo
    $response=& $Request GET "/repos/$repo/releases/latest" $null
    if ($response.StatusCode -ne 200) {throw "Latest published release for '$Id' is unavailable."}
    $skipped=[Collections.Generic.List[object]]::new()
    function Test-ReleaseCandidate($Release) {
        if ($Release.draft -or $Release.prerelease) {return $null}
        $assets=@{};$reason=$null
        foreach ($asset in $Release.assets) {
            if ($asset.name -notin @('manifest.json','main.js','styles.css')) {continue}
            if ($assets.ContainsKey($asset.name) -or -not $asset.browser_download_url.StartsWith("https://github.com/$repo/releases/download/",[StringComparison]::Ordinal)) {$reason='Unexpected asset identity.';break}
            $assets[$asset.name]=$asset.browser_download_url
        }
        if (-not $reason -and (-not $assets.ContainsKey('manifest.json') -or -not $assets.ContainsKey('main.js'))) {$reason='Missing manifest.json or main.js.'}
        if (-not $reason) {
            $manifestResponse=& $Request GET $assets['manifest.json'] $null
            if ($manifestResponse.StatusCode -ne 200) {throw "Plugin '$Id' manifest download is unavailable; do not infer a packaging mismatch from a network failure."}
            $manifest=$manifestResponse.Data
            if ($manifest.id -cne $Id -or $manifest.version -cne ($Release.tag_name -creplace '^v','') -or -not $manifest.minAppVersion) {$reason='Manifest ID/version differs from release metadata.'}
            else {
                try {$null=[version]$manifest.version;$null=[version]$manifest.minAppVersion} catch {$reason='Manifest version fields are invalid.'}
            }
        }
        if ($reason) {$skipped.Add(@{tag=$Release.tag_name;reason=$reason});return $null}
        return @{id=$Id;repository=$repo;tag=$Release.tag_name;version=$manifest.version;minAppVersion=$manifest.minAppVersion;assets=$assets;skipped=$skipped.ToArray()}
    }
    $selected=Test-ReleaseCandidate $response.Data
    if ($null -ne $selected) {return $selected}
    $history=[Collections.Generic.List[object]]::new()
    for ($page=1; ;$page++) {
        $reply=& $Request GET "/repos/$repo/releases?per_page=100&page=$page" $null
        if ($reply.StatusCode -ne 200) {throw "Published release history for '$Id' is unavailable."}
        $batch=@($reply.Data)
        foreach ($release in $batch) {
            if (-not $release.draft -and -not $release.prerelease -and $release.tag_name -ne $response.Data.tag_name) {$history.Add($release)}
        }
        if ($batch.Count -lt 100) {break}
    }
    foreach ($release in @($history | Sort-Object {if ($_.ContainsKey('published_at')) {$_.published_at} else {''}} -Descending)) {
        $selected=Test-ReleaseCandidate $release
        if ($null -ne $selected) {return $selected}
    }
    throw "Plugin '$Id' has no published release with consistent required assets and version metadata."
}
function Get-ObsidianJournalPath([hashtable]$Identity,[string]$StateRoot=(Get-BootstrapStateRoot)) {
    $key=Get-BootstrapContentHash ($Identity.fullName.ToLowerInvariant()+'|'+[IO.Path]::GetFullPath($Identity.vaultPath).TrimEnd('\','/').ToLowerInvariant())
    [IO.Path]::GetFullPath((Join-Path $StateRoot ('vaults/'+$key+'.json')))
}
function Get-ObsidianAppVersion {
    # The executable's ProductVersion identifies the installer, not auto-updated app code.
    if (-not $env:APPDATA) {return $null}
    $cache=Join-Path $env:APPDATA 'obsidian'
    try {
        $registry=Join-Path $cache 'obsidian.json'
        if ($env:LOCALAPPDATA -and (Test-Path -LiteralPath $registry)) {
            $cli=Join-Path $env:LOCALAPPDATA 'Programs/Obsidian/Obsidian.com'
            $settings=ConvertFrom-BootstrapJson ([IO.File]::ReadAllText($registry))
            # Query only a running, CLI-enabled app; a version probe must not launch it.
            if ($settings.ContainsKey('cli') -and $settings.cli -and (Test-Path -LiteralPath $cli) -and @(Get-Process -Name Obsidian -ErrorAction SilentlyContinue).Count) {
                $output=& $cli version 2>&1
                if ($LASTEXITCODE -eq 0) {
                    foreach ($line in $output) {
                        if ([string]$line -match '^\s*(?:Obsidian\s+v?)?(\d+\.\d+\.\d+(?:\.\d+)?)(?:\s|$)') {return $Matches[1]}
                    }
                }
            }
        }
    } catch {# Fall back to the downloaded application cache if CLI readback is unavailable.
    }
    try {
        if (Test-Path -LiteralPath $cache -PathType Container) {
            $versions=@(foreach ($file in Get-ChildItem -LiteralPath $cache -File -Filter 'obsidian-*.asar') {
                $version=$null
                if ($file.Name -match '^obsidian-(\d+\.\d+\.\d+(?:\.\d+)?)\.asar$' -and [version]::TryParse($Matches[1],[ref]$version)) {$version}
            })
            if ($versions.Count) {return ($versions | Sort-Object -Descending | Select-Object -First 1).ToString()}
        }
    } catch {# An uncertain version leaves compatibility pending; do not use installer metadata.
    }
    return $null
}
function Test-ObsidianAppPlugins($Identity,$Plugins) {
    $pending="Open '$($Identity.vaultPath)' as an Obsidian vault, enable Community plugins and the four required plugins, then check Vault Nickname and Diagram Popup."
    $registry=Join-Path $env:APPDATA 'obsidian/obsidian.json'
    $cli=Join-Path $env:LOCALAPPDATA 'Programs/Obsidian/Obsidian.com'
    if (-not (Test-Path -LiteralPath $registry) -or -not (Test-Path -LiteralPath $cli)) {return @{verified=$false;pending=$pending}}
    try {
        $settings=ConvertFrom-BootstrapJson ([IO.File]::ReadAllText($registry))
        if (-not $settings.ContainsKey('cli') -or -not $settings.cli) {return @{verified=$false;pending=$pending}}
        $matches=@($settings.vaults.Keys | Where-Object {[IO.Path]::GetFullPath($settings.vaults[$_].path) -eq [IO.Path]::GetFullPath($Identity.vaultPath)})
        if ($matches.Count -ne 1) {return @{verified=$false;pending=$pending}}
        $vaultArgument='vault='+$matches[0]
        foreach ($plugin in $Plugins) {
            & $cli $vaultArgument 'plugin:enable' ('id='+$plugin.id) 'filter=community' 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {return @{verified=$false;pending=$pending}}
        }
        $raw=(& $cli $vaultArgument 'plugins:enabled' 'filter=community' 'versions' 'format=json' 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0) {return @{verified=$false;pending=$pending}}
        $enabled=ConvertFrom-BootstrapJson $raw
        foreach ($plugin in $Plugins) {
            if (@($enabled | Where-Object {$_.id -eq $plugin.id -and $_.version -eq $plugin.version}).Count -ne 1) {return @{verified=$false;pending=$pending}}
        }
        return @{verified=$true;pending=$null}
    } catch {return @{verified=$false;pending=$pending}}
}
function Assert-ObsidianOwnedPath([string]$Vault,[string]$Path) {
    $root=[IO.Path]::GetFullPath($Vault).TrimEnd('\','/')
    $target=[IO.Path]::GetFullPath($Path)
    if (-not $target.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {throw 'Plugin operation leaves the intended vault.'}
    $cursor=$target
    while ($cursor -ne $root) {
        if (Test-Path -LiteralPath $cursor) {
            $item=Get-Item -LiteralPath $cursor -Force
            if ($item.LinkType -or ($cursor -ne $target -and -not $item.PSIsContainer)) {throw 'Plugin path traverses a linked or file-valued directory.'}
        }
        $cursor=Split-Path $cursor -Parent
    }
}
function Install-ProjectObsidian(
    [hashtable]$Identity,[string]$PresetRoot=(Join-Path $PSScriptRoot '../assets/obsidian'),[string]$StateRoot=(Get-BootstrapStateRoot),
    [scriptblock]$Request={param($m,$e,$b) Invoke-ObsidianRequest $m $e $b},
    [scriptblock]$Download={param($Url,$Destination) Invoke-WebRequest -Uri $Url -OutFile $Destination},
    [switch]$RefreshPlugins,[string]$AppVersion=(Get-ObsidianAppVersion),
    [scriptblock]$Promote={param($Source,$Destination) Move-Item -LiteralPath $Source -Destination $Destination},
    [scriptblock]$AppCheck={param($id,$plugins) Test-ObsidianAppPlugins $id $plugins}
) {
    $path=Get-ObsidianJournalPath $Identity $StateRoot;$lock=$null;$journal=$null
    $result=@{plugins=@();configuration=$false;pending=@();installedVerified=$false;enabledVerified=$false;journalPath=$path}
    try {
        $ignore=Invoke-BootstrapGit $Identity.projectPath @('check-ignore','--no-index','docs/.obsidian/plugins/probe.js')
        if ($ignore.ExitCode -ne 0) {throw 'docs/.obsidian must be ignored by the actual Git checkout before local setup.'}
        $tracked=Invoke-BootstrapGit $Identity.projectPath @('ls-files','--','docs/.obsidian')
        if ($tracked.ExitCode -ne 0 -or $tracked.Output.Trim()) {throw 'docs/.obsidian contains tracked tooling files; preserve them and resolve the ignore/index conflict first.'}
        $local=Join-Path $Identity.vaultPath '.obsidian'
        Assert-ObsidianOwnedPath $Identity.vaultPath (Join-Path $local 'plugins')
        $lock=Enter-BootstrapLock $path
        $journal=Read-BootstrapJournal $path
        if ($null -eq $journal) {$journal=New-BootstrapJournal $Identity @();$journal.plugins=@{};$journal.operation=$null}
        if ($journal.identity.vaultPath -ne $Identity.vaultPath -or $journal.identity.fullName -ine $Identity.fullName) {throw 'Vault journal belongs to a different local checkout.'}
        $ids=ConvertFrom-BootstrapJson ([IO.File]::ReadAllText((Join-Path $PresetRoot 'plugins.json')))
        foreach ($id in $ids) {if ($id -notmatch '^[a-z0-9][a-z0-9-]*$') {throw 'Invalid recipe plugin ID.'}}
        $preferences=ConvertFrom-BootstrapJson ([IO.File]::ReadAllText((Join-Path $PresetRoot 'plugin-preferences.json')))
        New-Item -ItemType Directory -Path $local -Force | Out-Null
        foreach ($file in @('app.json','appearance.json','core-plugins.json')) {
            $target=Join-Path $local $file;Assert-ObsidianOwnedPath $Identity.vaultPath $target
            if (-not (Test-Path -LiteralPath $target)) {[IO.File]::WriteAllText($target,[IO.File]::ReadAllText((Join-Path $PresetRoot $file)),[Text.UTF8Encoding]::new($false))}
        }
        $community=Join-Path $local 'community-plugins.json';Assert-ObsidianOwnedPath $Identity.vaultPath $community
        $existing=[object[]]@()
        if (Test-Path -LiteralPath $community) {
            $existing=ConvertFrom-BootstrapJson ([IO.File]::ReadAllText($community))
            if ($existing -isnot [array] -or @($existing | Where-Object {$_ -isnot [string]}).Count) {throw 'community-plugins.json must contain a flat array of plugin IDs.'}
        }
        $enabled=@($existing);foreach ($id in $ids) {if ($id -notin $enabled) {$enabled+=$id}}
        if ($enabled.Count -ne $existing.Count) {[IO.File]::WriteAllText($community,(ConvertTo-Json -InputObject $enabled),[Text.UTF8Encoding]::new($false))}
        $result.configuration=$true
        function Save-Vault {Write-BootstrapJournal $path $journal $lock}
        function Restore-VaultOperation {
            if ($null -eq $journal.operation) {return}
            Assert-ObsidianOwnedPath $Identity.vaultPath $journal.operation.root
            if (-not [IO.Path]::GetFullPath($journal.operation.root).StartsWith([IO.Path]::GetFullPath((Join-Path $local '.bootstrap'))+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {throw 'Plugin recovery journal points outside its staging directory.'}
            foreach ($id in $journal.operation.releases.Keys) {
                if ($id -notin $ids) {throw 'Plugin recovery journal contains an unexpected plugin ID.'}
                $active=Join-Path $local ('plugins/'+$id);$backup=Join-Path $journal.operation.root ('backup/'+$id)
                Assert-ObsidianOwnedPath $Identity.vaultPath $backup
                if (Test-Path -LiteralPath $backup) {
                    Assert-ObsidianOwnedPath $Identity.vaultPath $active
                    if (Test-Path -LiteralPath $active) {Remove-Item -LiteralPath $active -Recurse -Force}
                    Move-Item -LiteralPath $backup -Destination $active
                } elseif ($id -in $journal.operation.promoted -and $id -notin $journal.operation.existed) {
                    Assert-ObsidianOwnedPath $Identity.vaultPath $active
                    if (Test-Path -LiteralPath $active) {Remove-Item -LiteralPath $active -Recurse -Force}
                }
            }
            $journal.operation.promoted=@();Save-Vault
        }
        Restore-VaultOperation
        $changes=@();$registry=$null
        foreach ($id in $ids) {
            $active=Join-Path $local ('plugins/'+$id);Assert-ObsidianOwnedPath $Identity.vaultPath (Join-Path $active 'manifest.json')
            $valid=$false;$manifest=$null
            if (Test-Path -LiteralPath (Join-Path $active 'manifest.json')) {
                try {
                    $manifest=ConvertFrom-BootstrapJson ([IO.File]::ReadAllText((Join-Path $active 'manifest.json')))
                    $valid=$manifest.id -ceq $id -and $manifest.version -and $manifest.minAppVersion -and (Test-Path -LiteralPath (Join-Path $active 'main.js') -PathType Leaf) -and (Get-Item -LiteralPath (Join-Path $active 'main.js')).Length -gt 0
                } catch {$valid=$false}
            }
            $interrupted=$null -ne $journal.operation -and $journal.operation.releases.ContainsKey($id)
            if ($valid -and -not $RefreshPlugins -and -not $interrupted) {
                if ($AppVersion -and [version]$AppVersion -lt [version]$manifest.minAppVersion) {throw "Installed plugin '$id' requires Obsidian $($manifest.minAppVersion)."}
                $skipped=@()
                if ($journal.plugins.ContainsKey($id) -and $journal.plugins[$id].ContainsKey('skipped')) {$skipped=$journal.plugins[$id].skipped}
                $result.plugins+=@{id=$id;version=$manifest.version;filesVerified=$true;skipped=$skipped};continue
            }
            if ($interrupted) {$release=$journal.operation.releases[$id]}
            else {
                if ($null -eq $registry) {
                    $reply=& $Request GET $script:RegistryUrl $null
                    if ($reply.StatusCode -ne 200) {throw 'Official Obsidian community registry is unavailable.'}
                    $registry=$reply.Data
                }
                $release=Get-ObsidianPluginRelease $id $registry $Request
            }
            if ($AppVersion -and [version]$AppVersion -lt [version]$release.minAppVersion) {throw "Plugin '$id' requires Obsidian $($release.minAppVersion); installed app is $AppVersion."}
            $changes+=@{id=$id;release=$release;active=$active}
        }
        if ($changes.Count) {
            if ($null -eq $journal.operation) {
                $operationRoot=Join-Path $local ('.bootstrap/'+[guid]::NewGuid().ToString('N'))
                $journal.operation=@{root=$operationRoot;releases=@{};promoted=@();existed=@()}
            }
            foreach ($change in $changes) {$journal.operation.releases[$change.id]=$change.release}
            Save-Vault
            foreach ($change in $changes) {
                $stage=Join-Path $journal.operation.root ('stage/'+$change.id);Assert-ObsidianOwnedPath $Identity.vaultPath $stage
                if (Test-Path -LiteralPath $stage) {Remove-Item -LiteralPath $stage -Recurse -Force}
                New-Item -ItemType Directory -Path $stage -Force | Out-Null
                if (Test-Path -LiteralPath $change.active) {
                    if (@(Get-ChildItem -LiteralPath $change.active -Recurse -Force | Where-Object LinkType).Count) {throw 'Existing plugin contains a linked path.'}
                    foreach ($child in Get-ChildItem -LiteralPath $change.active -Force) {Copy-Item -LiteralPath $child.FullName -Destination $stage -Recurse -Force}
                }
                foreach ($asset in $change.release.assets.Keys) {& $Download $change.release.assets[$asset] (Join-Path $stage $asset) | Out-Null}
                if (-not $change.release.assets.ContainsKey('styles.css') -and (Test-Path -LiteralPath (Join-Path $stage 'styles.css'))) {Remove-Item -LiteralPath (Join-Path $stage 'styles.css')}
                $manifest=ConvertFrom-BootstrapJson ([IO.File]::ReadAllText((Join-Path $stage 'manifest.json')))
                if ($manifest.id -cne $change.id -or $manifest.version -cne $change.release.version -or $manifest.minAppVersion -cne $change.release.minAppVersion -or (Get-Item -LiteralPath (Join-Path $stage 'main.js')).Length -eq 0) {throw "Downloaded plugin '$($change.id)' differs from its verified release."}
            }
            try {
                foreach ($change in $changes) {
                    $backup=Join-Path $journal.operation.root ('backup/'+$change.id);Assert-ObsidianOwnedPath $Identity.vaultPath $backup
                    New-Item -ItemType Directory -Path (Split-Path $backup -Parent) -Force | Out-Null
                    New-Item -ItemType Directory -Path (Split-Path $change.active -Parent) -Force | Out-Null
                    if (Test-Path -LiteralPath $change.active) {
                        $journal.operation.existed+=($change.id);Save-Vault
                        Move-Item -LiteralPath $change.active -Destination $backup
                    }
                    $journal.operation.promoted+=($change.id);Save-Vault
                    & $Promote (Join-Path $journal.operation.root ('stage/'+$change.id)) $change.active | Out-Null
                    $journal.plugins[$change.id]=$change.release
                    $result.plugins+=@{id=$change.id;version=$change.release.version;filesVerified=$true;skipped=$change.release.skipped}
                }
            } catch {Restore-VaultOperation;throw}
            # Retain backup files locally; journal points at the last complete backup for recovery.
            $journal.lastBackup=$journal.operation.root;$journal.operation=$null;Save-Vault
        }
        foreach ($id in $ids) {
            $plugin=Join-Path $local ('plugins/'+$id)
            if ($preferences.ContainsKey($id)) {
                foreach ($file in $preferences[$id].Keys) {
                    $target=Join-Path $plugin $file;Assert-ObsidianOwnedPath $Identity.vaultPath $target
                    if (-not (Test-Path -LiteralPath $target)) {[IO.File]::WriteAllText($target,($preferences[$id][$file] | ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))}
                }
            }
        }
        $nickname=Join-Path $local 'plugins/vault-nickname/data-shared.json';Assert-ObsidianOwnedPath $Identity.vaultPath $nickname
        if (-not (Test-Path -LiteralPath $nickname)) {[IO.File]::WriteAllText($nickname,(@{nickname=$Identity.title} | ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
        $result.installedVerified=$true
        if (-not $AppVersion) {$result.pending+='Obsidian application version is unknown: verify plugin minimum-app compatibility with the running app, then rerun local setup.'}
        $app=& $AppCheck $Identity $result.plugins
        $result.enabledVerified=[bool]$app.verified -and [bool]$AppVersion
        if (-not $app.verified) {$result.pending+=$app.pending}
        $journal.phases.files='verified';$journal.phases.app=if ($result.enabledVerified) {'verified'} else {'pending'};Save-Vault
    } catch {$result.pending+=($_.Exception.Message);$result.installedVerified=$false}
    finally {if ($null -ne $lock) {$lock.Dispose()}}
    return $result
}
function Get-LocalProjectIdentity([string]$Repository,[scriptblock]$Request={param($m,$e,$b) Invoke-GitHubRequest $m $e $b}) {
    $root=Invoke-BootstrapGit $Repository @('rev-parse','--show-toplevel')
    if ($root.ExitCode -ne 0) {throw 'Local setup requires a Git checkout.'}
    $path=[IO.Path]::GetFullPath($root.Output.Trim())
    $origin=Invoke-BootstrapGit $path @('remote','get-url','origin')
    if ($origin.ExitCode -ne 0 -or $origin.Output.Trim() -notmatch '^(?:https://github\.com/|git@github\.com:)([^/]+)/([^/]+?)(?:\.git)?$') {throw 'Local setup requires a canonical GitHub origin.'}
    $owner=$Matches[1];$repositoryName=$Matches[2]
    $repo=& $Request GET "/repos/$owner/$repositoryName" $null
    if ($repo.StatusCode -ne 200 -or -not $repo.Data.private -or $repo.Data.full_name -ine "$owner/$repositoryName") {throw 'Local setup requires the verified private project repository.'}
    foreach ($required in @('README.md','AGENTS.md','docs/DESIGN.md','docs/DECISIONS.md','docs/JUDGEMENTS.md','docs/NEXT.md','tools/verify.ps1','tools/Documentation.psm1')) {if (-not (Test-Path -LiteralPath (Join-Path $path $required) -PathType Leaf)) {throw "Private project foundation is missing $required."}}
    $line=([IO.File]::ReadAllText((Join-Path $path 'README.md')) -split "`n")[0].TrimEnd("`r")
    if ($line -notmatch '^# (.+)$') {throw 'Project README needs its original top-level project title.'}
    $title=$Matches[1].Replace('\_','_')
    @{title=$title;description='';owner=$owner;repository=$repositoryName;fullName="$owner/$repositoryName";notesRepository=$repositoryName+'-release-notes';notesFullName="$owner/$repositoryName-release-notes";parent=(Split-Path $path -Parent);projectPath=$path;vaultPath=(Join-Path $path 'docs');defaultBranch='main'}
}
Export-ModuleMember -Function Invoke-ObsidianRequest,Get-ObsidianPluginRelease,Get-ObsidianJournalPath,Install-ProjectObsidian,Get-LocalProjectIdentity

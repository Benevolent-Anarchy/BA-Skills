Import-Module "$skillRoot/scripts/State.psm1" -Force
if (Test-Path "$skillRoot/scripts/Obsidian.psm1") {Import-Module "$skillRoot/scripts/Obsidian.psm1" -Force}
. "$PSScriptRoot/ObsidianFixture.ps1"
Test 'followup plugin digests refuse changed or truncated staged assets before promotion' {
    foreach ($damage in @('changed-main','truncated-main','manifest','stylesheet')) {
        $f=New-ObsidianFixture ('digest '+$damage)
        if ($damage -eq 'stylesheet') {
            $url='https://github.com/fixture/dataview/releases/download/9.1.0/styles.css'
            $f.releases.dataview.assets+=@{name='styles.css';browser_download_url=$url};$f.assets[$url]='body {}'
        }
        Set-ObsidianFixtureDigests $f
        $assetName=if ($damage -eq 'manifest') {'manifest.json'} elseif ($damage -eq 'stylesheet') {'styles.css'} else {'main.js'}
        $url=@($f.releases.dataview.assets | Where-Object name -eq $assetName)[0].browser_download_url
        $f.assets[$url]=if ($damage -eq 'truncated-main') {'/'} else {$f.assets[$url]+' '}
        $result=Invoke-ObsidianFixture $f
        Assert (-not $result.installedVerified -and ($result.pending -join ' ') -match 'digest.*mismatch|mismatch.*digest') "Damaged $damage asset was accepted or not diagnosed."
        Assert (-not (Test-Path "$($f.identity.vaultPath)/.obsidian/plugins/dataview/main.js")) 'Damaged staged release reached the active vault.'
    }
}
Test 'followup plugin digest verification is pinned across interrupted refresh' {
    $f=New-ObsidianFixture 'pinned digest';Set-ObsidianFixtureDigests $f
    $first=Invoke-ObsidianFixture $f
    Assert $first.installedVerified 'Initial digest-bearing fixture failed.'
    $before=Get-FileHash "$($f.identity.vaultPath)/.obsidian/plugins/dataview/main.js"
    foreach ($release in $f.releases.Values) {
        $release.tag_name='9.2.0'
        foreach ($asset in $release.assets) {
            $old=$asset.browser_download_url;$asset.browser_download_url=$old.Replace('9.1.0','9.2.0')
            $f.assets[$asset.browser_download_url]=$f.assets[$old].Replace('9.1.0','9.2.0')
        }
    }
    Set-ObsidianFixtureDigests $f;$f.failDownload='mermaid-popup.*main.js'
    $interrupted=Invoke-ObsidianFixture $f -Refresh
    Assert (-not $interrupted.installedVerified) 'Refresh fixture was not interrupted.'
    $journal=Read-BootstrapJournal $interrupted.journalPath
    Assert ($journal.operation.releases.dataview.ContainsKey('digests')) 'Interrupted release journal did not retain published digests.'
    $digest=$journal.operation.releases.dataview.digests['main.js']
    $url=@($f.releases.dataview.assets | Where-Object name -eq 'main.js')[0].browser_download_url
    $expected=$f.assets[$url];$f.assets[$url]='// replaced after interruption'
    Set-ObsidianFixtureDigests $f;$f.failDownload='';$requests=$f.calls.Count
    $bad=Invoke-ObsidianFixture $f
    Assert (-not $bad.installedVerified -and ($bad.pending -join ' ') -match 'digest.*mismatch') 'Retry accepted a different asset using refreshed rather than pinned metadata.'
    Assert ($f.calls.Count -eq $requests -and (Get-FileHash $before.Path).Hash -eq $before.Hash) 'Digest failure changed metadata selection or the prior installation.'
    $f.assets[$url]=$expected
    $recovered=Invoke-ObsidianFixture $f
    Assert ($recovered.installedVerified -and $f.calls.Count -eq $requests -and @($recovered.plugins | Where-Object digestVerification -ne 'verified').Count -eq 0) 'Correct pinned assets did not recover with verified digest receipts.'
    Assert ((Read-BootstrapJournal $recovered.journalPath).plugins.dataview.digests['main.js'] -eq $digest) 'Completed journal lost the pinned digest.'
    $repeat=Invoke-ObsidianFixture $f
    Assert ($repeat.installedVerified -and @($repeat.plugins | Where-Object digestVerification -ne 'verified').Count -eq 0 -and $f.calls.Count -eq $requests) 'Ordinary repeat lost integrity verification or fetched another release.'
}
Test 'followup digestless plugin releases install with explicit unverified receipts' {
    $f=New-ObsidianFixture 'legacy digests'
    foreach ($release in $f.releases.Values) {foreach ($asset in $release.assets) {$asset.digest=$null}}
    $result=Invoke-ObsidianFixture $f
    Assert ($result.installedVerified -and $result.plugins.Count -eq 4) 'Legacy digestless assets failed installation.'
    foreach ($plugin in $result.plugins) {Assert ($plugin.digestVerification -eq 'unverified-by-digest' -and 'main.js' -in $plugin.assetsWithoutDigest) 'Missing digests were silently reported as verified.'}
}
Test 'review Obsidian compatibility uses the updated application cache version' {
    $f=New-ObsidianFixture 'updated application';$appData=New-BootstrapFixture 'app-cache';$localData=New-BootstrapFixture 'installer'
    foreach ($name in @('obsidian-1.14.9.asar','obsidian-1.14.10.asar','obsidian-not-a-version.asar','obsidian-99.0.0.asar.tmp')) {Write-FixtureText "$appData/obsidian/$name" 'Fixture cache'}
    foreach ($url in @($f.assets.Keys | Where-Object {$_ -like '*/manifest.json'})) {$f.assets[$url]=$f.assets[$url].Replace('1.0.0','1.14.2')}
    $savedApp=$env:APPDATA;$savedLocal=$env:LOCALAPPDATA
    try {
        $env:APPDATA=$appData;$env:LOCALAPPDATA=$localData
        $f.appVersion=& (Get-Module Obsidian) {Get-ObsidianAppVersion}
        Assert ($f.appVersion -eq '1.14.10') 'Updated application version was not read and sorted numerically.'
        $result=Invoke-ObsidianFixture $f
        Assert $result.installedVerified ('Updated app was rejected: '+($result.pending -join ' '))
        $requests=$f.calls.Count
        $repeat=Invoke-ObsidianFixture $f
        Assert ($repeat.installedVerified -and $f.calls.Count -eq $requests) 'Ordinary setup rejected already installed compatible plugins.'
    } finally {$env:APPDATA=$savedApp;$env:LOCALAPPDATA=$savedLocal}
}
Test 'review an unknown Obsidian version leaves compatibility pending' {
    $f=New-ObsidianFixture 'unknown application'
    $result=Install-ProjectObsidian -Identity $f.identity -PresetRoot $presetRoot -StateRoot $f.stateRoot -Request $f.request -Download $f.download -AppVersion '' -Promote $f.promote -AppCheck {param($Identity,$Plugins) @{verified=$true;pending=$null}}
    Assert ($result.installedVerified -and -not $result.enabledVerified -and ($result.pending -join ' ') -match 'version.*unknown|cannot determine.*version') 'Unknown compatibility was claimed verified or described as an incompatible/missing installation.'
    Assert ((Read-BootstrapJournal $result.journalPath).phases.app -eq 'pending') 'Unknown compatibility completed the vault journal.'
}
Test 'obsidian decodes binary JSON download responses' {
    $module=Get-Module Obsidian
    & $module {function script:Invoke-WebRequest {param($Uri) @{Content=[Text.Encoding]::UTF8.GetBytes('{"id":"dataview","version":"9.1.0"}')}}}
    try {
        $response=Invoke-ObsidianRequest GET 'https://github.com/fixture/dataview/releases/download/9.1.0/manifest.json'
        Assert ($response.StatusCode -eq 200 -and $response.Data.version -eq '9.1.0') 'Binary JSON response was rejected.'
    } finally {& $module {Remove-Item -LiteralPath Function:Invoke-WebRequest}}
}
Test 'obsidian skips inconsistent latest metadata and reports the newest consistent release' {
    $f=New-ObsidianFixture 'fallback'
    $valid=$f.releases.dataview.Clone();$valid.published_at='2026-09-01T00:00:00Z'
    $f.releases.dataview.tag_name='9.2.0';$f.releases.dataview.published_at='2026-10-01T00:00:00Z'
    $f.history.dataview=@($f.releases.dataview,$valid)
    $release=Get-ObsidianPluginRelease dataview $f.registry $f.request
    Assert ($release.version -eq '9.1.0' -and $release.skipped.Count -eq 1 -and $release.skipped[0].tag -eq '9.2.0') 'No correct fallback/skip report.'
    $result=Invoke-ObsidianFixture $f
    Assert ($result.installedVerified -and @($result.plugins | Where-Object {$_.id -eq 'dataview' -and $_.skipped[0].tag -eq '9.2.0'}).Count -eq 1) 'Skip report lost during installation.'
}
Test 'obsidian installs latest published plugin assets with a new nickname' {
    $f=New-ObsidianFixture 'new vault'
    $result=Invoke-ObsidianFixture $f
    Assert ($result.installedVerified -and $result.plugins.Count -eq 4 -and @($result.plugins | Where-Object {-not $_.filesVerified}).Count -eq 0) ($result | ConvertTo-Json -Depth 12 -Compress)
    $nickname=Get-Content "$($f.identity.vaultPath)/.obsidian/plugins/vault-nickname/data-shared.json" -Raw | ConvertFrom-Json
    Assert ($nickname.nickname -ceq $f.identity.title) 'Old nickname copied.'
    Assert (-not $result.enabledVerified -and $result.pending.Count -gt 0) 'Installed files falsely mean loaded plugins.'
    Assert ((Invoke-FixtureGit $f.identity.projectPath @('check-ignore','docs/.obsidian/plugins/dataview/main.js')) -match 'dataview') 'Plugin assets are not ignored.'
    $inspector=Get-Content "$($f.identity.vaultPath)/.obsidian/plugins/vault-inspector/data.json" -Raw | ConvertFrom-Json -AsHashtable
    Assert ($inspector.Keys.Count -eq 1 -and $inspector.ContainsKey('settings') -and $inspector.settings.ignoredIssueFingerprints.Count -eq 0) 'Findings/history leaked.'
}
Test 'obsidian validates registry identity release assets and compatibility' {
    foreach ($invalid in @('id','tag','main','draft','minimum')) {
        $f=New-ObsidianFixture 'invalid'
        switch ($invalid) {
            id {$url=$f.releases.dataview.assets[0].browser_download_url;$f.assets[$url]=$f.assets[$url].Replace('dataview','wrong-id')}
            tag {$f.releases.dataview.tag_name='8.0.0'}
            main {$f.releases.dataview.assets=@($f.releases.dataview.assets | Where-Object name -ne 'main.js')}
            draft {$f.releases.dataview.draft=$true}
            minimum {$f.appVersion='0.9.0'}
        }
        $result=Invoke-ObsidianFixture $f
        Assert (-not $result.installedVerified) "Invalid $invalid passed."
        Assert (-not (Test-Path "$($f.identity.vaultPath)/.obsidian/plugins/dataview/main.js")) 'Invalid release promoted.'
    }
}
Test 'obsidian preserves custom preferences extra plugins and workspace on repeat' {
    $f=New-ObsidianFixture 'repeat'
    Invoke-ObsidianFixture $f | Out-Null
    $local="$($f.identity.vaultPath)/.obsidian"
    Write-FixtureText "$local/app.json" '{"promptDelete":true,"custom":42}'
    Write-FixtureText "$local/workspace.json" '{"open":"keep"}'
    Write-FixtureText "$local/plugins/dataview/data.json" '{"custom":"keep"}'
    Write-FixtureText "$local/plugins/extra/main.js" '// keep'
    Write-FixtureText "$local/community-plugins.json" '["extra","dataview"]'
    $before=$f.calls.Count
    $result=Invoke-ObsidianFixture $f
    Assert ($result.installedVerified -and $f.calls.Count -eq $before) 'Repeat fetched an update.'
    Assert ([IO.File]::ReadAllText("$local/app.json") -ceq '{"promptDelete":true,"custom":42}' -and [IO.File]::ReadAllText("$local/workspace.json") -ceq '{"open":"keep"}' -and [IO.File]::ReadAllText("$local/plugins/dataview/data.json") -ceq '{"custom":"keep"}') 'Local preferences replaced.'
    $configured=Get-Content "$local/community-plugins.json" -Raw | ConvertFrom-Json
    Assert ($configured.Count -eq 5 -and @($configured | Where-Object {$_ -isnot [string]}).Count -eq 0 -and 'extra' -in $configured) 'Community plugins must remain a flat ID list containing extra plugins.'
}
Test 'obsidian stages downloads and restores all previous binaries after promotion failure' {
    $f=New-ObsidianFixture 'refresh'
    Invoke-ObsidianFixture $f | Out-Null
    $before=Get-FileHash "$($f.identity.vaultPath)/.obsidian/plugins/dataview/main.js"
    foreach ($id in $f.releases.Keys) {
        $f.releases[$id].tag_name='9.2.0'
        foreach ($asset in $f.releases[$id].assets) {
            $old=$asset.browser_download_url;$new=$old.Replace('9.1.0','9.2.0')
            $f.assets[$new]=$f.assets[$old].Replace('9.1.0','9.2.0');$asset.browser_download_url=$new
        }
    }
    $f.failDownload='mermaid-popup.*main.js'
    $result=Invoke-ObsidianFixture $f -Refresh
    Assert (-not $result.installedVerified -and (Get-FileHash $before.Path).Hash -eq $before.Hash) 'Failed download mixed installations.'
    $f.failDownload='';$f.failPromotion=$true
    $result=Invoke-ObsidianFixture $f -Refresh
    Assert (-not $result.installedVerified -and (Get-FileHash $before.Path).Hash -eq $before.Hash) 'Failed promotion lost previous binary.'
    $requests=$f.calls.Count;$f.failPromotion=$false
    $result=Invoke-ObsidianFixture $f
    Assert ($result.installedVerified -and $f.calls.Count -eq $requests) 'Interrupted refresh did not use its pinned staged releases.'
    Assert ((Get-FileHash $before.Path).Hash -ne $before.Hash -and @($result.plugins | Where-Object version -ne '9.2.0').Count -eq 0) 'New release did not replace old assets after recovery.'
}
Test 'obsidian derives fresh clone identity with isolated vault journals and no create routes' {
    $f=New-ObsidianFixture 'first clone'
    $first=Get-LocalProjectIdentity -Repository $f.identity.projectPath -Request {param($Method,$Endpoint,$Body) @{StatusCode=200;Data=@{full_name='Benevolent-Anarchy/Obsidian-Fixture';private=$true;permissions=@{pull=$true}}}}
    $cloneParent=New-BootstrapFixture 'second clone'
    $second=$first.Clone();$second.projectPath=Join-Path $cloneParent 'Renamed Local Folder';$second.parent=$cloneParent;$second.vaultPath=Join-Path $second.projectPath 'docs'
    Assert ((Get-ObsidianJournalPath $first $f.stateRoot) -ne (Get-ObsidianJournalPath $second $f.stateRoot)) 'Two clones share state.'
    Assert ($first.title -ceq $f.identity.title -and $first.projectPath -eq $f.identity.projectPath) 'Identity guessed from directory instead of Git/README.'
    Expect-Error {Get-LocalProjectIdentity -Repository $f.identity.projectPath -Request {param($m,$e,$b) @{StatusCode=200;Data=@{full_name='Benevolent-Anarchy/Obsidian-Fixture';private=$false}}}} 'private'
}
Test 'obsidian refuses setup when the actual ignore rule is missing' {
    $f=New-ObsidianFixture 'not ignored'
    Write-FixtureText "$($f.identity.projectPath)/.gitignore" ''
    $result=Invoke-ObsidianFixture $f
    Assert (-not $result.installedVerified -and $f.downloads.Count -eq 0) 'Ignored tooling preflight was skipped.'
}
Test 'obsidian rejects tracked tooling and linked plugin folders before downloads' {
    $f=New-ObsidianFixture 'tracked tooling'
    Write-FixtureText "$($f.identity.vaultPath)/.obsidian/app.json" '{}'
    Invoke-FixtureGit $f.identity.projectPath @('add','-f','docs/.obsidian/app.json') | Out-Null
    $result=Invoke-ObsidianFixture $f
    Assert (-not $result.installedVerified -and $f.downloads.Count -eq 0) 'Tracked tooling accepted.'
    $f=New-ObsidianFixture 'linked tooling'
    $outside=New-BootstrapFixture 'outside plugin'
    New-Item -ItemType Directory -Path "$($f.identity.vaultPath)/.obsidian/plugins" -Force | Out-Null
    New-Item -ItemType Junction -Path "$($f.identity.vaultPath)/.obsidian/plugins/dataview" -Target $outside | Out-Null
    $result=Invoke-ObsidianFixture $f
    Assert (-not $result.installedVerified -and @(Get-ChildItem $outside -Force).Count -eq 0) 'Linked plugin target modified.'
}
Test 'obsidian supports optional styles and independent setup of actual clone paths' {
    $f=New-ObsidianFixture 'styles'
    $url='https://github.com/fixture/dataview/releases/download/9.1.0/styles.css'
    $f.releases.dataview.assets+=@{name='styles.css';browser_download_url=$url};$f.assets[$url]='.fixture {}'
    $result=Invoke-ObsidianFixture $f
    Assert ($result.installedVerified -and [IO.File]::ReadAllText("$($f.identity.vaultPath)/.obsidian/plugins/dataview/styles.css") -ceq '.fixture {}') 'Published stylesheet missing.'
    $second=New-ObsidianFixture 'second path'
    $secondResult=Invoke-ObsidianFixture $second
    Assert ($secondResult.installedVerified -and $secondResult.journalPath -ne $result.journalPath) 'Second clone state replaced first.'
    $firstState=Read-BootstrapJournal $result.journalPath
    Assert ($firstState.identity.vaultPath -eq $f.identity.vaultPath) 'First vault journal overwritten.'
    $suffix=New-ObsidianFixture 'valid suffix'
    Invoke-FixtureGit $suffix.identity.projectPath @('remote','set-url','origin','https://github.com/Benevolent-Anarchy/Actual-release-notes.git') | Out-Null
    $id=Get-LocalProjectIdentity $suffix.identity.projectPath {param($m,$e,$b) @{StatusCode=200;Data=@{private=$true;full_name='Benevolent-Anarchy/Actual-release-notes'}}}
    Assert ($id.repository -eq 'Actual-release-notes') 'Suffix alone rejected a real private project.'
}

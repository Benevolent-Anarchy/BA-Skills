Import-Module "$skillRoot/scripts/State.psm1" -Force
if (Test-Path "$skillRoot/scripts/Obsidian.psm1") {Import-Module "$skillRoot/scripts/Obsidian.psm1" -Force}
. "$PSScriptRoot/ObsidianFixture.ps1"
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

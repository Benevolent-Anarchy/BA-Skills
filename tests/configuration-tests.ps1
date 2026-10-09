# Exercises grouped configuration through planning, setup and local preparation in disposable fixtures.

# Specifies shared store mappings independently of the production expansion code.
function New-GroupedFixture([string]$Name) {
    $repo=New-StoreFixture $Name
    $config=[ordered]@{
        schemaVersion=1;project='.';previousRelease='v1.2.2'
        exports=[ordered]@{windows='Windows existing';linux='Linux existing';aab='Android existing AAB'}
        verification=@{gate=@{script='tools/verify.ps1'};standalone=@{exports=@('windows','linux');script='tools/standalone.ps1';arguments=@('{artifact}')}}
        distributions=[ordered]@{
            itch=@{game='example/real-game';ignore=@('steam_api*.dll','libsteam_api.so','libgodotsteam.*','steam_appid.txt');displayNameTemplate='{title} {version} ({os})';channels=[ordered]@{windows='windows';linux='linux'}}
            steam=@{appId=100;branch='default';exclude=@('*.pdb');depots=[ordered]@{'101'='windows';'102'='linux'}}
            'google-play'=@{export='aab';previousRelease=$null;track='production';releaseStatus='completed';language='en-US';retainVersionCodes=$null}
            notes=$true
        }
    }
    Write-Json (Join-Path $repo 'release.json') $config
    Invoke-FixtureGit $repo @('add','release.json') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Use grouped release configuration') | Out-Null
    return $repo
}
Test 'grouped configuration reuses exports and defaults while holding an unknown Play release' {
    $repo=New-GroupedFixture 'grouped-plan'
    $before=Invoke-FixtureGit $repo @('status','--porcelain=v1');$hash=(Get-FileHash (Join-Path $repo '.git/index')).Hash
    $plan=Get-ReleasePlan $repo @('itch-windows','itch-linux','steam')
    Assert $plan.ready 'Complete desktops were blocked by held Play.'
    $windows=@($plan.destinations | Where-Object id -EQ 'itch-windows')[0];$steamRecord=@($plan.destinations | Where-Object id -EQ steam)[0]
    Assert ($windows.target -ceq 'example/real-game:windows' -and $windows.displayName -ceq 'Fixture 1.2.3 (Windows)') 'Shared defaults were lost.'
    Assert ($steamRecord.depots[0].preset -ceq 'Windows existing' -and $steamRecord.depots[0].exclude[0] -ceq '*.pdb') 'Steam did not reuse the common export.'
    Assert (@($plan.destinations | Where-Object {$_.id -eq 'google-play' -and $_.status -eq 'not-selected'}).Count -eq 1) 'Play was selected implicitly.'
    Assert ((Get-FileHash (Join-Path $repo '.git/index')).Hash -ceq $hash -and (Invoke-FixtureGit $repo @('status','--porcelain=v1')) -ceq $before) 'Plan changed source/index.'
}
Test 'grouped explicit null and per-channel overrides preserve independent store history' {
    $repo=New-GroupedFixture 'grouped-overrides'
    Change-Config $repo {param($c)
        $c.distributions.itch.channels.linux=@{export='linux';channel='linux-beta';previousRelease=$null;displayNameTemplate='{title} beta {version}';ignore=@('steam_api*.dll','libsteam_api.so','libgodotsteam.*','steam_appid.txt','*.pdb')}
        $c.distributions.steam.depots['102']=@{export='linux';exclude=@()}
    }
    $settings=Get-ReleaseConfiguration $repo;$linux=@($settings.config.destinations | Where-Object id -EQ 'itch-linux')[0]
    Assert ($linux.target -ceq 'example/real-game:linux-beta' -and $linux.ignore -contains '*.pdb') 'Channel override lost.'
    Assert ($settings.config.destinationBaselines.Contains('itch-linux') -and $null -eq $settings.config.destinationBaselines['itch-linux']) 'Null fell back to root.'
    Assert (@($settings.config.destinations | Where-Object id -EQ steam)[0].depots[1].exclude.Count -eq 0) 'Empty override inherited exclusions.'
    Assert ((Get-ReleasePlan $repo @('itch-windows')).configurationReady -and -not (Get-ReleasePlan $repo @('itch-linux')).configurationReady) 'Unknown history blocked the wrong platform.'
}
Test 'grouped unknown fields and unresolved aliases fail before planning' {
    $repo=New-GroupedFixture 'grouped-invalid';$path=Join-Path $repo 'release.json';$original=[IO.File]::ReadAllText($path)
    foreach ($case in @(
        @{change={param($c) $c.distributions.itch.typo='ignored'};error='Unknown'},
        @{change={param($c) $c.distributions.itch.channels.windows=@{export='windows';typo='ignored'}};error='Unknown'},
        @{change={param($c) $c.distributions.steam.depots['101']=@{export='windows';typo='ignored'}};error='Unknown'},
        @{change={param($c) $c.distributions.itch.channels.windows='invented'};error='export alias'},
        @{change={param($c) $c.verification.standalone.exports=@('invented')};error='export alias'},
        @{change={param($c) $c.distributions.notes='true'};error='boolean'}
    )) {
        [IO.File]::WriteAllText($path,$original);Change-Config $repo $case.change
        Expect-Error {Get-ReleasePlan $repo @('itch-windows')} $case.error
    }
}
Test 'grouped shared standalone hook receives each inspected executable filename' {
    $repo=New-GroupedFixture 'grouped-filenames'
    @'
# Checks that the shared hook receives the actual export filename for this platform.
param([string]$ArtifactDirectory,[string]$Filename)
if (-not (Test-Path -LiteralPath (Join-Path $ArtifactDirectory $Filename) -PathType Leaf)) {exit 12}
if ($Filename -cnotin @('Game.exe','Game.x86_64')) {exit 13}
if (Get-ChildItem $ArtifactDirectory -Recurse -File | Where-Object {$_.Name -like 'steam_api*.dll'}) {exit 14}
'@ | Set-Content (Join-Path $repo 'tools/standalone.ps1')
    Change-Config $repo {param($c) $c.distributions.itch.Remove('displayNameTemplate');$c.verification.standalone.arguments=@('-ArtifactDirectory','{artifact}','-Filename','{filename}')}
    Invoke-FixtureGit $repo @('add','.') | Out-Null;Invoke-FixtureGit $repo @('commit','--quiet','-m','Configure common filename-aware check') | Out-Null
    $prepared=Invoke-ReleasePrepare $repo @('itch-windows','itch-linux') (Join-Path $sandbox 'grouped-filename-state') $engine
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($prepared.status -eq 'prepared' -and $state.checks['itch-windows'].standalone -eq 'succeeded' -and $state.checks['itch-linux'].standalone -eq 'succeeded') 'Both inspected filenames were not checked.'
}
Test 'grouped setup saves shared store facts and asks once for the selected itch game' {
    $repo=New-StoreFixture 'grouped-setup-create';Remove-Item -LiteralPath (Join-Path $repo 'release.json')
    $report=Get-ReleaseSetup $repo @('itch-windows','itch-linux')
    Assert (@($report.questions | Where-Object key -EQ 'distributions.itch.game').Count -eq 1) 'Owner/game question repeated per channel.'
    $answers=Join-Path $sandbox 'grouped-setup-answers.json'
    Write-Json $answers @{
        stores=@('itch','steam','notes');previousRelease='v1.2.2'
        'distributions.itch.game'='example/real-game';'distributions.itch.previousRelease'='v1.2.2'
        'distributions.itch.channels'=@{windows='windows';linux='linux'}
        'distributions.steam.appId'=100;'distributions.steam.branch'='default';'distributions.steam.previousRelease'='v1.2.2'
        'distributions.steam.depots'=@{'101'='windows';'102'='linux'}
    }
    Set-ReleaseSetup $repo $answers 'missing' | Out-Null
    $saved=Get-Content (Join-Path $repo 'release.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($saved.schemaVersion -eq 1 -and $saved.exports.windows -ceq 'Windows existing' -and $saved.distributions.itch.channels.windows -ceq 'windows') 'Setup did not save grouped schema 1.'
    Assert (-not $saved.Contains('destinations') -and -not $saved.Contains('standalone')) 'Execution records leaked into configuration.'
    Assert ((Get-ReleasePlan $repo @('itch-windows','steam')).configurationReady) 'Saved config cannot be planned.'
}
Test 'grouped setup retains custom aliases and per-channel overrides when adding a store' {
    $repo=New-GroupedFixture 'grouped-setup-preserve'
    Change-Config $repo {param($c)
        $c.exports.desktop=$c.exports.windows;$c.exports.Remove('windows');$c.distributions.itch.channels.windows='desktop'
        $c.verification.standalone.exports=@('desktop','linux')
        $c.distributions.itch.channels.linux=@{export='linux';channel='linux-beta';previousRelease=$null};$c.distributions.Remove('steam')
    }
    $hash=(Get-FileHash (Join-Path $repo 'release.json')).Hash.ToLowerInvariant();$answers=Join-Path $sandbox 'grouped-setup-preserve.json'
    Write-Json $answers @{stores=@('itch','steam','google-play','notes');'distributions.steam.appId'=100;'distributions.steam.branch'='default';'distributions.steam.depots'=@{'101'='desktop';'102'='linux'}}
    Set-ReleaseSetup $repo $answers $hash | Out-Null
    $saved=Get-Content (Join-Path $repo 'release.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($saved.exports.desktop -ceq 'Windows existing' -and -not $saved.exports.Contains('windows')) 'Custom alias duplicated.'
    Assert ($saved.distributions.itch.channels.linux.channel -ceq 'linux-beta' -and $null -eq $saved.distributions.itch.channels.linux.previousRelease) 'Channel reset.'
    Assert ($saved.verification.standalone.exports[0] -ceq 'desktop' -and $null -eq $saved.distributions['google-play'].previousRelease) 'Hook or held Play history reset.'
}
Test 'grouped setup requires confirmed Butler channel mappings before saving a newly configured game' {
    $repo=New-Fixture 'grouped-setup-channels';Remove-Item -LiteralPath (Join-Path $repo 'release.json')
    $answers=Join-Path $sandbox 'grouped-unconfirmed-channels.json'
    Write-Json $answers @{previousRelease='v1.2.2';'distributions.itch.game'='example/real-game'}
    Expect-Error {Set-ReleaseSetup $repo $answers 'missing'} 'confirm.*channel|channel.*confirm'
    Assert (-not (Test-Path -LiteralPath (Join-Path $repo 'release.json'))) 'Unconfirmed proposed channels saved.'
}
Test 'grouped setup asks for ambiguous desktop mappings instead of choosing or failing to report' {
    $repo=New-Fixture 'grouped-setup-ambiguous';Remove-Item -LiteralPath (Join-Path $repo 'release.json')
    @'
[preset.0]
name="Windows existing"
platform="Windows Desktop"
export_path="dist/windows/Game.exe"
[preset.1]
name="Windows alternate"
platform="Windows Desktop"
export_path="dist/alternate/Game.exe"
'@ | Set-Content (Join-Path $repo 'export_presets.cfg')
    $report=Get-ReleaseSetup $repo
    Assert ($report.configuration.exports.Count -eq 2 -and $report.configuration.distributions.itch.channels.Count -eq 0) 'Ambiguous Windows preset selected.'
    Assert (@($report.questions | Where-Object key -EQ 'distributions.itch.channels').Count -eq 1) 'Missing mapping question.'
    $scoped=Get-ReleaseSetup $repo @('itch-windows')
    Assert ($scoped.selection.selected[0] -ceq 'itch-windows' -and @($scoped.questions | Where-Object key -EQ 'distributions.itch.channels').Count -eq 1) 'Explicit unresolved selection lost.'
}
Test 'grouped defaults cannot hide malformed baselines or patterns behind channel overrides' {
    $repo=New-GroupedFixture 'grouped-masked-defaults';$path=Join-Path $repo 'release.json';$original=[IO.File]::ReadAllText($path)
    foreach ($case in @(
        @{change={param($c) $c.distributions.itch.channels.windows='Windows'};error='export alias'},
        @{change={param($c) $c.distributions.itch.previousRelease=7;$c.distributions.itch.channels.windows=@{export='windows';previousRelease='v1.2.2'};$c.distributions.itch.channels.linux=@{export='linux';previousRelease='v1.2.2'}};error='previousRelease'},
        @{change={param($c) $c.distributions.steam.exclude='*.pdb';$c.distributions.steam.depots['101']=@{export='windows';exclude=@()};$c.distributions.steam.depots['102']=@{export='linux';exclude=@()}};error='patterns|exclude'},
        @{change={param($c) $c.distributions.itch.channels.windows=@{export='windows';ignore=@('steam_api*.dll','libsteam_api.so','libgodotsteam.*','steam_appid.txt',('bad'+[char]10+'pattern'))}};error='patterns'}
    )) {
        [IO.File]::WriteAllText($path,$original);Change-Config $repo $case.change
        Expect-Error {Get-ReleaseConfiguration $repo} $case.error
    }
}
Test 'grouped setup reconfirms channels when changing to a different itch game' {
    $repo=New-GroupedFixture 'grouped-setup-other-game';$configPath=Join-Path $repo 'release.json';$hash=(Get-FileHash $configPath).Hash.ToLowerInvariant()
    $answers=Join-Path $sandbox 'grouped-other-game.json';Write-Json $answers @{'distributions.itch.game'='example/different-game'}
    Expect-Error {Set-ReleaseSetup $repo $answers $hash} 'confirm.*channel|channel.*confirm'
    Assert ((Get-FileHash $configPath).Hash.ToLowerInvariant() -ceq $hash) 'Changed game inherited unconfirmed channels.'
    Write-Json $answers @{'distributions.itch.game'='example/different-game';'distributions.itch.channels'=@{windows='windows';linux='linux'}}
    Set-ReleaseSetup $repo $answers $hash | Out-Null
    Assert (@((Get-ReleasePlan $repo @('itch-windows')).destinations | Where-Object id -EQ 'itch-windows')[0].target -ceq 'example/different-game:windows') 'Confirmed target was lost.'
}
Test 'grouped interactive setup parses export maps and repairs unresolved mappings' {
    $repo=New-Fixture 'grouped-interactive-exports'
    Change-Config $repo {param($c) $c.exports=@{};$c.distributions.itch.channels=@{};$c.verification.Remove('standalone')}
    $prompt={param($question)
        switch ($question.key) {
            'exports' {'{"windows":"Windows existing"}'}
            'distributions.itch.channels' {'{"windows":"windows"}'}
            'verification.standalone' {'{"exports":["windows"],"script":"tools/standalone.ps1","arguments":["{artifact}"]}'}
            default {''}
        }
    }
    $result=Invoke-ReleaseInteractiveSetup $repo @() $prompt
    Assert ($result.written -and (Get-ReleasePlan $repo @('itch-windows')).configurationReady) 'Interactive export map repair failed.'
}

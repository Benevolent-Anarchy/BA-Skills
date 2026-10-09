function New-ObsidianFixture([string]$Name) {
    $parent=New-BootstrapFixture $Name
    $identity=New-BootstrapIdentity -Name 'Obsidian Fixture' -Description 'Fixture' -Parent $parent
    Write-ProjectFoundation $identity | Out-Null
    Invoke-FixtureGit $identity.projectPath @('init','--initial-branch=main') | Out-Null
    Invoke-FixtureGit $identity.projectPath @('remote','add','origin',"https://github.com/$($identity.fullName).git") | Out-Null
    $f=@{identity=$identity;stateRoot=(New-BootstrapFixture 'vault-state');registry=@();releases=@{};history=@{};assets=@{};calls=[Collections.Generic.List[string]]::new();downloads=[Collections.Generic.List[string]]::new();failDownload='';failPromotion=$false;appVersion='1.12.7'}
    foreach ($id in @('dataview','mermaid-popup','vault-inspector','vault-nickname')) {
        $f.registry+=@{id=$id;repo="fixture/$id"}
        $manifest=@{id=$id;version='9.1.0';minAppVersion='1.0.0'}
        $assets=@(foreach ($name in @('manifest.json','main.js')) {@{name=$name;browser_download_url="https://github.com/fixture/$id/releases/download/9.1.0/$name"}})
        $f.releases[$id]=@{tag_name='9.1.0';draft=$false;prerelease=$false;assets=$assets}
        $f.assets[$assets[0].browser_download_url]=$manifest | ConvertTo-Json -Compress
        $f.assets[$assets[1].browser_download_url]="// $id 9.1.0"
    }
    $f.request={param($Method,$Endpoint,$Body)
        $f.calls.Add($Endpoint)
        if ($Endpoint -eq 'https://raw.githubusercontent.com/obsidianmd/obsidian-releases/master/community-plugins.json') {return @{StatusCode=200;Data=$f.registry}}
        if ($Endpoint -match '^/repos/fixture/([^/]+)/releases/latest$') {return @{StatusCode=200;Data=$f.releases[$Matches[1]]}}
        if ($Endpoint -match '^/repos/fixture/([^/]+)/releases\?per_page=100&page=(\d+)$') {
            $id=$Matches[1];$page=[int]$Matches[2]
            $items=if ($f.history.ContainsKey($id)) {$f.history[$id]} else {@($f.releases[$id])}
            return @{StatusCode=200;Data=@($items | Select-Object -Skip (($page-1)*100) -First 100)}
        }
        if ($f.assets.ContainsKey($Endpoint)) {return @{StatusCode=200;Data=($f.assets[$Endpoint] | ConvertFrom-Json -AsHashtable)}}
        throw "Unexpected plugin request: $Endpoint"
    }.GetNewClosure()
    $f.download={param($Url,$Destination)
        $f.downloads.Add($Url)
        if ($f.failDownload -and $Url -match $f.failDownload) {throw 'Injected failed download'}
        Write-FixtureText $Destination $f.assets[$Url]
    }.GetNewClosure()
    $f.promote={param($Source,$Destination)
        if ($f.failPromotion -and $Destination.EndsWith('mermaid-popup')) {throw 'Injected promotion failure'}
        Move-Item -LiteralPath $Source -Destination $Destination
    }.GetNewClosure()
    return $f
}
function Invoke-ObsidianFixture($Fixture,[switch]$Refresh) {
    Install-ProjectObsidian -Identity $Fixture.identity -PresetRoot $presetRoot -StateRoot $Fixture.stateRoot -Request $Fixture.request -Download $Fixture.download -AppVersion $Fixture.appVersion -Promote $Fixture.promote -RefreshPlugins:$Refresh
}
function Set-ObsidianFixtureDigests($Fixture) {
    foreach ($release in $Fixture.releases.Values) {
        foreach ($asset in $release.assets) {$asset.digest='sha256:'+(Get-BootstrapContentHash $Fixture.assets[$asset.browser_download_url])}
    }
}

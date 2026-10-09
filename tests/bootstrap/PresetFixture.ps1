function New-PresetPrerequisiteFixture([string]$Missing='', [string]$GodotVersion='4.7.2.stable.official') {
    $fixture=@{missing=$Missing;godotVersion=$GodotVersion;calls=[Collections.Generic.List[string]]::new()}
    $fixture.probe={
        param($name)
        $fixture.calls.Add($name)
        return @{passed=($name -ne $fixture.missing);version=$(if($name -eq 'godot'){$fixture.godotVersion}else{'fixture'});executable='fixture';message=$(if($name -eq $fixture.missing){"Missing $name"}else{''})}
    }.GetNewClosure()
    return $fixture
}
function New-PresetMetadataFixture {
    $fixture=@{fail=$false;calls=[Collections.Generic.List[string]]::new();tauri=@{versions=@(@{num='3.0.0';yanked=$false},@{num='3.1.0-beta.1';yanked=$false},@{num='9.0.0';yanked=$true},@{num='2.99.0';yanked=$false})};npm=@{'dist-tags'=@{latest='4.0.0'};versions=@{'4.0.0'=@{version='4.0.0';dist=@{tarball='https://registry.npmjs.org/create-tauri-app/-/create-tauri-app-4.0.0.tgz';integrity=('sha512-'+[Convert]::ToBase64String([byte[]]::new(64)))}}}}}
    $fixture.request={param($uri)
        $fixture.calls.Add($uri)
        if ($fixture.fail) {throw 'HTTP metadata unavailable'}
        switch ($uri) {
            'https://crates.io/api/v1/crates/tauri' {return $fixture.tauri}
            'https://registry.npmjs.org/create-tauri-app' {return $fixture.npm}
            'https://api.github.com/repos/bitwes/Gut/git/ref/tags/v9.7.1' {return @{object=@{type='commit';sha=('a'*40)}}}
            default {throw "Unexpected metadata URI: $uri"}
        }
    }.GetNewClosure()
    return $fixture
}

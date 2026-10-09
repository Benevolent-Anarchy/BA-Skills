function New-PresetPrerequisiteFixture([string]$Missing='', [string]$GodotVersion='4.7.2.stable.official') {
    $fixture=@{missing=$Missing;godotVersion=$GodotVersion;calls=[Collections.Generic.List[string]]::new()}
    $fixture.probe={
        param($name)
        $fixture.calls.Add($name)
        return @{passed=($name -ne $fixture.missing);version=$(if($name -eq 'godot'){$fixture.godotVersion}else{'fixture'});executable='fixture';message=$(if($name -eq $fixture.missing){"Missing $name"}else{''})}
    }.GetNewClosure()
    return $fixture
}

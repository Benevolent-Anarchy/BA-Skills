#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Get-VerificationGodot {
    if ($env:GODOT) {
        $command=Get-Command $env:GODOT -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $command) {throw "GODOT executable is unavailable: $env:GODOT"}
        return $command.Source
    }
    foreach ($name in @('godot','godot4')) {
        $command=Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) {return $command.Source}
    }
    throw 'Godot executable missing. Install Godot 4.7 and set GODOT or add it to PATH.'
}
function Get-GodotSourceFiles([string]$Directory) {
    foreach ($item in Get-ChildItem -LiteralPath $Directory) {
        if (-not $item.PSIsContainer) {$item}
        elseif (-not ($item.Name.StartsWith('.') -or (Test-Path (Join-Path $item.FullName '.gdignore')) -or (Test-Path (Join-Path $item.FullName 'project.godot')))) {Get-GodotSourceFiles $item.FullName}
    }
}
function Get-GutDirectories([string]$Repository,[bool]$Rendered) {
    $testRoot=Join-Path $Repository 'test'
    if (-not (Test-Path $testRoot -PathType Container)) {return}
    $files=@(Get-GodotSourceFiles $testRoot | Where-Object {$_.Name -like 'test_*.gd'})
    foreach ($directory in @($files.DirectoryName | Sort-Object -Unique)) {
        $relative=[IO.Path]::GetRelativePath($Repository,$directory).Replace('\','/')
        $isRendered=$relative -ceq 'test/rendered' -or $relative.StartsWith('test/rendered/')
        if ($isRendered -eq $Rendered) {"res://$relative"}
    }
}
function Invoke-GodotVerification([string]$Repository,[hashtable]$Config,[scriptblock]$Process) {
    $stages=[Collections.Generic.List[object]]::new();$diagnostics=[Collections.Generic.List[string]]::new();$stage='godot-import'
    try {
        if (-not $Config.ContainsKey('godot') -or $Config.godot.versionFamily -cne '4.7' -or $Config.godot.renderedTests -isnot [bool]) {throw 'Godot verification configuration requires versionFamily 4.7 and a renderedTests boolean.'}
        $exe=Get-VerificationGodot
        $version=& $Process $exe @('--version') $Repository @{}
        if ($version.ExitCode -ne 0 -or $version.Output.Trim() -cnotmatch '^4\.7\.[0-9]+\.stable') {throw "Unsupported Godot version: $($version.Output.Trim()). This recipe requires stable 4.7.x."}
        foreach ($file in @('project.godot','addons/gut/gut_cmdln.gd','addons/gut/plugin.cfg','tools/check_scripts.gd','tools/verify_pre_run.gd','tools/verify_post_run.gd')) {if (-not (Test-Path (Join-Path $Repository $file) -PathType Leaf)) {throw "Required Godot source missing: $file"}}
        $import=& $Process $exe @('--headless','--path',$Repository,'--import') $Repository @{}
        if ($import.ExitCode -ne 0) {throw "Godot import failed: $($import.Output)"}
        $invalid=@(Get-GodotSourceFiles $Repository | Where-Object {$_.Extension -eq '.import' -and (Select-String -LiteralPath $_.FullName -Pattern '^valid=false\s*$' -Quiet)})
        if ($invalid.Count) {throw ('Assets failed to import: '+($invalid.Name -join ', '))}
        $stages.Add(@{Name=$stage;Passed=$true;ExitCode=0;Diagnostics=@()})
        $stage='godot-compile'
        $compile=& $Process $exe @('--headless','--path',$Repository,'--script','res://tools/check_scripts.gd') $Repository @{}
        if ($compile.ExitCode -ne 0) {throw "Script compilation failed: $($compile.Output)"}
        $stages.Add(@{Name=$stage;Passed=$true;ExitCode=0;Diagnostics=@()})
        $renderedDirs=@(Get-GutDirectories $Repository $true)
        $renderedRequired=$Config.godot.renderedTests -or ($Config.ContainsKey('requiredChecks') -and 'gut-rendered' -in $Config.requiredChecks) -or $renderedDirs.Count -gt 0
        foreach ($rendered in @( $false )+$(if($renderedRequired){@($true)}else{@()})) {
            $stage=if($rendered){'gut-rendered'}else{'gut-headless'}
            $dirs=@(Get-GutDirectories $Repository $rendered)
            if (-not $dirs.Count) {throw "$stage found no tests."}
            $run='ba-verify-'+[guid]::NewGuid().ToString('N')
            $relative=".godot/$run";$report=Join-Path $Repository $relative
            [IO.Directory]::CreateDirectory($report) | Out-Null
            $gutConfig=@{dirs=$dirs;include_subdirs=$false}
            [IO.File]::WriteAllText("$report/config.json",($gutConfig | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
            [string[]]$display=@(if($rendered){'--windowed','--resolution','640x480'}else{'--headless'})
            $arguments=$display+@('--path',$Repository,'--script','res://addons/gut/gut_cmdln.gd',"-gconfig=res://$relative/config.json",'-gexit','-gpre_run_script=res://tools/verify_pre_run.gd','-gpost_run_script=res://tools/verify_post_run.gd',"-gjunit_xml_file=res://$relative/results.xml")
            $environment=@{BA_VERIFY_RESULTS="$report/results.xml";BA_VERIFY_TOTALS="$report/totals.json"}
            $result=& $Process $exe $arguments $Repository $environment
            if ($result.ExitCode -ne 0) {throw "$stage failed: $($result.Output)"}
            if (-not (Test-Path "$report/results.xml" -PathType Leaf)) {throw "$stage wrote no results XML."}
            [xml]$xml=[IO.File]::ReadAllText("$report/results.xml")
            $root=$xml.DocumentElement
            if ($root.LocalName -cne 'testsuites' -or $root.GetAttribute('tests') -cnotmatch '^[0-9]+$') {throw "$stage wrote malformed results."}
            $tests=[int]$root.GetAttribute('tests')
            if ($tests -le 0) {throw "$stage found zero tests."}
            foreach ($field in @('failures','errors')) {
                if ($field -ceq 'errors' -and -not $root.HasAttribute($field)) {continue} # GUT 9.7.1 omits the optional errors count.
                if ($root.GetAttribute($field) -cnotmatch '^[0-9]+$' -or [int]$root.GetAttribute($field) -ne 0) {throw "$stage reported test $field."}
            }
            if ($xml.SelectNodes('//failure|//error').Count -gt 0) {throw "$stage reported failed tests."}
            if (-not (Test-Path "$report/totals.json" -PathType Leaf)) {throw "$stage post-run hook wrote no totals."}
            $totals=[IO.File]::ReadAllText("$report/totals.json") | ConvertFrom-Json -AsHashtable
            if ($totals.hookComplete -cne $true -or $totals.failed -cne $false) {throw "$stage hook did not complete cleanly; unexpected errors or orphan nodes."}
            foreach ($field in @('scripts','tests','asserts','seconds')) {if ($totals[$field] -isnot [ValueType] -or $totals[$field] -is [bool] -or $totals[$field] -lt 0) {throw "$stage malformed totals: $field"}}
            if ($totals.tests -ne $tests -or $totals.scripts -lt 1) {throw "$stage totals do not match executed tests."}
            $stages.Add(@{Name=$stage;Passed=$true;ExitCode=0;Diagnostics=@();Totals=$totals})
        }
    } catch {$diagnostics.Add($_.Exception.Message);$stages.Add(@{Name=$stage;Passed=$false;ExitCode=1;Diagnostics=@()})}
    return @{Passed=(@($stages | Where-Object {-not $_.Passed}).Count -eq 0);Stages=$stages.ToArray();Diagnostics=$diagnostics.ToArray()}
}
Export-ModuleMember -Function Invoke-GodotVerification,Get-VerificationGodot,Get-GodotSourceFiles

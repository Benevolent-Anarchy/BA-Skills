#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Read-ProjectVerificationConfig([string]$Repository) {
    try {
        $config=ConvertFrom-Json -AsHashtable ([IO.File]::ReadAllText((Join-Path $Repository 'tools/verify.json')))
        if ($config -isnot [hashtable] -or $config.schemaVersion -ne 1 -or $config.preset -notin @('foundation','godot','tauri') -or $config.requiredChecks -isnot [array]) {throw 'Invalid configuration schema or preset.'}
        [string[]]$required=@(switch ($config.preset) {
            foundation {@('documentation')}
            godot {@('documentation','godot-import','godot-compile','gut-headless')}
            tauri {@('documentation','typescript','frontend-tests','frontend-build','rust-format','rust-lint','rust-tests','tauri-build')}
        })
        foreach ($check in $required) {if ($check -notin $config.requiredChecks) {throw "Missing required check: $check"}}
        if (@($config.requiredChecks | Where-Object {$_ -isnot [string] -or $_ -notin ($required+@('gut-rendered'))}).Count -or @($config.requiredChecks | Select-Object -Unique).Count -ne $config.requiredChecks.Count) {throw 'Invalid required checks.'}
        if ($config.preset -ne 'godot' -and 'gut-rendered' -in $config.requiredChecks) {throw 'Rendered tests require the Godot preset.'}
        return $config
    } catch {throw "Verification config: $($_.Exception.Message)"}
}
function Invoke-VerificationProcess([string]$Executable,[string[]]$Arguments,[string]$Repository,[hashtable]$Environment=@{},[int]$TimeoutSeconds=900) {
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$Executable;$info.WorkingDirectory=$Repository
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach ($argument in $Arguments) {$info.ArgumentList.Add($argument)}
    foreach ($key in $Environment.Keys) {$info.Environment[$key]=[string]$Environment[$key]}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info
    try {
        $null=$process.Start()
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds*1000)) {$process.Kill($true);$process.WaitForExit();throw "Process timed out: $Executable"}
        return @{ExitCode=$process.ExitCode;Output=($stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult());Executable=$Executable}
    } finally {$process.Dispose()}
}
function Invoke-ProjectVerification([string]$Repository,[scriptblock]$Process={param($exe,$arguments,$cwd,$environment) Invoke-VerificationProcess $exe $arguments $cwd $environment},[switch]$RequireExactPreparedVersions) {
    $stages=[Collections.Generic.List[object]]::new();$diagnostics=[Collections.Generic.List[string]]::new();$binary=$null
    try {$config=Read-ProjectVerificationConfig $Repository}
    catch {return @{Passed=$false;Stages=@();Diagnostics=@($_.Exception.Message)}}
    try {
        Import-Module (Join-Path $PSScriptRoot 'Documentation.psm1') -Force
        $docs=Test-ProjectDocumentation -Repository $Repository
        $messages=@($docs.Diagnostics | ForEach-Object {"{0}:{1}: {2}: {3}" -f $_.File,$_.Line,$_.Code,$_.Message})
        $stages.Add(@{Name='documentation';Passed=$docs.Passed;ExitCode=$(if($docs.Passed){0}else{1});Diagnostics=$messages})
    } catch {$stages.Add(@{Name='documentation';Passed=$false;ExitCode=1;Diagnostics=@($_.Exception.Message)})}
    if ($config.preset -ne 'foundation') {
        try {
            $helper=if ($config.preset -eq 'godot') {'GodotVerification'} else {'TauriVerification'}
            $module=Join-Path $Repository "tools/$helper.psm1"
            if (-not (Test-Path -LiteralPath $module -PathType Leaf)) {throw "Required preset helper missing: $module"}
            Import-Module $module -Force
            $engine=if ($config.preset -eq 'godot') {Invoke-GodotVerification $Repository $config $Process} else {Invoke-TauriVerification $Repository $config $Process -RequireExactPreparedVersions:$RequireExactPreparedVersions}
            if ($engine.ContainsKey('BinaryPath')) {$binary=$engine.BinaryPath}
            foreach ($stage in $engine.Stages) {$stages.Add($stage)}
            foreach ($message in $engine.Diagnostics) {$diagnostics.Add($message)}
        } catch {$stages.Add(@{Name=$config.preset;Passed=$false;ExitCode=1;Diagnostics=@($_.Exception.Message)})}
    }
    foreach ($required in $config.requiredChecks) {
        if (@($stages | Where-Object Name -eq $required).Count -ne 1) {$stages.Add(@{Name=$required;Passed=$false;ExitCode=1;Diagnostics=@("Required stage did not report exactly one result: $required")})}
    }
    foreach ($stage in $stages) {foreach ($message in $stage.Diagnostics) {$diagnostics.Add([string]$message)}}
    return @{Passed=(@($stages | Where-Object {-not $_.Passed}).Count -eq 0);Stages=$stages.ToArray();Diagnostics=$diagnostics.ToArray();BinaryPath=$binary}
}
Export-ModuleMember -Function Read-ProjectVerificationConfig,Invoke-ProjectVerification,Invoke-VerificationProcess

#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../assets/project/tools/Verification.psm1')

function Resolve-BootstrapPreset([hashtable]$Identity,[string]$Preset='godot',[string]$Renderer,[string]$AppIdentifier) {
    $Preset=$Preset.ToLowerInvariant()
    if ($Preset -notin @('foundation','godot','tauri')) {throw 'Invalid preset; choose godot, tauri or foundation.'}
    $selection=@{name=$Preset;recipeVersion=1;renderer=$null;appIdentifier=$null;packageName=$null;crateName=$null}
    if ($Preset -ne 'godot' -and $PSBoundParameters.ContainsKey('Renderer')) {throw 'Renderer is a Godot-only option.'}
    if ($Preset -ne 'tauri' -and $PSBoundParameters.ContainsKey('AppIdentifier')) {throw 'Application identifier is a Tauri-only option.'}
    if ($Preset -eq 'godot') {
        if (-not $PSBoundParameters.ContainsKey('Renderer')) {$Renderer='compatibility'}
        $Renderer=$Renderer.ToLowerInvariant()
        if ($Renderer -notin @('compatibility','forward-plus','mobile')) {throw 'Invalid Godot renderer.'}
        $selection.renderer=$Renderer
    } elseif ($Preset -eq 'tauri') {
        $base=[regex]::Replace($Identity.repository.ToLowerInvariant(),'[^a-z0-9-]+','-').Trim('-')
        if (-not $base) {$base='project'}
        $reserved=@('as','async','await','break','const','continue','crate','dyn','else','enum','extern','false','fn','for','if','impl','in','let','loop','match','mod','move','mut','pub','ref','return','self','static','struct','super','trait','true','type','unsafe','use','where','while','abstract','become','box','do','final','macro','override','priv','try','typeof','unsized','virtual','yield','gen')
        if ($base -notmatch '^[a-z]' -or $base -in $reserved) {$base='project-'+$base}
        if ($base -notmatch '^[a-z][a-z0-9-]*$' -or $base.Length -gt 214) {throw 'Cannot derive legal package/crate names.'}
        $selection.packageName=$base;$selection.crateName=$base
        if (-not $PSBoundParameters.ContainsKey('AppIdentifier')) {
            $prefix=switch ($Identity.owner.ToLowerInvariant()) {
                'benevolent-anarchy' {'org.benevolent-anarchy'}
                'cicely-f' {'com.cicely-f'}
                default {'com.'+$Identity.owner.ToLowerInvariant()}
            }
            $AppIdentifier=$prefix+'.'+$base
        }
        if ($AppIdentifier -notmatch '^[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z][A-Za-z0-9-]*)+$') {throw 'Invalid application identifier: use dot-separated segments starting with a letter, then letters, digits or hyphens.'}
        $selection.appIdentifier=$AppIdentifier
    }
    return $selection
}

function Assert-BootstrapPresetOverride([hashtable]$Stored,[Collections.IDictionary]$BoundParameters) {
    $keys=@{Preset='name';Renderer='renderer';AppIdentifier='appIdentifier'}
    foreach ($key in $keys.Keys) {
        if (-not $BoundParameters.Contains($key)) {continue}
        $actual=[string]$BoundParameters[$key];$expected=[string]$Stored[$keys[$key]]
        if ($key -ne 'AppIdentifier') {$actual=$actual.ToLowerInvariant();$expected=$expected.ToLowerInvariant()}
        if (-not $actual -or $actual -cne $expected) {throw "Preset option conflicts with stored $key. Resume with the recorded selection."}
    }
}

function Get-BootstrapToolPath([string]$Name) {
    $command=Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {return $command.Source}
    if ($Name -in @('rustc','cargo','rustfmt','cargo-clippy','rustup')) {
        $candidate=Join-Path $env:USERPROFILE ".cargo/bin/$Name.exe"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {return $candidate}
    }
    return $null
}

function Invoke-BootstrapPrerequisiteProbe([string]$Name) {
    try {
        if ($Name -eq 'msvc') {
            $finder=Join-Path ([Environment]::GetEnvironmentVariable('ProgramFiles(x86)')) 'Microsoft Visual Studio/Installer/vswhere.exe'
            if (-not (Test-Path -LiteralPath $finder -PathType Leaf)) {throw 'Microsoft C++ build tools were not found.'}
            $result=Invoke-VerificationProcess $finder @('-latest','-products','*','-requires','Microsoft.VisualStudio.Component.VC.Tools.x86.x64','-property','installationPath') ([IO.Path]::GetTempPath())
            if ($result.ExitCode -ne 0 -or -not $result.Output.Trim()) {throw 'MSVC x64/x86 C++ build tools were not found.'}
            return @{passed=$true;version='installed';executable=$result.Output.Trim();message=''}
        }
        if ($Name -eq 'webview2') {
            $runtime=@(foreach ($hive in @('HKLM:','HKCU:')) {
                foreach ($branch in @('SOFTWARE/Microsoft/EdgeUpdate/Clients/*','SOFTWARE/WOW6432Node/Microsoft/EdgeUpdate/Clients/*')) {
                    Get-ItemProperty ($hive+'/'+$branch) -ErrorAction SilentlyContinue | Where-Object {$_ -and $_.PSObject.Properties.Name -contains 'name' -and $_.name -like '*WebView2*'}
                }
            }) | Select-Object -First 1
            if (-not $runtime) {throw 'WebView2 Runtime was not found.'}
            return @{passed=$true;version=$runtime.pv;executable='WebView2';message=''}
        }
        $tool=switch ($Name) {godot {if($env:GODOT){$env:GODOT}else{'godot'}} rust {'rustc'} clippy {'cargo-clippy'} default {$Name}}
        $exe=Get-BootstrapToolPath $tool
        if (-not $exe) {throw "Required executable missing: $tool"}
        [string[]]$arguments=@('--version')
        # npm.cmd cannot be spawned without a shell. Invoke its JS CLI through Node.
        if ($Name -eq 'npm') {
            $cli=Join-Path (Split-Path $exe -Parent) 'node_modules/npm/bin/npm-cli.js'
            if (-not (Test-Path -LiteralPath $cli)) {throw 'Cannot locate npm CLI beside its executable.'}
            $exe=Get-BootstrapToolPath 'node';$arguments=@($cli,'--version')
        }
        # Explicit rustup run never installs a missing selected toolchain. Probe outside project overrides.
        if ($Name -in @('rust','cargo','rustfmt','clippy')) {
            $rustup=Get-BootstrapToolPath 'rustup'
            if ($rustup) {
                $active=Invoke-VerificationProcess $rustup @('show','active-toolchain') ([IO.Path]::GetTempPath())
                if ($active.ExitCode -ne 0) {throw $active.Output.Trim()}
                $toolchain=($active.Output.Trim() -split '\s+')[0]
                $arguments=@('run',$toolchain,$tool,'--version');$exe=$rustup
            }
        }
        $result=Invoke-VerificationProcess $exe $arguments ([IO.Path]::GetTempPath())
        if ($result.ExitCode -ne 0) {throw "Required $Name check failed: $($result.Output.Trim())"}
        return @{passed=$true;version=$result.Output.Trim();executable=(Get-BootstrapToolPath $tool);message=''}
    } catch {return @{passed=$false;version=$null;executable=$null;message=$_.Exception.Message}}
}

function Get-BootstrapPrerequisites([hashtable]$Selection,[scriptblock]$Probe={param($name) Invoke-BootstrapPrerequisiteProbe $name}) {
    [string[]]$names=@(switch ($Selection.name) {godot {'godot'} tauri {@('node','npm','rust','cargo','rustfmt','clippy','msvc','webview2')} foundation {@()} default {throw 'Invalid preset.'}})
    $checks=@(foreach ($name in $names) {
        try {$check=& $Probe $name;$check.name=$name}
        catch {$check=@{name=$name;passed=$false;version=$null;executable=$null;message=$_.Exception.Message}}
        if ($name -eq 'godot' -and $check.passed -and $check.version -notmatch '^4\.7\.') {$check.passed=$false;$check.message="Unsupported Godot version: $($check.version); recipe requires 4.7.x."}
        $check
    })
    return @{passed=(@($checks | Where-Object {-not $_.passed}).Count -eq 0);checks=$checks}
}
Export-ModuleMember -Function Resolve-BootstrapPreset,Assert-BootstrapPresetOverride,Get-BootstrapPrerequisites,Get-BootstrapToolPath

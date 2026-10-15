# Runs external tools through argument arrays without interpreting command text.
#requires -Version 7.2
Set-StrictMode -Version Latest

# Resolves an explicit executable or PATH command without invoking it.
function Find-ReleaseDoctorTool([string]$Name) {
    if (-not $Name) {return $null}
    $candidates=@(Get-Command $Name -All -CommandType Application,ExternalScript -ErrorAction SilentlyContinue | ForEach-Object {$_.Source})
    if (Test-Path -LiteralPath $Name -PathType Leaf) {$candidates+= (Get-Item -LiteralPath $Name).FullName}
    foreach ($candidate in $candidates) {
        if ($IsWindows) {
            $extension=[IO.Path]::GetExtension($candidate)
            if (-not $extension -or ($extension -ine '.ps1' -and $extension -notin @($env:PATHEXT -split ';'))) {continue}
        }
        return $candidate
    }
    return $null
}

function Invoke-ReleaseTool([string]$Executable, [string[]]$Arguments, [string]$Directory, [hashtable]$Environment=@{}) {
    $PSNativeCommandUseErrorActionPreference = $false
    $priorEnvironment=@{}
    Push-Location -LiteralPath $Directory
    try {
        foreach ($key in $Environment.Keys) {
            $priorEnvironment[$key]=[Environment]::GetEnvironmentVariable($key,'Process')
            [Environment]::SetEnvironmentVariable($key,$Environment[$key],'Process')
        }
        $resolved=Find-ReleaseDoctorTool $Executable
        if (-not $resolved) {throw "Tool '$Executable' did not run as a process: executable missing or not runnable."}
        $Executable=$resolved
        $global:LASTEXITCODE=$null
        if ($Executable.EndsWith('.ps1',[StringComparison]::OrdinalIgnoreCase)) {
            $lines = & (Join-Path $PSHOME $(if ($IsWindows) {'pwsh.exe'} else {'pwsh'})) -NoProfile -File $Executable @Arguments 2>&1
        } else { $lines = & $Executable @Arguments 2>&1 }
        if ($null -eq $LASTEXITCODE) {throw "Tool '$Executable' did not run as a process (no exit code)."}
        return @{exitCode=$LASTEXITCODE; text=($lines -join "`n")}
    } finally {
        foreach ($key in $priorEnvironment.Keys) {
            if ($null -eq $priorEnvironment[$key]) {Remove-Item -LiteralPath ('Env:'+$key) -ErrorAction SilentlyContinue}
            else {[Environment]::SetEnvironmentVariable($key,$priorEnvironment[$key],'Process')}
        }
        Pop-Location
    }
}
# Bounds harmless version probes; never passes credentials or interprets shell commands.
function Invoke-ReleaseProbe([string]$Executable, [string[]]$Arguments, [string]$Directory, [int]$TimeoutSeconds=15) {
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$Executable;$start.WorkingDirectory=$Directory
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    if ($Executable.EndsWith('.ps1',[StringComparison]::OrdinalIgnoreCase)) {
        $start.FileName=Join-Path $PSHOME $(if ($IsWindows) {'pwsh.exe'} else {'pwsh'})
        foreach ($arg in @('-NoProfile','-File',$Executable)) {$start.ArgumentList.Add($arg)}
    }
    foreach ($arg in $Arguments) {$start.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    try {
        $null=$process.Start()
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds*1000)) {
            $process.Kill($true);$null=$process.WaitForExit(5000)
            return @{exitCode=124;text='Version probe timed out.'}
        }
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout,$stderr),5000)) {return @{exitCode=124;text='Version probe output timed out.'}}
        return @{exitCode=$process.ExitCode;text=$stdout.Result+"`n"+$stderr.Result}
    } finally {$process.Dispose()}
}
Export-ModuleMember -Function Find-ReleaseDoctorTool,Invoke-ReleaseTool,Invoke-ReleaseProbe

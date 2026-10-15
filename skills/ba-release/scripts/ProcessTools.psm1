# Runs external tools through argument arrays without interpreting command text.
#requires -Version 7.2
Set-StrictMode -Version Latest

# Resolves an explicit executable or PATH command without invoking it.
function Find-ReleaseDoctorTool([string]$Name) {
    if (-not $Name) {return $null}
    $candidates=@(Get-Command $Name -All -CommandType Application,ExternalScript -ErrorAction SilentlyContinue | ForEach-Object {$_.Source})
    if ([IO.Path]::GetFileName($Name) -cne $Name -and (Test-Path -LiteralPath $Name -PathType Leaf)) {$candidates+= (Get-Item -LiteralPath $Name).FullName}
    foreach ($candidate in $candidates) {
        if ($IsWindows) {
            $extension=[IO.Path]::GetExtension($candidate)
            # Association-only PATHEXT entries launch unwatched; accept only waited processes.
            if ($extension -notin @('.exe','.com','.bat','.cmd','.ps1')) {continue}
        }
        return $candidate
    }
    return $null
}

# Marks only library-generated diagnostics as safe for release journals.
# Never pass external tool output or provider exception text as the diagnostic.
function New-ReleaseDiagnosticError([string]$Message, [string]$Diagnostic=$Message) {
    $exception=[Exception]::new($Message)
    $exception.Data['releaseDiagnostic']=$Diagnostic
    return $exception
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
        if (-not $resolved) {throw (New-ReleaseDiagnosticError "Tool '$Executable' did not run as a process: executable missing or not runnable." 'Tool executable is missing or not runnable; supply its runtime path.')}
        $Executable=$resolved
        $global:LASTEXITCODE=$null
        try {
            if ($Executable.EndsWith('.ps1',[StringComparison]::OrdinalIgnoreCase)) {
                $lines = & (Join-Path $PSHOME $(if ($IsWindows) {'pwsh.exe'} else {'pwsh'})) -NoProfile -File $Executable @Arguments 2>&1
            } else { $lines = & $Executable @Arguments 2>&1 }
        } catch {throw (New-ReleaseDiagnosticError 'Tool process could not be started; check executable format and execute permission.')}
        # Defensive guard: supported tool types must produce their own native exit code.
        if ($null -eq $LASTEXITCODE) {throw (New-ReleaseDiagnosticError "Tool '$Executable' did not run as a process (no exit code)." 'Tool did not report a process exit code; inspect the executable before retrying.')}
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
Export-ModuleMember -Function Find-ReleaseDoctorTool,New-ReleaseDiagnosticError,Invoke-ReleaseTool,Invoke-ReleaseProbe

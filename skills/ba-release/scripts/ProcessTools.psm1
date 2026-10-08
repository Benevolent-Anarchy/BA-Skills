# Runs external tools through argument arrays without interpreting command text.
#requires -Version 7.2
Set-StrictMode -Version Latest

function Invoke-ReleaseTool([string]$Executable, [string[]]$Arguments, [string]$Directory) {
    $PSNativeCommandUseErrorActionPreference = $false
    Push-Location -LiteralPath $Directory
    try {
        if ($Executable.EndsWith('.ps1',[StringComparison]::OrdinalIgnoreCase)) {
            $lines = & (Join-Path $PSHOME $(if ($IsWindows) {'pwsh.exe'} else {'pwsh'})) -NoProfile -File $Executable @Arguments 2>&1
        } else { $lines = & $Executable @Arguments 2>&1 }
        return @{exitCode=$LASTEXITCODE; text=($lines -join "`n")}
    } finally { Pop-Location }
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
Export-ModuleMember -Function Invoke-ReleaseTool,Invoke-ReleaseProbe

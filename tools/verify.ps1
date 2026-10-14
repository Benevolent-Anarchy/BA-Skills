#requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$failed=$false
# Walk only source directories; avoid ignored receipts, fixture output and linked checkouts.
function Get-SourceScripts([string]$Directory) {
    foreach ($item in Get-ChildItem -LiteralPath $Directory -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {continue}
        if ($item.PSIsContainer) {
            if ($item.Name -notin @('.git','.test-results','.superpowers','__pycache__')) {Get-SourceScripts $item.FullName}
        } elseif ($item.Extension -in @('.ps1','.psm1')) {$item}
    }
}
foreach ($file in Get-SourceScripts $root) {
    $tokens=$null;$errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    foreach ($parseError in $errors) {
        Write-Output "$($file.FullName):$($parseError.Extent.StartLineNumber): $($parseError.Message)"
        $failed=$true
    }
}
if ($failed) {exit 1}
# Suites share nothing but the machine (each builds its own temporary sandbox), so they run at once;
# each one's output and exit code are held until it finishes, then printed whole in this fixed order.
$jobs=[Collections.Generic.List[object]]::new()
$encoding=[Console]::OutputEncoding
try {
    # Suites write in the console code page they inherit; UTF-8 keeps every character through the capture.
    try {[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)} catch {$encoding=$null}
    foreach ($suite in @('tests/run-tests.ps1','tests/bootstrap/run-tests.ps1','tests/integrate/run-tests.ps1')) {
        $jobs.Add((Start-ThreadJob -ArgumentList (Join-Path $PSHOME 'pwsh.exe'),(Join-Path $root $suite) -ScriptBlock {
            param([string]$Pwsh,[string]$Suite)
            $start=[Diagnostics.ProcessStartInfo]::new($Pwsh)
            foreach ($argument in '-NoProfile','-File',$Suite) {$start.ArgumentList.Add($argument)}
            $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
            $start.StandardOutputEncoding=[Console]::OutputEncoding;$start.StandardErrorEncoding=[Console]::OutputEncoding
            $process=$null;$finished=$false
            try {
                $process=[Diagnostics.Process]::Start($start)
                # Keep both streams' lines in arrival order, as 2>&1 does. Every wait here is short, so a stop request
                # gets through even while a suite's child holds its output open or a suite runs on after closing it.
                $streams=@($process.StandardOutput,$process.StandardError)
                $reads=@($streams[0].ReadLineAsync(),$streams[1].ReadLineAsync())
                $output=[Collections.Generic.List[string]]::new()
                while ($reads[0] -or $reads[1]) {
                    $null=[Threading.Tasks.Task]::WaitAny([Threading.Tasks.Task[]]@($reads | Where-Object {$_}),200)
                    foreach ($i in 0,1) {
                        if (-not $reads[$i] -or -not $reads[$i].IsCompleted) {continue}
                        if ($null -eq $reads[$i].Result) {$reads[$i]=$null} else {$output.Add($reads[$i].Result);$reads[$i]=$streams[$i].ReadLineAsync()}
                    }
                }
                while (-not $process.WaitForExit(200)) {}
                $finished=$true
                @{output=$output;exitCode=$process.ExitCode}
            } finally {
                # Unless the suite finished, end it and every process it started, also when the suite itself has exited.
                if ($process -and -not $finished) {$process.Kill($true)}
            }
        }))
    }
    foreach ($job in $jobs) {
        # Wait and receive separately: Receive-Job -Wait -AutoRemoveJob sometimes fails to find a finished thread job.
        $result=Receive-Job -Job (Wait-Job -Job $job)
        Write-Output $result.output
        if ($result.exitCode -ne 0) {$failed=$true}
    }
} finally {
    # Also runs when the gate is cancelled or fails: removing only this gate's jobs stops any suite still running.
    if ($jobs.Count) {$jobs | Remove-Job -Force}
    if ($encoding) {[Console]::OutputEncoding=$encoding}
}
if ($failed) {exit 1}
Write-Output 'Verification passed: BA-Skills.'
exit 0

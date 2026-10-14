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
$jobs=foreach ($suite in @('tests/run-tests.ps1','tests/bootstrap/run-tests.ps1','tests/integrate/run-tests.ps1')) {
    Start-ThreadJob -ArgumentList (Join-Path $PSHOME 'pwsh.exe'),(Join-Path $root $suite) -ScriptBlock {
        param([string]$Pwsh,[string]$Suite)
        $output=& $Pwsh -NoProfile -File $Suite 2>&1 | ForEach-Object {"$_"}
        @{output=$output;exitCode=$LASTEXITCODE}
    }
}
foreach ($job in $jobs) {
    # Wait, receive and remove separately: Receive-Job -Wait -AutoRemoveJob sometimes fails to find a finished thread job.
    $result=Receive-Job -Job (Wait-Job -Job $job)
    Remove-Job -Job $job
    Write-Output $result.output
    if ($result.exitCode -ne 0) {$failed=$true}
}
if ($failed) {exit 1}
Write-Output 'Verification passed: BA-Skills.'
exit 0

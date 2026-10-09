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
foreach ($suite in @('tests/run-tests.ps1','tests/bootstrap/run-tests.ps1')) {
    & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File (Join-Path $root $suite)
    if ($LASTEXITCODE -ne 0) {$failed=$true}
}
if ($failed) {exit 1}
Write-Output 'Verification passed: BA-Skills.'
exit 0

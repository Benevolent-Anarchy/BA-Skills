#requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'Verification.psm1') -Force
    $report=Invoke-ProjectVerification -Repository (Split-Path $PSScriptRoot -Parent)
    foreach ($message in $report.Diagnostics) {Write-Output $message}
    foreach ($stage in $report.Stages) {Write-Output ("{0}: {1}" -f $stage.Name,$(if($stage.Passed){'passed'}else{'FAILED'}))}
    if (-not $report.Passed) {exit 1}
    Write-Output 'Verification passed: complete project gate.'
    exit 0
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}

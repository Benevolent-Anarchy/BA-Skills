#requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'Documentation.psm1') -Force
    $report=Test-ProjectDocumentation -Repository (Split-Path $PSScriptRoot -Parent)
    foreach ($item in $report.Diagnostics) {
        Write-Output ("{0}:{1}: {2}: {3}" -f $item.File,$item.Line,$item.Code,$item.Message)
    }
    if (-not $report.Passed) {exit 1}
    Write-Output 'Verification passed: documentation.'
    exit 0
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}

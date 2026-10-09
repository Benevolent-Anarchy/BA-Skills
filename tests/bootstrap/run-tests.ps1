#requires -Version 7.2
[CmdletBinding()]
param([string]$Filter='*')
$ErrorActionPreference='Stop'
$script:Passed=0; $script:Failed=0
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$skillRoot=Join-Path $root 'skills/ba-bootstrap'
$assetRoot=Join-Path $skillRoot 'assets/project'
$presetRoot=Join-Path $skillRoot 'assets/obsidian'
$sandbox=Join-Path ([IO.Path]::GetTempPath()) ('ba-bootstrap-tests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
foreach ($suite in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*-tests.ps1' | Where-Object Name -ne 'run-tests.ps1' | Sort-Object Name) { . $suite.FullName }
Write-Output "Bootstrap tests: $script:Passed passed, $script:Failed failed. Fixtures: $sandbox"
if ($script:Passed+$script:Failed -eq 0) { throw 'No tests matched Filter.' }
if ($script:Failed -gt 0) { exit 1 }
exit 0

#requires -Version 7.2
[CmdletBinding()]
param([switch]$IncludeWsl,[string[]]$WslDistribution=@(),[switch]$CheckOnly)
$ErrorActionPreference='Stop'
$skillItem=Get-Item -LiteralPath (Split-Path $PSScriptRoot -Parent)
$source=if ($skillItem.LinkType) {$skillItem.ResolveLinkTarget($true).FullName} else {$skillItem.FullName}
$repositoryRoot=Split-Path (Split-Path $source -Parent) -Parent
& (Join-Path $repositoryRoot 'install.ps1') -Skill ba-bootstrap @PSBoundParameters

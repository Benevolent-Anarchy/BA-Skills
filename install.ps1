# Dispatches installation to the canonical skill so installation logic has one owner.
#requires -Version 7.2
[CmdletBinding()]
param([switch]$IncludeWsl, [string[]]$WslDistribution = @(), [switch]$CheckOnly)
& (Join-Path $PSScriptRoot 'skills/ba-release/scripts/install.ps1') @PSBoundParameters

# Installs one canonical ba-release folder for installed native and optional WSL agents.
#requires -Version 7.2
[CmdletBinding()]
param([switch]$IncludeWsl, [string[]]$WslDistribution = @(), [switch]$CheckOnly)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Install.psm1') -Force
$source = Split-Path $PSScriptRoot -Parent
$targets = @(Get-ReleaseSkillTargets -IncludeWsl:$IncludeWsl -WslDistribution $WslDistribution)
if ($targets.Count -eq 0) { throw 'No installed Codex or Claude Code executable found in the selected environments.' }
@(Install-ReleaseSkill -Source $source -Targets $targets -CheckOnly:$CheckOnly) | ConvertTo-Json -Depth 10

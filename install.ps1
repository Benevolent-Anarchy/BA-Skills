# Installs selected canonical skills after preflighting every selected target.
#requires -Version 7.2
[CmdletBinding()]
param([ValidateSet('ba-release','ba-bootstrap','ba-integrate','all')][string]$Skill='all',[switch]$IncludeWsl,[string[]]$WslDistribution=@(),[switch]$CheckOnly)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'skills/ba-release/scripts/Install.psm1') -Force
$names=if ($Skill -eq 'all') {@('ba-release','ba-bootstrap','ba-integrate')} else {@($Skill)}
$selections=@();$results=[Collections.Generic.List[object]]::new()
foreach ($name in $names) {
    $source=Join-Path $PSScriptRoot ('skills/'+$name)
    $targets=@(Get-ReleaseSkillTargets -SkillName $name -IncludeNativeAliases:($name -ne 'ba-release') -IncludeWsl:$IncludeWsl -WslDistribution $WslDistribution)
    if ($targets.Count -eq 0) {
        if ($Skill -eq 'ba-release') {throw 'No installed Codex or Claude Code executable found in the selected environments.'}
        $results.Add(@{skill=$name;status='not-installed';reason='No installed agent executable detected for release discovery.'})
    } else {$selections+=@{name=$name;source=$source;targets=$targets}}
}
foreach ($selection in $selections) {Install-ReleaseSkill -Source $selection.source -Targets $selection.targets -SkillName $selection.name -CheckOnly | Out-Null}
foreach ($selection in $selections) {
    foreach ($record in @(Install-ReleaseSkill -Source $selection.source -Targets $selection.targets -SkillName $selection.name -CheckOnly:$CheckOnly)) {
        $record | Add-Member -NotePropertyName skill -NotePropertyValue $selection.name
        $results.Add($record)
    }
}
ConvertTo-Json -InputObject $results.ToArray() -Depth 10

Import-Module "$root/skills/ba-release/scripts/Install.psm1" -Force
function New-InstallationFixture {
    $homePath=New-BootstrapFixture 'home'
    $source=Join-Path $homePath 'canonical/ba-bootstrap'
    Write-FixtureText "$source/SKILL.md" "---`nname: ba-bootstrap`ndescription: Fixture`n---`n"
    $release=Join-Path $homePath '.agents/skills/ba-release/keep.txt';Write-FixtureText $release 'keep release'
    $targets=@(
        @{agent='codex';platform='local';path=(Join-Path $homePath '.agents/skills/ba-bootstrap');legacyPath=(Join-Path $homePath '.codex/skills/ba-bootstrap')},
        @{agent='claude';platform='local';path=(Join-Path $homePath '.claude/skills/ba-bootstrap')}
    )
    @{home=$homePath;source=$source;releaseSentinel=$release;targets=$targets}
}
Test 'bootstrap installation links one source and preserves release and other skills' {
    $f=New-InstallationFixture
    $first=@(Install-ReleaseSkill -Source $f.source -Targets $f.targets -SkillName ba-bootstrap)
    $again=@(Install-ReleaseSkill -Source $f.source -Targets $f.targets -SkillName ba-bootstrap)
    Assert ($first[0].status -eq 'installed' -and $again[0].status -eq 'already-linked') 'Not repeatable.'
    Assert ((Get-Item $f.targets[1].path).ResolveLinkTarget($true).FullName -eq $f.source) 'Wrong source.'
    Assert ([IO.File]::ReadAllText($f.releaseSentinel) -ceq 'keep release') 'Release changed.'
}
Test 'bootstrap installation preflights all targets and supports check-only' {
    $f=New-InstallationFixture
    $check=@(Install-ReleaseSkill $f.source $f.targets -SkillName ba-bootstrap -CheckOnly)
    Assert ($check[0].status -eq 'missing' -and -not (Test-Path $f.targets[0].path)) 'Check-only installed.'
    Write-FixtureText $f.targets[1].path 'conflict'
    Expect-Error {Install-ReleaseSkill $f.source $f.targets -SkillName ba-bootstrap} 'conflict'
    Assert (-not (Test-Path $f.targets[0].path) -and [IO.File]::ReadAllText($f.targets[1].path) -ceq 'conflict') 'Preflight installed or replaced a conflicting target.'
}
Test 'bootstrap installation respects selected legacy names and file-valued parents' {
    $f=New-InstallationFixture
    Write-FixtureText $f.targets[0].legacyPath 'legacy conflict'
    Expect-Error {Install-ReleaseSkill $f.source $f.targets -SkillName ba-bootstrap} 'legacy'
    Assert (-not (Test-Path $f.targets[1].path)) 'Legacy conflict created another alias.'
    $f=New-InstallationFixture
    Write-FixtureText "$($f.home)/blocked" 'parent file'
    $f.targets[1].path=Join-Path $f.home 'blocked/ba-bootstrap'
    Expect-Error {Install-ReleaseSkill $f.source $f.targets -SkillName ba-bootstrap} 'parent'
    Assert (-not (Test-Path $f.targets[0].path)) 'First alias written before parent conflict.'
}
Test 'bootstrap installation requires both native aliases and respects Claude config' {
    $f=New-InstallationFixture;$before=$env:CLAUDE_CONFIG_DIR
    $module=Get-Module Install
    & $module {function script:Get-Command {param($Name,$ErrorAction) return $null}}
    try {
        $env:CLAUDE_CONFIG_DIR=Join-Path $f.home 'custom-claude'
        $targets=@(Get-ReleaseSkillTargets -SkillName ba-bootstrap -IncludeNativeAliases)
        Assert ($targets.Count -eq 2 -and $targets[0].path.EndsWith('.agents\skills\ba-bootstrap') -and $targets[1].path -eq (Join-Path $env:CLAUDE_CONFIG_DIR 'skills/ba-bootstrap')) 'Wrong native discovery targets.'
        Assert (@(Get-ReleaseSkillTargets).Count -eq 0) 'Default release executable detection changed.'
    } finally {$env:CLAUDE_CONFIG_DIR=$before;& $module {Remove-Item -LiteralPath Function:Get-Command}}
}
Test 'bootstrap installation root selects skills and preflights the entire selection' {
    $f=New-InstallationFixture;$repo=Join-Path $f.home 'installer-repo'
    Write-FixtureText "$repo/skills/ba-release/SKILL.md" 'Fixture release skill'
    Write-FixtureText "$repo/skills/ba-bootstrap/SKILL.md" 'Fixture bootstrap skill'
    Write-FixtureText "$repo/install.ps1" ([IO.File]::ReadAllText("$root/install.ps1"))
    $moduleText=[IO.File]::ReadAllText("$root/skills/ba-release/scripts/Install.psm1")
    $discovery=@'
function Get-ReleaseSkillTargets {
    param([switch]$IncludeWsl,[string[]]$WslDistribution,[string]$SkillName='ba-release',[switch]$IncludeNativeAliases)
    return @{agent='claude';platform='local';path=(Join-Path '__FIXTURE_HOME__' ('test-targets/'+$SkillName))}
}
Export-ModuleMember -Function Get-ReleaseSkillTargets,Install-ReleaseSkill
'@
    Write-FixtureText "$repo/skills/ba-release/scripts/Install.psm1" ($moduleText+"`n"+$discovery.Replace('__FIXTURE_HOME__',$f.home.Replace("'","''")))
    $out=& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File "$repo/install.ps1" -Skill ba-bootstrap -CheckOnly 2>&1
    Assert ($LASTEXITCODE -eq 0) "Named check-only failed: $out"
    Assert (-not (Test-Path "$($f.home)/test-targets/ba-bootstrap")) 'Check-only wrote alias.'
    Write-FixtureText "$($f.home)/test-targets/ba-bootstrap" 'conflict'
    $out=& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File "$repo/install.ps1" -Skill all 2>&1
    Assert ($LASTEXITCODE -ne 0 -and -not (Test-Path "$($f.home)/test-targets/ba-release")) 'Second skill conflict left the first skill installed.'
}

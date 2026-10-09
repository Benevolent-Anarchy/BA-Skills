# Discovers user-level agents and links the canonical skill without replacing files.
#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Runs a shell only inside the selected Linux distribution; arguments remain positional.
function Invoke-WslScript([string]$Distribution, [string]$Script, [string[]]$Arguments = @()) {
    $output = & wsl.exe --distribution $Distribution --exec sh -lc $Script -- @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "WSL operation failed in '$Distribution': $output" }
    return (($output -join "`n").Replace([string][char]0, '').Trim())
}

# Uses each runtime's own home and installed executables; never maps a Windows home to Linux.
function Get-ReleaseSkillTargets([switch]$IncludeWsl, [string[]]$WslDistribution = @(), [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')][string]$SkillName='ba-release', [switch]$IncludeNativeAliases) {
    $targets = [Collections.Generic.List[object]]::new()
    $userDirectory = [Environment]::GetFolderPath('UserProfile')
    if (-not $userDirectory) { throw 'Cannot resolve the current user home.' }
    if ($IncludeNativeAliases -or (Get-Command codex -ErrorAction SilentlyContinue)) {
        $targets.Add(@{agent='codex'; platform='local'; path=(Join-Path $userDirectory ".agents/skills/$SkillName")})
    }
    if ($IncludeNativeAliases -or (Get-Command claude -ErrorAction SilentlyContinue)) {
        $claudeDirectory = if ($env:CLAUDE_CONFIG_DIR) { [IO.Path]::GetFullPath($env:CLAUDE_CONFIG_DIR) } else { Join-Path $userDirectory '.claude' }
        $targets.Add(@{agent='claude'; platform='local'; path=(Join-Path $claudeDirectory "skills/$SkillName")})
    }
    if ($IncludeWsl -and $IsWindows -and (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        if ($WslDistribution.Count -eq 0) {
            $listed = & wsl.exe --list --quiet 2>&1
            if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate WSL distributions.' }
            $WslDistribution = @(($listed -join "`n").Replace([string][char]0,'').Split("`n") | ForEach-Object {$_.Trim()} | Where-Object {$_})
        }
        $probe = @'
if command -v codex >/dev/null 2>&1; then printf 'codex\t%s\n' "$HOME/.agents/skills/$1"; fi
if command -v claude >/dev/null 2>&1; then printf 'claude\t%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/$1"; fi
'@
        foreach ($distribution in $WslDistribution) {
            $result = Invoke-WslScript $distribution $probe @($SkillName)
            foreach ($line in $result.Split("`n")) {
                if (-not $line) { continue }
                $fields = $line.Split("`t")
                if ($fields.Count -ne 2 -or $fields[1] -notmatch '^/') { throw 'Invalid WSL discovery result.' }
                $targets.Add(@{agent=$fields[0]; platform='wsl'; distribution=$distribution; path=$fields[1]})
            }
        }
    }
    return $targets.ToArray()
}

# Preflights the complete target set, then creates only missing links; repeated runs are no-ops.
function Install-ReleaseSkill([string]$Source, [object[]]$Targets, [switch]$CheckOnly, [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')][string]$SkillName='ba-release') {
    $sourceItem = Get-Item -LiteralPath $Source
    if (-not $sourceItem.PSIsContainer -or -not (Test-Path -LiteralPath (Join-Path $Source 'SKILL.md') -PathType Leaf)) { throw 'Canonical SKILL.md is missing.' }
    $canonical = if ($sourceItem.LinkType) { $sourceItem.ResolveLinkTarget($true).FullName } else { $sourceItem.FullName }
    $inspected = [Collections.Generic.List[object]]::new()
    foreach ($target in $Targets) {
        $record = @{} + $target
        $record.status = 'missing'
        if ($target.platform -eq 'wsl') {
            $linuxSource = Invoke-WslScript $target.distribution 'wslpath -a -u "$1"' @($canonical)
            $probe = @'
if [ ! -f "$1/SKILL.md" ]; then printf 'source-missing'; exit 0; fi
parent=$(dirname -- "$2")
while [ ! -e "$parent" ] && [ ! -L "$parent" ]; do parent=$(dirname -- "$parent"); done
if [ ! -d "$parent" ]; then printf 'conflict-parent'; exit 0; fi
if [ "$3" = codex ]; then
  legacy=${4:-${CODEX_HOME:-$HOME/.codex}/skills/$5}
  if [ -e "$legacy" ] || [ -L "$legacy" ]; then
    if [ ! -L "$legacy" ] || [ "$(readlink -f -- "$legacy")" != "$(readlink -f -- "$1")" ]; then printf 'conflict-legacy'; exit 0; fi
  fi
fi
if [ -e "$2" ] || [ -L "$2" ]; then
  if [ -L "$2" ] && [ "$(readlink -f -- "$2")" = "$(readlink -f -- "$1")" ]; then printf 'already-linked'; else printf 'conflict'; fi
else printf 'missing'; fi
'@
            $legacyPath = if ($target.Contains('legacyPath')) {$target.legacyPath} else {''}
            $record.status = Invoke-WslScript $target.distribution $probe @($linuxSource,$target.path,$target.agent,$legacyPath,$SkillName)
            $record.source = $linuxSource
            if ($record.status -notin @('missing','already-linked')) { throw "Installation conflict at $($target.distribution):$($target.path) ($($record.status)). Nothing was replaced." }
        } elseif ($target.platform -eq 'local') {
            $record.source = $canonical
            $ancestorPath = Split-Path ([IO.Path]::GetFullPath($target.path)) -Parent
            while ($ancestorPath) {
                $ancestor = Get-Item -LiteralPath $ancestorPath -Force -ErrorAction SilentlyContinue
                if ($ancestor) {
                    if (-not $ancestor.PSIsContainer -or ($ancestor.LinkType -and -not $ancestor.ResolveLinkTarget($true))) { throw "Installation conflict at parent directory $ancestorPath." }
                    break
                }
                $nextAncestor = Split-Path $ancestorPath -Parent
                if ($nextAncestor -eq $ancestorPath) { throw "Installation conflict at parent directory $ancestorPath." }
                $ancestorPath = $nextAncestor
            }
            $item = Get-Item -LiteralPath $target.path -Force -ErrorAction SilentlyContinue
            if ($null -ne $item) {
                $resolved = if ($item.LinkType) { $item.ResolveLinkTarget($true) } else { $null }
                if ($null -eq $resolved -or $resolved.FullName -cne $canonical) {
                    if (-not ($IsWindows -and $null -ne $resolved -and $resolved.FullName -ieq $canonical)) {
                        throw "Installation conflict at $($target.path). Existing files, directories and wrong links are preserved."
                    }
                }
                $record.status = 'already-linked'
            }
            # Detect conflicting legacy Codex aliases without writing another copy there.
            if ($target.agent -eq 'codex') {
                $legacyRoot = if ($env:CODEX_HOME) {$env:CODEX_HOME} else {Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'}
                $legacyPath = if ($target.Contains('legacyPath')) {$target.legacyPath} else {Join-Path $legacyRoot "skills/$SkillName"}
                $legacy = Get-Item -LiteralPath $legacyPath -Force -ErrorAction SilentlyContinue
                if ($legacy) {
                    $resolvedLegacy = if ($legacy.LinkType) {$legacy.ResolveLinkTarget($true)} else {$null}
                    if (-not $resolvedLegacy -or $resolvedLegacy.FullName -ne $canonical) { throw "Installation conflict at legacy Codex path $legacyPath." }
                }
            }
        } else { throw "Unknown installation platform '$($target.platform)'." }
        $inspected.Add($record)
    }
    foreach ($record in $inspected) {
        if ($record.status -eq 'missing' -and -not $CheckOnly) {
            if ($record.platform -eq 'wsl') {
                $install = @'
mkdir -p -- "$(dirname -- "$2")"
ln -s -- "$1" "$2"
'@
                Invoke-WslScript $record.distribution $install @($record.source,$record.path) | Out-Null
            } else {
                New-Item -ItemType Directory -Path (Split-Path $record.path -Parent) -Force | Out-Null
                New-Item -ItemType $(if ($IsWindows) {'Junction'} else {'SymbolicLink'}) -Path $record.path -Target $canonical | Out-Null
            }
            $record.status = 'installed'
        }
        [pscustomobject]$record
    }
}
Export-ModuleMember -Function Get-ReleaseSkillTargets,Install-ReleaseSkill

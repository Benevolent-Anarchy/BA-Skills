# Runs ba-release integration contracts entirely in disposable local repositories.
#requires -Version 7.2
[CmdletBinding()]
param([string]$Filter = '*')
$ErrorActionPreference = 'Stop'
$script:Passed = 0
$script:Failed = 0
$root = Split-Path $PSScriptRoot -Parent
$module = Join-Path $root 'skills/ba-release/scripts/Release.psm1'
$installer = Join-Path $root 'skills/ba-release/scripts/Install.psm1'
if (-not (Test-Path $module) -or -not (Test-Path $installer)) {
    throw 'Required behavior is missing: release and installation modules do not exist.'
}
Import-Module $module -Force
Import-Module $installer -Force
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('ba-release-tests-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $sandbox | Out-Null

function Assert($condition, [string]$message) {
    if (-not $condition) { throw $message }
}
function Expect-Error([scriptblock]$action, [string]$pattern) {
    $caught = $null
    try { & $action | Out-Null } catch { $caught = $_.Exception.Message }
    Assert ($null -ne $caught -and $caught -match $pattern) "Expected '$pattern', got '$caught'."
}
function Test([string]$name, [scriptblock]$body) {
    if ($name -notlike $Filter) {return}
    try { & $body; $script:Passed++; Write-Output "PASS $name" }
    catch { $script:Failed++; Write-Output "FAIL $name : $($_.Exception.Message)" }
}
function Write-Json($path, $value) {
    $value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
}
function Invoke-FixtureGit($repo, [string[]]$arguments) {
    $result = & git -C $repo @arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Fixture git failed: $result" }
    return ($result -join "`n")
}
function New-Fixture([string]$name) {
    $repo = Join-Path $sandbox $name
    New-Item -ItemType Directory -Path $repo | Out-Null
    Invoke-FixtureGit $repo @('init','--quiet','--initial-branch=main') | Out-Null
    Invoke-FixtureGit $repo @('config','user.email','fixture@example.invalid') | Out-Null
    Invoke-FixtureGit $repo @('config','user.name','Release fixture') | Out-Null
    Invoke-FixtureGit $repo @('remote','add','origin','https://github.com/Example/Real-Game.git') | Out-Null
    @'
[application]
config/name="Fixture"
config/version="1.2.3"
'@ | Set-Content -LiteralPath (Join-Path $repo 'project.godot')
    @'
[preset.0]
name="Windows existing"
platform="Windows Desktop"
export_path="dist/windows/Game.exe"
[preset.0.options]
binary_format/architecture="x86_64"
[preset.1]
name="Linux existing"
platform="Linux"
export_path="dist/linux/Game.x86_64"
'@ | Set-Content -LiteralPath (Join-Path $repo 'export_presets.cfg')
    New-Item -ItemType Directory -Path (Join-Path $repo 'tools') | Out-Null
    '# Verification fixture: succeeds without external effects.' | Set-Content (Join-Path $repo 'tools/verify.ps1')
    @'
param([string]$ArtifactDirectory)
if (Get-ChildItem $ArtifactDirectory -Recurse -File | Where-Object {$_.Name -like 'steam_api*.dll'}) {exit 12}
if (-not (Get-ChildItem $ArtifactDirectory -File | Where-Object {($_.Name -like '*.exe' -or $_.Name -like '*.x86_64') -and (Get-Content $_.FullName -Raw) -match 'exported game'})) {exit 13}
exit 0
'@ | Set-Content (Join-Path $repo 'tools/standalone.ps1')
    $config = [ordered]@{
        schemaVersion=1;project='.';previousRelease='v1.2.2';androidVersionCodePolicy='existing'
        exports=[ordered]@{windows='Windows existing';linux='Linux existing'}
        verification=@{gate=@{script='tools/verify.ps1';arguments=@()};standalone=@{exports=@('windows','linux');script='tools/standalone.ps1';arguments=@('{artifact}')}}
        distributions=[ordered]@{
            itch=@{game='example/real-game';channels=[ordered]@{windows='windows';linux='linux'};ignore=@('steam_api*.dll','libsteam_api.so','libgodotsteam.*','steam_appid.txt')}
            notes=$true
        }
    }
    Write-Json (Join-Path $repo 'release.json') $config
    Invoke-FixtureGit $repo @('add','.') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Previous published release') | Out-Null
    Invoke-FixtureGit $repo @('tag','v1.2.2') | Out-Null
    'player-visible fix' | Set-Content (Join-Path $repo 'fix.txt')
    Invoke-FixtureGit $repo @('add','fix.txt') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Fix controller focus') | Out-Null
    return $repo
}
function Change-Config($repo, [scriptblock]$change) {
    $config = Get-Content (Join-Path $repo 'release.json') -Raw | ConvertFrom-Json -AsHashtable
    & $change $config
    Write-Json (Join-Path $repo 'release.json') $config
}

Test 'installation is idempotent and retains unrelated skills' {
    $source = Join-Path $sandbox 'canonical'; New-Item -ItemType Directory $source | Out-Null
    'skill' | Set-Content (Join-Path $source 'SKILL.md')
    $discovery = Join-Path $sandbox 'discovery'; New-Item -ItemType Directory $discovery | Out-Null
    'keep' | Set-Content (Join-Path $discovery 'other.txt')
    $targets = @(@{ agent='codex'; path=(Join-Path $discovery 'ba-release'); platform='local' })
    $first = @(Install-ReleaseSkill -Source $source -Targets $targets)
    $second = @(Install-ReleaseSkill -Source $source -Targets $targets)
    Assert ($first[0].status -eq 'installed' -and $second[0].status -eq 'already-linked') 'Repeat did not reuse link.'
    Assert ((Get-Content (Join-Path $discovery 'other.txt')) -eq 'keep') 'Other skill changed.'
    Assert ((Get-Item $targets[0].path).LinkType -in @('Junction','SymbolicLink')) 'Skill was copied instead of linked.'
}
Test 'all conflicts are preflighted before any new link' {
    $source = Join-Path $sandbox 'canonical'
    $conflict = Join-Path $sandbox 'conflicting-file'; 'keep' | Set-Content $conflict
    $newLink = Join-Path $sandbox 'must-not-exist/ba-release'
    Expect-Error { Install-ReleaseSkill $source @(@{path=$newLink;platform='local';agent='codex'},@{path=$conflict;platform='local';agent='claude'}) } 'conflict'
    Assert (-not (Test-Path $newLink)) 'A link was installed despite another conflict.'
    Assert ((Get-Content $conflict) -eq 'keep') 'Conflict was overwritten.'
}
Test 'conflicting parent files are detected before any installation' {
    $source = Join-Path $sandbox 'canonical'
    $parentFile = Join-Path $sandbox 'parent-is-file'; 'keep parent' | Set-Content $parentFile
    $newLink = Join-Path $sandbox 'ancestor-preflight/ba-release'
    $caught = $false
    try { Install-ReleaseSkill $source @(@{path=$newLink;platform='local';agent='claude'},@{path=(Join-Path $parentFile 'ba-release');platform='local';agent='claude'}) | Out-Null } catch { $caught=$true }
    Assert $caught 'Conflicting parent did not fail installation.'
    Assert (-not (Test-Path $newLink)) 'Installer mutated a first link before discovering a parent-file conflict.'
    Assert ((Get-Content $parentFile) -eq 'keep parent') 'Existing parent file changed.'
}
Test 'wrong and dangling links are preserved and rejected' {
    $wrong = Join-Path $sandbox 'wrong-target'; New-Item -ItemType Directory $wrong | Out-Null
    $link = Join-Path $sandbox 'wrong-link'
    New-Item -ItemType $(if ($IsWindows) {'Junction'} else {'SymbolicLink'}) -Path $link -Target $wrong | Out-Null
    Expect-Error { Install-ReleaseSkill (Join-Path $sandbox 'canonical') @(@{path=$link;platform='local';agent='codex'}) } 'conflict'
    Assert ((Get-Item $link).ResolveLinkTarget($true).FullName -eq $wrong) 'Wrong link changed.'
}
Test 'read-only plan uses Godot version, history, explicit selection and derived notes repo' {
    $repo = New-Fixture 'plan'
    $before = Invoke-FixtureGit $repo @('status','--porcelain=v1','--untracked-files=all')
    $filesBefore = @(Get-ChildItem $repo -Recurse -File -Force | ForEach-Object { "$($_.FullName):$((Get-FileHash $_.FullName).Hash)" })
    $plan = Get-ReleasePlan -Repository $repo -Destination @('itch-windows','notes')
    Assert ($plan.version -eq '1.2.3') 'Wrong version source.'
    Assert ($plan.notesRepository -eq 'Example/Real-Game-release-notes') 'Notes name not derived from remote.'
    Assert ($plan.changes.Count -eq 1 -and $plan.changes[0].subject -eq 'Fix controller focus') 'Wrong release boundary.'
    Assert ($plan.destinations[1].status -eq 'not-selected') 'Unselected destination was scheduled.'
    Assert ($plan.blockers.Count -eq 0) "Unexpected blockers: $($plan.blockers -join ', ')"
    Assert ($before -eq (Invoke-FixtureGit $repo @('status','--porcelain=v1','--untracked-files=all'))) 'Plan changed Git status.'
    $filesAfter = @(Get-ChildItem $repo -Recurse -File -Force | ForEach-Object { "$($_.FullName):$((Get-FileHash $_.FullName).Hash)" })
    Assert (($filesBefore -join "`n") -eq ($filesAfter -join "`n")) 'Plan wrote files.'
    Assert ((Get-ReleasePlan $repo @('notes','itch-windows')).planId -eq $plan.planId) 'Plan identity depends on selection order.'
}
Test 'missing publication facts block planning without inventing values' {
    $repo = New-Fixture 'missing'
    Change-Config $repo { param($c) $c.previousRelease=$null; $c.distributions.itch.game=$null }
    $plan = Get-ReleasePlan $repo @('itch-windows')
    Assert (($plan.blockers -join ' ') -match 'previousRelease' -and ($plan.blockers -join ' ') -match 'target') 'Missing facts not reported.'
    Assert ($plan.changes.Count -eq 0) 'Invented previous release.'
    Expect-Error { Get-ReleasePlan $repo @('made-up') } 'Unknown destination'
}
Test 'read-only planning does not refresh Git index stat data' {
    $repo = New-Fixture 'index-read-only'
    $indexPath = Join-Path $repo '.git/index'
    $indexHash = (Get-FileHash $indexPath).Hash
    $file = Get-Item (Join-Path $repo 'fix.txt')
    $file.LastWriteTimeUtc=$file.LastWriteTimeUtc.AddMinutes(5)
    $plan = Get-ReleasePlan $repo @('notes')
    Assert $plan.ready 'Timestamp-only difference should not make source dirty.'
    Assert ((Get-FileHash $indexPath).Hash -eq $indexHash) 'Read-only plan rewrote Git index cache data.'
}
Test 'validation rejects nonexistent presets, escaping paths, unknown settings and credentials' {
    $repo = New-Fixture 'invalid'
    $original = Get-Content (Join-Path $repo 'release.json') -Raw
    foreach ($case in @(
        @{change={param($c) $c.exports.windows='Invented preset'}; error='preset'},
        @{change={param($c) $c.project='../outside'}; error='inside'},
        @{change={param($c) $c.token='secret'}; error='credential|Unknown'},
        @{change={param($c) $c.verification.gate.arguments=@('--password','secret')}; error='credential'},
        @{change={param($c) $c.schemaVersion=9}; error='schemaVersion'},
        @{change={param($c) $c.version='9.9.9'}; error='Unknown'}
    )) {
        $original | Set-Content (Join-Path $repo 'release.json')
        Change-Config $repo $case.change
        Expect-Error { Get-ReleaseConfiguration $repo } $case.error
    }
}
Test 'ref must resolve to an ancestor and empty selection never means all' {
    $repo = New-Fixture 'refs'
    $plan = Get-ReleasePlan $repo @()
    Assert ($plan.selectedDestinations.Count -eq 0 -and ($plan.blockers -join ' ') -match 'Select') 'Empty selection published all.'
    Change-Config $repo {param($c) $c.previousRelease='missing-ref'}
    Expect-Error { Get-ReleasePlan $repo @('notes') } 'ref'
}

# The executable fixtures replace only the external export/upload/API boundary.
$engine = Join-Path $sandbox 'engine.ps1'
@'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
$index = [Array]::IndexOf($Rest,'--export-release')
if ($index -lt 0) { exit 3 }
$output = $Rest[$index+2]
if ($env:BA_FIXTURE_EXPORT_LOG) {Add-Content $env:BA_FIXTURE_EXPORT_LOG $Rest[$index+1]}
New-Item -ItemType Directory (Split-Path $output -Parent) -Force | Out-Null
'exported game' | Set-Content -LiteralPath $output
if ($output.EndsWith('.apk')) { 'optional signature fixture' | Set-Content -LiteralPath ($output+'.idsig'); exit 0 }
'steam fixture' | Set-Content (Join-Path (Split-Path $output -Parent) 'steam_api64.dll')
'sidecar' | Set-Content -LiteralPath ($output + '.pck')
exit 0
'@ | Set-Content $engine
$butler = Join-Path $sandbox 'butler.ps1'
@'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
if ($Rest -notcontains '--ignore' -or $Rest -notcontains '--userversion') { exit 9 }
if ($Rest -contains '--dry-run') {
    if ($env:BA_FIXTURE_BAD_SELECTION) {'steam_api64.dll';exit 0}
    if (Test-Path -LiteralPath $Rest[1] -PathType Leaf) {[IO.Path]::GetFileName($Rest[1]);exit 0}
    Get-ChildItem $Rest[1] -Recurse -File | Where-Object {$_.Name -notlike 'steam_api*.dll'} | ForEach-Object {[IO.Path]::GetRelativePath($Rest[1],$_.FullName).Replace('\','/')}
    exit 0
}
if ($Rest -contains 'example/real-game:linux' -and -not $env:BA_FIXTURE_ALLOW_LINUX) { exit 7 }
exit 0
'@ | Set-Content $butler
if ($IsWindows) {('@"'+(Join-Path $PSHOME 'pwsh.exe')+'" -NoProfile -File "'+$butler+'" %*') | Set-Content (Join-Path $sandbox 'butler.cmd')}
else {("#!/bin/sh`nexec pwsh -NoProfile -File '"+$butler+"' `"`$@`"") | Set-Content (Join-Path $sandbox 'butler'); & chmod +x (Join-Path $sandbox 'butler')}
$env:PATH=$sandbox+[IO.Path]::PathSeparator+$env:PATH
Test 'prepare resumes at the same version and publish reports partial failures per destination' {
    $repo = New-Fixture 'lifecycle'
    $stateRoot = Join-Path $sandbox 'state'
    $prepared = Invoke-ReleasePrepare $repo @('itch-windows','itch-linux') $stateRoot $engine
    Assert ($prepared.status -eq 'prepared') "Prepare failed: $($prepared.status)"
    $state = Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($state.artifacts.Count -eq 2) 'Artifacts missing.'
    $versionHash = (Get-FileHash (Join-Path $repo 'project.godot')).Hash
    $again = Invoke-ReleasePrepare $repo @('itch-linux','itch-windows') $stateRoot $engine
    Assert ($again.statePath -eq $prepared.statePath) 'Resume created a second release.'
    Assert ((Get-FileHash (Join-Path $repo 'project.godot')).Hash -eq $versionHash) 'Version changed.'
    Expect-Error { Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler } 'approval'
    $notesHash = (Get-FileHash (Join-Path $prepared.statePath 'notes.md') -Algorithm SHA256).Hash.ToLowerInvariant()
    $result = Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 $notesHash
    Assert ($result.status -eq 'partial-failure') 'Partial failure was reported as success.'
    Assert ($result.destinations['itch-windows'].status -eq 'succeeded') 'Windows success lost.'
    Assert ($result.destinations['itch-linux'].status -eq 'failed') 'Linux failure hidden.'
    $env:BA_FIXTURE_ALLOW_LINUX='1'
    try { $result = Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler } finally { Remove-Item Env:BA_FIXTURE_ALLOW_LINUX }
    Assert ($result.status -eq 'published') 'Retry failed.'
    Assert ($result.destinations['itch-windows'].attempts -eq 1 -and $result.destinations['itch-linux'].attempts -eq 2) 'Retry repeated successful upload.'
    Add-Content (Join-Path $prepared.statePath 'notes.md') 'Changed after approval'
    Expect-Error { Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler } 'approval'
}
Test 'artifact tampering and interrupted publication cannot silently resume' {
    $repo = New-Fixture 'tamper'
    $prepared = Invoke-ReleasePrepare $repo @('itch-windows') (Join-Path $sandbox 'tamper-state') $engine
    $stateFile = Join-Path $prepared.statePath 'state.json'
    $state = Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    $hash = (Get-FileHash (Join-Path $prepared.statePath 'notes.md')).Hash.ToLowerInvariant()
    $state.destinations['itch-windows'].status='in-progress'
    Write-Json $stateFile $state
    $result = Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 $hash
    Assert ($result.destinations['itch-windows'].status -eq 'uncertain') 'Interrupted upload claimed success or was repeated.'
    Assert ($result.destinations['itch-windows'].attempts -eq 0) 'Uncertain upload was automatically retried.'
    $file = Join-Path $prepared.statePath $state.artifacts[0].files[0].path
    Add-Content $file 'tampered'
    Expect-Error { Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -RetryUncertain } 'artifact'
}

$gh = Join-Path $sandbox 'github.ps1'
@'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
if ($Rest -notcontains '--hostname' -or $Rest -notcontains 'github.com' -or ($Rest -join ' ') -notmatch 'repos/Example/Real-Game-release-notes') { exit 13 }
$store=if (($Rest -join ' ') -match '/contents/availability/') {$env:BA_FIXTURE_NOTE_STORE+'.availability'} else {$env:BA_FIXTURE_NOTE_STORE}
if ($Rest -contains 'PUT') {
    $inputIndex = [Array]::IndexOf($Rest,'--input')
    $body = Get-Content -LiteralPath $Rest[$inputIndex+1] -Raw | ConvertFrom-Json
    [IO.File]::WriteAllText($store,[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($body.content)))
    '{"content":{"sha":"fixture-commit"}}'; exit 0
}
if (($Rest -join ' ') -notmatch '/contents/') {
    @{private=($env:BA_FIXTURE_PRIVATE -eq '1');permissions=@{push=($env:BA_FIXTURE_NO_PUSH -ne '1')}} | ConvertTo-Json -Compress; exit 0
}
if (Test-Path -LiteralPath $store) {
    @{sha='fixture-old-sha';encoding='base64';content=[Convert]::ToBase64String([IO.File]::ReadAllBytes($store))} | ConvertTo-Json -Compress
    exit 0
}
Write-Output 'HTTP 404: Not Found'; exit 1
'@ | Set-Content $gh
Test 'notes are approval gated, public, idempotent and never overwrite different content' {
    $repo = New-Fixture 'public-notes'
    $prepared = Invoke-ReleasePrepare $repo @('itch-windows','notes') (Join-Path $sandbox 'note-state') $engine
    $state = Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($state.artifacts.Count -eq 1) 'Prepared release exported an unexpected build.'
    $env:BA_FIXTURE_NOTE_STORE = Join-Path $sandbox 'remote-note.md'
    $notesPath = Join-Path $prepared.statePath 'notes.md'
    $hash = (Get-FileHash $notesPath).Hash.ToLowerInvariant()
    try {
        Expect-Error { Invoke-ReleasePublish -StatePath $prepared.statePath -GhExecutable $gh } 'approval'
        Assert (-not (Test-Path $env:BA_FIXTURE_NOTE_STORE)) 'Unapproved notes were published.'
        $env:BA_FIXTURE_PRIVATE='1'
        $result = Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -GhExecutable $gh -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 $hash
        Assert ($result.destinations.notes.status -eq 'failed' -and -not (Test-Path $env:BA_FIXTURE_NOTE_STORE)) 'Private notes repo was published to.'
        Remove-Item Env:BA_FIXTURE_PRIVATE
        'conflicting existing public notes' | Set-Content $env:BA_FIXTURE_NOTE_STORE
        $conflictHash = (Get-FileHash $env:BA_FIXTURE_NOTE_STORE).Hash
        $result = Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -GhExecutable $gh
        Assert ($result.destinations.notes.status -eq 'failed') 'Conflicting notes were called successful.'
        Assert ((Get-FileHash $env:BA_FIXTURE_NOTE_STORE).Hash -eq $conflictHash) 'Existing public note content was overwritten.'
        [IO.File]::WriteAllText($env:BA_FIXTURE_NOTE_STORE,[IO.File]::ReadAllText($notesPath))
        $result = Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -GhExecutable $gh
        Assert ($result.status -eq 'published') 'Identical existing notes were not recognized.'
        $again = Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -GhExecutable $gh
        Assert ($again.destinations.notes.attempts -eq 1) 'Published notes were unnecessarily repeated.'
    } finally {
        Remove-Item Env:BA_FIXTURE_PRIVATE -ErrorAction SilentlyContinue
        Remove-Item Env:BA_FIXTURE_NOTE_STORE -ErrorAction SilentlyContinue
    }
}
Test 'notes writer creates exactly the approved UTF-8 text in a new public file' {
    $repo = New-Fixture 'new-notes'
    $prepared = Invoke-ReleasePrepare $repo @('itch-windows','notes') (Join-Path $sandbox 'new-note-state') $engine
    $state = Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    $notesPath = Join-Path $prepared.statePath 'notes.md'
    [IO.File]::WriteAllText($notesPath,"# Release`n`n- 控制器修复 — improved focus.`n`n[Release availability](../availability/1.2.3.json)`n",[Text.UTF8Encoding]::new($false))
    $env:BA_FIXTURE_NOTE_STORE=Join-Path $sandbox 'new-remote-note.md'
    try {
        $result = Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -GhExecutable $gh -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-FileHash $notesPath).Hash.ToLowerInvariant()
        Assert ($result.status -eq 'published') 'New public note failed.'
        Assert ([IO.File]::ReadAllText($env:BA_FIXTURE_NOTE_STORE) -ceq [IO.File]::ReadAllText($notesPath)) 'Published notes differed from approved content.'
    } finally { Remove-Item Env:BA_FIXTURE_NOTE_STORE }
}
Test 'prepare refuses dirty sources and changed same-version selection' {
    $repo = New-Fixture 'preconditions'
    $stateRoot = Join-Path $sandbox 'precondition-state'
    'uncommitted change' | Add-Content (Join-Path $repo 'fix.txt')
    Expect-Error { Invoke-ReleasePrepare $repo @('notes') $stateRoot } 'uncommitted'
    Assert (-not (Test-Path $stateRoot)) 'Blocked plan created preparation state.'
    Invoke-FixtureGit $repo @('checkout','--','fix.txt') | Out-Null
    $prepared = Invoke-ReleasePrepare $repo @('notes') $stateRoot
    Expect-Error { Invoke-ReleasePrepare $repo @('itch-windows') $stateRoot $engine } 'different release plan'
    $state = Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($state.plan.selectedDestinations.Count -eq 1 -and $state.plan.selectedDestinations[0] -eq 'notes') 'Original selection was replaced.'
}
Test 'validation rejects duplicate keys, malformed origin and symlink escape' {
    $repo = New-Fixture 'duplicate-path'
    $original = Get-Content (Join-Path $repo 'release.json') -Raw
    $original.Replace('"schemaVersion": 1','"schemaVersion": 1, "schemaVersion": 1') | Set-Content (Join-Path $repo 'release.json')
    Expect-Error { Get-ReleaseConfiguration $repo } 'Duplicate'
    $original | Set-Content (Join-Path $repo 'release.json')
    Invoke-FixtureGit $repo @('remote','set-url','origin','https://user:password@github.com/Example/Real-Game.git') | Out-Null
    Expect-Error { Get-ReleaseConfiguration $repo } 'credential-free'
    Invoke-FixtureGit $repo @('remote','set-url','origin','https://github.com/Example/Real-Game.git') | Out-Null
    $outside = Join-Path $sandbox 'outside'; New-Item -ItemType Directory $outside | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'tools/verify.ps1') -Destination (Join-Path $outside 'verify.ps1')
    New-Item -ItemType $(if ($IsWindows) {'Junction'} else {'SymbolicLink'}) -Path (Join-Path $repo 'escape') -Target $outside | Out-Null
    Change-Config $repo {param($c) $c.verification.gate.script='escape/verify.ps1'}
    Expect-Error { Get-ReleaseConfiguration $repo } 'inside'
}

if ($IsWindows -and (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    $available = ((& wsl.exe --list --quiet) -join "`n").Replace([string][char]0,'').Split("`n") | ForEach-Object {$_.Trim()} | Where-Object {$_}
    if ($available) {
        $distribution = @($available)[0]
        Test 'WSL links the same Windows canonical skill and refuses Linux conflicts' {
            $linuxRoot = '/tmp/ba-release-tests-' + [guid]::NewGuid().ToString('N')
            $source = Join-Path $sandbox 'canonical'
            $linuxLink = "$linuxRoot/discovery/ba-release"
            $target = @{agent='claude';platform='wsl';distribution=$distribution;path=$linuxLink}
            $first = @(Install-ReleaseSkill $source @($target))
            $again = @(Install-ReleaseSkill $source @($target))
            Assert ($first[0].status -eq 'installed' -and $again[0].status -eq 'already-linked') 'WSL repeat did not reuse the canonical symlink.'
            $content = & wsl.exe --distribution $distribution --exec cat "$linuxLink/SKILL.md"
            Assert ($LASTEXITCODE -eq 0 -and ($content -join '').Trim() -eq 'skill') 'WSL link does not read the Windows canonical file.'
            & wsl.exe --distribution $distribution --exec sh -lc 'printf keep > "$1/conflict"' -- $linuxRoot
            $newLocal = Join-Path $sandbox 'wsl-conflict-preflight/ba-release'
            Expect-Error { Install-ReleaseSkill $source @(@{agent='codex';platform='local';path=$newLocal},@{agent='claude';platform='wsl';distribution=$distribution;path="$linuxRoot/conflict"}) } 'conflict'
            Assert (-not (Test-Path $newLocal)) 'Native link changed despite WSL conflict.'
            & wsl.exe --distribution $distribution --exec sh -lc 'mkdir -p -- "$1/legacy"; printf keep > "$1/legacy/ba-release"' -- $linuxRoot
            $beforeLegacy = Join-Path $sandbox 'wsl-legacy-preflight/ba-release'
            Expect-Error { Install-ReleaseSkill $source @(@{agent='claude';platform='local';path=$beforeLegacy},@{agent='codex';platform='wsl';distribution=$distribution;path="$linuxRoot/modern/ba-release";legacyPath="$linuxRoot/legacy/ba-release"}) } 'conflict'
            Assert (-not (Test-Path $beforeLegacy)) 'Native link changed despite WSL legacy conflict.'
        }
    }
}
# Adds inspected-format store settings; fixture transports replace only remote boundaries.
function New-StoreFixture([string]$name) {
    $repo = New-Fixture $name
    @'
[preset.2]
name="Android existing AAB"
platform="Android"
export_path="dist/android/Game.aab"
[preset.2.options]
version/code=12
version/name=""
package/unique_name="com.example.realgame"
package/signed=true
gradle_build/use_gradle_build=true
gradle_build/export_format=1
'@ | Add-Content (Join-Path $repo 'export_presets.cfg')
    Change-Config $repo {param($c)
        $c.exports.aab='Android existing AAB'
        $c.distributions.steam=@{appId=100;branch='default';exclude=@('*.pdb');depots=[ordered]@{'101'='windows';'102'='linux'}}
        $c.distributions['google-play']=@{export='aab';track='production';releaseStatus='completed';language='en-US';retainVersionCodes=@('11')}
    }
    Invoke-FixtureGit $repo @('add','release.json','export_presets.cfg') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Configure inspected store exports') | Out-Null
    return $repo
}
function Add-FixtureApk([string]$repo) {
    @'
[preset.3]
name="Android existing APK"
platform="Android"
export_path="dist/android/Game.apk"
[preset.3.options]
version/code=3
version/name=""
package/unique_name="com.example.realgame"
package/signed=true
gradle_build/use_gradle_build=false
gradle_build/export_format=0
'@ | Add-Content (Join-Path $repo 'export_presets.cfg')
    Change-Config $repo {param($c)
        $c.exports.apk='Android existing APK'
        $c.distributions.itch.channels.windows=@{export='windows';displayNameTemplate='{title} {version} ({os})'}
        $c.distributions.itch.channels.android=@{export='apk';displayNameTemplate='{title} {version} ({os})'}
        $c.androidVersionCodePolicy='increment-selected'
    }
    Invoke-FixtureGit $repo @('add','.') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Configure independent Android counters') | Out-Null
}
$steam = Join-Path $sandbox 'steamcmd.ps1'
@'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
$index=[Array]::IndexOf($Rest,'+run_app_build')
if ($index -lt 0 -or $Rest -notcontains '+login') {exit 4}
$appFile=$Rest[$index+1]
$vdf=[IO.File]::ReadAllText($appFile)
if ($vdf -notmatch '"AppID"\s+"100"' -or $vdf -notmatch '"SetLive"\s+""') {exit 5}
$directory=Split-Path $appFile -Parent
foreach ($id in @('101','102')) {
    $depot=[IO.File]::ReadAllText((Join-Path $directory "depot_$id.vdf"))
    if ($depot -notmatch '"FileExclusion"\s+"\*\.pdb"') {exit 6}
}
if ($env:BA_FIXTURE_STEAM_FALSE_SUCCESS) { 'ERROR! App build failed.'; exit 0 }
if ($env:BA_FIXTURE_STEAM_LATE_ERROR) { 'Successfully finished AppID 100 build (BuildID 999).';exit 9 }
'Successfully finished AppID 100 build (BuildID 999).'; exit 0
'@ | Set-Content $steam
function New-PlayServer {
    $server = @{calls=[Collections.Generic.List[object]]::new();bundles=@();uploads=0;commits=0;failCommit=$false;creates=0;expired=$false;deletes=0;failDelete=$false;workTrack=@{track='production';releases=@(@{versionCodes=@('11')})};deployedTrack=@{track='production';releases=@(@{versionCodes=@('11')})}}
    $handler = {param($request)
        $server.calls.Add($request)
        if ($request.uri -notmatch '^https://androidpublisher\.googleapis\.com/') {throw 'Wrong API host.'}
        if ($request.uri -match '/edits$' -and $request.method -eq 'POST') {$server.creates++;$server.workTrack=$server.deployedTrack;return @{id="edit-$($server.creates)"}}
        if ($request.uri -match '/edits/edit-([0-9]+)$') {
            if ($request.method -eq 'DELETE') {$server.deletes++;if ($server.failDelete) {throw 'Fixture cleanup unavailable.'};return @{}}
            if ($Matches[1] -eq '1' -and $server.expired) {$error404=[Exception]::new('Fixture edit not found.');$error404.Data['statusCode']=404;throw $error404}
            return @{id="edit-$($Matches[1])"}
        }
        if ($request.uri -match '/bundles\?uploadType=media$') {
            $server.uploads++
            $bundle=@{versionCode=12;sha256=(Get-FileHash $request.file).Hash.ToLowerInvariant()}
            $server.bundles=@($bundle); return $bundle
        }
        if ($request.uri -match '/bundles$') {return @{bundles=$server.bundles}}
        if ($request.uri -match '/tracks/production$') {
            if ($request.method -eq 'PUT') {
                if ($request.body.releases[0].versionCodes -notcontains '11' -or $request.body.releases[0].versionCodes -notcontains '12') {throw 'Track update dropped explicitly retained version codes.'}
                if ($request.body.releases[0].name -ne '1.2.3') {throw 'Play release name did not use Godot version.'}
                if ($request.body.releases[0].releaseNotes[0].language -ne 'en-US') {throw 'Wrong release-note locale.'}
                $server.workTrack=$request.body
            }
            return $server.workTrack
        }
        if ($request.uri -match ':validate$') {return @{id='edit-1'}}
        if ($request.uri -match ':commit\?changesInReviewBehavior=ERROR_IF_IN_REVIEW$') {
            $server.commits++
            if ($server.failCommit) {$server.failCommit=$false; throw 'Simulated lost commit response.'}
            $server.deployedTrack=$server.workTrack
            return @{id='edit-1'}
        }
        throw "Unexpected fixture API operation: $($request.method) $($request.uri)"
    }.GetNewClosure()
    return @{server=$server;handler=$handler}
}
Test 'store planning derives Android package/code and includes Steam depots without default selection' {
    $repo = New-StoreFixture 'store-plan'
    $plan = Get-ReleasePlan $repo @('steam','google-play')
    Assert $plan.ready 'Inspected multi-store plan did not validate.'
    $play = @($plan.destinations | Where-Object id -EQ 'google-play')[0]
    Assert ($play.packageName -eq 'com.example.realgame' -and $play.versionCode -eq 12) 'Android metadata was invented instead of read.'
    $steamPlan = @($plan.destinations | Where-Object id -EQ 'steam')[0]
    Assert ($steamPlan.appId -eq 100 -and $steamPlan.depots.Count -eq 2 -and $steamPlan.branch -eq 'default') 'Steam configuration missing from plan.'
    Assert ($plan.destinations[0].status -eq 'not-selected') 'Selecting stores also selected itch.'
}
Test 'store publication separates uploaded Steam from submitted Play and resumes without repeating uploads' {
    $repo = New-StoreFixture 'stores-publish'
    $prepared = Invoke-ReleasePrepare $repo @('itch-windows','steam','google-play') (Join-Path $sandbox 'stores-state') $engine
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($state.artifacts.Count -eq 3) 'Shared Windows artifact was exported twice or Android was omitted.'
    $playNotes=Join-Path $prepared.statePath 'notes.google-play.txt'
    [IO.File]::WriteAllText($playNotes,'Improved controller focus.')
    $approvedHash=Get-ReleaseNotesHash $prepared.statePath $state.plan
    $api=New-PlayServer
    $env:BA_STEAM_USERNAME='fixture-account'
    try {
        $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -SteamCmdExecutable $steam -PlayTransport $api.handler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 $approvedHash
        Assert ($result.destinations.steam.status -eq 'awaiting-store-action' -and $result.destinations.steam.remote.buildId -eq '999') 'Steam upload was claimed live without portal activation/notes.'
        Assert ($result.destinations['google-play'].status -eq 'submitted') 'Play submission was claimed fully live or failed.'
        Assert ($result.destinations['itch-windows'].status -eq 'succeeded') 'Independent itch upload failed.'
        $again=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -SteamCmdExecutable $steam -PlayTransport $api.handler
        Assert ($again.destinations.steam.attempts -eq 1 -and $api.server.uploads -eq 1 -and $api.server.commits -eq 1) 'Resume repeated completed store upload/submission.'
        Add-Content $playNotes 'Changed after approval'
        Expect-Error { Invoke-ReleasePublish -StatePath $prepared.statePath -SteamCmdExecutable $steam -PlayTransport $api.handler } 'approval'
    } finally {Remove-Item Env:BA_STEAM_USERNAME}
}
Test 'Play commit ambiguity is journaled and retry reuses the edit, bundle and version code' {
    $repo=New-StoreFixture 'play-ambiguity'
    $prepared=Invoke-ReleasePrepare $repo @('google-play') (Join-Path $sandbox 'play-ambiguity-state') $engine
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    $api=New-PlayServer; $api.server.failCommit=$true
    $result=Invoke-ReleasePublish -StatePath $prepared.statePath -PlayTransport $api.handler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan)
    Assert ($result.destinations['google-play'].status -eq 'uncertain') 'Lost commit response was reported as definite failure/success.'
    $again=Invoke-ReleasePublish -StatePath $prepared.statePath -PlayTransport $api.handler
    Assert ($api.server.commits -eq 1 -and $again.status -eq 'needs-reconciliation') 'Ambiguous Play commit was repeated automatically.'
    $retried=Invoke-ReleasePublish -StatePath $prepared.statePath -PlayTransport $api.handler -RetryUncertain
    Assert ($retried.destinations['google-play'].status -eq 'submitted' -and $api.server.uploads -eq 1) 'Explicit retry did not reuse the uploaded bundle.'
    Assert ((Get-ReleaseConfiguration $repo).presets[2].versionCode -eq 12) 'Android version code changed on retry.'
}
Test 'Steam zero-exit error output cannot be called uploaded' {
    $repo=New-StoreFixture 'steam-false-success'
    $prepared=Invoke-ReleasePrepare $repo @('steam') (Join-Path $sandbox 'steam-false-state') $engine
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    $env:BA_STEAM_USERNAME='fixture-account'; $env:BA_FIXTURE_STEAM_FALSE_SUCCESS='1'
    try {
        $result=Invoke-ReleasePublish -StatePath $prepared.statePath -SteamCmdExecutable $steam -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan)
        Assert ($result.destinations.steam.status -notin @('succeeded','submitted','awaiting-store-action')) 'Steam error exit 0 was accepted as success.'
    } finally {Remove-Item Env:BA_STEAM_USERNAME;Remove-Item Env:BA_FIXTURE_STEAM_FALSE_SUCCESS}
}
Test 'late Steam errors retain uploaded build proof for reconciliation and never repeat automatically' {
    $repo=New-StoreFixture 'steam-late-error'
    $prepared=Invoke-ReleasePrepare $repo @('steam') (Join-Path $sandbox 'steam-late-state') $engine
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    $env:BA_STEAM_USERNAME='fixture-account';$env:BA_FIXTURE_STEAM_LATE_ERROR='1'
    try {
        $result=Invoke-ReleasePublish -StatePath $prepared.statePath -SteamCmdExecutable $steam -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan)
        Assert ($result.destinations.steam.status -eq 'uncertain' -and $result.destinations.steam.remote.buildId -eq '999') 'Steam completed build proof was lost after a late error.'
        $again=Invoke-ReleasePublish -StatePath $prepared.statePath -SteamCmdExecutable $steam
        Assert ($again.destinations.steam.attempts -eq 1) 'Late Steam error repeated upload without reconciliation.'
        $reconciled=Invoke-ReleasePublish -StatePath $prepared.statePath -SteamCmdExecutable $steam -RetryUncertain
        Assert ($reconciled.destinations.steam.status -eq 'awaiting-store-action') 'Known Steam upload was repeated instead of resuming console work.'
    } finally {Remove-Item Env:BA_STEAM_USERNAME;Remove-Item Env:BA_FIXTURE_STEAM_LATE_ERROR}
}
Test 'expired Play edit replacement is explicit and keeps bundle code, hash, artifacts and approval' {
    $repo=New-StoreFixture 'play-expired'
    $prepared=Invoke-ReleasePrepare $repo @('google-play') (Join-Path $sandbox 'play-expired-state') $engine
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    $api=New-PlayServer;$api.server.failCommit=$true
    $first=Invoke-ReleasePublish -StatePath $prepared.statePath -PlayTransport $api.handler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan)
    $api.server.expired=$true
    $refused=Invoke-ReleasePublish -StatePath $prepared.statePath -PlayTransport $api.handler -RetryUncertain
    Assert ($api.server.creates -eq 1 -and $refused.destinations['google-play'].status -eq 'uncertain') 'Expired edit was replaced without authorization.'
    $resumed=Invoke-ReleasePublish -StatePath $prepared.statePath -PlayTransport $api.handler -RetryUncertain -ReplacePlayEdit
    Assert ($resumed.destinations['google-play'].status -eq 'submitted' -and $api.server.uploads -eq 1 -and $api.server.creates -eq 2) 'Expired edit could not resume the same bundle/code with explicit replacement.'
    Assert ($resumed.destinations['google-play'].remote.previousEdits[0].id -eq 'edit-1') 'Replacement discarded previous edit evidence.'
}
Test 'committed Play edit reconciliation recognizes an identical deployed track without another commit' {
    $repo=New-StoreFixture 'play-committed-recovery'
    $prepared=Invoke-ReleasePrepare $repo @('google-play') (Join-Path $sandbox 'play-committed-state') $engine
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    $api=New-PlayServer
    $first=Invoke-ReleasePublish -StatePath $prepared.statePath -PlayTransport $api.handler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan)
    # Simulate the successful commit reply being lost before its final journal write.
    $stateFile=Join-Path $prepared.statePath 'state.json'
    $journal=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    $journal.destinations['google-play'].status='in-progress';$journal.destinations['google-play'].remote.phase='committing';Write-Json $stateFile $journal
    $api.server.expired=$true
    $again=Invoke-ReleasePublish -StatePath $prepared.statePath -PlayTransport $api.handler -RetryUncertain -ReplacePlayEdit
    Assert ($again.destinations['google-play'].status -eq 'submitted' -and $api.server.commits -eq 1 -and $api.server.uploads -eq 1 -and $api.server.deletes -eq 1) 'Reconciliation recommitted an identical deployed release or left its read-only edit open.'
}
Test 'store settings retain unknown facts as blockers and reject incompatible Android/version/rollout data' {
    $repo=New-StoreFixture 'stores-validation'
    Change-Config $repo {param($c) $c.distributions.steam.branch=$null;$c.distributions['google-play'].track=$null;$c.distributions['google-play'].releaseStatus=$null;$c.distributions['google-play'].language=$null;$c.distributions['google-play'].retainVersionCodes=$null}
    $plan=Get-ReleasePlan $repo @('steam','google-play')
    Assert (-not $plan.ready -and ($plan.blockers -join ' ') -match 'Steam branch' -and ($plan.blockers -join ' ') -match 'retainVersionCodes') 'Missing store facts were guessed.'
    Change-Config $repo {param($c) $c.distributions['google-play'].releaseStatus='completed';$c.distributions['google-play'].userFraction=0.5}
    Expect-Error {Get-ReleaseConfiguration $repo} 'userFraction'
    Change-Config $repo {param($c) $c.distributions['google-play'].userFraction=$null}
    $presetFile=Join-Path $repo 'export_presets.cfg'
    $text=[IO.File]::ReadAllText($presetFile)
    [IO.File]::WriteAllText($presetFile,$text.Replace('version/name=""','version/name="99.0.0"'))
    Expect-Error {Get-ReleaseConfiguration $repo} 'version/name'
    [IO.File]::WriteAllText($presetFile,$text.Replace('package/signed=true','package/signed=false'))
    Expect-Error {Get-ReleaseConfiguration $repo} 'signed Gradle AAB'
    [IO.File]::WriteAllText($presetFile,$text.Replace('package/signed=true','package/signed="true"'))
    Expect-Error {Get-ReleaseConfiguration $repo} 'signed Gradle AAB'
}
Test 'Play cleanup failure preserves a proven deployed release without another update or commit' {
    $repo=New-StoreFixture 'play-cleanup-error'
    $prepared=Invoke-ReleasePrepare $repo @('google-play') (Join-Path $sandbox 'play-cleanup-state') $engine
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    $api=New-PlayServer
    $first=Invoke-ReleasePublish -StatePath $prepared.statePath -PlayTransport $api.handler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan)
    $stateFile=Join-Path $prepared.statePath 'state.json'
    $journal=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    $journal.destinations['google-play'].status='in-progress';$journal.destinations['google-play'].remote.phase='committing';Write-Json $stateFile $journal
    $api.server.expired=$true;$api.server.failDelete=$true
    $result=Invoke-ReleasePublish -StatePath $prepared.statePath -PlayTransport $api.handler -RetryUncertain -ReplacePlayEdit
    Assert ($result.destinations['google-play'].status -eq 'submitted' -and $result.destinations['google-play'].remote.cleanupStatus -eq 'failed') 'Cleanup error erased a proven deployed match.'
    $again=Invoke-ReleasePublish -StatePath $prepared.statePath -PlayTransport $api.handler
    Assert ($api.server.commits -eq 1 -and $api.server.uploads -eq 1 -and $again.destinations['google-play'].attempts -eq 2) 'Cleanup error caused another publication operation.'
}
Test 'verified store receipts complete pending destinations without repeating publication' {
    $repo=New-StoreFixture 'store-receipts'
    $prepared=Invoke-ReleasePrepare $repo @('steam','google-play') (Join-Path $sandbox 'receipt-state') $engine
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    $hash=Get-ReleaseNotesHash $prepared.statePath $state.plan
    $api=New-PlayServer; $env:BA_STEAM_USERNAME='fixture-account'
    try {$result=Invoke-ReleasePublish -StatePath $prepared.statePath -SteamCmdExecutable $steam -PlayTransport $api.handler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 $hash}
    finally {Remove-Item Env:BA_STEAM_USERNAME}
    $receiptPath=Join-Path $prepared.statePath 'receipt.json'
    $receipt=@{destination='steam';planId=$state.plan.planId;notesSha256=$hash;observedAt=[DateTimeOffset]::UtcNow.ToString('o');live=$true;appId=100;buildId='wrong';branch='default';announcementUrl='https://store.steampowered.com/news/app/100/view/123'}
    Write-Json $receiptPath $receipt
    Expect-Error {Confirm-ReleaseStoreCompletion $prepared.statePath $receiptPath} 'buildId'
    $receipt.buildId='999';Write-Json $receiptPath $receipt
    $steamResult=Confirm-ReleaseStoreCompletion $prepared.statePath $receiptPath
    Assert ($steamResult.destinations.steam.status -eq 'succeeded' -and $steamResult.status -eq 'submitted') 'Steam receipt lost the independent pending Play state.'
    $receipt=@{destination='google-play';planId=$state.plan.planId;notesSha256=$hash;observedAt=[DateTimeOffset]::UtcNow.ToString('o');live=$true;packageName='com.example.realgame';versionCode=12;track='production';releaseStatus='completed';userFraction=$null;evidenceUrl='https://play.google.com/console'}
    Write-Json $receiptPath $receipt
    $final=Confirm-ReleaseStoreCompletion $prepared.statePath $receiptPath
    Assert ($final.status -eq 'published' -and $api.server.commits -eq 1 -and $final.destinations.steam.attempts -eq 1) 'Receipt verification repeated uploads or failed to finish the release.'
    $receipt.versionCode=13;Write-Json $receiptPath $receipt
    Expect-Error {Confirm-ReleaseStoreCompletion $prepared.statePath $receiptPath} 'versionCode'
    $receipt.versionCode=12;Write-Json $receiptPath $receipt
    $stateFile=Join-Path $prepared.statePath 'state.json'
    $journal=Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable
    $journal.destinations['google-play'].status='uncertain';$journal.destinations['google-play'].remote=@{phase='edit-created';editId='edit-1'};Write-Json $stateFile $journal
    Expect-Error {Confirm-ReleaseStoreCompletion $prepared.statePath $receiptPath} 'bundle hash'
}
Test 'state staging refuses an outside link into the source repository before any writes' {
    $repo=New-Fixture 'linked-state-source'
    $link=Join-Path $sandbox 'state-root-link'
    New-Item -ItemType $(if ($IsWindows) {'Junction'} else {'SymbolicLink'}) -Path $link -Target $repo | Out-Null
    $before=Invoke-FixtureGit $repo @('status','--porcelain=v1','--untracked-files=all')
    Expect-Error {Invoke-ReleasePrepare $repo @('itch-windows') $link $engine} 'outside the source'
    Assert ((Invoke-FixtureGit $repo @('status','--porcelain=v1','--untracked-files=all')) -ceq $before) 'Linked state staging changed source files before refusal.'
}
Test 'setup inspects actual project and asks only missing facts for selected stores without writes' {
    $repo=New-StoreFixture 'setup-report'
    Change-Config $repo {param($c) $c.previousRelease=$null;$c.distributions.itch.game=$null;$c.distributions.steam.branch=$null;$c.distributions['google-play'].track=$null}
    $configPath=Join-Path $repo 'release.json'
    $before=(Get-FileHash $configPath).Hash
    $report=Get-ReleaseSetup $repo @('itch-windows','steam')
    Assert ($report.facts.version -eq '1.2.3' -and $report.facts.presets[2].versionCode -eq 12) 'Setup did not inspect actual Godot facts.'
    $keys=@($report.questions | ForEach-Object {$_.key})
    Assert ($keys -contains 'previousRelease' -and $keys -contains 'distributions.itch.game' -and $keys -contains 'distributions.steam.branch') 'Setup omitted required questions.'
    Assert (-not ($keys -contains 'distributions.google-play.track')) 'Holding Google Play still required its track.'
    Assert ($before -eq (Get-FileHash $configPath).Hash) 'Setup inspection changed configuration.'
}
Test 'setup creates an inspected configuration and refuses stale, secret or invalid answers' {
    $repo=New-Fixture 'setup-create'
    Remove-Item -LiteralPath (Join-Path $repo 'release.json')
    $report=Get-ReleaseSetup $repo
    Assert ($report.configSha256 -eq 'missing' -and $report.facts.presets[0].name -eq 'Windows existing') 'Missing-config setup invented presets.'
    $answersPath=Join-Path $sandbox 'setup-answers.json'
    Write-Json $answersPath @{stores=@('itch','notes');previousRelease='v1.2.2';'distributions.itch.game'='example/real-game';'distributions.itch.channels'=@{windows='windows';linux='linux'}}
    $written=Set-ReleaseSetup -Repository $repo -AnswersPath $answersPath -ExpectedConfigSha256 'missing'
    Assert ($written.written -and (Get-ReleaseConfiguration $repo).config.exports[0] -eq 'Windows existing') 'Setup did not save an inspected valid config.'
    $hash=(Get-FileHash (Join-Path $repo 'release.json')).Hash
    Expect-Error {Set-ReleaseSetup -Repository $repo -AnswersPath $answersPath -ExpectedConfigSha256 'missing'} 'changed|conflict'
    Write-Json $answersPath @{'distributions.itch.game'='made up';'previousRelease'='v1.2.2'}
    Expect-Error {Set-ReleaseSetup -Repository $repo -AnswersPath $answersPath -ExpectedConfigSha256 $hash.ToLowerInvariant()} 'Butler owner/game'
    Write-Json $answersPath @{token='forbidden'}
    Expect-Error {Set-ReleaseSetup -Repository $repo -AnswersPath $answersPath -ExpectedConfigSha256 $hash.ToLowerInvariant()} 'Credentials'
    Assert ($hash -eq (Get-FileHash (Join-Path $repo 'release.json')).Hash) 'Rejected setup answers changed a file.'
}
Test 'setup separates editable source files from missing release information and keeps store selection explicit' {
    $repo=New-Fixture 'setup-dirty'
    Add-Content (Join-Path $repo 'fix.txt') 'uncommitted local work'
    $plan=Get-ReleasePlan $repo @('itch-windows')
    Assert ($plan.configurationReady -and -not $plan.ready -and $plan.sourceChanges.Count -eq 1) 'Source changes were reported as missing configuration.'
    $report=Get-ReleaseSetup $repo
    Assert ($report.selection.required -and @($report.selection.choices | Where-Object {$_.id -eq 'itch-windows'}).Count -eq 1) 'Setup silently selected all stores.'
    $report=Get-ReleaseSetup $repo @('itch-windows')
    Assert ($report.questions.Count -eq 0) 'Complete selected configuration still asked for source-commit cleanup as information.'
}
Test 'setup store edits preserve counter policy and deliberately unknown channel baselines' {
    $repo=New-Fixture 'setup-preserve'
    Change-Config $repo {param($c) $c.androidVersionCodePolicy='existing';$c.distributions.itch.channels.linux=@{export='linux';previousRelease=$null}}
    $hash=(Get-FileHash (Join-Path $repo 'release.json')).Hash.ToLowerInvariant()
    $answers=Join-Path $sandbox 'preserve-answers.json';Write-Json $answers @{stores=@('itch','notes')}
    Set-ReleaseSetup $repo $answers $hash | Out-Null
    $settings=Get-ReleaseConfiguration $repo
    Assert ($settings.config.androidVersionCodePolicy -eq 'existing' -and $settings.config.destinationBaselines.Contains('itch-linux') -and $null -eq $settings.config.destinationBaselines['itch-linux']) 'Changing store choices reset approved policy or guessed a held-channel baseline.'
}
Test 'setup inspects a nested actual Godot project and leaves ambiguous project choices unresolved' {
    $repo=New-Fixture 'nested-setup'
    Remove-Item -LiteralPath (Join-Path $repo 'release.json')
    $project=Join-Path $repo 'game';New-Item -ItemType Directory $project | Out-Null
    Move-Item -LiteralPath (Join-Path $repo 'project.godot') -Destination $project
    Move-Item -LiteralPath (Join-Path $repo 'export_presets.cfg') -Destination $project
    $report=Get-ReleaseSetup $repo
    Assert ($report.facts.project -eq 'game' -and $report.facts.version -eq '1.2.3') 'Setup invented a root project instead of inspecting the nested one.'
    $other=Join-Path $repo 'other';New-Item -ItemType Directory $other | Out-Null
    Copy-Item -LiteralPath (Join-Path $project 'project.godot') -Destination $other
    Copy-Item -LiteralPath (Join-Path $project 'export_presets.cfg') -Destination $other
    $report=Get-ReleaseSetup $repo
    Assert ($report.questions[0].key -eq 'project' -and $null -eq $report.configuration) 'Ambiguous projects were silently selected.'
    $answers=Join-Path $sandbox 'nested-answers.json';Write-Json $answers @{project='game';stores=@('itch','notes');previousRelease='v1.2.2'}
    Set-ReleaseSetup $repo $answers 'missing' | Out-Null
    Assert ((Get-ReleaseConfiguration $repo).config.project -eq 'game') 'Setup did not use the explicitly chosen real project.'
}
Test 'setup asks for standalone checks when configuration has no check entries' {
    $repo=New-Fixture 'setup-missing-checks'
    Change-Config $repo {param($c) $c.verification.Remove('standalone') | Out-Null}
    $report=Get-ReleaseSetup $repo @('itch-windows')
    Assert (@($report.questions | Where-Object {$_.key -eq 'verification.standalone'}).Count -eq 1) 'Missing standalone check was not asked about.'
}
Test 'interactive setup exposes newly chosen store questions and writes one validated config' {
    $repo=New-StoreFixture 'interactive-setup'
    Remove-Item -LiteralPath (Join-Path $repo 'release.json')
    $asked=[Collections.Generic.List[string]]::new()
    $prompt={param($question)
        $asked.Add($question.key)
        switch ($question.key) {
            'stores' {'steam,google-play,notes'}
            'previousRelease' {'v1.2.2'}
            'distributions.steam.appId' {'100'}
            'distributions.steam.branch' {'default'}
            'distributions.steam.depots' {'{"101":"windows","102":"linux"}'}
            'distributions.google-play.track' {'production'}
            'distributions.google-play.releaseStatus' {'completed'}
            'distributions.google-play.language' {'en-US'}
            'distributions.google-play.retainVersionCodes' {'[]'}
            default {if ($question.key -like '*.previousRelease') {'v1.2.2'} else {''}}
        }
    }.GetNewClosure()
    $result=Invoke-ReleaseInteractiveSetup $repo @() $prompt
    Assert ($result.written -and $asked.Contains('distributions.steam.appId') -and $asked.Contains('distributions.google-play.track') -and -not $asked.Contains('distributions.itch.game')) 'Wizard did not adapt to the selected stores.'
    Assert ((Get-ReleasePlan $repo @('steam','google-play')).configurationReady) 'Wizard wrote incomplete selected store settings.'
}
Test 'itch supports the inspected signed APK and plans its display label without another desktop export' {
    $repo=New-StoreFixture 'itch-apk'
    @'
[preset.3]
name="Android existing APK"
platform="Android"
export_path="dist/android/Game.apk"
[preset.3.options]
version/code=3
version/name=""
package/unique_name="com.example.realgame"
package/signed=true
gradle_build/use_gradle_build=false
gradle_build/export_format=0
'@ | Add-Content (Join-Path $repo 'export_presets.cfg')
    Change-Config $repo {param($c)
        $c.exports.apk='Android existing APK'
        $c.distributions.itch.channels.windows=@{export='windows';displayNameTemplate='{title} {version} ({os})'}
        $c.distributions.itch.channels.android=@{export='apk';displayNameTemplate='{title} {version} ({os})'}
    }
    Invoke-FixtureGit $repo @('add','.') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Configure signed itch APK') | Out-Null
    $plan=Get-ReleasePlan $repo @('steam','itch-windows','itch-android')
    Assert ($plan.destinations[0].displayName -eq 'Fixture 1.2.3 (Windows)' -and @($plan.destinations | Where-Object id -EQ 'itch-android')[0].displayName -eq 'Fixture 1.2.3 (Android)') 'Itch label did not use Godot title/version and actual platform.'
    $prepared=Invoke-ReleasePrepare $repo @('steam','itch-windows','itch-android') (Join-Path $sandbox 'apk-state') $engine
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($state.artifacts.Count -eq 3 -and @($state.artifacts | Where-Object {$_.preset -eq 'Windows existing'}).Count -eq 1) 'Desktop exports were repeated per store.'
    $notesHash=Get-ReleaseNotesHash $prepared.statePath $state.plan
    $env:BA_STEAM_USERNAME='fixture'
    try {$result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -SteamCmdExecutable $steam -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 $notesHash}
    finally {Remove-Item Env:BA_STEAM_USERNAME}
    Assert ($result.destinations['itch-windows'].status -eq 'awaiting-store-action' -and $result.destinations['itch-windows'].remote.live) 'Live Butler upload with an outstanding label update was hidden.'
    Change-Config $repo {param($c) $c.distributions['google-play'].export='apk'}
    Expect-Error {Get-ReleaseConfiguration $repo} 'AAB'
}
Test 'standalone checks withhold only excluded files on both desktops and Butler dry-run must agree' {
    $repo=New-Fixture 'standalone-selection'
    $prepared=Invoke-ReleasePrepare $repo @('itch-windows','itch-linux') (Join-Path $sandbox 'standalone-state') $engine
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($state.checks['itch-windows'].standalone -eq 'succeeded' -and $state.checks['itch-linux'].standalone -eq 'succeeded') 'Both standalone platforms were not checked.'
    Assert ($state.checks['itch-windows'].dryRun -eq 'succeeded' -and $state.checks['itch-linux'].dryRun -eq 'succeeded') 'Butler selection was not verified.'
    Assert (@($state.artifacts | ForEach-Object {$_.files} | Where-Object {$_.path -like '*steam_api64.dll'}).Count -eq 2) 'Shared desktop artifacts lost their Steam files.'
    $bad=New-Fixture 'bad-selection'
    $env:BA_FIXTURE_BAD_SELECTION='1'
    try {$result=Invoke-ReleasePrepare $bad @('itch-windows') (Join-Path $sandbox 'bad-selection-state') $engine}
    finally {Remove-Item Env:BA_FIXTURE_BAD_SELECTION}
    Assert ($result.status -eq 'preparation-failed') 'An incorrect upload selection passed the release gate.'
}
Test 'independent stores can catch up later without rebuilding desktops, repeating uploads or changing the game version' {
    $repo=New-StoreFixture 'independent-stores'
    $stateRoot=Join-Path $sandbox 'independent-state'
    $env:BA_FIXTURE_EXPORT_LOG=Join-Path $sandbox 'independent-exports.txt'
    $env:BA_STEAM_USERNAME='fixture'
    try {
        $prepared=Invoke-ReleasePrepare $repo @('steam','itch-windows') $stateRoot $engine
        $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -SteamCmdExecutable $steam -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan) -PlayTransport {throw 'Google must be untouched while held.'}
        Assert ($result.destinations['google-play'].status -eq 'not-selected' -and $result.destinations['itch-windows'].status -eq 'succeeded') 'Holding Google caused a store operation.'
        $canonicalHash=(Get-FileHash (Join-Path $prepared.statePath 'notes.md')).Hash
        $versionHash=(Get-FileHash (Join-Path $repo 'project.godot')).Hash
        $extended=Expand-ReleaseDestinations $prepared.statePath @('google-play') $engine
        $state=Get-Content (Join-Path $extended.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert ($state.artifacts.Count -eq 3 -and (Get-Content $env:BA_FIXTURE_EXPORT_LOG).Count -eq 3) 'Later Play distribution rebuilt shared desktops.'
        Assert ($canonicalHash -eq (Get-FileHash (Join-Path $prepared.statePath 'notes.md')).Hash -and $versionHash -eq (Get-FileHash (Join-Path $repo 'project.godot')).Hash) 'Extension bumped version or rewrote canonical notes.'
        Expect-Error {Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -SteamCmdExecutable $steam} 'approval'
        $fake=New-PlayServer
        $result=Invoke-ReleasePublish -StatePath $prepared.statePath -ButlerExecutable $butler -SteamCmdExecutable $steam -PlayTransport $fake.handler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan)
        Assert ($fake.server.uploads -eq 1 -and $result.destinations.steam.attempts -eq 1 -and $result.destinations['itch-windows'].attempts -eq 1) 'Extension repeated completed store operations.'
        $ledger=Get-ReleaseLiveLedger $repo $stateRoot
        Assert ($ledger.Contains('itch:example/real-game:windows') -and -not $ledger.Contains('play:com.example.realgame:production') -and -not $ledger.Contains('steam:100:default')) 'Live baselines equated uploads/submissions with confirmed releases.'
    } finally {Remove-Item Env:BA_FIXTURE_EXPORT_LOG;Remove-Item Env:BA_STEAM_USERNAME}
}
Test 'extension rejects unrelated source changes before reserving an Android counter' {
    $repo=New-StoreFixture 'extension-source-conflict'
    Change-Config $repo {param($c) $c.androidVersionCodePolicy='increment-selected'}
    Invoke-FixtureGit $repo @('add','release.json') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Choose Android counter') | Out-Null
    $prepared=Invoke-ReleasePrepare $repo @('steam') (Join-Path $sandbox 'extension-conflict-state') $engine
    Add-Content (Join-Path $repo 'fix.txt') 'unrelated gameplay change'
    Invoke-FixtureGit $repo @('add','fix.txt') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Unrelated later source') | Out-Null
    $before=(Get-FileHash (Join-Path $repo 'export_presets.cfg')).Hash
    Expect-Error {Expand-ReleaseDestinations $prepared.statePath @('google-play') $engine} 'Source changed|source differs'
    Assert ($before -eq (Get-FileHash (Join-Path $repo 'export_presets.cfg')).Hash -and -not (Test-Path (Join-Path $prepared.statePath 'extension-source'))) 'Rejected extension mutated source/reserved a counter.'
}
Test 'extension freezes already submitted locale notes while allowing new destination approval' {
    $repo=New-StoreFixture 'extension-notes-freeze'
    $prepared=Invoke-ReleasePrepare $repo @('google-play') (Join-Path $sandbox 'extension-notes-state') $engine
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    $fake=New-PlayServer
    Invoke-ReleasePublish -StatePath $prepared.statePath -PlayTransport $fake.handler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan) | Out-Null
    Expand-ReleaseDestinations $prepared.statePath @('steam') $engine | Out-Null
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    'Claims never submitted to Play' | Set-Content (Join-Path $prepared.statePath 'notes.google-play.txt')
    Expect-Error {Invoke-ReleasePublish -StatePath $prepared.statePath -PlayTransport $fake.handler -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan)} 'locale|approval'
    Assert ($fake.server.commits -eq 1) 'A completed store was resubmitted.'
}
Test 'later Play inclusion reserves its counter once and retains accurate desktop artifact provenance' {
    $repo=New-StoreFixture 'later-play-counter'
    Change-Config $repo {param($c) $c.androidVersionCodePolicy='increment-selected'}
    Invoke-FixtureGit $repo @('add','release.json') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Choose Android counter') | Out-Null
    $prepared=Invoke-ReleasePrepare $repo @('steam') (Join-Path $sandbox 'later-play-state') $engine
    $original=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    $result=Expand-ReleaseDestinations $prepared.statePath @('google-play') $engine
    Assert ($result.status -eq 'source-update-required' -and (Get-ReleaseConfiguration $repo).presets[2].versionCode -eq 13) 'Later Play inclusion did not reserve exactly one counter.'
    $result=Expand-ReleaseDestinations $prepared.statePath @('google-play') $engine
    Assert ((Get-ReleaseConfiguration $repo).presets[2].versionCode -eq 13) 'Extension retry incremented again.'
    Invoke-FixtureGit $repo @('add','export_presets.cfg') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Reserve later Play code') | Out-Null
    $result=Expand-ReleaseDestinations $prepared.statePath @('google-play') $engine
    Assert ($result.status -eq 'prepared' -and (Get-ReleaseConfiguration $repo).version -eq '1.2.3') 'Later Play changed the game version or did not prepare.'
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($state.artifacts[0].sourceCommit -eq $original.plan.head -and $state.artifacts[2].sourceCommit -eq $state.plan.head -and $state.artifacts[2].sourceCommit -ne $original.plan.head) 'Mixed metadata revisions concealed artifact source commits.'
}
Test 'uncertain Steam upload retains its artifact source when a later Android counter commit extends the release' {
    $repo=New-StoreFixture 'uncertain-provenance'
    Change-Config $repo {param($c) $c.androidVersionCodePolicy='increment-selected'}
    Invoke-FixtureGit $repo @('add','release.json') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Choose counter') | Out-Null
    $prepared=Invoke-ReleasePrepare $repo @('steam') (Join-Path $sandbox 'uncertain-provenance-state') $engine
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    $oldHead=$state.plan.head
    $env:BA_STEAM_USERNAME='fixture';$env:BA_FIXTURE_STEAM_LATE_ERROR='1'
    try {Invoke-ReleasePublish -StatePath $prepared.statePath -SteamCmdExecutable $steam -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan) | Out-Null}
    finally {Remove-Item Env:BA_STEAM_USERNAME;Remove-Item Env:BA_FIXTURE_STEAM_LATE_ERROR}
    Expand-ReleaseDestinations $prepared.statePath @('google-play') $engine | Out-Null
    Invoke-FixtureGit $repo @('add','export_presets.cfg') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Reserve later Android code') | Out-Null
    Expand-ReleaseDestinations $prepared.statePath @('google-play') $engine | Out-Null
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    Invoke-ReleasePublish -StatePath $prepared.statePath -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan) -PlayTransport {throw 'Keep Play unsubmitted in this fixture.'} | Out-Null
    $receipt=Join-Path $prepared.statePath 'steam-observation.json'
    Write-Json $receipt @{destination='steam';planId=$state.plan.planId;notesSha256=(Get-ReleaseNotesHash $prepared.statePath $state.plan);observedAt=[DateTimeOffset]::UtcNow.ToString('o');live=$true;appId=100;buildId='999';branch='default';announcementUrl='https://store.steampowered.com/news/app/100/view/555'}
    Confirm-ReleaseStoreCompletion $prepared.statePath $receipt | Out-Null
    $ledger=Get-ReleaseLiveLedger $repo (Join-Path $sandbox 'uncertain-provenance-state')
    Assert ($ledger['steam:100:default'].sourceCommit -eq $oldHead -and $oldHead -ne $state.plan.head) 'Steam live provenance was rewritten to a source commit its artifacts did not use.'
}
Test 'exported version overrides are inspected and Play changelog filenames use the configured locale and numeric code' {
    $repo=New-StoreFixture 'version-metadata'
    $presetPath=Join-Path $repo 'export_presets.cfg'
    $presetText=[IO.File]::ReadAllText($presetPath).Replace('[preset.0.options]',"[preset.0.options]`napplication/file_version=`"9.9.9`"`napplication/product_version=`"`"")
    [IO.File]::WriteAllText($presetPath,$presetText)
    Expect-Error {Get-ReleaseConfiguration $repo} 'version metadata|file_version'
    $path=Join-Path $repo 'export_presets.cfg';$text=[IO.File]::ReadAllText($path);[IO.File]::WriteAllText($path,$text.Replace('9.9.9','1.2.3'))
    Change-Config $repo {param($c) $c.distributions['google-play'].language='en-GB'}
    Invoke-FixtureGit $repo @('add','.') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Choose actual release metadata') | Out-Null
    $prepared=Invoke-ReleasePrepare $repo @('google-play') (Join-Path $sandbox 'metadata-state') $engine
    'Approved player-facing changes' | Set-Content (Join-Path $prepared.statePath 'notes.google-play.txt')
    $files=@(Export-ReleasePlayChangelogs $prepared.statePath)
    Assert ($files[0].EndsWith('en-GB/changelogs/12.txt') -or $files[0].EndsWith('en-GB\changelogs\12.txt')) 'Fastlane changelog used the display version or hard-coded locale.'
    Assert ([IO.File]::ReadAllText($files[0]) -ceq [IO.File]::ReadAllText((Join-Path $prepared.statePath 'notes.google-play.txt'))) 'Changelog packaging changed approved claims.'
}
Test 'public release notes wait for a live store, check permissions first and record partial availability' {
    $repo=New-StoreFixture 'notes-shipment'
    $prepared=Invoke-ReleasePrepare $repo @('notes') (Join-Path $sandbox 'notes-shipment-state')
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    $env:BA_FIXTURE_NOTE_STORE=Join-Path $sandbox 'shipment-note.md'
    try {
        $result=Invoke-ReleasePublish -StatePath $prepared.statePath -GhExecutable $gh -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan)
        Assert (-not (Test-Path $env:BA_FIXTURE_NOTE_STORE) -and $result.destinations.notes.status -eq 'awaiting-release' -and $result.status -eq 'awaiting-release') 'Unshipped changes were published or misreported as a failed release.'
        $extended=Expand-ReleaseDestinations $prepared.statePath @('itch-windows','steam') $engine
        $state=Get-Content (Join-Path $extended.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        $env:BA_FIXTURE_NO_PUSH='1'
        $result=Invoke-ReleasePublish -StatePath $prepared.statePath -GhExecutable $gh -ButlerExecutable $butler -SteamCmdExecutable $steam -ApprovedPlanId $state.plan.planId -ApprovedNotesSha256 (Get-ReleaseNotesHash $prepared.statePath $state.plan)
        Assert ($result.destinations['itch-windows'].attempts -eq 0) 'Store publication started before checking notes permissions.'
        Remove-Item Env:BA_FIXTURE_NO_PUSH
        $env:BA_STEAM_USERNAME='fixture'
        $result=Invoke-ReleasePublish -StatePath $prepared.statePath -GhExecutable $gh -ButlerExecutable $butler -SteamCmdExecutable $steam
        Assert ($result.destinations.notes.status -eq 'succeeded' -and $result.destinations.steam.status -eq 'awaiting-store-action') 'Partial store availability prevented truthful released notes.'
        $availability=Get-Content ($env:BA_FIXTURE_NOTE_STORE+'.availability') -Raw | ConvertFrom-Json -AsHashtable
        Assert ($availability.destinations['itch-windows'].live -eq $true -and $availability.destinations.steam.live -eq $false -and $availability.destinations['google-play'].status -eq 'not-selected') 'Availability falsely claimed all stores were live.'
    } finally {Remove-Item Env:BA_FIXTURE_NOTE_STORE;Remove-Item Env:BA_FIXTURE_NO_PUSH -ErrorAction SilentlyContinue;Remove-Item Env:BA_STEAM_USERNAME -ErrorAction SilentlyContinue}
}
Test 'per-channel live baselines retain missed changes in later store note evidence' {
    $repo=New-Fixture 'destination-baselines'
    Change-Config $repo {param($c) $c.distributions.itch.channels.linux=@{export='linux';previousRelease=$null}}
    Invoke-FixtureGit $repo @('add','release.json') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Confirm destination baseline') | Out-Null
    $plan=Get-ReleasePlan $repo @('itch-windows')
    Assert ($plan.ready -and $plan.destinations[0].changes.Count -eq 2) 'Confirmed channel changes were missing.'
    $plan=Get-ReleasePlan $repo @('itch-linux')
    Assert (-not $plan.configurationReady -and $plan.destinations[1].previousCommit -eq $null) 'Unknown live channel baseline was guessed.'
}
Test 'prepare reads the explicitly selected live ledger before readiness checks and version reservation' {
    $repo=New-StoreFixture 'custom-ledger'
    Change-Config $repo {param($c) $c.distributions.steam.previousRelease=$null}
    Invoke-FixtureGit $repo @('add','release.json') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Record unknown baseline') | Out-Null
    $stateRoot=Join-Path $sandbox 'custom-ledger-state'
    $id=(& (Get-Module Release) {param($path) (Get-ReleaseTextHash $path).Substring(0,20)} ((Get-Item $repo).FullName))
    $repositoryState=Join-Path $stateRoot $id
    New-Item -ItemType Directory -Path $repositoryState -Force | Out-Null
    $baseline=Invoke-FixtureGit $repo @('rev-parse','v1.2.2')
    Write-Json (Join-Path $repositoryState 'live.json') @{'steam:100:default'=@{sourceCommit=$baseline;version='1.2.2'}}
    $plan=Get-ReleasePlan -Repository $repo -Destination @('steam') -StateRoot $stateRoot
    Assert ($plan.ready -and $plan.baselines.steam -ceq $baseline) 'Custom-ledger plan is not ready.'
    $first=Invoke-ReleasePrepare $repo @('steam') $stateRoot $engine -VersionChange patch
    Assert ($first.status -eq 'source-update-required') 'Preparation ignored the custom ledger before reserving the requested version.'
    Invoke-FixtureGit $repo @('add','project.godot') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Commit reserved version') | Out-Null
    $prepared=Invoke-ReleasePrepare $repo @('steam') $stateRoot $engine -VersionChange patch
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($prepared.status -eq 'prepared' -and $state.plan.baselines.steam -ceq $baseline) 'Committed preparation lost the custom live baseline.'
}
Test 'projected patch plan consistently labels the requested version and excludes held exports without writes' {
    $repo=New-StoreFixture 'projected-plan';Add-FixtureApk $repo
    $before=@(Get-ChildItem $repo -Recurse -File -Force | ForEach-Object {"$($_.FullName):$((Get-FileHash $_.FullName).Hash)"})
    $plan=Get-ReleasePlan -Repository $repo -Destination @('steam','itch-windows','itch-android','notes') -VersionChange patch
    Assert ($plan.version -eq '1.2.4' -and $plan.sourceVersion -eq '1.2.3' -and $plan.preview) 'Next-version preview is ambiguous.'
    Assert ($plan.destinations[0].displayName -eq 'Fixture 1.2.4 (Windows)' -and @($plan.destinations | Where-Object id -EQ notes)[0].path -eq 'releases/1.2.4.md' -and $plan.notesDraft -match '# Fixture 1.2.4' -and $plan.notesDraft -match 'availability/1.2.4.json') 'Projected labels or notes still use the old version.'
    Assert ($plan.requiredExports.Count -eq 3 -and @($plan.requiredExports | Where-Object {$_.name -eq 'Android existing AAB'}).Count -eq 0) 'Held Play export appears in the required build list.'
    Assert ($plan.configurationReady -and -not $plan.ready -and ($plan.blockers -join ' ') -match 'source version') 'Projected plan pretends its source already contains the version.'
    $after=@(Get-ChildItem $repo -Recurse -File -Force | ForEach-Object {"$($_.FullName):$((Get-FileHash $_.FullName).Hash)"})
    Assert (($before -join "`n") -ceq ($after -join "`n")) 'Preview changed source, configuration or Git index.'
}
Test 'selected APK and AAB counters advance independently once through retries and successive extensions' {
    $repo=New-StoreFixture 'independent-counters';Add-FixtureApk $repo
    $stateRoot=Join-Path $sandbox 'independent-counter-state'
    $prepared=Invoke-ReleasePrepare $repo @('steam') $stateRoot $engine
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    $desktopManifest=$state.artifacts | ConvertTo-Json -Depth 20 -Compress
    $apk=Expand-ReleaseDestinations $prepared.statePath @('itch-android') $engine
    Assert ($apk.status -eq 'source-update-required') 'Selected APK counter was not reserved before export.'
    $settings=Get-ReleaseConfiguration $repo
    Assert ($settings.version -eq '1.2.3' -and $settings.presets[3].versionCode -eq 4 -and $settings.presets[2].versionCode -eq 12) 'APK extension changed the held Play counter or semantic version.'
    Expand-ReleaseDestinations $prepared.statePath @('itch-android') $engine | Out-Null
    Assert ((Get-ReleaseConfiguration $repo).presets[3].versionCode -eq 4) 'Interrupted APK extension incremented again.'
    Invoke-FixtureGit $repo @('add','export_presets.cfg') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Reserve APK counter') | Out-Null
    $prepared=Expand-ReleaseDestinations $prepared.statePath @('itch-android') $engine
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    $apkArtifact=@($state.artifacts | Where-Object {$_.preset -eq 'Android existing APK'})[0] | ConvertTo-Json -Depth 20 -Compress
    $play=Expand-ReleaseDestinations $prepared.statePath @('google-play') $engine
    Assert ($play.status -eq 'source-update-required') 'Later Play counter was not reserved.'
    $settings=Get-ReleaseConfiguration $repo
    Assert ($settings.version -eq '1.2.3' -and $settings.presets[2].versionCode -eq 13 -and $settings.presets[3].versionCode -eq 4) 'Later Play extension changed an existing APK counter.'
    Expand-ReleaseDestinations $prepared.statePath @('google-play') $engine | Out-Null
    Assert ((Get-ReleaseConfiguration $repo).presets[2].versionCode -eq 13) 'Interrupted Play extension incremented again.'
    Invoke-FixtureGit $repo @('add','export_presets.cfg') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Reserve Play counter') | Out-Null
    $prepared=Expand-ReleaseDestinations $prepared.statePath @('google-play') $engine
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ((@($state.artifacts | Where-Object {$_.preset -ne 'Android existing APK' -and $_.preset -ne 'Android existing AAB'}) | ConvertTo-Json -Depth 20 -Compress) -ceq $desktopManifest) 'Later Android distribution rebuilt existing desktops.'
    Assert ((@($state.artifacts | Where-Object {$_.preset -eq 'Android existing APK'})[0] | ConvertTo-Json -Depth 20 -Compress) -ceq $apkArtifact -and $state.artifacts.Count -eq 4) 'Later Play distribution rebuilt the existing APK.'
    Invoke-ReleasePrepare $repo @('steam','itch-android','google-play') $stateRoot $engine | Out-Null
    Assert ((Get-ReleaseConfiguration $repo).presets[2].versionCode -eq 13 -and (Get-ReleaseConfiguration $repo).presets[3].versionCode -eq 4) 'Prepared retry changed either Android counter.'
}
Test 'first preparation reserves each selected Android counter once and leaves unselected counters unchanged' {
    foreach ($includePlay in @($false,$true)) {
        $repo=New-StoreFixture "first-counter-$includePlay";Add-FixtureApk $repo
        $selection=@('itch-android');if ($includePlay) {$selection+='google-play'}
        $stateRoot=Join-Path $sandbox "first-counter-state-$includePlay"
        $first=Invoke-ReleasePrepare $repo $selection $stateRoot $engine -VersionChange patch
        Assert ($first.status -eq 'source-update-required' -and -not (Test-Path (Join-Path $first.statePath 'builds'))) 'Android settings were not reserved before export.'
        Invoke-ReleasePrepare $repo $selection $stateRoot $engine -VersionChange patch | Out-Null
        $settings=Get-ReleaseConfiguration $repo;$expectedAab=if ($includePlay) {13} else {12}
        Assert ($settings.version -eq '1.2.4' -and $settings.presets[3].versionCode -eq 4 -and $settings.presets[2].versionCode -eq $expectedAab) 'First preparation or retry changed the wrong counter.'
        Invoke-FixtureGit $repo @('add','project.godot','export_presets.cfg') | Out-Null
        Invoke-FixtureGit $repo @('commit','--quiet','-m','Release source settings') | Out-Null
        $prepared=Invoke-ReleasePrepare $repo $selection $stateRoot $engine -VersionChange patch
        $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert ($prepared.status -eq 'prepared' -and $state.artifacts.Count -eq $selection.Count) 'Selected Android artifacts were not prepared once each.'
        Invoke-ReleasePrepare $repo $selection $stateRoot $engine -VersionChange patch | Out-Null
        Assert ((Get-ReleaseConfiguration $repo).presets[3].versionCode -eq 4 -and (Get-ReleaseConfiguration $repo).presets[2].versionCode -eq $expectedAab) 'Prepared retry advanced the counters.'
    }
}
Test 'version reservation updates source settings once, commits before export and keeps retries at the reserved code' {
    $repo=New-StoreFixture 'version-reservation'
    Change-Config $repo {param($c) $c.androidVersionCodePolicy='increment-selected'}
    Invoke-FixtureGit $repo @('add','release.json') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Choose Android release policy') | Out-Null
    $stateRoot=Join-Path $sandbox 'version-state'
    $before=Get-ReleasePlan $repo @('google-play')
    $result=Invoke-ReleasePrepare $repo @('google-play') $stateRoot $engine -VersionChange patch
    Assert ($result.status -eq 'source-update-required') 'Source version update was exported before commit.'
    Assert (-not (Test-Path (Join-Path $result.statePath 'builds'))) 'Modified source was exported.'
    $settings=Get-ReleaseConfiguration $repo
    Assert ($settings.version -eq '1.2.4' -and $settings.presets[2].versionCode -eq 13) 'Requested version and separate Android counter did not advance.'
    $again=Invoke-ReleasePrepare $repo @('google-play') $stateRoot $engine -VersionChange patch
    Assert ($again.status -eq 'source-update-required' -and (Get-ReleaseConfiguration $repo).presets[2].versionCode -eq 13) 'Retry advanced the counter again.'
    Expect-Error {Invoke-ReleasePrepare $repo @('steam') $stateRoot $engine -VersionChange patch} 'selection|reservation'
    Invoke-FixtureGit $repo @('add','project.godot','export_presets.cfg') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Release version settings') | Out-Null
    $prepared=Invoke-ReleasePrepare $repo @('google-play') $stateRoot $engine -VersionChange patch
    Assert ($prepared.status -eq 'prepared') 'Committed reservation did not prepare.'
    $state=Get-Content (Join-Path $prepared.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert ($state.plan.head -eq (Invoke-FixtureGit $repo @('rev-parse','HEAD')) -and $state.plan.version -eq '1.2.4' -and $state.plan.destinations[4].versionCode -eq 13) 'Artifact provenance used the older source commit.'
    $manifest=$state.artifacts | ConvertTo-Json -Depth 20 -Compress
    $retry=Invoke-ReleasePrepare $repo @('google-play') $stateRoot $engine -VersionChange patch
    $state=Get-Content (Join-Path $retry.statePath 'state.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert (($state.artifacts | ConvertTo-Json -Depth 20 -Compress) -ceq $manifest -and (Get-ReleaseConfiguration $repo).presets[2].versionCode -eq 13) 'Prepared retry rebuilt or changed its code.'
}
Test 'version operations are explicit and holding Play leaves Android counters unchanged' {
    $repo=New-StoreFixture 'version-hold-play'
    Change-Config $repo {param($c) $c.androidVersionCodePolicy='increment-selected'}
    Invoke-FixtureGit $repo @('add','release.json') | Out-Null
    Invoke-FixtureGit $repo @('commit','--quiet','-m','Choose counter policy') | Out-Null
    $configHash=(Get-FileHash (Join-Path $repo 'export_presets.cfg')).Hash
    $result=Invoke-ReleasePrepare $repo @('steam') (Join-Path $sandbox 'version-hold-state') $engine
    Assert ($result.status -eq 'prepared' -and $configHash -eq (Get-FileHash (Join-Path $repo 'export_presets.cfg')).Hash) 'Holding Play changed Android settings.'
    Assert ((Get-ReleaseVersion '1.2.3' minor) -eq '1.3.0' -and (Get-ReleaseVersion '1.2.3' major) -eq '2.0.0' -and (Get-ReleaseVersion '1.2.3' current) -eq '1.2.3') 'Semantic version operations are missing.'
}
. (Join-Path $PSScriptRoot 'configuration-tests.ps1')
. (Join-Path $PSScriptRoot 'doctor-tests.ps1')
. (Join-Path $PSScriptRoot 'play-auth-tests.ps1')
. (Join-Path $PSScriptRoot 'host-runtime-tests.ps1')
Write-Output "Results: $script:Passed passed; $script:Failed failed. Fixture directory: $sandbox"
if ($script:Passed + $script:Failed -eq 0) {throw 'No tests matched Filter.'}
if ($script:Failed -gt 0) { exit 1 }

#requires -Version 7.2
param([string]$SkillRoot,[string]$Sandbox)
$ErrorActionPreference='Stop'
$sandbox=$Sandbox
$env:LOCALAPPDATA=Join-Path $sandbox 'profile/local'
$env:APPDATA=Join-Path $sandbox 'profile/roaming'
$global:FixtureRealGit=(Get-Command git -CommandType Application | Select-Object -First 1).Source
. "$PSScriptRoot/../TestSupport.ps1"
. "$PSScriptRoot/../GitHubFixture.ps1"
. "$PSScriptRoot/../ObsidianFixture.ps1"
Import-Module "$SkillRoot/scripts/Project.psm1"
Import-Module "$SkillRoot/scripts/State.psm1"
$global:CliApi=New-GitHubFixture -FailPhase labels
$global:CliPlugins=New-ObsidianFixture 'plugin seed'
$global:BoundaryCalls=[Collections.Generic.List[string]]::new()
$global:BoundaryLog=Join-Path $sandbox 'boundary.log'
# These process-local boundaries reject unknown requests; production adapters and CLI stay unchanged.
function global:gh {
    $arguments=@($args)
    if ($arguments[0] -ne 'api') {throw 'Unexpected GitHub command.'}
    $endpoint=$arguments[1];$method=$arguments[[Array]::IndexOf($arguments,'--method')+1]
    $body=$null;$inputIndex=[Array]::IndexOf($arguments,'--input')
    if ($inputIndex -ge 0) {$body=ConvertFrom-BootstrapJson ([IO.File]::ReadAllText($arguments[$inputIndex+1]))}
    $global:BoundaryCalls.Add("$method $endpoint")
    try {$reply=if ($endpoint -like '/repos/fixture/*/releases*') {& $global:CliPlugins.request $method $endpoint $body} else {& $global:CliApi.request $method $endpoint $body}}
    catch {Add-Content -LiteralPath $global:BoundaryLog -Value $_.Exception.ToString();throw}
    $global:LASTEXITCODE=if ($reply.StatusCode -lt 400) {0} else {1}
    "HTTP/2.0 $($reply.StatusCode) Fixture`nContent-Type: application/json`n`n$(ConvertTo-Json -InputObject $reply.Data -Depth 40 -Compress)"
}
function global:git {
    $arguments=@($args)
    $push=[Array]::IndexOf($arguments,'push')
    if ($push -ge 0) {
        Assert ($arguments[0] -eq '-C' -and $arguments[-2] -eq 'origin' -and $arguments[-1] -eq 'main') 'Unexpected push.'
        $repository=$arguments[1]
        $origin=& $global:FixtureRealGit -C $repository remote get-url origin
        $name=$origin -replace '^https://github.com/','' -replace '\.git$',''
        Assert ($global:CliApi.repos.ContainsKey($name)) 'Unowned fixture push.'
        & $global:FixtureRealGit -C $repository push $global:CliApi.repos[$name].bare main 2>&1
        $global:LASTEXITCODE=$LASTEXITCODE
        return
    }
    Assert (-not @($arguments | Where-Object {$_ -in @('clone','fetch','pull','ls-remote')}).Count) 'Network Git forbidden in offline CLI.'
    & $global:FixtureRealGit @arguments 2>&1
    $global:LASTEXITCODE=$LASTEXITCODE
}
function global:Invoke-WebRequest {
    param([string]$Uri,[string]$OutFile)
    $global:BoundaryCalls.Add("GET $Uri")
    if ($Uri -eq 'https://raw.githubusercontent.com/obsidianmd/obsidian-releases/master/community-plugins.json') {
        return @{Content=($global:CliPlugins.registry | ConvertTo-Json -Depth 20 -Compress)}
    }
    Assert ($global:CliPlugins.assets.ContainsKey($Uri)) "Unknown offline download: $Uri"
    if ($OutFile) {Write-FixtureText $OutFile $global:CliPlugins.assets[$Uri];return}
    return @{Content=[Text.Encoding]::UTF8.GetBytes($global:CliPlugins.assets[$Uri])}
}
function Invoke-Cli([hashtable]$Parameters) {
    $output=& "$SkillRoot/scripts/bootstrap.ps1" @Parameters
    $code=$LASTEXITCODE
    @{code=$code;report=ConvertFrom-BootstrapJson ($output -join "`n")}
}
$missing=Invoke-Cli @{Mode='create';Name='Missing Description'}
Assert ($missing.code -eq 1 -and $missing.report.status -eq 'missing-input' -and $global:BoundaryCalls.Count -eq 0) 'Missing input contacted a service.'
$discardIdentity=New-BootstrapIdentity -Name 'Abandoned CLI Project' -Description 'Purpose' -Parent $sandbox -Owner cicely-f
Import-Module "$SkillRoot/scripts/Presets.psm1"
$discardSelection=Resolve-BootstrapPreset $discardIdentity -Preset tauri
$discardJournal=New-BootstrapJournal $discardIdentity @() $discardSelection
$discardPath=Get-BootstrapJournalPath $discardIdentity;Write-BootstrapJournal $discardPath $discardJournal
$discard=Invoke-Cli @{Mode='discard';Name=$discardIdentity.title;Owner='cicely-f'}
Assert ($discard.code -eq 0 -and $discard.report.status -eq 'discarded' -and -not (Test-Path $discardPath) -and $global:BoundaryCalls.Count -eq 0) 'CLI discard failed, used the wrong owner or contacted GitHub.'
$parent=Join-Path $sandbox 'first parent with spaces'
New-Item -ItemType Directory -Path $parent | Out-Null
$parameters=@{Name='CLI Literal Project';Description='Literal $5, `ticks`, and $(never execute).';Parent=$parent;Preset='foundation'}
$plan=Invoke-Cli ($parameters+@{Mode='plan'})
Assert ($plan.code -eq 0 -and $plan.report.status -eq 'ready') 'CLI plan failed.'
Assert (-not (Test-Path $plan.report.identity.projectPath) -and -not (Test-Path $plan.report.journalPath)) 'Plan wrote checkout/state.'
Assert (@($global:CliApi.calls | Where-Object method -ne 'GET').Count -eq 0) 'Plan mutated repository.'
$create=Invoke-Cli ($parameters+@{Mode='create'})
Assert ($create.code -eq 1 -and $create.report.status -eq 'partial' -and $create.report.phases.privateRepository -eq 'verified') ($create | ConvertTo-Json -Depth 30)
$before=[IO.File]::ReadAllText($create.report.journalPath);$offset=$global:BoundaryCalls.Count
$conflicting=Invoke-Cli @{Mode='resume';Name=$parameters.Name;Preset='tauri'}
Assert ($conflicting.code -eq 1 -and $conflicting.report.status -eq 'blocked' -and ($conflicting.report.conflicts -join ' ') -match 'conflict') 'Conflicting preset accepted by CLI.'
Assert ($global:BoundaryCalls.Count -eq $offset -and [IO.File]::ReadAllText($create.report.journalPath) -ceq $before) 'Conflicting resume touched a service or journal.'
$global:CliApi.failPhase=''
$resume=Invoke-Cli @{Mode='resume';Name=$parameters.Name;Owner='Benevolent-Anarchy'}
Assert ($resume.code -eq 1 -and $resume.report.status -eq 'partial' -and $resume.report.phases.obsidian -eq 'needs-app') ($resume | ConvertTo-Json -Depth 30)
Assert ($resume.report.identity.description -ceq $parameters.Description -and $resume.report.identity.projectPath -eq $plan.report.identity.projectPath) 'Stored literal inputs changed.'
Assert ((Get-Content -Raw -LiteralPath "$($resume.report.identity.projectPath)/README.md").Contains($parameters.Description)) 'README changed literal description.'
$before=[IO.File]::ReadAllText($resume.report.journalPath);$offset=$global:CliApi.calls.Count
$status=Invoke-Cli @{Mode='status';Name=$parameters.Name;Owner='Benevolent-Anarchy'}
Assert ($status.code -eq 1 -and $status.report.status -eq 'partial') 'Status exit contract failed.'
Assert ([IO.File]::ReadAllText($resume.report.journalPath) -ceq $before) 'Status changed journal.'
Assert (@($global:CliApi.calls | Select-Object -Skip $offset | Where-Object method -ne 'GET').Count -eq 0) 'Status mutated repository.'
$id=$resume.report.identity
$clone=Join-Path (Join-Path $sandbox 'second parent with spaces') $id.repository
$cloneOutput=& $global:FixtureRealGit clone --quiet $global:CliApi.repos[$id.fullName].bare $clone 2>&1
Assert ($LASTEXITCODE -eq 0) ($cloneOutput -join "`n")
$checkoutOutput=& $global:FixtureRealGit -C $clone checkout --quiet main 2>&1
Assert ($LASTEXITCODE -eq 0) ($checkoutOutput -join "`n")
& $global:FixtureRealGit -C $clone remote set-url origin "https://github.com/$($id.fullName).git"
$offset=$global:CliApi.calls.Count
$engineSetup=Invoke-Cli @{Mode='local-setup';Repository=$clone;Preset='tauri'}
Assert ($engineSetup.code -eq 1 -and $engineSetup.report.status -eq 'blocked' -and ($engineSetup.report.conflicts -join ' ') -match 'Obsidian only') 'local-setup accepted engine conversion.'
Assert ($global:CliApi.calls.Count -eq $offset -and -not (Test-Path "$clone/docs/.obsidian")) 'Rejected engine setup changed the clone or contacted GitHub.'
$local=Invoke-Cli @{Mode='local-setup';Repository=$clone}
Assert ($local.code -eq 1 -and $local.report.status -eq 'partial' -and $local.report.installedVerified -and -not $local.report.enabledVerified) ($local | ConvertTo-Json -Depth 20)
Assert (@($global:CliApi.calls | Select-Object -Skip $offset | Where-Object method -ne 'GET').Count -eq 0) 'Clone setup mutated GitHub.'
Assert (@($global:CliApi.calls | Where-Object isRepositoryCreate).Count -eq 2) 'Duplicate repositories created.'
Assert ((Get-Content -Raw "$clone/docs/.obsidian/plugins/vault-nickname/data-shared.json" | ConvertFrom-Json).nickname -ceq $id.title) 'Clone nickname wrong.'
@{missing=$missing;plan=$plan;create=$create;resume=$resume;status=$status;local=$local;boundaryCalls=$global:BoundaryCalls.Count;creates=2;clone=$clone} | ConvertTo-Json -Depth 40

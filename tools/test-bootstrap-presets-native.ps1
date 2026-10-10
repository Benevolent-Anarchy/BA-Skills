#requires -Version 7.2
[CmdletBinding()]
param([ValidateSet('godot','tauri','all')][string]$Preset='all',[string]$FixtureParent)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$skill=Join-Path $root 'skills/ba-bootstrap'
foreach ($module in @('Project','Presets','State','Preparation')) {Import-Module "$skill/scripts/$module.psm1" -Force}
Import-Module "$skill/assets/project/tools/Verification.psm1" -Force
if (-not $FixtureParent) {$FixtureParent=[IO.Path]::GetTempPath()}
$parent=[IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($FixtureParent))
$runName='ba-native-'+[guid]::NewGuid().ToString('N').Substring(0,12)
$run=Join-Path $parent $runName
$evidence=Join-Path $root ".test-results/ba-bootstrap-presets/$runName"
Assert-BootstrapOwnedPath $parent $run
if(Test-Path -LiteralPath $run){throw 'Native fixture path already exists.'}
[IO.Directory]::CreateDirectory($run) | Out-Null
[IO.Directory]::CreateDirectory($evidence) | Out-Null
$commands=[Collections.Generic.List[object]]::new();$results=[Collections.Generic.List[object]]::new()
$git=(Get-Command git -CommandType Application | Select-Object -First 1).Source
$pwsh=(Get-Process -Id $PID).Path
function Invoke-NativeCommand([string]$Exe,[string[]]$Arguments,[string]$Directory,[hashtable]$Environment=@{},[switch]$AllowFailure) {
    $reply=Invoke-VerificationProcess $Exe $Arguments $Directory $Environment
    $log=Join-Path $evidence ('command-'+$commands.Count+'.log')
    [IO.File]::WriteAllText($log,$reply.Output,[Text.UTF8Encoding]::new($false))
    $commands.Add(@{executable=$Exe;arguments=$Arguments;directory=$Directory;exitCode=$reply.ExitCode;log=$log})
    if (-not $AllowFailure -and $reply.ExitCode -ne 0) {throw "Native command failed ($($reply.ExitCode)); see $log"}
    return $reply
}
$process={param($exe,$arguments,$cwd,$environment) Invoke-NativeCommand $exe $arguments $cwd $environment -AllowFailure}
function Invoke-NativeGate([string]$Directory,[string]$Label,[string]$FailurePattern) {
    Write-Host "Native gate: $Label"
    $reply=Invoke-NativeCommand $pwsh @('-NoProfile','-File',"$Directory/tools/verify.ps1") $Directory -AllowFailure
    if ($FailurePattern) {
        if ($reply.ExitCode -eq 0 -or $reply.Output -notmatch $FailurePattern) {throw "Expected $Label failure was not detected; $($reply.Output)"}
    } elseif ($reply.ExitCode -ne 0) {throw "$Label gate failed; see $($commands[$commands.Count-1].log)"}
    return @{label=$Label;exitCode=$reply.ExitCode;output=$reply.Output}
}
function Assert-NativeTree([string]$Directory,[object[]]$Manifest,[hashtable]$Selection) {
    Assert-BootstrapPreparedBytes $Directory $Manifest
    $status=(Invoke-NativeCommand $git @('-C',$Directory,'status','--porcelain') $run).Output.Trim()
    if ($status) {throw "Native gate left the checkout dirty: $status"}
    $paths=(Invoke-NativeCommand $git @('-C',$Directory,'ls-tree','-r','--name-only','HEAD') $run).Output.Trim() -split "`r?`n"
    if ((@($paths | Sort-Object) -join "`n") -cne (@($Manifest.path | Sort-Object) -join "`n")) {throw 'Initial tree differs from frozen paths.'}
    # One batch compares raw working bytes with every committed blob, including binary icons.
    $hashes=(Invoke-NativeCommand $git (@('-C',$Directory,'hash-object','--no-filters','--')+@($Manifest.path)) $run).Output.Trim() -split "`r?`n"
    $tree=(Invoke-NativeCommand $git @('-C',$Directory,'ls-tree','-r','HEAD') $run).Output.Trim() -split "`r?`n"
    $blobs=@{};foreach($line in $tree){if($line -notmatch '^100(?:644|755) blob ([0-9a-f]+)\t(.+)$'){throw 'Unexpected native tree entry.'};$blobs[$Matches[2]]=$Matches[1]}
    for($index=0;$index -lt $Manifest.Count;$index++){if($hashes[$index] -cne $blobs[$Manifest[$index].path]){throw "Committed bytes differ: $($Manifest[$index].path)"}}
    $exclude=Join-Path $Directory '.git/native-empty-excludes';[IO.File]::WriteAllText($exclude,'')
    $prefix=@('-C',$Directory,'-c',"core.excludesFile=$exclude",'check-ignore','--no-index','--')
    $required=Invoke-NativeCommand $git ($prefix+@($Manifest.path)) $run -AllowFailure
    if($required.ExitCode -ne 1){throw "Required source is ignored: $($required.Output)"}
    $outputs=@('dist/native.zip','nested/dist/native.zip','.test-results/native.json','docs/.obsidian/app.json','docs/Vault Inspector Reports/native.md')
    $outputs+=if($Selection.name -eq 'godot'){@('.godot/cache','android/build/cache','.mono/temp/cache','export_credentials.cfg')}else{@('node_modules/package/cache','src-tauri/target/cache','src-tauri/gen/schemas/config.json')}
    foreach($output in $outputs){$ignored=Invoke-NativeCommand $git ($prefix+@($output)) $run -AllowFailure;if($ignored.ExitCode -ne 0){throw "Generated output is not ignored: $output"}}
    if($Selection.name -eq 'godot') {
        $addable=@('addons/x/bin/lib.dll','assets/obj/ship.obj.import','bin/source.gd','obj/source.gd')
        $source=Invoke-NativeCommand $git ($prefix+$addable) $run -AllowFailure
        if($source.ExitCode -ne 1){throw "Godot addon or asset source is ignored: $($source.Output)"}
    }
    return @{status=$status;sourceHash=(Get-BootstrapTemplateVersion $Manifest);trackedPaths=$Manifest.Count;binaryPaths=@($Manifest.path | Where-Object {$_ -match '\.(png|ico|icns)$'})}
}
function Invoke-NativeNegative([string]$Directory,[string]$Label,[string]$Relative,[string]$Fixture,[string]$Pattern) {
    $target=Join-Path $Directory $Relative
    Assert-BootstrapOwnedPath $run $target
    $bytes=[IO.File]::ReadAllBytes($target)
    try {
        [IO.File]::WriteAllBytes($target,[IO.File]::ReadAllBytes((Join-Path $root "tests/bootstrap/fixtures/native/$Fixture")))
        return Invoke-NativeGate $Directory $Label $Pattern
    } finally {Assert-BootstrapOwnedPath $run $target;[IO.File]::WriteAllBytes($target,$bytes)}
}
try {
    $variants=if($Preset -eq 'godot'){@('compatibility','forward-plus','mobile')}elseif($Preset -eq 'tauri'){@('tauri')}else{@('compatibility','forward-plus','mobile','tauri')}
    foreach ($variant in $variants) {
        $kind=if($variant -eq 'tauri'){'tauri'}else{'godot'}
        $id=New-BootstrapIdentity -Name "Native $kind $variant" -Description 'Local native bootstrap validation.' -Parent (Join-Path $run 'original with spaces')
        $selection=if($kind -eq 'godot'){Resolve-BootstrapPreset $id -Preset godot -Renderer $variant}else{Resolve-BootstrapPreset $id -Preset tauri}
        $prerequisites=Get-BootstrapPrerequisites $selection
        if(-not $prerequisites.passed){throw ($prerequisites | ConvertTo-Json -Depth 10)}
        $state=Join-Path $run "state-$variant"
        $journal=New-BootstrapJournal $id @() $selection;$path=Get-BootstrapJournalPath $id $state
        $checkpoint={param($phase,$value) $journal.preparation.checkpoints[$phase]=$value;Write-BootstrapJournal $path $journal}.GetNewClosure()
        Write-Host "Preparing native $variant starter"
        $prepared=Initialize-BootstrapPreparation $id $selection $journal $state $checkpoint -Process $process
        Save-BootstrapPreparedProject $journal $path $null $prepared.sourcePath $prepared.manifest
        $frozen=Read-BootstrapPreparedProject $journal $state
        Write-BootstrapManifest $id.projectPath $frozen.manifest | Out-Null
        Install-BootstrapLockedDependencies $id.projectPath $selection $process
        $bare=Join-Path $run "$variant.git"
        $null=Invoke-NativeCommand $git @('init','--bare','--initial-branch=main',$bare) $run
        $null=Invoke-NativeCommand $git @('init','--initial-branch=main',$id.projectPath) $run
        $null=Invoke-NativeCommand $git @('-C',$id.projectPath,'config','user.name','Bootstrap Native Test') $run
        $null=Invoke-NativeCommand $git @('-C',$id.projectPath,'config','user.email','bootstrap-native@example.invalid') $run
        $null=Invoke-NativeCommand $git (@('-C',$id.projectPath,'add','-f','--')+@($frozen.manifest.path)) $run
        $null=Invoke-NativeCommand $git @('-C',$id.projectPath,'-c','commit.gpgSign=false','commit','-m','Frozen native starter') $run
        $null=Invoke-NativeCommand $git @('-C',$id.projectPath,'push',$bare,'main') $run
        $originalGate=Invoke-NativeGate $id.projectPath "$variant original"
        $originalTree=Assert-NativeTree $id.projectPath $frozen.manifest $selection
        $clone=Join-Path $run "fresh clone with spaces/$variant"
        $null=Invoke-NativeCommand $git @('clone','--no-hardlinks',$bare,$clone) $run
        Install-BootstrapLockedDependencies $clone $selection $process
        $cloneGate=Invoke-NativeGate $clone "$variant fresh clone"
        $cloneTree=Assert-NativeTree $clone $frozen.manifest $selection
        $negative=[Collections.Generic.List[object]]::new()
        if($variant -in @('compatibility','tauri')) {
            $negative.Add((Invoke-NativeNegative $clone 'broken docs' 'README.md' 'broken-docs.md' 'documentation: FAILED'))
            if($kind -eq 'godot') {
                $negative.Add((Invoke-NativeNegative $clone 'Godot compilation' 'test/test_main.gd' 'broken-godot.gd' 'godot-(compile|import): FAILED'))
                $dependency=Join-Path $clone 'addons/gut/gut_cmdln.gd'
            } else {
                $negative.Add((Invoke-NativeNegative $clone 'TypeScript compilation' 'src/main.ts' 'broken-typescript.ts' 'typescript: FAILED'))
                $negative.Add((Invoke-NativeNegative $clone 'frontend assertion' 'src/main.test.ts' 'failing-frontend.test.ts' 'frontend-tests: FAILED'))
                $negative.Add((Invoke-NativeNegative $clone 'frontend all skipped' 'src/main.test.ts' 'skipped-frontend.test.ts' 'frontend-tests: FAILED'))
                $negative.Add((Invoke-NativeNegative $clone 'Rust compilation' 'src-tauri/src/lib.rs' 'broken-rust.rs' '(rust-lint|rust-tests|tauri-build): FAILED'))
                $dependency=Join-Path $clone 'src-tauri/Cargo.lock'
            }
            $hidden=$dependency+'.native-hidden'
            Assert-BootstrapOwnedPath $run $dependency;Assert-BootstrapOwnedPath $run $hidden
            Move-Item -LiteralPath $dependency -Destination $hidden
            try {$negative.Add((Invoke-NativeGate $clone 'missing required dependency' '(gut-headless|tauri): FAILED|Missing|required.*missing'))}
            finally {Assert-BootstrapOwnedPath $run $hidden;Move-Item -LiteralPath $hidden -Destination $dependency}
            $restored=Invoke-NativeGate $clone "$variant restored"
            $cloneTree=Assert-NativeTree $clone $frozen.manifest $selection
            if($kind -eq 'godot'){$null=Invoke-NativeCommand $pwsh @('-NoProfile','-File',"$clone/tools/verify_selftest.ps1") $clone}
        }
        $reportRoots=if($kind -eq 'godot'){@(Get-ChildItem "$clone/.godot" -Directory -Filter 'ba-verify-*' | ForEach-Object {$_.FullName})}else{@("$clone/.test-results")}
        $reports=@($reportRoots | ForEach-Object {Get-ChildItem $_ -Recurse -File -ErrorAction SilentlyContinue} | Where-Object {$_.Extension -in @('.json','.xml')} | ForEach-Object {@{path=$_.FullName;content=[IO.File]::ReadAllText($_.FullName)}})
        if($reports.Count -eq 0){throw 'Native gate produced no retained test reports.'}
        $results.Add(@{preset=$selection;prerequisites=$prerequisites;resolution=$journal.resolution;manifest=$journal.manifest;original=$id.projectPath;clone=$clone;originalGate=$originalGate;cloneGate=$cloneGate;originalTree=$originalTree;cloneTree=$cloneTree;negative=$negative.ToArray();testReports=$reports})
        @{passed=$true;results=$results.ToArray();commands=$commands.ToArray()} | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath "$evidence/receipt.json" -Encoding utf8NoBOM
    }
    Write-Output "Native preset validation passed. Evidence: $evidence; retained fixtures: $run"
} catch {
    @{passed=$false;error=$_.Exception.Message;results=$results.ToArray();commands=$commands.ToArray()} | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath "$evidence/receipt.json" -Encoding utf8NoBOM
    throw
}

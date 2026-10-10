Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Project.psm1')
Import-Module (Join-Path $PSScriptRoot 'Dependencies.psm1')
Import-Module (Join-Path $PSScriptRoot 'Preparation.psm1')
Import-Module (Join-Path $PSScriptRoot '../assets/project/tools/Verification.psm1')
Import-Module (Join-Path $PSScriptRoot '../assets/presets/godot/tools/GodotVerification.psm1')
function Initialize-GodotPreset {
    param([hashtable]$Identity,[hashtable]$Selection,[hashtable]$Resolution,[string]$Repository,[scriptblock]$Download={param($uri,$path) Invoke-WebRequest -Uri $uri -OutFile $path | Out-Null},[scriptblock]$Process={param($exe,$arguments,$cwd,$environment) Invoke-VerificationProcess $exe $arguments $cwd $environment},[hashtable]$Checkpoints=@{},[scriptblock]$Checkpoint={param($phase,$value)})
    if ($Selection.name -cne 'godot' -or $Resolution.selections.gut -cne '9.7.1') {throw 'Godot recipe requires the recorded GUT 9.7.1 resolution.'}
    if ($Checkpoints.ContainsKey('godot-ready')) {
        Assert-BootstrapPreparedBytes $Repository $Checkpoints['godot-ready'].manifest
        return @{trackedPaths=@($Checkpoints['godot-ready'].manifest.path);receipts=@($Checkpoints['gut-acquired'])}
    }
    if (-not $Checkpoints.ContainsKey('godot-source')) {
        if ($Checkpoints.ContainsKey('godot-source-started')) {throw 'Godot source has no completion receipt. Preserve unresolved preparation and recover with the recorded recipe.'}
        $Checkpoints['godot-source-started']=@{startedAt=[DateTime]::UtcNow.ToString('o')}
        & $Checkpoint 'godot-source-started' $Checkpoints['godot-source-started'] | Out-Null
    $root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../assets/presets/godot'))
    $renderer=@{compatibility='gl_compatibility';'forward-plus'='forward_plus';mobile='mobile'}[$Selection.renderer]
    $feature=@{compatibility='GL Compatibility';'forward-plus'='Forward Plus';mobile='Mobile'}[$Selection.renderer]
    $manifest=@(foreach ($file in Get-ChildItem $root -Recurse -File -Force | Where-Object Name -ne 'gitignore.fragment') {
        $path=[IO.Path]::GetRelativePath($root,$file.FullName).Replace('\','/');$bytes=[IO.File]::ReadAllBytes($file.FullName)
        if ($path.EndsWith('.template') -or [IO.Path]::GetExtension($path) -in @('.gd','.godot','.tscn','.cfg','.uid','.import','.ps1','.psm1','.txt','.json','.svg') -or $file.Name -in @('.gdignore','.gitkeep')) {$bytes=ConvertTo-BootstrapTextBytes $bytes}
        if ($path.EndsWith('.template')) {
            $path=$path.Substring(0,$path.Length-9)
            $text=[Text.Encoding]::UTF8.GetString($bytes).Replace('{{TITLE_JSON}}',($Identity.title | ConvertTo-Json -Compress)).Replace('{{FEATURE_JSON}}',($feature | ConvertTo-Json -Compress)).Replace('{{RENDERER_JSON}}',($renderer | ConvertTo-Json -Compress))
            $bytes=[Text.Encoding]::UTF8.GetBytes($text)
        }
        @{path=$path;bytes=$bytes;sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()}
    })
    Write-BootstrapManifest $Repository $manifest | Out-Null
    $dependencies=$Repository+'.dependencies';[IO.Directory]::CreateDirectory($dependencies) | Out-Null
    $artifact=$Resolution.artifacts[0].Clone()
    if ($Checkpoints.ContainsKey('gut-acquired')) {$artifact.sha256=$Checkpoints['gut-acquired'].sha256}
    $receipt=Receive-BootstrapArtifact $artifact "$dependencies/gut.zip" $Download
    $Checkpoints['gut-acquired']=$receipt
    & $Checkpoint 'gut-acquired' $receipt | Out-Null
    $source=Expand-BootstrapSourceArchive "$dependencies/gut.zip" "$dependencies/gut" @('addons/gut/plugin.cfg','addons/gut/gut_cmdln.gd','addons/gut/LICENSE.md')
    $gut=@(foreach ($file in Get-ChildItem "$source/addons/gut" -Recurse -File -Force) {
        $bytes=[IO.File]::ReadAllBytes($file.FullName)
        @{path=[IO.Path]::GetRelativePath($source,$file.FullName).Replace('\','/');bytes=$bytes;sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()}
    })
    Write-BootstrapManifest $Repository $gut | Out-Null
    $config=@{schemaVersion=1;preset='godot';requiredChecks=@('documentation','godot-import','godot-compile','gut-headless');godot=@{versionFamily='4.7';renderedTests=$false}}
    [IO.File]::WriteAllText("$Repository/tools/verify.json",(($config | ConvertTo-Json -Depth 5)+"`n").Replace("`r`n","`n"),[Text.UTF8Encoding]::new($false))
    [IO.File]::AppendAllText("$Repository/.gitignore",[IO.File]::ReadAllText("$root/gitignore.fragment").Replace("`r`n","`n"),[Text.UTF8Encoding]::new($false))
    $sourcePaths=@(Get-ChildItem $Repository -Recurse -File -Force | Where-Object {$_.FullName -notmatch '[\\/]\.(godot|git)[\\/]'} | ForEach-Object {[IO.Path]::GetRelativePath($Repository,$_.FullName).Replace('\','/')})
    $sourceManifest=@(Get-BootstrapPreparedManifest $Repository $sourcePaths)
    $Checkpoints['godot-source']=@{manifest=@($sourceManifest | ForEach-Object {@{path=$_.path;sha256=$_.sha256}})}
    & $Checkpoint 'godot-source' $Checkpoints['godot-source'] | Out-Null
    }
    Assert-BootstrapPreparedBytes $Repository $Checkpoints['godot-source'].manifest
    $exe=Get-VerificationGodot
    $import=& $Process $exe @('--headless','--path',$Repository,'--import') $Repository @{}
    if ($import.ExitCode -ne 0) {throw "Godot preparation import failed: $($import.Output)"}
    $files=@(Get-GodotSourceFiles $Repository)
    foreach ($gd in $files | Where-Object Extension -eq '.gd') {if (-not (Test-Path ($gd.FullName+'.uid') -PathType Leaf)) {throw "Godot did not retain source UID: $($gd.Name)"}}
    $paths=@(Get-ChildItem $Repository -Recurse -File -Force | Where-Object {$_.FullName -notmatch '[\\/]\.(godot|git)[\\/]'} | ForEach-Object {[IO.Path]::GetRelativePath($Repository,$_.FullName).Replace('\','/')})
    $ready=@(Get-BootstrapPreparedManifest $Repository $paths)
    $Checkpoints['godot-ready']=@{manifest=@($ready | ForEach-Object {@{path=$_.path;sha256=$_.sha256}})}
    & $Checkpoint 'godot-ready' $Checkpoints['godot-ready'] | Out-Null
    return @{trackedPaths=$paths;receipts=@($Checkpoints['gut-acquired'])}
}
Export-ModuleMember -Function Initialize-GodotPreset

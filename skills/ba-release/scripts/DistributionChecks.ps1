# Verifies each Butler file selection and tests desktop exports with excluded Steam files genuinely absent.

# Applies the supported basename patterns using case-sensitive matching, as Butler does.
function Test-ReleaseIgnoredFile([string]$Name, [string[]]$Patterns) {
    foreach ($pattern in $Patterns) {
        if ([Management.Automation.WildcardPattern]::new($pattern,[Management.Automation.WildcardOptions]::None).IsMatch($Name)) {return $true}
    }
    return $false
}

# A signed Android APK is the store payload; its optional v4 sidecar stays local.
function Get-ReleaseButlerInput([string]$Directory, $Preset, $Destination) {
    if ($Preset.platform -ne 'Android') {return $Directory}
    $apk=Join-Path $Directory $Preset.filename
    if (-not (Test-Path -LiteralPath $apk -PathType Leaf)) {throw 'Prepared signed APK is missing.'}
    $unexpected=@(Get-ChildItem -LiteralPath $Directory -Recurse -File | Where-Object {
        $_.FullName -cne $apk -and $_.FullName -cne ($apk+'.idsig') -and -not (Test-ReleaseIgnoredFile $_.Name $Destination.ignore)
    })
    if ($unexpected.Count) {throw 'Additional Android payload files need an explicitly supported distribution configuration.'}
    return $apk
}

# Checks the approved common artifact in place, restoring withheld files before any publication.
function Invoke-ReleaseDistributionChecks($Settings, $State, [string]$StatePath, [string]$ButlerExecutable, [scriptblock]$Save) {
    if (-not $State.Contains('checks')) {$State.checks=[ordered]@{}}
    foreach ($destination in @($State.plan.destinations | Where-Object {$_.selected -and $_.type -eq 'itch'})) {
        $artifact=@($State.artifacts | Where-Object {$_.preset -ceq $destination.preset})[0]
        $directory=Resolve-ReleasePath $StatePath $artifact.directory -MustExist
        $preset=@($Settings.presets | Where-Object {$_.name -ceq $destination.preset})[0]
        if (-not $State.checks.Contains($destination.id)) {$State.checks[$destination.id]=@{standalone='pending';dryRun='pending';error=$null}}
        $record=$State.checks[$destination.id]
        $inputPath=if ($preset.platform -eq 'Android') {Join-Path $directory $preset.filename} else {$directory}
        $inputRelative=[IO.Path]::GetRelativePath($StatePath,$inputPath).Replace('\','/')
        if ($record.standalone -in @('succeeded','not-applicable') -and $record.dryRun -eq 'succeeded' -and
            ($preset.platform -ne 'Android' -or ($record.Contains('input') -and $record.input -ceq $inputRelative))) {continue}
        $files=@(Get-ChildItem -LiteralPath $directory -Recurse -File)
        $excluded=@($files | Where-Object {Test-ReleaseIgnoredFile $_.Name $destination.ignore})
        $included=@($files | Where-Object {-not (Test-ReleaseIgnoredFile $_.Name $destination.ignore)})
        try {
            $inputPath=Get-ReleaseButlerInput $directory $preset $destination
            if ($preset.platform -eq 'Android') {
                $included=@($files | Where-Object {$_.FullName -ceq $inputPath})
                $excluded=@($files | Where-Object {$_.FullName -cne $inputPath})
            }
            if ($preset.platform -ne 'Android' -and $record.standalone -ne 'succeeded') {
                $check=@($Settings.config.standalone | Where-Object {$_.preset -ceq $destination.preset})[0]
                $hold=Join-Path $StatePath ('standalone-withheld/'+[guid]::NewGuid().ToString('N'))
                $moves=[Collections.Generic.List[object]]::new()
                try {
                    foreach ($file in $excluded) {
                        $target=Join-Path $hold ([IO.Path]::GetRelativePath($directory,$file.FullName))
                        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
                        Move-Item -LiteralPath $file.FullName -Destination $target
                        $moves.Add(@{original=$file.FullName;held=$target})
                    }
                    $arguments=@($check.arguments | ForEach-Object {$_.Replace('{artifact}',$directory).Replace('{platform}',$preset.platform).Replace('{repository}',$Settings.repository).Replace('{filename}',$preset.filename)})
                    $result=Invoke-ReleaseTool (Resolve-ReleasePath $Settings.repository $check.script -Leaf) $arguments $directory
                    if ($result.exitCode -ne 0) {throw 'Standalone functionality check failed.'}
                    $record.standalone='succeeded'
                } finally {
                    foreach ($move in $moves) {
                        if (Test-Path -LiteralPath $move.original) {throw 'Standalone check recreated a withheld file; inspect before restoring or publishing.'}
                        Move-Item -LiteralPath $move.held -Destination $move.original
                    }
                }
                Assert-ReleaseArtifacts $StatePath $State
            } elseif ($preset.platform -eq 'Android') {$record.standalone='not-applicable'}
            $arguments=@('push',$inputPath,$destination.target,'--dry-run','--userversion',$State.plan.version)
            foreach ($pattern in $destination.ignore) {$arguments+=@('--ignore',$pattern)}
            $preview=Invoke-ReleaseTool $ButlerExecutable $arguments $StatePath
            if ($preview.exitCode -ne 0) {throw 'Butler dry-run failed.'}
            $text=$preview.text -replace '\x1b\[[0-9;]*[A-Za-z]',''
            foreach ($file in $excluded) {
                $relative=[IO.Path]::GetRelativePath($directory,$file.FullName).Replace('\','/')
                if ($text -match ('(?m)(?:^|\s)'+[regex]::Escape($relative)+'\s*$')) {throw 'Butler dry-run includes an excluded Steam file.'}
            }
            foreach ($file in $included) {
                $relative=[IO.Path]::GetRelativePath($directory,$file.FullName).Replace('\','/')
                if ($text -notmatch ('(?m)(?:^|\s)'+[regex]::Escape($relative)+'\s*$')) {throw 'Butler dry-run did not list every approved artifact file.'}
            }
            $record.dryRun='succeeded';$record.error=$null
            $record.input=$inputRelative
            $record.included=@($included | ForEach-Object {[IO.Path]::GetRelativePath($directory,$_.FullName).Replace('\','/')})
            $record.excluded=@($excluded | ForEach-Object {[IO.Path]::GetRelativePath($directory,$_.FullName).Replace('\','/')})
            $record.previewSha256=Get-ReleaseTextHash $text
            [IO.File]::WriteAllText((Join-Path $StatePath "selection.$($destination.id).txt"),$text,[Text.UTF8Encoding]::new($false))
            & $Save
        } catch {$record.error='Standalone test or Butler file-selection check failed; inspect local configuration and withheld files.';& $Save;throw}
    }
}

# Inspects local prerequisites for explicit destinations without exports, sign-in or remote operations.

# Reads Godot's documented host directories, including editor self-contained mode.
function Get-ReleaseDoctorDirectories([string]$Engine) {
    if ($Engine) {
        $engineItem=Get-Item -LiteralPath $Engine
        if ($engineItem.LinkType) {$engineItem=$engineItem.ResolveLinkTarget($true)}
        $engineDirectory=Split-Path $engineItem.FullName -Parent
        if ((Test-Path -LiteralPath (Join-Path $engineDirectory '_sc_')) -or (Test-Path -LiteralPath (Join-Path $engineDirectory '._sc_'))) {
            $data=Join-Path $engineDirectory 'editor_data';return @{data=$data;settings=$data}
        }
    }
    $profile=[Environment]::GetFolderPath('UserProfile')
    if ($IsWindows) {$data=Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Godot';return @{data=$data;settings=$data}}
    if ($IsMacOS) {$data=Join-Path $profile 'Library/Application Support/Godot';return @{data=$data;settings=$data}}
    $dataBase=if ($env:XDG_DATA_HOME) {$env:XDG_DATA_HOME} else {Join-Path $profile '.local/share'}
    $settingsBase=if ($env:XDG_CONFIG_HOME) {$env:XDG_CONFIG_HOME} else {Join-Path $profile '.config'}
    return @{data=(Join-Path $dataBase 'godot');settings=(Join-Path $settingsBase 'godot')}
}

# Reports presence separately from unverified remote access and signing correctness.
function Get-ReleaseDoctor {
    param([string]$Repository,[string[]]$Destination=@(),[string]$GodotExecutable,
        [string]$ButlerExecutable='butler',[string]$SteamCmdExecutable='steamcmd',[string]$GhExecutable='gh',
        [string]$TemplateRoot,[string]$EditorSettingsPath,[string]$AndroidSdkPath,[string]$JavaSdkPath,
        [ValidateRange(1,60)][int]$ProbeTimeoutSeconds=15)
    $settings=Get-ReleaseConfiguration $Repository
    $plan=Get-ReleasePlan -Repository $Repository -Destination $Destination
    $checks=[Collections.Generic.List[object]]::new()
    $add={param($id,$status,$message) $checks.Add([ordered]@{id=$id;status=$status;message=$message})}
    & $add 'plan' $(if ($plan.ready) {'passed'} else {'blocked'}) $(if ($plan.ready) {'Configuration, selected baselines and source are ready.'} else {$plan.blockers -join ' '})
    $selected=@($plan.destinations | Where-Object {$_.selected})
    $types=@($selected | ForEach-Object {$_.type})
    foreach ($tool in @(@{id='butler';type='itch';path=$ButlerExecutable},@{id='steamcmd';type='steam';path=$SteamCmdExecutable},@{id='gh';type='notes';path=$GhExecutable})) {
        if ($tool.type -notin $types) {& $add $tool.id 'skipped' 'Destination not selected.';continue}
        $found=Find-ReleaseDoctorTool $tool.path
        & $add $tool.id $(if ($found) {'passed'} else {'blocked'}) $(if ($found) {"Executable found: $found"} else {"Executable missing; supply the runtime path for $($tool.id)."})
    }
    foreach ($auth in @(@{id='steam-auth';type='steam';variable='BA_STEAM_USERNAME'},@{id='play-auth';type='google-play';variable='BA_GOOGLE_PLAY_ACCESS_TOKEN'})) {
        if ($auth.type -notin $types) {& $add $auth.id 'skipped' 'Destination not selected.';continue}
        $present=-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($auth.variable))
        & $add $auth.id $(if ($present) {'unverified'} else {'blocked'}) $(if ($present) {'Runtime authentication input exists; account access/expiry is not verified.'} else {"Provide $($auth.variable) at runtime; browser sign-in does not authenticate this adapter."})
    }
    if ('itch' -in $types) {& $add 'itch-auth' 'unverified' 'Verify the existing Butler login and selected target access before publication; no sign-in was attempted.'}
    if ('notes' -in $types) {& $add 'notes-access' 'unverified' 'Verify the public notes repository and GitHub write permission before publication; no network request was made.'}
    if ($plan.Contains('sourceTag')) {
        # A tag this checkout already has on the release's source is pushed as it is, so only a tag still to be made needs a tagger.
        $local=try {Get-ReleaseLocalTagCommit $settings.repository $plan.sourceTag.name} catch {$null}
        $unverified='push access to origin and existing tags there are not verified, as no network request was made.'
        if ($local -ceq $plan.sourceTag.commit) {& $add 'source-tag' 'unverified' "This checkout's tag $($plan.sourceTag.name) already names the release's source and is pushed as it is; $unverified"}
        else {
            $identity=Invoke-ReleaseTool 'git' @('--no-optional-locks','-C',$settings.repository,'var','GIT_COMMITTER_IDENT') $settings.repository
            & $add 'source-tag' $(if ($identity.exitCode -eq 0) {'unverified'} else {'blocked'}) $(if ($identity.exitCode -eq 0) {"Git can name the annotated tag's tagger; $unverified"} else {'Git has no tagger identity for the annotated release tag; set user.name and user.email for this checkout.'})
        }
    }
    $engine=$null;$engineVersion=$null;$directories=$null
    if ($plan.requiredExports.Count) {
        try {$engine=Get-ReleaseEngine $GodotExecutable} catch {}
        & $add 'godot' $(if ($engine) {'passed'} else {'blocked'}) $(if ($engine) {"Executable found: $engine"} else {'Godot executable missing; supply -GodotExecutable.'})
        if ($engine) {
            $versionError='Godot version was unreadable or the bounded probe failed.'
            try {$version=Invoke-ReleaseProbe $engine @('--version') ([IO.Path]::GetTempPath()) $ProbeTimeoutSeconds}
            catch {$version=@{exitCode=125;text=''};$versionError='Godot version probe could not start; check executable format and execute permission.'}
            $text=$version.text.Trim()
            if ($version.exitCode -eq 0 -and $text -match '^(\d+\.\d+(?:\.\d+)?)\.(stable|beta\d*|rc\d*|dev\d*)(?:\.|$)') {
                $engineVersion=$Matches[1]+'.'+$Matches[2]
                $engineMinor=($Matches[1].Split('.')[0..1] -join '.')
                $projectText=[IO.File]::ReadAllText((Join-Path $settings.projectPath 'project.godot'))
                $required=if ($projectText -match '(?m)^config/features=PackedStringArray\("(\d+\.\d+)"') {$Matches[1]} else {$null}
                & $add 'godot-version' $(if (-not $required -or $required -ceq $engineMinor) {'passed'} else {'blocked'}) $(if ($required -and $required -cne $engineMinor) {"Project requires Godot $required; selected engine is $engineVersion."} else {"Selected engine: $engineVersion. The project's complete gate still determines compatibility."})
            } else {& $add 'godot-version' 'blocked' $versionError}
            $directories=Get-ReleaseDoctorDirectories $engine
        }
        if (-not $TemplateRoot -and $directories) {$TemplateRoot=Join-Path $directories.data 'export_templates'}
        $sections=Read-GodotSections (Join-Path $settings.projectPath 'export_presets.cfg')
        foreach ($preset in $plan.requiredExports) {
            $section=@($sections.Keys | Where-Object {$_ -match '^preset\.\d+$' -and $sections[$_]['name'] -ceq $preset.name})[0]
            $options=if ($sections.Contains($section+'.options')) {$sections[$section+'.options']} else {@{}}
            $architecture=if ($options.Contains('binary_format/architecture')) {$options['binary_format/architecture']} else {'x86_64'}
            $custom=$options['custom_template/release']
            $useGradle=$preset.platform -eq 'Android' -and $options['gradle_build/use_gradle_build'] -eq $true
            if ($useGradle) {$custom=$options['gradle_build/android_source_template']}
            $files=if ($preset.platform -eq 'Windows Desktop') {@("windows_release_$architecture.exe")} elseif ($preset.platform -eq 'Linux') {@("linux_release.$architecture")} elseif ($useGradle) {@('android_source.zip')} else {@('android_release.apk')}
            $found=$false
            if ($custom) {
                $customPath=if ($custom.StartsWith('res://')) {Join-Path $settings.projectPath $custom.Substring(6)} elseif ([IO.Path]::IsPathRooted($custom)) {$custom} else {Join-Path $settings.projectPath $custom}
                $found=Test-Path -LiteralPath $customPath -PathType Leaf
            } elseif ($TemplateRoot -and $engineVersion) {
                $found=@($files | Where-Object {-not (Test-Path -LiteralPath (Join-Path $TemplateRoot "$engineVersion/$_") -PathType Leaf)}).Count -eq 0
            }
            & $add ('template:'+$preset.name) $(if ($found) {'passed'} else {'blocked'}) $(if ($found) {'Selected release template files exist; exporting remains a separate check.'} else {'Install exact selected-engine templates or provide -TemplateRoot/the configured custom release template.'})
        }
    } else {& $add 'godot' 'skipped' 'No selected exports.'}
    $android=@($plan.requiredExports | Where-Object {$_.platform -eq 'Android'})
    if ($android.Count) {
        $editor=@{}
        if (-not $EditorSettingsPath -and $directories -and $engineVersion) {
            $minor=($engineVersion.Split('.')[0..1] -join '.')
            $EditorSettingsPath=Join-Path $directories.settings "editor_settings-$minor.tres"
        }
        if ($EditorSettingsPath -and (Test-Path -LiteralPath $EditorSettingsPath -PathType Leaf)) {
            $editorSections=Read-GodotSections $EditorSettingsPath
            if ($editorSections.Contains('resource')) {$editor=$editorSections.resource}
        }
        if (-not $AndroidSdkPath) {$AndroidSdkPath=$editor['export/android/android_sdk_path']}
        if (-not $AndroidSdkPath) {$AndroidSdkPath=if ($env:ANDROID_HOME) {$env:ANDROID_HOME} else {$env:ANDROID_SDK_ROOT}}
        if (-not $JavaSdkPath) {$JavaSdkPath=$editor['export/android/java_sdk_path']}
        if (-not $JavaSdkPath) {$JavaSdkPath=$env:JAVA_HOME}
        $sdkFound=$AndroidSdkPath -and (Test-Path -LiteralPath (Join-Path $AndroidSdkPath ('platform-tools/adb'+$(if ($IsWindows) {'.exe'} else {''}))) -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $AndroidSdkPath 'build-tools') -PathType Container)
        & $add 'android-sdk' $(if ($sdkFound) {'passed'} else {'blocked'}) $(if ($sdkFound) {'Configured SDK has platform tools and build-tools; the full gate/export must verify required package versions.'} else {'Configured Android SDK/platform-tools/build-tools are missing; supply -AndroidSdkPath or configure Godot.'})
        $java=if ($JavaSdkPath) {Join-Path $JavaSdkPath ('bin/java'+$(if ($IsWindows) {'.exe'} else {''}))} else {$null}
        $javaFound=$java -and (Test-Path -LiteralPath $java -PathType Leaf)
        & $add 'java-sdk' $(if ($javaFound) {'passed'} else {'blocked'}) $(if ($javaFound) {'Configured JDK executable exists; Gradle/export remains the compatibility check.'} else {'Configured Java SDK is missing; supply -JavaSdkPath or configure Godot.'})
        $credentialPath=Join-Path $settings.projectPath '.godot/export_credentials.cfg'
        $credentials=if (Test-Path -LiteralPath $credentialPath -PathType Leaf) {Read-GodotSections $credentialPath} else {@{}}
        foreach ($preset in $android) {
            $section=@($sections.Keys | Where-Object {$_ -match '^preset\.\d+$' -and $sections[$_]['name'] -ceq $preset.name})[0]+'.options'
            $options=$sections[$section]
            $values=@{}
            foreach ($item in @(@{key='keystore/release';env='GODOT_ANDROID_KEYSTORE_RELEASE_PATH'},@{key='keystore/release_user';env='GODOT_ANDROID_KEYSTORE_RELEASE_USER'},@{key='keystore/release_password';env='GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD'})) {
                $value=[Environment]::GetEnvironmentVariable($item.env)
                if (-not $value -and $credentials.Contains($section)) {$value=$credentials[$section][$item.key]}
                if (-not $value) {$value=$options[$item.key]}
                $values[$item.key]=$value
            }
            $keyPath=$values['keystore/release']
            if ($keyPath -and $keyPath.StartsWith('res://')) {$keyPath=Join-Path $settings.projectPath $keyPath.Substring(6)}
            elseif ($keyPath -and -not [IO.Path]::IsPathRooted($keyPath)) {$keyPath=Join-Path $settings.projectPath $keyPath}
            $signingFound=$keyPath -and (Test-Path -LiteralPath $keyPath -PathType Leaf) -and $values['keystore/release_user'] -and $values['keystore/release_password']
            & $add ('signing:'+$preset.name) $(if ($signingFound) {'passed'} else {'blocked'}) $(if ($signingFound) {'Release keystore, alias and password are present; key validity and the exported signature are not verified.'} else {'Supply release keystore, alias and password through Godot private export credentials or its documented runtime environment variables.'})
            if ($options['gradle_build/use_gradle_build'] -eq $true) {
                $buildDirectory=$options['gradle_build/gradle_build_directory']
                # Godot appends build/ to the configured template root (default res://android).
                if (-not $buildDirectory) {$buildDirectory='res://android'}
                $buildPath=if ($buildDirectory.StartsWith('res://')) {Join-Path $settings.projectPath $buildDirectory.Substring(6)} elseif ([IO.Path]::IsPathRooted($buildDirectory)) {$buildDirectory} else {Join-Path $settings.projectPath $buildDirectory}
                $buildPath=Join-Path $buildPath 'build'
                $gradleFound=(Test-Path -LiteralPath (Join-Path $buildPath 'build.gradle') -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $buildPath 'build.gradle.kts') -PathType Leaf)
                & $add ('gradle:'+$preset.name) $(if ($gradleFound) {'passed'} else {'blocked'}) 'The selected Gradle preset needs its installed project Android build template at the configured directory.'
            }
        }
    } else {& $add 'android-sdk' 'skipped' 'No selected Android export.';& $add 'java-sdk' 'skipped' 'No selected Android export.'}
    return [ordered]@{ready=(@($checks | Where-Object {$_.status -eq 'blocked'}).Count -eq 0);remoteAccessVerified=$false;readOnly=$true;repository=$settings.repository;version=$settings.version;selectedDestinations=$plan.selectedDestinations;checks=$checks.ToArray()}
}

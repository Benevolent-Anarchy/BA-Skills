#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Resolve-BootstrapRepositoryName([AllowEmptyString()][string]$Name) {
    $repository=[regex]::Replace($Name.Trim(),'\s+','-')
    if (-not $repository -or $repository -notmatch '^[A-Za-z0-9._-]+$') {
        throw 'Project name must use ASCII letters, digits, spaces, dots, hyphens or underscores.'
    }
    if (($repository+'-release-notes').Length -gt 100) { throw 'Both repository names must fit 100 characters, including -release-notes.' }
    if ($repository -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)' -or
        $repository.EndsWith('.') -or $repository -match '^\.+$' -or $repository -ieq '.git') {
        throw 'The project name is reserved or cannot be used as a Windows directory name.'
    }
    return $repository
}

function New-BootstrapIdentity(
    [AllowEmptyString()][string]$Name,[AllowEmptyString()][string]$Description,
    [string]$Parent='C:\Users\cicel\Dev',[string]$Owner='Benevolent-Anarchy'
) {
    $repository=Resolve-BootstrapRepositoryName $Name
    if ([string]::IsNullOrWhiteSpace($Description)) { throw 'A project description is required.' }
    if ($Owner -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$' -or $Owner.EndsWith('-')) { throw 'Invalid GitHub owner.' }
    if (-not [IO.Path]::IsPathFullyQualified($Parent)) { throw 'Parent must be an absolute directory path.' }
    $parentPath=[IO.Path]::GetFullPath($Parent)
    $ancestor=$parentPath
    while ($ancestor) {
        $item=Get-Item -LiteralPath $ancestor -Force -ErrorAction SilentlyContinue
        if ($item) {
            if (-not $item.PSIsContainer -or ($item.LinkType -and -not $item.ResolveLinkTarget($true))) { throw "Parent is not a usable directory: $ancestor" }
            break
        }
        $next=Split-Path $ancestor -Parent
        if ($next -eq $ancestor) { break }; $ancestor=$next
    }
    $path=Join-Path $parentPath $repository
    return @{
        title=$Name.Trim(); description=$Description.Trim(); owner=$Owner
        repository=$repository; fullName="$Owner/$repository"
        notesRepository=($repository+'-release-notes'); notesFullName="$Owner/$repository-release-notes"
        parent=$parentPath; projectPath=$path; vaultPath=(Join-Path $path 'docs'); defaultBranch='main'
    }
}

function Get-BootstrapContentHash([string]$Text) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

function ConvertTo-BootstrapMarkdownTitle([string]$Title) {
    # A title remains one literal heading even if the input used tabs/newlines.
    return ([regex]::Replace($Title,'\s+',' ')).Replace('_','\_')
}

function Get-BootstrapPresetDocumentation([hashtable]$Selection) {
    $name=if($null -eq $Selection){'foundation'}else{$Selection.name}
    switch($name) {
        foundation {return @{name='Documentation foundation';setup='This preset supplies documentation and the working process. It has no engine dependencies. Use PowerShell 7.2 or newer and Git.';gate='The complete initial gate validates documentation. Extend this same gate as project checks are added.'}}
        godot {return @{name='Godot';setup=@'
Use Godot 4.7.x and PowerShell 7.2 or newer. GUT 9.7.1 is vendored in `addons/gut/`; no test package download is needed after cloning. Open `project.godot` in the matching Godot editor. If the executable is not available as `godot` or `godot4`, set the process-local `GODOT` environment variable to its full path before verification. Preserve committed `.uid` and source `.import` sidecars; `.godot/` is an ignored cache.
'@;gate='The complete gate validates documentation, Godot import and script compilation, and GUT tests with post-run error/orphan checks. It discovers rendered tests when present; those checks require a display. `tools/verify_selftest.ps1` separately exercises deliberate verifier failures.'}}
        tauri {return @{name='Tauri';setup=@'
Use Node.js/npm, stable Rust with rustfmt and Clippy, and PowerShell 7.2 or newer. Windows also needs the MSVC C++ build tools and WebView2. Install missing toolchains separately; bootstrap reports missing prerequisites before creating repositories. After a fresh clone, install the frozen frontend dependencies:

```powershell
npm ci
```

`Cargo.lock` freezes Rust dependencies; verification uses locked Cargo commands. Use `npm run dev` for the frontend or `npm run tauri dev` for the desktop development app.
'@;gate='The complete gate validates documentation, TypeScript, the frontend entry-point test and build, Rust formatting, Clippy, Rust tests, and a native Tauri build without installer bundling. The initial official Rust scaffold has no Rust unit tests; add meaningful tests as behavior develops. A successful build alone does not establish an observed app launch.'}}
        default {throw 'Unknown preset for documentation.'}
    }
}
function Get-ProjectManifest([hashtable]$Identity,[string]$AssetRoot=(Join-Path $PSScriptRoot '../assets/project'),[hashtable]$PresetSelection) {
    $assetPath=[IO.Path]::GetFullPath($AssetRoot)
    if (-not (Test-Path -LiteralPath $assetPath -PathType Container)) { throw 'Project assets are missing.' }
    $presetDocs=Get-BootstrapPresetDocumentation $PresetSelection
    $tokens=@{
        '{{PROJECT_TITLE}}'=(ConvertTo-BootstrapMarkdownTitle $Identity.title)
        '{{DESCRIPTION}}'=$Identity.description
        '{{ISSUES_URL}}'="https://github.com/$($Identity.fullName)/issues"
        '{{PRESET_NAME}}'=$presetDocs.name
        '{{PRESET_SETUP}}'=$presetDocs.setup
        '{{PRESET_GATE}}'=$presetDocs.gate
    }
    foreach ($file in Get-ChildItem -LiteralPath $assetPath -Recurse -File -Force | Sort-Object FullName) {
        if ($file.LinkType) { throw "Linked project asset is not supported: $($file.FullName)" }
        $relative=[IO.Path]::GetRelativePath($assetPath,$file.FullName).Replace('\','/') -replace '\.template$',''
        $text=[IO.File]::ReadAllText($file.FullName).Replace("`r`n","`n")
        # Replace tokens in one pass, so supplied text containing a token stays literal.
        $text=[regex]::Replace($text,'\{\{(?:PROJECT_TITLE|DESCRIPTION|ISSUES_URL|PRESET_NAME|PRESET_SETUP|PRESET_GATE)\}\}',[Text.RegularExpressions.MatchEvaluator]{param($match) $tokens[$match.Value]})
        $text=$text.Replace("`r`n","`n")
        @{path=$relative; text=$text; bytes=[Text.Encoding]::UTF8.GetBytes($text); sha256=(Get-BootstrapContentHash $text)}
    }
}

function Get-PublicReadme([hashtable]$Identity) {
    $title=ConvertTo-BootstrapMarkdownTitle $Identity.title
    $template=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../assets/public-README.md.template')).Replace("`r`n","`n")
    return $template.Replace('{{PROJECT_TITLE}}',$title)
}

function Assert-BootstrapOwnedPath([string]$Root,[string]$Path) {
    $rootPath=[IO.Path]::GetFullPath($Root)
    $current=[IO.Path]::GetFullPath($Path)
    if ($current -ne $rootPath -and -not $current.StartsWith($rootPath+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Foundation path escapes its project.' }
    while ($current) {
        $item=Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Foundation link conflict: $current" }
        if ($current -eq $rootPath) { break }
        $current=Split-Path $current -Parent
    }
}
function Assert-BootstrapRelativePath([string]$Path) {
    if (-not $Path -or $Path -match '(^/|[\\:]|(^|/)\.{1,2}(/|$)|(^|/)\.git(/|$)|//)' -or [IO.Path]::IsPathRooted($Path)) {throw "Unsafe manifest path: $Path"}
    foreach ($part in $Path.Split('/')) {
        if (-not $part -or $part -match '[<>"|?*\x00-\x1f]' -or $part -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)' -or $part -match '[. ]$') {throw "Unsafe manifest path: $Path"}
    }
}

function Write-BootstrapManifest([string]$Repository,[object[]]$Manifest) {
    $Repository=[IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Repository))
    $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    # Preflight the entire manifest before creating even the first parent/file.
    foreach ($entry in $manifest) {
        Assert-BootstrapRelativePath $entry.path
        if (-not $paths.Add($entry.path)) {throw "Duplicate manifest path: $($entry.path)"}
        [byte[]]$bytes=@(if ($entry.ContainsKey('bytes')) {$entry.bytes} else {[Text.Encoding]::UTF8.GetBytes($entry.text)})
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        if ($hash -cne $entry.sha256) {throw "Manifest hash differs from bytes: $($entry.path)"}
        $target=Join-Path $Repository $entry.path
        Assert-BootstrapOwnedPath $Repository $target
        $item=Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.PSIsContainer -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.sha256)) { throw "Foundation file conflict: $target" }
        $ancestor=Split-Path $target -Parent
        while ($ancestor) {
            $parentItem=Get-Item -LiteralPath $ancestor -Force -ErrorAction SilentlyContinue
            if ($parentItem -and -not $parentItem.PSIsContainer) { throw "Foundation parent conflict: $ancestor" }
            if ($ancestor -eq $Repository) { break }; $ancestor=Split-Path $ancestor -Parent
        }
    }
    foreach ($relative in $paths) {
        $parent=$relative
        while ($parent.Contains('/')) {
            $parent=$parent.Substring(0,$parent.LastIndexOf('/'))
            if ($paths.Contains($parent)) {throw "Manifest parent file conflict: $parent"}
        }
    }
    foreach ($entry in $manifest) {
        $target=Join-Path $Repository $entry.path
        if (-not (Test-Path -LiteralPath $target)) {
            New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
            [byte[]]$bytes=@(if ($entry.ContainsKey('bytes')) {$entry.bytes} else {[Text.Encoding]::UTF8.GetBytes($entry.text)})
            [IO.File]::WriteAllBytes($target,$bytes)
        }
    }
    return $manifest
}
function Write-ProjectFoundation([hashtable]$Identity,[string]$AssetRoot=(Join-Path $PSScriptRoot '../assets/project'),[hashtable]$PresetSelection) {
    Write-BootstrapManifest -Repository $Identity.projectPath -Manifest @(Get-ProjectManifest -Identity $Identity -AssetRoot $AssetRoot -PresetSelection $PresetSelection)
}
Export-ModuleMember -Function Resolve-BootstrapRepositoryName,New-BootstrapIdentity,Get-BootstrapContentHash,Get-ProjectManifest,Get-PublicReadme,Write-ProjectFoundation,Write-BootstrapManifest,Assert-BootstrapRelativePath,Assert-BootstrapOwnedPath

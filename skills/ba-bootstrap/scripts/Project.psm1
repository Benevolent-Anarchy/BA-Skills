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

function Get-ProjectManifest([hashtable]$Identity,[string]$AssetRoot=(Join-Path $PSScriptRoot '../assets/project')) {
    $assetPath=[IO.Path]::GetFullPath($AssetRoot)
    if (-not (Test-Path -LiteralPath $assetPath -PathType Container)) { throw 'Project assets are missing.' }
    $tokens=@{
        '{{PROJECT_TITLE}}'=(ConvertTo-BootstrapMarkdownTitle $Identity.title)
        '{{DESCRIPTION}}'=$Identity.description
        '{{ISSUES_URL}}'="https://github.com/$($Identity.fullName)/issues"
    }
    foreach ($file in Get-ChildItem -LiteralPath $assetPath -Recurse -File -Force | Sort-Object FullName) {
        if ($file.LinkType) { throw "Linked project asset is not supported: $($file.FullName)" }
        $relative=[IO.Path]::GetRelativePath($assetPath,$file.FullName).Replace('\','/') -replace '\.template$',''
        $text=[IO.File]::ReadAllText($file.FullName).Replace("`r`n","`n")
        # Replace tokens in one pass, so supplied text containing a token stays literal.
        $text=[regex]::Replace($text,'\{\{(?:PROJECT_TITLE|DESCRIPTION|ISSUES_URL)\}\}',[Text.RegularExpressions.MatchEvaluator]{param($match) $tokens[$match.Value]})
        @{path=$relative; text=$text; sha256=(Get-BootstrapContentHash $text)}
    }
}

function Get-PublicReadme([hashtable]$Identity) {
    $title=ConvertTo-BootstrapMarkdownTitle $Identity.title
    $template=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../assets/public-README.md.template')).Replace("`r`n","`n")
    return $template.Replace('{{PROJECT_TITLE}}',$title)
}

function Assert-FoundationPath([string]$Root,[string]$Path) {
    $rootPath=[IO.Path]::GetFullPath($Root)
    $current=[IO.Path]::GetFullPath($Path)
    if ($current -ne $rootPath -and -not $current.StartsWith($rootPath+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Foundation path escapes its project.' }
    while ($current) {
        $item=Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($item -and $item.LinkType) { throw "Foundation link conflict: $current" }
        if ($current -eq $rootPath) { break }
        $current=Split-Path $current -Parent
    }
}

function Write-ProjectFoundation([hashtable]$Identity,[string]$AssetRoot=(Join-Path $PSScriptRoot '../assets/project')) {
    $manifest=@(Get-ProjectManifest -Identity $Identity -AssetRoot $AssetRoot)
    # Preflight the entire manifest before creating even the first parent/file.
    foreach ($entry in $manifest) {
        $target=Join-Path $Identity.projectPath $entry.path
        Assert-FoundationPath $Identity.projectPath $target
        $item=Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.PSIsContainer -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.sha256)) { throw "Foundation file conflict: $target" }
        $ancestor=Split-Path $target -Parent
        while ($ancestor) {
            $parentItem=Get-Item -LiteralPath $ancestor -Force -ErrorAction SilentlyContinue
            if ($parentItem -and -not $parentItem.PSIsContainer) { throw "Foundation parent conflict: $ancestor" }
            if ($ancestor -eq $Identity.projectPath) { break }; $ancestor=Split-Path $ancestor -Parent
        }
    }
    foreach ($entry in $manifest) {
        $target=Join-Path $Identity.projectPath $entry.path
        if (-not (Test-Path -LiteralPath $target)) {
            New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
            [IO.File]::WriteAllText($target,$entry.text,[Text.UTF8Encoding]::new($false))
        }
    }
    return $manifest
}
Export-ModuleMember -Function Resolve-BootstrapRepositoryName,New-BootstrapIdentity,Get-BootstrapContentHash,Get-ProjectManifest,Get-PublicReadme,Write-ProjectFoundation

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Project.psm1')

function Invoke-BootstrapMetadataRequest([string]$Uri) {
    $response=Invoke-WebRequest -Uri $Uri -Headers @{'User-Agent'='BA-Bootstrap (Benevolent-Anarchy/BA-Skills)';Accept='application/json'}
    return $response.Content | ConvertFrom-Json -AsHashtable
}
function Get-BootstrapStableVersion([string[]]$Versions) {
    $stable=@($Versions | Where-Object {$_ -cmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'} | Sort-Object { [version]$_ } -Descending)
    if (-not $stable.Count) {throw 'Upstream metadata contains no stable release.'}
    return $stable[0]
}
function Get-BootstrapDependencyResolution {
    param([hashtable]$Selection,[scriptblock]$Request={param($Uri) Invoke-BootstrapMetadataRequest $Uri})
    $result=@{schemaVersion=1;preset=$Selection.name;selections=@{};artifacts=@();resolvedAt=[DateTime]::UtcNow.ToString('o')}
    switch ($Selection.name) {
        foundation {return $result}
        godot {
            $ref=& $Request 'https://api.github.com/repos/bitwes/Gut/git/ref/tags/v9.7.1'
            $commit=$ref.object
            if ($commit.type -ceq 'tag') {$tag=& $Request "https://api.github.com/repos/bitwes/Gut/git/tags/$($commit.sha)";$commit=$tag.object}
            if ($commit.type -cne 'commit' -or $commit.sha -cnotmatch '^[0-9a-f]{40}$') {throw 'GUT tag metadata does not identify an immutable source commit.'}
            $result.selections=@{gut='9.7.1';godotCompatibility='4.7.x'}
            $result.artifacts=@(@{name='gut';version='9.7.1';commit=$commit.sha;uri="https://codeload.github.com/bitwes/Gut/zip/$($commit.sha)";proof='immutable-commit-no-published-digest'})
        }
        tauri {
            $crates=& $Request 'https://crates.io/api/v1/crates/tauri'
            $tauri=Get-BootstrapStableVersion @($crates.versions | Where-Object {-not $_.yanked} | ForEach-Object {$_.num})
            $npm=& $Request 'https://registry.npmjs.org/create-tauri-app'
            $generator=Get-BootstrapStableVersion @($npm.versions.Keys)
            $record=$npm.versions[$generator]
            if ($record.version -cne $generator -or $record.dist.tarball -cnotmatch '^https://registry\.npmjs\.org/create-tauri-app/-/create-tauri-app-[0-9]+\.[0-9]+\.[0-9]+\.tgz$' -or $record.dist.integrity -cnotmatch '^sha512-[A-Za-z0-9+/]+={0,2}$') {throw 'Official generator version or integrity metadata is inconsistent.'}
            $decoded=[Convert]::FromBase64String($record.dist.integrity.Substring(7))
            if ($decoded.Length -ne 64) {throw 'Official generator integrity metadata is malformed.'}
            $result.selections=@{tauri=$tauri;generator=$generator}
            $result.artifacts=@(@{name='generator';version=$generator;uri=$record.dist.tarball;integrity=$record.dist.integrity;proof='published-integrity'})
        }
        default {throw "Unsupported dependency preset '$($Selection.name)'."}
    }
    return $result
}
function Receive-BootstrapArtifact {
    param([hashtable]$Artifact,[string]$Destination,[scriptblock]$Download={param($Uri,$Path) Invoke-WebRequest -Uri $Uri -OutFile $Path | Out-Null})
    $Destination=[IO.Path]::GetFullPath($Destination);$parent=Split-Path $Destination -Parent
    Assert-BootstrapOwnedPath $parent $Destination
    if ($Artifact.uri -cnotmatch '^https://') {throw 'Artifact requires an HTTPS source URI.'}
    $existing=Test-Path -LiteralPath $Destination
    if ($existing -and -not $Artifact.ContainsKey('sha256') -and -not $Artifact.ContainsKey('integrity')) {throw 'Existing artifact has no retained digest; preserve it and inspect unresolved acquisition.'}
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $working=if($existing){$Destination}else{$Destination+'.'+[guid]::NewGuid().ToString('N')+'.partial'}
    if (-not $existing) {& $Download $Artifact.uri $working | Out-Null}
    $bytes=[IO.File]::ReadAllBytes($working)
    $sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    if ($Artifact.ContainsKey('sha256') -and $sha -cne $Artifact.sha256) {throw "Artifact '$($Artifact.name)' retained digest mismatch. Preserve evidence; do not resolve a replacement."}
    $verified=$false
    if ($Artifact.ContainsKey('integrity')) {
        if ($Artifact.integrity -cnotmatch '^sha512-([A-Za-z0-9+/]+={0,2})$') {throw 'Unsupported artifact integrity metadata.'}
        $actual='sha512-'+[Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData($bytes))
        if ($actual -cne $Artifact.integrity) {throw "Artifact '$($Artifact.name)' published integrity mismatch."}
        $verified=$true
    }
    if (-not $existing) {[IO.File]::Move($working,$Destination)}
    return @{name=$Artifact.name;uri=$Artifact.uri;sha256=$sha;integrityVerified=$verified;proof=$Artifact.proof;bytes=$bytes.Length}
}
function Expand-BootstrapSourceArchive {
    param([string]$Archive,[string]$Destination,[string[]]$RequiredPaths)
    $Destination=[IO.Path]::GetFullPath($Destination)
    Assert-BootstrapOwnedPath (Split-Path $Destination -Parent) $Destination
    if (Test-Path -LiteralPath $Destination) {throw 'Archive destination already exists; preserve it rather than overwrite.'}
    $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $manifest=[Collections.Generic.List[object]]::new();$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $top=$null;[long]$total=0
        foreach ($entry in $zip.Entries) {
            $name=$entry.FullName.TrimEnd('/')
            Assert-BootstrapRelativePath $name
            if (-not $seen.Add($name)) {throw "Archive has duplicate or case-conflicting path '$name'."}
            $mode=($entry.ExternalAttributes -shr 16) -band 0xF000
            if ($mode -eq 0xA000 -or ($entry.ExternalAttributes -band 0x400) -ne 0) {throw "Archive link '$name' is not permitted."}
            $parts=$name.Split('/')
            if (-not $top) {$top=$parts[0]} elseif ($parts[0] -cne $top) {throw 'Source archive must have exactly one root directory.'}
            if ($entry.FullName.EndsWith('/')) {continue}
            if ($parts.Count -lt 2) {throw 'Source archive file lies outside its root directory.'}
            $total+=$entry.Length
            if ($total -gt 134217728 -or $manifest.Count -ge 5000) {throw 'Source archive exceeds preparation limits.'}
            $stream=$entry.Open();$memory=[IO.MemoryStream]::new()
            try {$stream.CopyTo($memory);$bytes=$memory.ToArray()} finally {$stream.Dispose();$memory.Dispose()}
            $manifest.Add(@{path=($parts[1..($parts.Count-1)] -join '/');bytes=$bytes;sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()})
        }
        foreach ($required in $RequiredPaths) {
            Assert-BootstrapRelativePath $required
            if ($required -cnotin @($manifest.path)) {throw "Archive is missing required source '$required'."}
        }
        # The manifest writer checks all file/parent conflicts before its first write.
        Write-BootstrapManifest $Destination $manifest.ToArray() | Out-Null
    } finally {$zip.Dispose()}
    return $Destination
}
Export-ModuleMember -Function Get-BootstrapDependencyResolution,Receive-BootstrapArtifact,Expand-BootstrapSourceArchive,Invoke-BootstrapMetadataRequest

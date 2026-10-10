Import-Module "$skillRoot/scripts/Presets.psm1" -Force
Import-Module "$skillRoot/scripts/Project.psm1" -Force
if (Test-Path "$skillRoot/scripts/Dependencies.psm1") {Import-Module "$skillRoot/scripts/Dependencies.psm1" -Force}
. "$PSScriptRoot/PresetFixture.ps1"
Test 'dependency resolution selects a new stable Tauri major without a ceiling' {
    $id=New-BootstrapIdentity -Name 'Future Tauri' -Description 'Purpose' -Parent $sandbox
    $f=New-PresetMetadataFixture
    $result=Get-BootstrapDependencyResolution (Resolve-BootstrapPreset $id -Preset tauri) $f.request
    Assert ($result.selections.tauri -ceq '3.0.0') 'Stable major rejected or prerelease/yanked selected.'
    Assert ($result.selections.generator -ceq '4.0.0') 'Generator version assumed equal to Tauri.'
    Assert ($result.artifacts[0].integrity -ceq $f.npm.versions['4.0.0'].dist.integrity) 'Published integrity lost.'
    $f.npm.versions['4.0.0'].version='4.0.1'
    Expect-Error {Get-BootstrapDependencyResolution (Resolve-BootstrapPreset $id -Preset tauri) $f.request} 'metadata|version'
    $f.fail=$true
    Expect-Error {Get-BootstrapDependencyResolution (Resolve-BootstrapPreset $id -Preset tauri) $f.request} 'HTTP'
}
Test 'dependency Godot pin retains immutable commit without claiming published proof' {
    $id=New-BootstrapIdentity -Name 'Gut Project' -Description 'Purpose' -Parent $sandbox
    $f=New-PresetMetadataFixture
    $result=Get-BootstrapDependencyResolution (Resolve-BootstrapPreset $id) $f.request
    Assert ($result.selections.gut -ceq '9.7.1' -and $result.artifacts[0].commit -ceq ('a'*40)) 'Godot compatible pin changed.'
    Assert ($result.artifacts[0].proof -ceq 'immutable-commit-no-published-digest') 'Local hash misrepresented as upstream proof.'
}
Test 'dependency acquisition enforces published integrity and frozen retry bytes' {
    $dir=New-BootstrapFixture 'artifact'
    $f=@{bytes=[byte[]]@(1,2,3,255)}
    $download={param($uri,$path) [IO.File]::WriteAllBytes($path,$f.bytes)}.GetNewClosure()
    $sri='sha512-'+[Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData($f.bytes))
    $artifact=@{name='generator';uri='https://example.invalid/generator.tgz';integrity=$sri;proof='published-integrity'}
    $receipt=Receive-BootstrapArtifact $artifact "$dir/generator.tgz" $download
    Assert ($receipt.sha256 -match '^[0-9a-f]{64}$' -and $receipt.integrityVerified) 'Receipt missing integrity evidence.'
    $f.bytes=[byte[]]@(5,6)
    Expect-Error {Receive-BootstrapArtifact $artifact "$dir/changed.tgz" $download} 'integrity'
    $pin=$artifact.Clone();$pin.Remove('integrity');$pin.sha256=$receipt.sha256
    Expect-Error {Receive-BootstrapArtifact $pin "$dir/retry.tgz" $download} 'digest|hash'
    $same=Receive-BootstrapArtifact $pin "$dir/generator.tgz" $download
    Assert ($same.sha256 -ceq $receipt.sha256) 'Recorded acquisition not reused.'
}
function New-DependencyZip([string]$Path,[hashtable]$Entries,[string]$Link='') {
    $zip=[IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Create)
    try {foreach ($name in $Entries.Keys) {
        $entry=$zip.CreateEntry($name)
        if ($name -ceq $Link) {$entry.ExternalAttributes=[int](-1577058304)} # Unix symlink 0120000.
        $stream=$entry.Open();try {$bytes=[Text.Encoding]::UTF8.GetBytes($Entries[$name]);$stream.Write($bytes,0,$bytes.Length)} finally {$stream.Dispose()}
    }} finally {$zip.Dispose()}
}
Test 'dependency archive validates every path link and required file before extraction' {
    $dir=New-BootstrapFixture 'archives'
    New-DependencyZip "$dir/good.zip" @{'upstream/addons/gut/plugin.cfg'='plugin';'upstream/LICENSE.md'='license';'upstream/addons/gut/nested/file.gd'='source'}
    $root=Expand-BootstrapSourceArchive "$dir/good.zip" "$dir/good" @('addons/gut/plugin.cfg','LICENSE.md')
    Assert (Test-Path "$root/addons/gut/nested/file.gd") 'Nested source missing.'
    foreach ($case in @(@{name='traversal';entries=@{'upstream/../escape'='bad'};link=''},@{name='link';entries=@{'upstream/addons/gut/plugin.cfg'='target'};link='upstream/addons/gut/plugin.cfg'},@{name='missing';entries=@{'upstream/README.md'='only readme'};link=''})) {
        New-DependencyZip "$dir/$($case.name).zip" $case.entries $case.link
        Expect-Error {Expand-BootstrapSourceArchive "$dir/$($case.name).zip" "$dir/$($case.name)" @('addons/gut/plugin.cfg','LICENSE.md')} 'path|link|missing|required'
        Assert (-not (Test-Path "$dir/$($case.name)")) 'Invalid archive partially extracted.'
    }
}

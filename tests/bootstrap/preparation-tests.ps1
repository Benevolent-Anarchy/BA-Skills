Import-Module "$skillRoot/scripts/Presets.psm1" -Force
Import-Module "$skillRoot/scripts/State.psm1" -Force
if (Test-Path "$skillRoot/scripts/Preparation.psm1") {Import-Module "$skillRoot/scripts/Preparation.psm1" -Force}
function New-PreparationFixture {
    $fixture=@{state=(New-BootstrapFixture 'snapshot state');source=(New-BootstrapFixture 'snapshot source')}
    $fixture.identity=New-BootstrapIdentity -Name 'Frozen Project' -Description 'Purpose' -Parent $sandbox
    $fixture.selection=Resolve-BootstrapPreset $fixture.identity -Preset tauri
    Write-FixtureText "$($fixture.source)/package-lock.json" '{"lockfileVersion":3,"packages":{}}'
    [IO.File]::WriteAllBytes("$($fixture.source)/icon.ico",[byte[]]@(0,255,128,10,13))
    $fixture.manifest=@(Get-BootstrapPreparedManifest $fixture.source @('package-lock.json','icon.ico'))
    $fixture.journal=New-BootstrapJournal -Identity $fixture.identity -Manifest @() -PresetSelection $fixture.selection
    $fixture.path=Get-BootstrapJournalPath $fixture.identity $fixture.state
    return $fixture
}
Test 'preparation freezes exact bytes and survives changes to source and upstream' {
    $f=New-PreparationFixture
    $lock=Enter-BootstrapLock $f.path
    try {Save-BootstrapPreparedProject -Journal $f.journal -JournalPath $f.path -Lock $lock -Source $f.source -Manifest $f.manifest}
    finally {$lock.Dispose()}
    Write-FixtureText "$($f.source)/package-lock.json" 'changed upstream'
    $stored=Read-BootstrapJournal $f.path
    Assert ($stored.schemaVersion -eq 2 -and $stored.presetSelection.name -ceq 'tauri') 'Selection not recorded.'
    $read=Read-BootstrapPreparedProject $stored $f.state
    Assert (($read.manifest.sha256 -join ',') -ceq (($f.manifest | Sort-Object path).sha256 -join ',')) 'Frozen bytes re-resolved.'
    Assert ([IO.File]::ReadAllBytes("$($read.sourcePath)/icon.ico")[1] -eq 255) 'Icon changed.'
    $changed=$f.identity.Clone();$changed.description='Changed purpose'
    Expect-Error {Assert-BootstrapJournal $stored $changed @() $f.selection} 'input'
    $different=Resolve-BootstrapPreset $f.identity -Preset godot
    Expect-Error {Assert-BootstrapJournal $stored $f.identity @() $different} 'input|preset'
}
Test 'preparation rejects corrupted missing and extra snapshot files without repair' {
    $f=New-PreparationFixture
    Save-BootstrapPreparedProject -Journal $f.journal -JournalPath $f.path -Source $f.source -Manifest $f.manifest
    $read=Read-BootstrapPreparedProject $f.journal $f.state
    Write-FixtureText "$($read.sourcePath)/unexpected.txt" 'extra'
    Expect-Error {Read-BootstrapPreparedProject $f.journal $f.state} 'unexpected|manifest|paths'
    Remove-Item -LiteralPath "$($read.sourcePath)/unexpected.txt"
    Write-FixtureText "$($read.sourcePath)/package-lock.json" 'corrupt'
    Expect-Error {Read-BootstrapPreparedProject $f.journal $f.state} 'hash|bytes|differ'
    Expect-Error {Save-BootstrapPreparedProject -Journal $f.journal -JournalPath $f.path -Source $f.source -Manifest $f.manifest} 'hash|bytes|differ'
    Assert ([IO.File]::ReadAllText("$($read.sourcePath)/package-lock.json") -ceq 'corrupt') 'Corrupt evidence replaced.'
    Remove-Item -LiteralPath "$($read.sourcePath)/package-lock.json"
    Expect-Error {Read-BootstrapPreparedProject $f.journal $f.state} 'missing|manifest|paths'
}
Test 'preparation rejects unsafe source paths and linked snapshot directories' {
    $f=New-PreparationFixture
    Expect-Error {Get-BootstrapPreparedManifest $f.source @('../outside')} 'path'
    Expect-Error {Get-BootstrapPreparedManifest $f.source @('icon.ico','ICON.ico')} 'duplicate|case'
    $other=New-BootstrapFixture 'foreign snapshot'
    New-Item -ItemType Directory -Path "$($f.state)/prepared" | Out-Null
    New-Item -ItemType Junction -Path "$($f.state)/prepared/$($f.journal.invocationId)" -Target $other | Out-Null
    Expect-Error {Save-BootstrapPreparedProject -Journal $f.journal -JournalPath $f.path -Source $f.source -Manifest $f.manifest} 'link|conflict'
    Assert (@(Get-ChildItem $other -Force).Count -eq 0) 'Foreign snapshot changed.'
}
Test 'preparation adopts only its exact promoted snapshot after lost publication' {
    $f=New-PreparationFixture
    Save-BootstrapPreparedProject -Journal $f.journal -JournalPath $f.path -Source $f.source -Manifest $f.manifest
    $f.journal.preparation.phase='snapshotting'
    Write-BootstrapJournal $f.path $f.journal
    $before=[IO.File]::ReadAllBytes((Join-Path $f.state $f.journal.preparation.snapshot)+'/'+'icon.ico')
    Save-BootstrapPreparedProject -Journal $f.journal -JournalPath $f.path -Source $f.source -Manifest $f.manifest
    Assert ((Read-BootstrapJournal $f.path).preparation.phase -ceq 'frozen') 'Promoted snapshot not recovered.'
    $read=Read-BootstrapPreparedProject $f.journal $f.state
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes("$($read.sourcePath)/icon.ico")) -ceq [Convert]::ToBase64String($before)) 'Recovery regenerated snapshot.'
}
Test 'state v2 hashes canonical options and preserves a literal legacy journal' {
    $f=New-PreparationFixture
    $copy=@{crateName=$f.selection.crateName;packageName=$f.selection.packageName;appIdentifier=$f.selection.appIdentifier;renderer=$null;recipeVersion=1;name='tauri'}
    Assert ((Get-BootstrapInputHash $f.identity $copy) -ceq $f.journal.inputHash) 'Hashtable order changed input hash.'
    $legacyPath=Join-Path $PSScriptRoot 'fixtures/legacy-foundation-journal.json'
    $original=[IO.File]::ReadAllText($legacyPath)
    $legacy=Read-BootstrapJournal $legacyPath
    Assert ($legacy.schemaVersion -eq 1 -and -not $legacy.ContainsKey('presetSelection')) 'Legacy upgraded.'
    Expect-Error {Assert-BootstrapJournal $legacy $legacy.identity (Get-ProjectManifest $legacy.identity)} 'matching version|template'
    $legacy.phases.complete='verified'
    Assert-BootstrapJournal $legacy $legacy.identity @()
    Assert ([IO.File]::ReadAllText($legacyPath) -ceq $original) 'Legacy fixture rewritten.'
    Expect-Error {Assert-BootstrapJournal $legacy $legacy.identity @() (Resolve-BootstrapPreset $legacy.identity)} 'foundation|preset'
}

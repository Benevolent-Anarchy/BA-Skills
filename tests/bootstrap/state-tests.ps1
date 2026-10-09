if (Test-Path "$skillRoot/scripts/State.psm1") {Import-Module "$skillRoot/scripts/State.psm1" -Force}
Test 'state creation writes atomic identity snapshots and rejects malformed journals' {
    $state=New-BootstrapFixture 'state'
    $identity=New-BootstrapIdentity -Name 'State Fixture' -Description 'Test' -Parent $sandbox
    $path=Get-BootstrapJournalPath -Identity $identity -StateRoot $state
    Assert ($null -eq (Read-BootstrapJournal $path)) 'Missing state is not null.'
    $journal=New-BootstrapJournal -Identity $identity -Manifest (Get-ProjectManifest $identity)
    Write-BootstrapJournal -Path $path -Journal $journal
    $read=Read-BootstrapJournal $path
    Assert ($read.invocationId -eq $journal.invocationId -and $read.identity.fullName -eq $identity.fullName) 'Snapshot changed identity.'
    $caseIdentity=$identity.Clone();$caseIdentity.owner=$identity.owner.ToUpper();$caseIdentity.repository=$identity.repository.ToUpper()
    Assert ((Get-BootstrapJournalPath $caseIdentity $state) -eq $path) 'Case-equivalent identity has a second journal.'
    Write-FixtureText $path '{bad json'
    Expect-Error {Read-BootstrapJournal $path} 'journal'
}
Test 'state creation rejects concurrent writers and incompatible inputs' {
    $state=New-BootstrapFixture 'lock'
    $id=New-BootstrapIdentity -Name 'Locked' -Description 'Test' -Parent $sandbox
    $path=Get-BootstrapJournalPath $id $state
    $journal=New-BootstrapJournal $id (Get-ProjectManifest $id)
    Write-BootstrapJournal $path $journal
    $lock=Enter-BootstrapLock $path
    try {
        Expect-Error {Enter-BootstrapLock $path} 'another|locked'
        Expect-Error {Write-BootstrapJournal $path $journal} 'another|locked'
        Assert ((Read-BootstrapJournal $path).invocationId -eq $journal.invocationId) 'Previous snapshot lost.'
    } finally {$lock.Dispose()}
    $changed=$id.Clone();$changed.description='Changed'
    Expect-Error {Assert-BootstrapJournal $journal $changed (Get-ProjectManifest $changed)} 'input'
    $journal.templateVersion='different'
    Expect-Error {Assert-BootstrapJournal $journal $id (Get-ProjectManifest $id)} 'template'
}

Import-Module "$skillRoot/scripts/Project.psm1" -Force
Test 'manifest preserves binary files and checks every conflict before writing' {
    $path=New-BootstrapFixture 'binary with spaces'
    [byte[]]$bytes=@(0,255,128,10,13,0)
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    $entries=@(@{path='src-tauri/icons/icon.ico';bytes=$bytes;sha256=$hash})
    Write-BootstrapManifest -Repository $path -Manifest $entries | Out-Null
    Assert ((Get-FileHash "$path/src-tauri/icons/icon.ico").Hash.ToLowerInvariant() -ceq $hash) 'Binary bytes changed.'
    Write-FixtureText "$path/late.txt" 'existing'
    $entries+=@{path='first-new.txt';bytes=[Text.Encoding]::UTF8.GetBytes('new');sha256=(Get-BootstrapContentHash 'new')}
    $entries+=@{path='late.txt';bytes=[Text.Encoding]::UTF8.GetBytes('changed');sha256=(Get-BootstrapContentHash 'changed')}
    Expect-Error {Write-BootstrapManifest $path $entries} 'conflict'
    Assert (-not (Test-Path "$path/first-new.txt")) 'Wrote before late conflict.'
    Assert ([IO.File]::ReadAllText("$path/late.txt") -ceq 'existing') 'Changed existing file.'
}
Test 'manifest rejects traversal duplicate names incorrect digests and linked parents' {
    $path=New-BootstrapFixture 'unsafe manifest'
    $entry=@{path='safe.txt';text='safe';sha256=(Get-BootstrapContentHash 'safe')}
    foreach ($name in @('../escape.txt','/absolute.txt','C:/absolute.txt','.git/config','a/../b','a\\b','file:stream')) {
        $bad=$entry.Clone();$bad.path=$name
        Expect-Error {Write-BootstrapManifest $path @($entry,$bad)} 'path|unsafe|duplicate'
        Assert (-not (Test-Path "$path/safe.txt")) 'Wrote before unsafe path.'
    }
    $duplicate=$entry.Clone();$duplicate.path='SAFE.txt'
    Expect-Error {Write-BootstrapManifest $path @($entry,$duplicate)} 'duplicate'
    $parentFile=$entry.Clone();$parentFile.path='directory'
    $child=$entry.Clone();$child.path='directory/child.txt'
    Expect-Error {Write-BootstrapManifest $path @($entry,$parentFile,$child)} 'parent|conflict'
    Assert (-not (Test-Path "$path/safe.txt")) 'Wrote before manifest parent conflict.'
    $bad=$entry.Clone();$bad.sha256='0'*64
    Expect-Error {Write-BootstrapManifest $path @($bad)} 'hash|digest'
    $other=New-BootstrapFixture 'linked destination'
    New-Item -ItemType Junction -Path "$path/linked" -Target $other | Out-Null
    $bad=$entry.Clone();$bad.path='linked/probe.txt'
    Expect-Error {Write-BootstrapManifest $path @($bad)} 'link|conflict'
    Assert (@(Get-ChildItem $other -Force).Count -eq 0) 'Changed link target.'
}
Test 'manifest common ignores keep exports out and preserve source through Git filters' {
    $id=New-BootstrapIdentity -Name 'Ignore Rules' -Description 'Purpose' -Parent (New-BootstrapFixture 'ignore parent')
    Write-ProjectFoundation $id | Out-Null
    $path=$id.projectPath
    Invoke-FixtureGit $path @('init','--quiet','--initial-branch=main') | Out-Null
    Write-FixtureText "$path/empty-excludes" ''
    $gitArguments=@('-c',("core.excludesFile=$path/empty-excludes"),'check-ignore','--no-index')
    $ignored=Invoke-FixtureGit $path ($gitArguments+@('dist/export.exe','nested/dist/export.zip','docs/.obsidian/plugins/main.js'))
    Assert ($ignored.Contains('dist/export.exe') -and $ignored.Contains('nested/dist/export.zip')) 'Exports not ignored.'
    foreach ($source in @('assets/source.png','tools/helper.exe')) {
        & git -C $path @gitArguments $source 2>&1 | Out-Null
        Assert ($LASTEXITCODE -eq 1) "Source ignored: $source"
    }
    Invoke-FixtureGit $path @('config','core.autocrlf','true') | Out-Null
    Invoke-FixtureGit $path @('add','--','README.md','.gitattributes') | Out-Null
    $committed=Invoke-FixtureGit $path @('rev-parse',':README.md')
    $raw=Invoke-FixtureGit $path @('hash-object','--no-filters','README.md')
    Assert ($committed -ceq $raw) 'LF source changed through filters.'
    [byte[]]$icon=@(0,255,128,13,10)
    [IO.Directory]::CreateDirectory("$path/icons") | Out-Null
    [IO.File]::WriteAllBytes("$path/icons/icon.ico",$icon)
    Invoke-FixtureGit $path @('add','--','icons/icon.ico') | Out-Null
    Assert ((Invoke-FixtureGit $path @('rev-parse',':icons/icon.ico')) -ceq (Invoke-FixtureGit $path @('hash-object','--no-filters','icons/icon.ico'))) 'Icon transformed.'
}

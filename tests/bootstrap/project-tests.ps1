$projectModule=Join-Path $skillRoot 'scripts/Project.psm1'
if (Test-Path -LiteralPath $projectModule) { Import-Module $projectModule -Force }
Test 'identity preserves case and derives the pair without a public checkout' {
    $id=New-BootstrapIdentity -Name '  Foo   Bar Baz  ' -Description 'Private purpose'
    Assert ($id.repository -ceq 'Foo-Bar-Baz') 'Wrong slug.'
    Assert ($id.notesFullName -ceq 'Benevolent-Anarchy/Foo-Bar-Baz-release-notes') 'Wrong public name.'
    Assert ($id.projectPath -eq 'C:\Users\cicel\Dev\Foo-Bar-Baz') 'Wrong default parent.'
    Assert (-not $id.ContainsKey('notesPath')) 'Public path was invented.'
    $personal=New-BootstrapIdentity -Name 'My Project' -Description 'Purpose' -Parent $sandbox -Owner cicely-f
    Assert ($personal.fullName -ceq 'cicely-f/My-Project') 'Owner override ignored.'
    Assert ((Resolve-BootstrapRepositoryName -Name "Tabs`tAnd`nLines") -ceq 'Tabs-And-Lines') 'Whitespace conversion failed.'
}
Test 'identity validates both repository and Windows name boundaries' {
    foreach ($name in @('','   ','NUL.notes','con','COM1.cfg','LPT9','Foo.','..','Å game','a/b','a:b')) {
        Expect-Error { New-BootstrapIdentity -Name $name -Description 'Purpose' -Parent $sandbox } 'name|Windows|ASCII'
    }
    Expect-Error { New-BootstrapIdentity -Name ('A'*87) -Description 'Purpose' -Parent $sandbox } '100'
    Assert ((New-BootstrapIdentity -Name ('A'*86) -Description 'Purpose' -Parent $sandbox).notesRepository.Length -eq 100) 'Valid boundary rejected.'
    Expect-Error { New-BootstrapIdentity -Name 'Valid' -Description ' ' -Parent $sandbox } 'description'
    $file=Join-Path $sandbox 'parent-file'; Write-FixtureText $file 'keep'
    Expect-Error { New-BootstrapIdentity -Name 'Valid' -Description 'Purpose' -Parent $file } 'directory|parent'
}
Test 'foundation creates only the private skeleton and ignored local tooling' {
    $parent=New-BootstrapFixture 'foundation parent'
    $description='Literal $(do-not-execute) `ticks` {braces} $variables'
    $id=New-BootstrapIdentity -Name 'Foundation Project' -Description $description -Parent $parent
    $manifest=@(Write-ProjectFoundation -Identity $id -AssetRoot $assetRoot)
    foreach ($path in @('README.md','AGENTS.md','CLAUDE.md','.gitignore','docs/DESIGN.md','docs/DECISIONS.md','docs/JUDGEMENTS.md','docs/NEXT.md','docs/design/.gitkeep','docs/decisions/.gitkeep','docs/judgements/.gitkeep')) {
        Assert (Test-Path -LiteralPath (Join-Path $id.projectPath $path) -PathType Leaf) "Missing $path."
    }
    Assert ((Get-Content -LiteralPath (Join-Path $id.projectPath 'README.md') -Raw).Contains($description)) 'Description was evaluated or changed.'
    Assert (-not (Test-Path (Join-Path $id.projectPath '_project-meta'))) 'Unexpected metadata directory.'
    Invoke-FixtureGit $id.projectPath @('init','--quiet','--initial-branch=main') | Out-Null
    $ignored=Invoke-FixtureGit $id.projectPath @('check-ignore','docs/.obsidian/plugins/plugin/main.js','docs/.vault-nickname','.scratch/plan.md')
    Assert ($ignored -match 'docs/.obsidian' -and $ignored -match 'docs/.vault-nickname' -and $ignored -match '.scratch') 'Tool state, including Vault Nickname legacy settings, is not ignored.'
    Assert (@($manifest | Where-Object {$_.sha256 -notmatch '^[a-f0-9]{64}$'}).Count -eq 0) 'Manifest lacks actual hashes.'
    $public=Get-PublicReadme -Identity $id
    Assert ($public -ceq "# Foundation Project release notes`n`nThis repository is the public record of release notes for Foundation Project.`n") 'Wrong public README.'
    Assert (-not $public.Contains($description)) 'Private description leaked.'
}
Test 'foundation preflights every file conflict before writing any missing file' {
    $parent=New-BootstrapFixture 'conflicts'
    $id=New-BootstrapIdentity -Name 'Conflict Project' -Description 'Purpose' -Parent $parent
    Write-FixtureText (Join-Path $id.projectPath 'docs/JUDGEMENTS.md') 'keep my work'
    Expect-Error { Write-ProjectFoundation -Identity $id -AssetRoot $assetRoot } 'conflict'
    Assert (-not (Test-Path (Join-Path $id.projectPath 'README.md'))) 'Earlier file was written before conflict.'
    Assert ((Get-Content (Join-Path $id.projectPath 'docs/JUDGEMENTS.md') -Raw) -ceq 'keep my work') 'Conflict replaced.'
}
Test 'foundation rejects linked paths and reuses identical files' {
    $parent=New-BootstrapFixture 'links'
    $id=New-BootstrapIdentity -Name 'Link Project' -Description 'Purpose' -Parent $parent
    New-Item -ItemType Directory -Path $id.projectPath | Out-Null
    $other=New-BootstrapFixture 'other'
    New-Item -ItemType Junction -Path (Join-Path $id.projectPath 'docs') -Target $other | Out-Null
    Expect-Error { Write-ProjectFoundation -Identity $id -AssetRoot $assetRoot } 'link|conflict'
    Assert (@(Get-ChildItem -LiteralPath $other -Force).Count -eq 0) 'Linked destination changed.'
    $safe=New-BootstrapIdentity -Name 'Repeat Project' -Description 'Purpose' -Parent $parent
    Write-ProjectFoundation -Identity $safe -AssetRoot $assetRoot | Out-Null
    $before=(Get-FileHash (Join-Path $safe.projectPath 'README.md')).Hash
    Write-ProjectFoundation -Identity $safe -AssetRoot $assetRoot | Out-Null
    Assert ((Get-FileHash (Join-Path $safe.projectPath 'README.md')).Hash -eq $before) 'Repeated generation changed content.'
}

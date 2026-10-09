Import-Module (Join-Path $skillRoot 'scripts/Project.psm1') -Force
Import-Module (Join-Path $assetRoot 'tools/Documentation.psm1') -Force
function New-PopulatedDocumentationFixture([string]$Name) {
    $parent=New-BootstrapFixture $Name
    $identity=New-BootstrapIdentity -Name 'Documentation Fixture' -Description 'Tests' -Parent $parent
    Write-ProjectFoundation -Identity $identity -AssetRoot $assetRoot | Out-Null
    $repo=$identity.projectPath
    foreach ($topic in @('interface','input')) {
        $title=(Get-Culture).TextInfo.ToTitleCase($topic)
        Write-FixtureText "$repo/docs/design/$topic.md" "# $title`n`n## Overview`nRelated [[DECISIONS]].`n"
    }
    Write-FixtureText "$repo/docs/decisions/interface.md" "# Interface`n`n## 2026-10-09`n`n### Keyboard navigation`nRationale.`n"
    Write-FixtureText "$repo/docs/decisions/input.md" "# Input`n`n## 2026-10-09`n`n### Pointer timing`nRationale.`n`n#### Keyboard navigation`nOrdinary subsection.`n"
    Write-FixtureText "$repo/docs/judgements/interface.md" "# Interface`n`n### Focus is visible`n*Judged 2024-02-29, on Windows desktop.*`nVerdict.`n"
    Write-FixtureText "$repo/docs/judgements/input.md" "# Input`n`n### Pointer is legible`n*Judged 2026-10-09, on Linux desktop.*`nVerdict.`n"
    Write-FixtureText "$repo/docs/DESIGN.md" @'
# Design

## Index
### Interface — [[design/interface|Interface]]
- [[design/interface#Overview|Overview]]
### Input — [[design/input|Input]]
- [[design/input#Overview|Overview]]
'@
    Write-FixtureText "$repo/docs/DECISIONS.md" @'
# Decisions

## Index
### Interface — [[decisions/interface|Interface]]
- [[decisions/interface#Keyboard navigation|Keyboard navigation]]
### Input — [[decisions/input|Input]]
- [[decisions/input#Pointer timing|Pointer timing]]
'@
    Write-FixtureText "$repo/docs/JUDGEMENTS.md" @'
# Judgements

## Index
### Interface — [[judgements/interface|Interface]]
- [[judgements/interface#Focus is visible|Focus is visible]] — Judged 2024-02-29, on Windows desktop — focus
### Input — [[judgements/input|Input]]
- [[judgements/input#Pointer is legible|Pointer is legible]] — Judged 2026-10-09, on Linux desktop — pointer
'@
    return $repo
}
function Replace-DocumentationFixture($Repository,$File,$Before,$After) {
    $path=Join-Path $Repository $File
    Write-FixtureText $path ([IO.File]::ReadAllText($path).Replace($Before,$After))
}
function Assert-DocumentationFailure($Repository,$Code) {
    $report=Test-ProjectDocumentation -Repository $Repository
    Assert (-not $report.Passed) "Invalid documentation passed ($Code)."
    Assert (@($report.Diagnostics | Where-Object Code -eq $Code).Count -gt 0) "Missing diagnostic $Code : $($report.Diagnostics | ConvertTo-Json -Depth 6 -Compress)"
}
Test 'gate accepts empty foundation and populated canon' {
    $parent=New-BootstrapFixture 'empty'
    $id=New-BootstrapIdentity -Name 'Empty' -Description 'Fixture' -Parent $parent
    Write-ProjectFoundation -Identity $id -AssetRoot $assetRoot | Out-Null
    Assert ((Test-ProjectDocumentation -Repository $id.projectPath).Passed) 'Fresh foundation failed.'
    $report=Test-ProjectDocumentation -Repository (New-PopulatedDocumentationFixture 'valid')
    Assert $report.Passed ($report.Diagnostics | ConvertTo-Json -Compress)
}
Test 'gate resolves implicit Markdown names with dots while preserving explicit attachments' {
    $repo=New-PopulatedDocumentationFixture 'dotted names'
    Move-Item -LiteralPath "$repo/docs/design/interface.md" -Destination "$repo/docs/design/version 1.0.md"
    Replace-DocumentationFixture $repo 'docs/DESIGN.md' 'design/interface' 'design/version 1.0'
    Write-FixtureText "$repo/docs/Version 1.0.md" "# Version 1.0`n`n## Details`nDocumented.`n"
    Write-FixtureText "$repo/docs/picture.png" 'An explicit attachment target'
    Add-Content -LiteralPath "$repo/docs/NEXT.md" -Value '[[Version 1.0]] [[Version 1.0#Details]] ![[picture.png]]'
    $report=Test-ProjectDocumentation -Repository $repo
    Assert $report.Passed ($report.Diagnostics | ConvertTo-Json -Depth 6 -Compress)
    Replace-DocumentationFixture $repo 'docs/NEXT.md' 'Version 1.0#Details' 'Version 1.0#Missing'
    Assert-DocumentationFailure $repo 'link-target'
}
Test 'review documentation links require portable file and directory casing' {
    foreach ($pair in @(@{good='[Design](DESIGN.md)';bad='[Design](design.md)'},@{good='[Readme](../README.md)';bad='[Readme](../readme.MD)'},@{good='[Topic](design/interface.md)';bad='[Topic](Design/interface.md)'},@{good='[[design/interface]]';bad='[[design/Interface]]'})) {
        $repo=New-PopulatedDocumentationFixture 'case-sensitive links'
        Add-Content -LiteralPath "$repo/docs/NEXT.md" -Value $pair.good
        Assert ((Test-ProjectDocumentation -Repository $repo).Passed) 'Correctly cased link failed.'
        Replace-DocumentationFixture $repo 'docs/NEXT.md' $pair.good $pair.bad
        $report=Test-ProjectDocumentation -Repository $repo
        Assert (-not $report.Passed -and @($report.Diagnostics | Where-Object {$_.Code -eq 'link-target' -and $_.File -eq 'docs/NEXT.md' -and $_.Line -gt 0}).Count -gt 0) 'A nonportable link passed or lost its source location.'
    }
}
Test 'gate requires actual indexes and directories' {
    foreach ($target in @('docs/DESIGN.md','docs/DECISIONS.md','docs/JUDGEMENTS.md','docs/design','docs/decisions','docs/judgements')) {
        $repo=New-PopulatedDocumentationFixture 'missing'
        # This disposable fixture is explicitly beneath the per-run test sandbox.
        Remove-Item -LiteralPath (Join-Path $repo $target) -Recurse -Force
        Assert-DocumentationFailure $repo 'required-path'
    }
}
Test 'gate requires exactly one live Index heading' {
    foreach ($replacement in @('## Not Index',"``````markdown`n## Index`n``````", "## Index`n## Index")) {
        $repo=New-PopulatedDocumentationFixture 'index'
        Replace-DocumentationFixture $repo 'docs/DESIGN.md' '## Index' $replacement
        Assert-DocumentationFailure $repo 'index-section'
    }
}
Test 'gate rejects missing local files headings and ambiguous targets' {
    foreach ($target in @('design/missing#Overview','design/input#Absent','design/input#Overview')) {
        $repo=New-PopulatedDocumentationFixture 'target'
        if ($target -eq 'design/input#Overview') { Add-Content "$repo/docs/design/input.md" "`n## Overview" }
        Replace-DocumentationFixture $repo 'docs/design/interface.md' 'DECISIONS' $target
        Assert-DocumentationFailure $repo 'link-target'
    }
}
Test 'gate indexes records using exact file identity' {
    $repo=New-PopulatedDocumentationFixture 'wrong-file'
    Replace-DocumentationFixture $repo 'docs/DECISIONS.md' 'decisions/interface#Keyboard navigation' 'decisions/input#Keyboard navigation'
    Assert-DocumentationFailure $repo 'not-indexed'
    Assert-DocumentationFailure $repo 'index-entry'
}
Test 'gate rejects topic group and top-level title mismatch' {
    $repo=New-PopulatedDocumentationFixture 'group'
    Replace-DocumentationFixture $repo 'docs/DECISIONS.md' '[[decisions/interface|Interface]]' '[[decisions/input|Input]]'
    Assert-DocumentationFailure $repo 'index-group'
    $repo=New-PopulatedDocumentationFixture 'title'
    Replace-DocumentationFixture $repo 'docs/DESIGN.md' 'design/interface|Interface' 'design/interface|Wrong'
    Assert-DocumentationFailure $repo 'topic-title'
}
Test 'gate rejects omitted duplicate and hidden index entries' {
    foreach ($replacement in @('', ('- [[decisions/interface#Keyboard navigation|Keyboard navigation]]' + "`n" + '- [[decisions/interface#Keyboard navigation|Keyboard navigation]]'), '<!-- - [[decisions/interface#Keyboard navigation|Keyboard navigation]] -->', "``````md`n- [[decisions/interface#Keyboard navigation|Keyboard navigation]]`n``````")) {
        $repo=New-PopulatedDocumentationFixture 'entries'
        Replace-DocumentationFixture $repo 'docs/DECISIONS.md' '- [[decisions/interface#Keyboard navigation|Keyboard navigation]]' $replacement
        Assert-DocumentationFailure $repo $(if ($replacement.StartsWith('-')) {'duplicate-index'} else {'not-indexed'})
    }
}
Test 'gate enforces citation uniqueness and real decision dates' {
    $repo=New-PopulatedDocumentationFixture 'key'
    Replace-DocumentationFixture $repo 'docs/decisions/input.md' '### Pointer timing' '### Keyboard navigation'
    Assert-DocumentationFailure $repo 'duplicate-key'
    foreach ($date in @('2026-02-30','2026-13-01','Undated')) {
        $repo=New-PopulatedDocumentationFixture 'date'
        Replace-DocumentationFixture $repo 'docs/decisions/interface.md' '2026-10-09' $date
        Assert-DocumentationFailure $repo 'decision-date'
    }
}
Test 'gate resolves Unicode aliases escaped paths external and repository links' {
    $repo=New-PopulatedDocumentationFixture 'links'
    Write-FixtureText "$repo/docs/Extra Note.md" "# Café`n`n## Ångström test`n[Self](#ångström-test) [[#Ångström test|Self]]`n[Readme](../README.md) [Folder](design/) [Other](https://example.org/missing) ![image](https://example.org/a.png)`n"
    Add-Content "$repo/docs/NEXT.md" "`n[[Extra Note#Ångström test|Alias]] [Alias](Extra%20Note.md#%C3%A5ngstr%C3%B6m-test)"
    Assert ((Test-ProjectDocumentation -Repository $repo).Passed) 'Valid local links failed.'
    Add-Content "$repo/docs/NEXT.md" "`n[Escape](../../outside.md)"
    Assert-DocumentationFailure $repo 'link-target'
}
Test 'gate requires independent immediate judgement fields' {
    foreach ($statement in @('Judged 2026-02-30, on Windows desktop.','Judged 2026-13-01, on Windows desktop.','Judged x2026-10-09y, on Windows desktop.','Judged 2026-10-09, on 2026-10-09.','Judged 2026-10-09. Prose on Windows desktop.','Judged Hardware not recorded, on Windows desktop.','Judged Date not recorded, on Windows desktop.','Judged 2026-10-09.','Judged 2026-10-09, on 1234.','Judged 2026-10-09, on desktop. Rechecked 2026-02-30.')) {
        $repo=New-PopulatedDocumentationFixture 'metadata'
        Replace-DocumentationFixture $repo 'docs/judgements/interface.md' 'Judged 2024-02-29, on Windows desktop.' $statement
        Assert-DocumentationFailure $repo 'judgement-fields'
    }
    foreach ($body in @("`n*Judged 2024-02-29, on Windows desktop.*", "Prose.`n*Judged 2024-02-29, on Windows desktop.*", "*Judged 2024-02-29,`non Windows desktop.*", "*Judged 2024-02-29, on Windows desktop.*`n*Judged 2024-02-29, on Windows desktop.*")) {
        $repo=New-PopulatedDocumentationFixture 'placement'
        Replace-DocumentationFixture $repo 'docs/judgements/interface.md' '*Judged 2024-02-29, on Windows desktop.*' $body
        Assert-DocumentationFailure $repo 'judgement-metadata'
    }
}
Test 'gate compares index metadata and allows hardware-not-applicable' {
    $repo=New-PopulatedDocumentationFixture 'copy'
    Replace-DocumentationFixture $repo 'docs/JUDGEMENTS.md' 'on Windows desktop' 'on Different hardware'
    Assert-DocumentationFailure $repo 'judgement-index'
    $repo=New-PopulatedDocumentationFixture 'inapplicable'
    Replace-DocumentationFixture $repo 'docs/judgements/interface.md' 'on Windows desktop' 'Hardware not applicable'
    Replace-DocumentationFixture $repo 'docs/JUDGEMENTS.md' 'on Windows desktop' 'Hardware not applicable'
    Assert ((Test-ProjectDocumentation -Repository $repo).Passed) 'Explicit hardware exemption rejected.'
}
Test 'gate reports explicitly incomplete history as a warning' {
    $repo=New-PopulatedDocumentationFixture 'history'
    Replace-DocumentationFixture $repo 'docs/judgements/interface.md' 'Judged 2024-02-29, on Windows desktop.' 'Judged Date not recorded, Hardware not recorded. Incomplete historical record.'
    Replace-DocumentationFixture $repo 'docs/JUDGEMENTS.md' 'Judged 2024-02-29, on Windows desktop' 'Judged Date not recorded, Hardware not recorded. Incomplete historical record'
    $report=Test-ProjectDocumentation -Repository $repo
    Assert $report.Passed 'Explicit history rejected.'
    Assert (@($report.Diagnostics | Where-Object { $_.Code -eq 'incomplete-record' -and $_.Severity -eq 'warning' }).Count -eq 1) 'History falsely counted as complete.'
    Replace-DocumentationFixture $repo 'docs/JUDGEMENTS.md' '. Incomplete historical record' ''
    Assert-DocumentationFailure $repo 'judgement-index'
}
Test 'gate rejects unreadable indexes and file-valued topical directories' {
    $repo=New-PopulatedDocumentationFixture 'unreadable'
    $stream=[IO.File]::Open("$repo/docs/DESIGN.md",[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try { Assert-DocumentationFailure $repo 'unreadable-file' } finally {$stream.Dispose()}
    $parent=New-BootstrapFixture 'wrong-type'
    $id=New-BootstrapIdentity -Name 'Wrong Type' -Description 'Fixture' -Parent $parent
    Write-ProjectFoundation -Identity $id -AssetRoot $assetRoot | Out-Null
    Remove-Item -LiteralPath "$($id.projectPath)/docs/design/.gitkeep"
    Remove-Item -LiteralPath "$($id.projectPath)/docs/design"
    Write-FixtureText "$($id.projectPath)/docs/design" 'A file'
    Assert-DocumentationFailure $id.projectPath 'required-path'
}
Test 'gate runs copied offline script from an unrelated directory' {
    $repo=New-PopulatedDocumentationFixture 'subprocess'
    Push-Location $env:TEMP
    try {
        $out=& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File "$repo/tools/verify.ps1" 2>&1
        Assert ($LASTEXITCODE -eq 0) "Copied gate failed: $out"
        Remove-Item -LiteralPath "$repo/docs/DESIGN.md"
        $out=& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File "$repo/tools/verify.ps1" 2>&1
        Assert ($LASTEXITCODE -eq 1) 'Failed gate returned success.'
        Assert (($out -join "`n") -match 'docs/DESIGN.md:1: required-path') 'No usable file/line diagnostic.'
    } finally { Pop-Location }
}

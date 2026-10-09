# ba-bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task, according to Cicely's selected execution method. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver an agent-agnostic skill that creates the agreed repository pair and seeds a private project with its documentation, working process, standalone verification gate and local Obsidian setup.

**Architecture:** Keep reusable project files and selected Obsidian preferences in the skill's assets. Small PowerShell modules own local generation, documentation validation, GitHub operations, recovery state and plugin setup; one command routes the workflow. Generated projects carry their own documentation validator, so using or checking a project does not depend on the skill remaining installed.

**Tech Stack:** PowerShell 7.2+, Git, authenticated GitHub CLI, GitHub REST APIs, JSON state/presets, Markdown and Obsidian wikilinks. No engine dependency in version one.

**Spec:** [Approved design](../specs/2026-10-09-ba-bootstrap-design.md). Read it with this plan; it defines the 17 agent rules, record content and all public/private boundaries.

**Status:** Proposed implementation plan for review. No implementation or live project creation is authorized by writing this file. Cicely approved the written design on 2026-10-09; plan review and execution-method selection are the next checkpoint.

## Global Constraints

- Use shared PowerShell 7.2+ helpers; the generated documentation gate runs offline from a fresh checkout.
- Parent directory default: `C:\Users\cicel\Dev`.
- GitHub owner default: `Benevolent-Anarchy`; optional switch: `cicely-f`.
- Trim surrounding whitespace and replace runs of whitespace in the project name with a hyphen, preserving capitalisation.
- Default branch: `main` in both repositories.
- There is no local clone or path for the public repository.
- The public repository initially contains exactly `README.md` and never receives the private description or foundation files.
- Ignore `docs/.obsidian/` and `.scratch/`; no mandatory `_project-meta/`.
- `AGENTS.md` is the canonical agent contract; `CLAUDE.md` is a short pointer.
- Required plugins: `vault-nickname`, `vault-inspector`, `dataview`, `mermaid-popup`, at their latest published community releases at setup time.
- Godot is a second-step preset, selected by default when available; version one implements only the foundation.
- Do not overwrite collisions, adopt unrelated repositories, change visibility after uploading content, or delete partial work to roll back.
- `tools/verify.ps1` must pass against the finished proposed state before a PR opens. Cicely retains merge control.

## Review Focus

These five conditions receive explicit tests in the owning tasks below:

1. A lost create/upload response must not cause a duplicate repository, forced push or adoption of somebody else's repository (Task 4).
2. A name valid on GitHub can still be unusable on Windows, or make the suffixed repository exceed GitHub's limit (Task 1).
3. A link can resolve while the index lists it under the wrong topic; code/comments can falsely appear to satisfy a missing record (Tasks 2–3).
4. A plugin upgrade or retry can corrupt existing local preferences or retain a mixed old/new installation; installed files do not prove app enablement (Task 5).
5. Installer changes can disturb ba-release or create one link before discovering a conflict in another target (Task 6).

## File ownership and interfaces

All paths below are repository-relative. Implementation happens in the attached `codex/ba-bootstrap` worktree, currently `C:\Users\cicel\.codex\worktrees\ba-bootstrap\BA-Skills`. Before touching shared installation code, incorporate the latest committed `main` after checking its status; another chat is developing ba-release. Do not move or stash its uncommitted files.

| File or group | Responsibility |
| --- | --- |
| `skills/ba-bootstrap/scripts/Project.psm1` | Identity validation, literal template expansion, content manifests and non-destructive local generation |
| `skills/ba-bootstrap/assets/project/` | Tracked files copied into the private project, including its standalone validator |
| `skills/ba-bootstrap/assets/public-README.md.template` | The only initial public-repository content |
| `skills/ba-bootstrap/assets/labels.json` | DRRD's 23 label names, colours and descriptions |
| `skills/ba-bootstrap/assets/obsidian/` | Selected preferences and required plugin IDs; no plugin binaries or project history |
| `skills/ba-bootstrap/scripts/State.psm1` | Atomic local progress journal and identity checks |
| `skills/ba-bootstrap/scripts/GitHub.psm1` | Typed GitHub requests, private push, public README and settings, labels and verification |
| `skills/ba-bootstrap/scripts/Obsidian.psm1` | Latest-release resolution, staged plugin installation and preference preservation |
| `skills/ba-bootstrap/scripts/Bootstrap.psm1` | Phase coordination and read-only status/plan reports |
| `skills/ba-bootstrap/scripts/bootstrap.ps1` | User-facing modes, parameters, interactive missing-input collection and exit codes |
| `skills/ba-bootstrap/SKILL.md`, `references/operations.md` | Agent-agnostic routing, creation authorization, truthful completion and browser-only settings |
| `skills/ba-bootstrap/scripts/install.ps1` | Dispatch installation to BA-Skills' root installer for this skill |
| `skills/ba-release/scripts/Install.psm1`, `install.ps1` | Extend existing installer with a skill-name parameter and root selection; retain release defaults |
| `tests/bootstrap/` | Offline behavioral suites and small reusable test/fixture support |
| `tools/verify.ps1` | BA-Skills' aggregate release/bootstrap test gate, distinct from the gate copied into new projects |
| `README.md` | Discover both skills, install them and run the repository gate |

The generated `Documentation.psm1` owns its scanner internally: keep the generated gate to two files. Split its internal functions by responsibility; do not add an engine, parser package or runtime dependency merely for documentation validation.

### Shared result shapes

Use ordered hashtables or `PSCustomObject`s with these exact property names. Public functions return data; diagnostics/progress must not accidentally become extra success-stream results.

```powershell
# Project identity returned by New-BootstrapIdentity
$identity = @{ title='Foo Bar Baz'; description='A useful project'; owner='Benevolent-Anarchy'
   repository='Foo-Bar-Baz'; fullName='Benevolent-Anarchy/Foo-Bar-Baz'
   notesRepository='Foo-Bar-Baz-release-notes'
   notesFullName='Benevolent-Anarchy/Foo-Bar-Baz-release-notes'
   parent='C:\Users\cicel\Dev'; projectPath='C:\Users\cicel\Dev\Foo-Bar-Baz'
   vaultPath='C:\Users\cicel\Dev\Foo-Bar-Baz\docs'; defaultBranch='main' }

# Content manifest entry; text is UTF-8 without BOM, hashes are of written bytes
@{ path='docs/DESIGN.md'; text='# Design'
   sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('# Design'))).ToLowerInvariant() }

# Documentation report returned by Test-ProjectDocumentation
@{ Passed=$false; Diagnostics=@(
   @{ Code='not-indexed'; Severity='error'; File='docs/decisions/interface.md'; Line=5
      Heading='Keyboard navigation'; Message='Entry is absent from DECISIONS.md.' }) }

# GitHub adapter response; non-success HTTP responses remain distinguishable
@{ StatusCode=200; Data=@{id=123; full_name='Benevolent-Anarchy/Foo-Bar-Baz'} }

# Overall workflow report; completed means every required phase verified
$key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity.fullName.ToLowerInvariant()))).ToLowerInvariant()
@{ status='partial'; identity=$identity; phases=@(); pending=@()
   journalPath=(Join-Path $env:LOCALAPPDATA ('BA-Skills/ba-bootstrap/state/' + $key + '.json')); errors=@() }
```

Each phase is `{ name, status, evidence, message }`, where status is `pending`, `verified`, `blocked`, or `needs-browser`. Documentation diagnostics have `Severity='error'` or `'warning'`; `Passed` is true only when no errors exist. Explicitly incomplete historical records emit warnings and never become trusted acceptance. Obsidian also reports each plugin's `id`, `version`, `filesVerified` and `enabledVerified`. Journal details and exception messages contain no credentials or command environments.

## Task 1: Generate the local foundation and validate identity

**Files:** Create `scripts/Project.psm1` and `assets/project/` under `skills/ba-bootstrap/`; create `assets/public-README.md.template`, `assets/labels.json`; create `tests/bootstrap/TestSupport.ps1`, `run-tests.ps1`, `project-tests.ps1`.

**Interfaces:**

- `Resolve-BootstrapRepositoryName -Name <string>` → validated case-preserving slug; no filesystem mutation or description required. Creation and journal lookup share it.
- `New-BootstrapIdentity -Name <string> -Description <string> -Parent <string> -Owner <string>` → identity shape above; defaults come from the spec.
- `Get-ProjectManifest -Identity <hashtable> -AssetRoot <string>` → manifest entry array.
- `Get-PublicReadme -Identity <hashtable>` → UTF-8 text with a heading and the agreed single sentence.
- `Write-ProjectFoundation -Identity <hashtable> -AssetRoot <string>` → manifest/report; compare all existing target files before writing any.
- Test support: `Test -Name <string> -Body <scriptblock>`, `Assert <bool> <message>`, `Expect-Error <scriptblock> <regex>`, `New-BootstrapFixture -Name <string>` → unique absolute directory under this run's sandbox.

- [ ] **1. Establish the offline test runner and a failing identity contract.** Follow the current `tests/run-tests.ps1` style without importing its fixtures or adding a dependency on Pester. `tests/bootstrap/run-tests.ps1` accepts `-Filter '*'`, loads `TestSupport.ps1` and the present `*-tests.ps1` files, fails if zero tests match, aggregates failures and exits nonzero. Each run has a unique temporary sandbox; fixture operations stay inside it. Set fixture roots once in that runner:

```powershell
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$skillRoot = Join-Path $root 'skills/ba-bootstrap'
$assetRoot = Join-Path $skillRoot 'assets/project'
$presetRoot = Join-Path $skillRoot 'assets/obsidian'
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('ba-bootstrap-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null
```

```powershell
Test 'identity preserves title case and derives both repositories' {
    $id = New-BootstrapIdentity -Name '  Foo   Bar Baz  ' -Description 'Private purpose'
    Assert ($id.repository -ceq 'Foo-Bar-Baz') 'Repository case or spacing changed.'
    Assert ($id.notesFullName -ceq 'Benevolent-Anarchy/Foo-Bar-Baz-release-notes') 'Wrong public name.'
    Assert ($id.projectPath -eq 'C:\Users\cicel\Dev\Foo-Bar-Baz') 'Wrong default parent.'
    Assert (-not $id.ContainsKey('notesPath')) 'Public checkout path was invented.'
}
Test 'identity rejects Windows devices and a suffix overflow' {
    Expect-Error { New-BootstrapIdentity -Name 'NUL.notes' -Description 'purpose' } 'Windows'
    Expect-Error { New-BootstrapIdentity -Name ('A' * 87) -Description 'purpose' } '100'
}
```

- [ ] **2. Run `pwsh -NoProfile -File tests/bootstrap/run-tests.ps1 -Filter 'identity*'`; confirm the expected missing-function failure.** Add cases for blank name/description, punctuation outside ASCII letters/digits/`.`/`-`/`_`, trailing dot, dot-only names, `CON`/`COM1`/`LPT9` with extensions, tab/newline whitespace conversion, a parent containing spaces, owner override, and a parent that is an existing file. An 86-character repository plus the 14-character suffix is allowed; 87 is rejected. Reject an unsupported human name with an explanation, without transliteration or another invented name.

- [ ] **3. Implement identity and literal manifest expansion.** Use `Path.GetFullPath` and fully qualified Windows parent paths. Verify existing parent ancestors are directories; do not create anything during identity inspection. Keep project title, repository slug and full names separate. Template substitutions replace only known literal tokens, without evaluating the supplied text.

```powershell
$title = $Name.Trim()
$repository = [regex]::Replace($title, '\s+', '-')
$notesRepository = $repository + '-release-notes'
if ($repository -notmatch '^[A-Za-z0-9._-]+$' -or $notesRepository.Length -gt 100) {
    throw 'Use ASCII letters, digits, dots, hyphens or underscores; both repository names must fit 100 characters.'
}
if ($repository -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)' -or
    $repository.EndsWith('.') -or $repository -match '^\.+$') {
    throw 'The project name cannot be used as a Windows directory name.'
}
```

- [ ] **4. Seed the agreed files.** Templates include root README with description, PowerShell 7.2+ verification command, canon/Issues pointers; AGENTS with the approved 17 rules; CLAUDE pointing to AGENTS; `.gitignore` containing `docs/.obsidian/` and `.scratch/`; three indexes with real `## Index` sections; minimal NEXT; three `.gitkeep` markers. Copy actual gate files once Tasks 2–3 supply them. Include authoring examples only in fenced code, not invented live records. Render Markdown titles as literal text. Use the agreed topical forms:

```markdown
### Interface — [[decisions/interface|Interface]]
- [[decisions/interface#Keyboard navigation|Keyboard navigation]] — keyboard, focus

### Interface — [[judgements/interface|Interface]]
- [[judgements/interface#Focus is visible|Focus is visible]] — Judged 2026-10-09, on Windows desktop — focus, contrast
```

Document `## YYYY-MM-DD` decision date groups, unique `###` record titles, decision rationale/supersession, immediate single-line judgement metadata and coverage/recheck fields exactly as the spec requires. Define all `##`–`######` headings in design topic files as substantive navigation targets, and show their links beneath the topic's index entry. Index prose outside `## Index` is guidance, not a second collection of entries.

- [ ] **5. Add and run manifest/conflict tests.** Public text is exactly `# Foo Bar Baz release notes`, blank line, `This repository is the public record of release notes for Foo Bar Baz.`, terminal newline. Check it contains none of the private description. A conflicting file, wrong symlink/junction or file-valued ancestor prevents writes to every other target; an identical existing file is accepted. Description text containing backticks, `$(...)`, dollar signs and braces remains literal and is never executed. Initial generation creates no project-specific Issues, notes, engine files or `_project-meta`.

Extract all 23 labels to JSON from the inspected DRRD repository, keeping colours/descriptions; replace the `design` description's `Design Notes` reference with `DESIGN.md`. Tests compare semantic names/colours/count against the checked-in snapshot and ensure no milestones or backlog are generated. Snapshot extraction is development work; the installed skill never needs DRRD.

- [ ] **6. Run the complete bootstrap suite, inspect the generated tree, and commit only this task's files.** Commit: `feat: seed bootstrap project documentation and identity`.

## Task 2: Parse live Markdown without treating examples as documentation

**Files:** Create `skills/ba-bootstrap/assets/project/tools/Documentation.psm1`; create `tests/bootstrap/markdown-tests.ps1` and `tests/bootstrap/fixtures/markdown/`.

**Interfaces:** Internal scanner `Get-DocumentationTokens -Text <string> -File <string>` → `{ Headings, Links, VisibleLines, LinkableLines }`. Every heading/link has its original 1-based line. Headings carry `Level`, `Title`, `Anchor`; links carry `Kind`, `Target`, `Label`, `Line`. Export the scanner for fixture tests; the generated gate uses only `Test-ProjectDocumentation` from Task 3.

- [ ] **1. Write failing scanner tests with actual competing live and hidden content.** Translate the relevant DRRD `test/support/record_check.gd` scanner and `test/fixtures/design_notes_code/`, `design_notes_markdown/`, `design_notes_fenced_index/` cases into engine-independent fixtures. Preserve examples showing why a fence, span or comment boundary matters; remove DRRD's 1000-character line rule and its nonempty-design requirement.

```powershell
Test 'scanner keeps code in heading titles but ignores links in code and comments' {
    $text = @'
# Topic
## Behaviour of `Size`
`[[missing#Target]]`
<!-- [[also-missing]] -->
[[design/topic#Behaviour of `Size`|Size]]
'@
    $tokens = Get-DocumentationTokens -Text $text -File 'docs/design/topic.md'
    Assert ($tokens.Headings[1].Title -ceq 'Behaviour of `Size`') 'Heading lost its code title.'
    Assert ($tokens.Links.Count -eq 1) 'Hidden example became a live link.'
    Assert ($tokens.Links[0].Line -eq 5) 'Diagnostics lost source line numbers.'
    Assert ($tokens.Links[0].Target -ceq 'design/topic#Behaviour of `Size`') 'Code inside the actual target was removed.'
}
```

- [ ] **2. Run `pwsh -NoProfile -File tests/bootstrap/run-tests.ps1 -Filter 'scanner*'` and confirm a missing scanner fails.** Add tests for backtick/tildes of differing lengths; invalid backtick info strings; closers with trailing text; indentation; multiline inline spans; unclosed literal backticks; comments containing backticks; comments ending mid-line; Obsidian `%%` comments; a heading ending an unmatched span's scope; CRLF/LF; escaped link syntax; reference-style Markdown links; readable aliases and code in a heading.

- [ ] **3. Port the tested two-view lexical scanner.** `VisibleLines` preserves inline code for heading titles; `LinkableLines` masks it. Both mask fenced code and comments and keep original line count. Track fence character/length, comment terminator and exact code-span run length. A closer must have the same fence character and at least the opener's length, with no trailing content. Inline spans cannot cross a paragraph/block boundary or an ATX heading. Use the DRRD implementation's explicit look-ahead for exact closing runs rather than a single regex over the entire document. Treat indented code as examples too.

```powershell
$headings = [Collections.Generic.List[object]]::new()
for ($i = 0; $i -lt $visibleLines.Count; $i++) {
    if ($visibleLines[$i] -match '^ {0,3}(#{1,6})(?:[ \t]+|$)(.*)$') {
        $level = $Matches[1].Length
        $title = [regex]::Replace($Matches[2], '[ \t]+#+[ \t]*$', '').Trim()
        $headings.Add(@{ Level=$level; Title=$title; Line=$i+1; Anchor=(Get-MarkdownAnchor $title) })
    }
}
```

Implement internal `Get-MarkdownAnchor -Title <string>` for rendered heading text using GitHub's documented lower-case/space/punctuation rules. Keep exact heading text for wikilinks, including code in citation keys. Extract inline Markdown links, image targets and referenced definitions only when their opening delimiter is live, respecting escapes, angle-bracket destinations and balanced destination parentheses. Preserve original positions while masking; parse each eligible target from the original text, with the target treated as an opaque destination rather than prose whose backticks/comments can be removed. A code span surrounding a whole link hides it; inline code within a real heading target must not alter that target. External schemes and protocol-relative URLs are classified as external, without being fetched. Read named wikilinks as vault-root-relative, `[[#Heading]]` as the current note, and aliases as labels rather than targets.

- [ ] **4. Run all scanner fixtures and inspect failure diagnostics.** A fake `## Index` inside a fence cannot create a real index; a later real heading after a comment is visible. Two distinct headings differing in inline code remain distinct. Ambiguous target headings remain visible to Task 3 rather than being silently assigned duplicate suffixes.

- [ ] **5. Commit the passing scanner and fixtures.** Commit: `feat: parse documentation headings and links independently of Godot`.

## Task 3: Enforce corpus/index agreement through the standalone gate

**Files:** Extend `assets/project/tools/Documentation.psm1`; create `assets/project/tools/verify.ps1`; extend the index templates; create `tests/bootstrap/documentation-tests.ps1`, `tests/bootstrap/fixtures/documentation/`.

**Interfaces:** `Test-ProjectDocumentation -Repository <string>` → `{ Passed, Diagnostics }`. Diagnostics have the shared shape above. Fixture helper `New-PopulatedDocumentationFixture -Name <string>` produces a foundation containing two design topics and one decision/judgement record per topic. Decisions have `### Keyboard navigation` in `interface.md`, `### Pointer timing` in `input.md`, and an ordinary `#### Keyboard navigation` subsection in `input.md`: the latter exists as a link target but is not the record. `tools/verify.ps1` resolves repository from `$PSScriptRoot`, emits useful diagnostics and exits 0 or 1.

- [ ] **1. Write failing corpus tests before implementing the validator.** Build complete fixture files with explicit links; modify one rule per test.

```powershell
Test 'gate rejects an entry indexed under a different existing topic' {
    $repo = New-PopulatedDocumentationFixture -Name 'wrong-topic'
    $index = Join-Path $repo 'docs/DECISIONS.md'
    $text = Get-Content -LiteralPath $index -Raw
    $text.Replace('decisions/interface#Keyboard navigation', 'decisions/input#Keyboard navigation') |
        Set-Content -LiteralPath $index -Encoding utf8NoBOM
    $report = Test-ProjectDocumentation -Repository $repo
    Assert (-not $report.Passed) 'Wrong topic passed because the heading exists elsewhere.'
    Assert (@($report.Diagnostics | Where-Object Code -eq 'not-indexed').Count -gt 0) 'Actual entry was not reported.'
}
Test 'gate accepts a fresh intentionally empty foundation' {
    $repo = New-BootstrapFixture -Name 'empty-foundation'
    $id = New-BootstrapIdentity -Name 'Empty Foundation' -Description 'Fixture' -Parent $repo
    Write-ProjectFoundation -Identity $id -AssetRoot $assetRoot | Out-Null
    Assert ((Test-ProjectDocumentation -Repository $id.projectPath).Passed) 'Empty valid canon failed.'
}
```

- [ ] **2. Run `pwsh -NoProfile -File tests/bootstrap/run-tests.ps1 -Filter 'gate*'`; confirm the missing validator/gate fails.** Additional invalid cases: removed index, unreadable index, removed topical directory, removed or fenced-only `## Index`, missing linked file/heading, an omitted real entry, duplicate defined citation keys, duplicate index entries, a link/group mismatch, title mismatch, and a commented/fenced copy falsely satisfying a missing live entry. Add successful cross-links, vault-root links, Markdown relative paths, a file with spaces, Unicode headings, aliases, external URLs and guidance links outside the Index section.

- [ ] **3. Implement two-way agreement with file identity, not a global heading-name lookup.** Scan tracked Markdown under `docs/`, excluding `.obsidian/` and `.gitkeep`; also check local links from those notes into the repository. Required indexes must have exactly one real `## Index`; its collection ends at the next heading of level 1 or 2. In design indexes, a topic file link has matching top-level title and each substantive heading is linked beneath it. Decision/judgement groups link their actual topic file; every record `###` key must have exactly one matching target/title entry under that group. Compare `(normalised repository-relative file, exact title)` pairs in both directions, and separately enforce unique decision/judgement citation keys per corpus. Resolve Markdown fragment anchors and exact wikilink headings against the named file; report ambiguity rather than picking one.

The resolver accepts file and directory navigation links, implicit `.md` in wikilinks, percent-encoded Markdown paths/fragments and current-note fragments. Relative Markdown paths can point out of `docs/` into the repository, but not outside the project. Do not follow directory links recursively or treat the three repeated `## Index` headings in different index files as globally conflicting.

- [ ] **4. Validate judgement fields separately and match indexed metadata.** Copy DRRD's accepted format and independent-field behavior; use `DateTime.TryParseExact` with invariant culture for real dates. A complete entry has exactly one immediate `*Judged ... .*` line; strip only its italics and final full stop for the index copy. An `on <hardware>` clause must occur at the start or after the date in the first sentence and name something other than only a date. `Hardware not applicable` is allowed explicitly. Historical `Date not recorded`/`Hardware not recorded` markers are accepted only alongside an explicit `Incomplete historical record` statement in the record and index, and produce an incomplete-record diagnostic distinct from trusted acceptance. Do not convert missing fields into those markers automatically.

Add tests for leap day, impossible day/month, embedded `x2026-10-09y`, date-as-device, device only in prose, wrapped/duplicate/delayed metadata, index-copy mismatch, accepted hardware-not-applicable, and visibly incomplete history. A marker for one field never satisfies the other. Decision date groups must be real `## YYYY-MM-DD` dates; an entry without a containing dated group fails. Record status/verdict prose stays human-authored; the machine cannot establish whether a person performed the check.

- [ ] **5. Add the gate wrapper and subprocess tests.** The module returns diagnostics rather than exiting its caller. The wrapper handles failures and does not print success after an exception.

```powershell
#requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'Documentation.psm1') -Force
    $report = Test-ProjectDocumentation -Repository (Split-Path $PSScriptRoot -Parent)
    foreach ($item in $report.Diagnostics) {
        Write-Output ("{0}:{1}: {2}: {3}" -f $item.File,$item.Line,$item.Code,$item.Message)
    }
    if (-not $report.Passed) { exit 1 }
    Write-Output 'Verification passed: documentation.'
    exit 0
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
```

Run the copied script from an unrelated working directory, with no Godot/Obsidian executable or skill module available. Delete one required index in that disposable checkout and assert a nonzero subprocess exit. Restore it and assert zero. The private README/NEXT/AGENTS name this exact gate. Its script/module contain no reference to the skill's absolute development path.

- [ ] **6. Run the full bootstrap suite, review useful file/line output and commit.** Commit: `feat: gate project documentation before pull requests`.

## Task 4: Create and verify the repository pair with recoverable progress

**Files:** Create `skills/ba-bootstrap/scripts/State.psm1`, `GitHub.psm1`, `Bootstrap.psm1`, `bootstrap.ps1`; create `tests/bootstrap/github-tests.ps1`, `state-tests.ps1`; extend `TestSupport.ps1` with fake API/Git adapters.

**Interfaces:**

- `Get-BootstrapJournalPath -Identity <hashtable> -StateRoot <string>` → absolute path; production root is `$env:LOCALAPPDATA/BA-Skills/ba-bootstrap/state/`.
- `Read-BootstrapJournal -Path <string>` → hashtable or null; reject invalid schema/content.
- `Write-BootstrapJournal -Path <string> -Journal <hashtable>` → atomic replacement of that journal only.
- `Invoke-GitHubRequest -Method <string> -Endpoint <string> -Body <hashtable>` → `{ StatusCode, Data }`; authentication comes from GitHub CLI, never a persisted token.
- `Invoke-BootstrapGit -Repository <string> -Arguments <string[]>` → `{ ExitCode, Output }`; no string-built shell command.
- `Get-BootstrapPlan -Identity <hashtable> -Request <scriptblock> -StateRoot <string>` → read-only conflicts/prerequisites/phases report.
- `Invoke-Bootstrap -Identity <hashtable> -StateRoot <string> -Request <scriptblock> -Git <scriptblock>` → shared overall report; optional adapters default to the two production functions.
- `Get-BootstrapStatus -Identity <hashtable> -StateRoot <string> -Request <scriptblock>` → observed phase/identity report without mutation.
- `Set-BootstrapBrowserEvidence -Identity <hashtable> -Setting <string> -Evidence <hashtable> -StateRoot <string> -Request <scriptblock>` → updated journal phase. `Setting='pullRequests'`; evidence contains `repositoryId`, `disabled=$true`, `sourceUrl` and `observedAt` from the authenticated setting readback. Verify recorded/observed repository ID before accepting evidence; a timestamp or URL alone is not proof.
- CLI modes: `plan`, `create`, `status`, `resume`, `local-setup`. Parameters: `-Name`, `-Description`, `-Parent`, `-Owner`, `-Repository`, `-Interactive`, `-RefreshPlugins`; state-root overrides are for module tests, not normal user prompts.

The API test adapter accepts positional `(Method, Endpoint, Body)` and returns the shared HTTP response shape. The Git adapter accepts positional `(Repository, Arguments)`. Fake Git can run local `init`, `config`, `add`, `commit` and inspection normally, while translating only network fetch/push calls to a sandbox bare repository. Tests retain the expected GitHub origin string and never contact a live service. `New-GitHubFixture -ExistingPublic <switch> -FailPhase <string>` returns `{ stateRoot, request, git, calls, failPhase }`; closures capture that mutable fixture object so changing `failPhase` actually changes the next response.

- [ ] **1. Pin collision and retry behavior with failing tests.** Use a fake API whose in-memory repositories, content, features and call history survive between two invocations.

```powershell
Test 'creation refuses an existing public name before creating the private repo' {
    $fixture = New-GitHubFixture -ExistingPublic
    $id = New-BootstrapIdentity -Name 'Example Project' -Description 'private purpose' -Parent $sandbox
    $report = Invoke-Bootstrap -Identity $id -StateRoot $fixture.stateRoot -Request $fixture.request -Git $fixture.git
    Assert ($report.status -eq 'blocked') 'Collision was accepted.'
    Assert (@($fixture.calls | Where-Object { $_.method -eq 'POST' }).Count -eq 0) 'Mutation preceded complete preflight.'
}
Test 'resume does not recreate repositories after a failed label operation' {
    $fixture = New-GitHubFixture -FailPhase 'labels'
    $id = New-BootstrapIdentity -Name 'Retry Example' -Description 'purpose' -Parent $sandbox
    Invoke-Bootstrap -Identity $id -StateRoot $fixture.stateRoot -Request $fixture.request -Git $fixture.git | Out-Null
    $fixture.failPhase = ''
    $report = Invoke-Bootstrap -Identity $id -StateRoot $fixture.stateRoot -Request $fixture.request -Git $fixture.git
    Assert (@($fixture.calls | Where-Object { $_.isRepositoryCreate }).Count -eq 2) 'A repository was created twice.'
    Assert (@($report.phases | Where-Object { $_.name -eq 'labels' -and $_.status -eq 'verified' }).Count -eq 1) 'Missing phase did not resume.'
}
```

- [ ] **2. Run `pwsh -NoProfile -File tests/bootstrap/run-tests.ps1 -Filter '*creation*'`; confirm the expected missing implementation fails.** Include fixtures for unknown owner, insufficient access, private/public visibility mismatch, repo ID mismatch, case-equivalent Windows path collision, wrong origin, unexpected staged changes, and an unreadable/corrupt journal. Inspect both remote names and all local conflicts before any mutation. An inaccessible/private 404 is not enough to claim a name is definitely available when authentication itself has failed.

- [ ] **3. Implement the journal before remote mutations.** Persist schema version, invocation UUID, identity/input hash, template version, generated path/hash manifest, repository IDs, phase states and verified refs/plugin versions. Key its filename by a digest of case-normalised owner/name, avoiding collisions from simply concatenating arbitrary names. Use UTF-8 JSON, a same-directory temporary file, an exclusive per-invocation lock and atomic rename; reject concurrent writers rather than losing updates. Keep tokens, authentication headers and environment dumps out of state/errors.

```powershell
$bytes = [Text.Encoding]::UTF8.GetBytes(($Identity.owner + '/' + $Identity.repository).ToLowerInvariant())
$key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
$journalPath = Join-Path $StateRoot ($key + '.json')
$temporaryPath = Join-Path $StateRoot ($key + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
[IO.File]::WriteAllText($temporaryPath, ($Journal | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
[IO.File]::Move($temporaryPath, $journalPath, $true)
```

Lock the journal for the mutation operation; read-only status can read the last complete atomic snapshot. Preserve a journal from an incompatible template version and report the mismatch; do not reinterpret an unfinished old manifest as the new template. Tests simulate interruption before replacement and verify the previous journal is readable. Additional tests reject a second writer and mismatched input hashes.

- [ ] **4. Implement the typed API adapter and remote creation.** Use `gh api` with positional argument arrays, `--method`, explicit JSON `--input` via a temporary UTF-8 file, response headers/status and GitHub's documented API-version header. Decode JSON and distinguish 404 from 401/403/409/422 and transport errors; do not print the request payload or credentials. The plan/inspection mode makes GET requests only and writes no journal/files.

Resolve `/user` and `/users/{owner}` first. Use `POST /orgs/{owner}/repos` for an organisation; use `POST /user/repos` only when the selected personal owner matches the authenticated user. Create the private repository with `private=true`, `has_issues=true`, `auto_init=false`, the supplied description and no license/template. Create the public repository with `private=false`, `has_issues=false`, `has_projects=false`, `has_wiki=false`, `auto_init=false` and no private description. Record each returned ID durably before advancing.

After an ambiguous create response, GET the exact name before any retry. If it is still absent and access is confirmed, report the request as unresolved before allowing a deliberate retry. If it exists but no returned ID was durably associated with this invocation, return `identity-unconfirmed` with its observed ID/name/visibility; do not adopt it using name/time alone. An agent can ask Cicely to resolve that concrete ownership ambiguity. A normal recorded-ID retry resumes automatically. Tests cover a server-side create followed by a lost response and assert no second POST or visibility change.

- [ ] **5. Seed private main and the public README independently.** Initialise the private local checkout with `git init --initial-branch=main`, expected origin and the manifest. Run its generated gate before committing. Stage only manifest paths; never `git add .` in a resumed directory with other files. Commit `Initial project foundation`, push `main` without force and verify the remote ref/tree. Existing partial local Git state is accepted only if path, origin, branch, generated hashes and journal evidence agree. If a push response is lost, compare the remote `main` SHA with the intended local commit before retrying.

```powershell
$manifestPaths = @($manifest | ForEach-Object path)
& $Git $Identity.projectPath (@('add','--') + $manifestPaths)
& $Git $Identity.projectPath @('commit','-m','Initial project foundation')
& $Git $Identity.projectPath @('push','--set-upstream','origin','main')
```

Check each adapter's `ExitCode` before advancing; the snippet's operations are sequential, not an unchecked batch. Refuse to continue when unexpected staged/source changes would enter the initial commit. Set/verify the private default branch as `main` after its ref exists.

For the public repository, use the contents API directly: `PUT /repos/{notesFullName}/contents/README.md` with base64 UTF-8 content and `message='Initial public release-notes record'`. For a completely empty repository, omit `branch`; read the created default branch, and if necessary rename that branch to `main` through the supported branch-rename endpoint. Verify `main` and the exact README text after seeding. If a prior PUT was successful but its response was lost, accept only the exact intended bytes in the recorded repository with no other tree entries. An existing differing README/content is a conflict, not something to replace. Do not create a local public checkout even temporarily.

Tests verify the public tree has exactly one blob, contains no private description, has the expected branch and never triggers local public Git operations. Include an organisation whose initial default is another branch; final `main` is still required.

- [ ] **6. Apply and read back labels/public settings.** Update missing/different labels using the snapshot, with URL-encoded names and pagination; retain labels outside the snapshot. Defaults already present are matched by name before creating anything. A label/API failure leaves its phase unfinished without rebuilding content.

Public settings include `has_issues=false`, `has_wiki=false`, `has_projects=false`, `has_discussions=false`, `has_downloads=false`, `allow_auto_merge=false`; set Actions permissions `enabled=false` through `/repos/{notesFullName}/actions/permissions`. Read back effective settings. Verify public visibility, `main`, `permissions.push`, and absence of Pages configuration, rather than archiving or locking release writes. Optional contribution/automation settings are enumerated in the operations reference from the live Settings surface; security protections are not blindly disabled. Private Issues and PRs stay enabled.

Use a supported PR-disable API only if its documentation/readback support is confirmed. Otherwise report `needs-browser`, link the exact repository Settings > General > Features page, and have the invoking agent uncheck Pull requests with authenticated browser tools. Reopen/read the setting to verify it, then use `Set-BootstrapBrowserEvidence` to record the observation against the same journalled repository ID. Never claim API success disabled PRs when there was no such request/readback. Status must retain this unfinished item if browser access is unavailable, and label stored browser evidence with its observation time rather than pretending an API freshly checked the setting. Cover missing API support with a fake response and assert `partial`, not `complete`; mismatched browser-evidence IDs fail without advancing the phase.

- [ ] **7. Complete orchestration and CLI contracts.** `create`/`resume` return truthful verified phase results and pending items; the Obsidian phase is wired in Task 5. `plan`/`status` do not create repositories, state, checkouts or plugin files. Creation parameters supplied by an authorized skill invocation are sufficient authority for the named pair. Interactive mode prompts only missing inputs and offers the agreed parent/owner defaults; noninteractive missing inputs produce a structured list, not a terminal hang. A successful response exits zero only when all required phases are verified; partial/blocked results exit nonzero with usable JSON.

`status`/`resume` derive owner/repository through `Resolve-BootstrapRepositoryName`, then restore the full identity from the journal; they do not manufacture a description or require the original parent to be entered again. `resume` reloads the journal rather than prompting for or silently changing old inputs. A completed bootstrap invocation can be inspected again after ordinary project development without regenerating its initial files; check observed identity and public settings, preserve modified canon and direct plugin work through `local-setup`. `local-setup` is defined in Task 5 and never calls repository-create routes.

- [ ] **8. Run state/API/Git fixtures and the complete bootstrap suite, inspect retry call histories, then commit.** Commit: `feat: create resumable private and public bootstrap repositories`.

## Task 5: Apply the curated Obsidian recipe to a new project or fresh clone

**Files:** Create `skills/ba-bootstrap/assets/obsidian/core-plugins.json`, `app.json`, `appearance.json`, `plugins.json`, `plugin-preferences.json`; create `scripts/Obsidian.psm1`; extend Bootstrap/CLI for `local-setup`; create `tests/bootstrap/obsidian-tests.ps1` and small release-asset fixtures.

**Interfaces:**

- `Get-ObsidianPluginRelease -Id <string> -Registry <object[]> -Request <scriptblock>` → `{ id, repository, tag, version, minAppVersion, assets }`.
- `Invoke-ObsidianRequest -Method <string> -Endpoint <string> -Body <hashtable>` → the shared HTTP response shape. Delegate GitHub API endpoints to `Invoke-GitHubRequest`; fetch the official raw registry over HTTPS without attaching GitHub authentication. This is the default plugin request adapter, separate from repository requests.
- `Get-ObsidianJournalPath -Identity <hashtable> -StateRoot <string>` → state-root `vaults/` path keyed by owner/repository plus the normalised absolute vault path, so two clones cannot replace each other's progress.
- `Install-ProjectObsidian -Identity <hashtable> -PresetRoot <string> -StateRoot <string> -Request <scriptblock> -Download <scriptblock> -RefreshPlugins <switch>` → `{ plugins, configuration, pending, installedVerified, enabledVerified, journalPath }`; StateRoot has the same production default as Task 4.
- `Get-LocalProjectIdentity -Repository <string>` → identity derived from the verified Git root/origin and initial README title; no GitHub create operations. Respect a clone's actual path rather than its original parent's path.
- Download adapter accepts `(Url, Destination)`; production uses HTTPS downloads to an explicit staging path. The request adapter uses Task 4's HTTP response contract; fixtures return registry/release/manifest data without network traffic. `New-ObsidianFixture -Name <string>` returns `{ identity, request, download }`, plus mutable release/failure data for the specific test. `Install-ProjectObsidian` supplies production adapters when omitted; repository orchestration passes the plugin adapter separately rather than assuming a GitHub-only request adapter can fetch the raw registry.

- [ ] **1. Write failing recipe/preservation tests before copying settings or installing plugins.** Use a mock registry with the four required IDs and release assets with matching manifests.

```powershell
Test 'obsidian setup uses latest releases and writes the project nickname' {
    $fixture = New-ObsidianFixture -Name 'new-vault'
    $result = Install-ProjectObsidian -Identity $fixture.identity -PresetRoot $presetRoot -Request $fixture.request -Download $fixture.download
    Assert ($result.plugins.Count -eq 4) 'Missing required plugin.'
    Assert (@($result.plugins | Where-Object { -not $_.filesVerified }).Count -eq 0) 'Installed assets were not verified.'
    $shared = Get-Content -LiteralPath (Join-Path $fixture.identity.vaultPath '.obsidian/plugins/vault-nickname/data-shared.json') -Raw | ConvertFrom-Json
    Assert ($shared.nickname -ceq $fixture.identity.title) 'DRRD nickname leaked into the new project.'
    Assert (-not $result.enabledVerified) 'File installation alone claimed the app loaded plugins.'
}
```

- [ ] **2. Run `pwsh -NoProfile -File tests/bootstrap/run-tests.ps1 -Filter 'obsidian*'`; confirm the missing setup fails.** Test a newer release than DRRD's installed copy, missing/incorrect manifest ID, mismatched tag/version, missing `main.js`, optional stylesheet absent, a failed download, a current Obsidian version below `minAppVersion`, and a second invocation. The second run preserves existing preferences and extra plugins, makes no update request for complete existing standard installations unless `-RefreshPlugins` is selected, and does not rewrite workspace/history.

- [ ] **3. Extract a selected recipe, not a copied vault.** Take DRRD's current `core-plugins.json`, `app.json` (`promptDelete=false`), empty appearance object, Dataview preferences, Vault Inspector's `settings` only and Vault Nickname's title behavior. Preserve the plugin's actual setting key spelling `enableBackwardsCompatibilty`; generate `data-shared.json` with the new title. Empty Vault Inspector ignored fingerprints/folders/path-specific exceptions and omit snapshots/scan history. Do not create Diagram Popup preference data when there is none. Keep Sync/Publish account data, workspace files, caches and findings out of the recipe.

`plugins.json` lists IDs only, without pinned versions or current binaries. `plugin-preferences.json` maps plugin IDs to their selected settings/files. Tests check the recipe has no old nickname, open files, scan snapshots or history; do not test every cosmetic setting's spelling as a substitute for behavior.

- [ ] **4. Resolve and stage latest published releases.** Read the official community-plugin registry, find each ID's canonical repository, then inspect its latest non-draft/non-prerelease GitHub release. Download `manifest.json`, `main.js` and published `styles.css` when present. Verify manifest ID, version/tag agreement and app compatibility. Revalidate these facts if using the official Obsidian CLI instead. Do not choose a repository from unverified search results or copy DRRD's installed binaries.

```powershell
$entry = @($Registry | Where-Object id -eq $Id)
if ($entry.Count -ne 1) { throw "Plugin '$Id' has no unique registry entry." }
$release = & $Request 'GET' ('/repos/' + $entry[0].repo + '/releases/latest') @{}
if ($release.StatusCode -ne 200) { throw "Latest release for '$Id' is unavailable." }
$assetNames = @($release.Data.assets | ForEach-Object name)
if ('manifest.json' -notin $assetNames -or 'main.js' -notin $assetNames) {
    throw "Release for '$Id' is missing required plugin assets."
}
```

Stage all files for each plugin outside the active plugin folder. A failed download leaves no mixed final installation. Before a refresh, retain existing plugin data/preferences and move the previous verified binaries to a journalled local backup, then promote the verified staged assets; recover the old installation on a promotion error. Store this progress in the vault-specific local journal using Task 4's atomic state writer; local setup does not overwrite the original project-creation journal. Record resolved versions after verification, and pin those versions only for retries of that interrupted setup. A future deliberate refresh resolves latest again.

- [ ] **5. Merge configuration without destroying local customisation.** On an empty vault, write the selected recipe and all four IDs to `community-plugins.json`. On an existing vault, create missing standard configuration files/plugin settings, union required IDs with extra IDs, preserve existing settings values and extra plugin folders, and apply no workspace/tab changes. Check the actual Git ignore result with `git check-ignore` before declaring local setup ready; report a missing ignore rule rather than silently committing `.obsidian`.

Add a failure-injection test that aborts halfway through a refresh and compares previous plugin binaries/preferences with their hashes, then retries using the recorded release version. Test spaces in the vault path and a verified clone under a different parent. Unrelated local configuration remains byte-for-byte intact where no merge is required.

- [ ] **6. Verify app enablement separately and wire local setup.** If the installed official CLI is enabled, use the explicitly resolved vault with the documented plugin install/enable/list commands and read back all four loaded IDs/versions. Do not address whichever vault happens to be foreground. Without supported CLI/app access, verify installed files and configured plugin IDs, return the precise first-use/enablement pending step, and never claim the application loaded them. A failed app check retains useful installed state.

`local-setup -Repository <clone>` derives the existing owner/repository/title from Git/README, verifies the private foundation's AGENTS/docs/gate structure and remote identity rather than assuming any name ending in `-release-notes` is public, and applies the same recipe without requiring a bootstrap journal from the original machine. A legitimately named private project ending in that suffix still works. It can read remote identity as needed, but never creates or rewrites either repository. `-RefreshPlugins` is explicit; default local setup does not upgrade every installed plugin. Test two clones on the same machine with different preferences and vault journals; neither changes the other or the creation journal.

- [ ] **7. Run Obsidian fixtures and the full bootstrap suite, then commit.** Commit: `feat: seed reusable Obsidian vault preferences and plugins`.

## Task 6: Author and test the shared skill; extend installation without release regressions

**Files:** Create `skills/ba-bootstrap/SKILL.md`, `references/operations.md`, `scripts/install.ps1`; modify root `install.ps1`, `README.md`, and `skills/ba-release/scripts/Install.psm1`; create `tests/bootstrap/installation-tests.ps1`. Existing `skills/ba-release/scripts/install.ps1` and callers keep their default release behavior.

**Interfaces:**

- Extend `Get-ReleaseSkillTargets` with `-SkillName <string> = 'ba-release'` and `-IncludeNativeAliases`; retain `-IncludeWsl`, `-WslDistribution`.
- Extend `Install-ReleaseSkill` with `-SkillName <string> = 'ba-release'`; retain `-Source`, `-Targets`, `-CheckOnly` and existing result shape.
- Root installer gains `-Skill ba-release|ba-bootstrap|all` (default `all`), retaining its previous switches. Preflight all selected source/target sets before creating any link.
- Bootstrap's installer calls the root installer with `-Skill ba-bootstrap`; release's direct installer continues selecting ba-release by default.
- `New-InstallationFixture` creates a temporary home/source with a valid fixture SKILL.md and unrelated release sentinel; returns `{ home, source, releaseSentinel }`. Tests construct discovery targets from that home, never the user's home.

- [ ] **1. Refresh the shared-code baseline.** Inspect current `main`, installer callers and release tests again. Incorporate only committed changes into this isolated branch without interfering with the other chat's workspace. Record the selected base commit and run `pwsh -NoProfile -File tests/run-tests.ps1`; failures are resolved before attributing a regression to bootstrap.

- [ ] **2. Run an isolated skill behavior baseline before writing SKILL.md.** Apply the writing-skills/test-driven-development guidance. A fresh evaluating agent receives only a realistic user request and fixture tools, without this plan's intended outcome. Permit only fake GitHub and temporary local/discovery paths. Example request:

```text
Set up "Reference Project" with description "A private experiment" under the supplied fixture parent. Use the fixture GitHub tools and the BA owner. Stop if the fixture reports an unresolved failure, then explain the result. Do not contact real services or write outside the fixture.
```

The fixture injects a failed public-setting phase after both repos exist. Observe whether the agent describes partial progress accurately and preserves the invocation instead of inventing a rollback/retry workflow. A separate fresh-clone request supplies an existing project and asks for the usual Obsidian setup, with no repository-creation authorization. Keep observations in ignored `.test-results/`; use real observed omissions to improve instructions. If a scenario already passes, do not misreport it as a failure; use an uncovered design requirement for the next probe. These small behavior checks are separate from the chosen implementation method and are explicitly required by writing-skills.

- [ ] **3. Write the concise agent-agnostic entry point and conditional operations reference.** Use required frontmatter only; no agent-specific UI metadata is necessary.

```yaml
---
name: ba-bootstrap
description: Use when starting a new Benevolent Anarchy or personal project, or applying the standard local Obsidian setup to an existing project clone.
---
```

The body collects name, description, parent and owner together, explains the defaults and derived pair, invokes helpers through `pwsh`, and routes `plan/create/status/resume/local-setup`. Creation requires an actual user request for the named pair; a discussion about a future project runs inspection only. An authorized invocation and supplied inputs permit its routine creation steps without repeated approvals. Read `references/operations.md` only for failed/resumed operations, browser settings or app enablement. Do not require Superpowers, ba-release or a specific harness to use the skill.

Include concrete supported invocations:

```powershell
pwsh -NoProfile -File scripts/bootstrap.ps1 -Mode plan -Name 'Foo Bar Baz' -Description 'A useful project'
pwsh -NoProfile -File scripts/bootstrap.ps1 -Mode create -Name 'Foo Bar Baz' -Description 'A useful project'
pwsh -NoProfile -File scripts/bootstrap.ps1 -Mode status -Name 'Foo Bar Baz'
pwsh -NoProfile -File scripts/bootstrap.ps1 -Mode resume -Name 'Foo Bar Baz'
pwsh -NoProfile -File scripts/bootstrap.ps1 -Mode local-setup -Repository 'C:\Users\cicel\Dev\Foo-Bar-Baz'
```

`status`/`resume` use name/owner to locate recorded inputs and do not require a new description. The reference explains journal identity ambiguity, preserving conflicts, exact public Settings pages and readback, plugin installed/enabled distinction, deliberate refresh, clone setup and the existing ba-release repository convention. Reconcile the current release skill's repository derivation/readiness without generating a guessed `release.json` or stores. Keep user-facing results focused on project URLs/path and actionable pending steps.

- [ ] **4. Write failing installation tests before extending installer parameters.** Existing release tests must stay intact. Bootstrap tests use fixture aliases, not real home paths.

```powershell
Test 'bootstrap installation links one source and retains release and other skills' {
    $fixture = New-InstallationFixture
    $targets = @(
        @{agent='codex';platform='local';path=(Join-Path $fixture.home '.agents/skills/ba-bootstrap')},
        @{agent='claude';platform='local';path=(Join-Path $fixture.home '.claude/skills/ba-bootstrap')}
    )
    $first = @(Install-ReleaseSkill -Source $fixture.source -Targets $targets -SkillName 'ba-bootstrap')
    $again = @(Install-ReleaseSkill -Source $fixture.source -Targets $targets -SkillName 'ba-bootstrap')
    Assert ($first[0].status -eq 'installed' -and $again[0].status -eq 'already-linked') 'Installation is not repeatable.'
    Assert ((Get-Item -LiteralPath $targets[1].path).ResolveLinkTarget($true).FullName -eq $fixture.source) 'Wrong canonical source.'
    Assert ((Get-Content -LiteralPath $fixture.releaseSentinel) -ceq 'keep release') 'Release installation changed.'
}
```

Also test conflict in the second skill/alias before the first new link, wrong/dangling links, file-valued parents, legacy Codex conflicts under the selected skill name, check-only no mutation, `CLAUDE_CONFIG_DIR`, default release callers and existing WSL behavior. Validate the effective targets for bootstrap include both native aliases even when a CLI executable is absent; this is the requested discovery setup, not evidence that every agent auto-discovers the skill.

- [ ] **5. Implement named installation with the established junction pattern.** Replace hardcoded discovery/legacy/WSL path suffixes inside the existing installer with the validated `SkillName` parameter, retaining its ba-release default. Pass the skill name to WSL scripts as a positional value rather than interpolating user-controlled shell code. `IncludeNativeAliases` requests both local targets; bootstrap enables it, while release retains executable detection. Respect the current user's profile and explicit Claude config directory. Preserve all unrelated links/files and reject conflicting legacy copies.

```powershell
# Root installer: preflight every selected skill, then install the same target sets.
foreach ($selection in $selections) {
    Install-ReleaseSkill -Source $selection.source -Targets $selection.targets -SkillName $selection.name -CheckOnly | Out-Null
}
foreach ($selection in $selections) {
    Install-ReleaseSkill -Source $selection.source -Targets $selection.targets -SkillName $selection.name -CheckOnly:$CheckOnly
}
```

Build `$selections` from the validated root `-Skill` choice, sources under that checkout's `skills/`, and targets for each name. Bootstrap's wrapper finds the canonical BA-Skills root from its source path and dispatches to the root installer. Its runtime project helpers remain self-contained; installation may use the repo's installer. Test the wrapper using fixture home targets or check-only inspection, without replacing the user's existing links with development-worktree targets.

- [ ] **6. Run forward behavior checks and metadata validation.** Fresh evaluating agents receive the finished skill and the same raw fixture scenarios, without baseline findings, desired answers or this plan. Assert the observed repo calls/files and final reports satisfy the design. A clone-only scenario never posts a create request. Change instructions only for demonstrated failures.

```powershell
python 'C:\Users\cicel\.codex\skills\.system\skill-creator\scripts\quick_validate.py' 'skills/ba-bootstrap'
pwsh -NoProfile -File tests/bootstrap/run-tests.ps1 -Filter '*installation*'
pwsh -NoProfile -File tests/run-tests.ps1
pwsh -NoProfile -File tests/bootstrap/run-tests.ps1
```

The metadata validator is a development check, not a dependency of generated projects. If the local Python validator needs its supported dependencies, use the available runtime and report actual validation, rather than replacing it with a frontmatter string-match test. Update BA-Skills README to discover both skills, their scope and installation choices. Commit: `feat: add shared bootstrap skill and named installation`.

## Task 7: Verify the whole workflow, run the bogus-project trial and prepare review

**Files:** Create BA-Skills `tools/verify.ps1`; extend `tests/bootstrap/cli-tests.ps1` and any demonstrated missing fixtures. Update README's gate command and the skill's operations guidance only where the trial reveals a real gap. Trial receipts stay in ignored `.test-results/` and the operational journal, not in seeded project canon or a release-notes repository.

**Interfaces:** Root BA-Skills gate aggregates existing release and bootstrap suites and script syntax checks; nonzero from any stage fails. The generated project's gate remains the standalone documentation gate from Task 3. A final review records findings against the completed branch, never merges it.

- [ ] **1. Exercise supported command-line modes in subprocesses.** Pin missing-input behavior, literal special-character descriptions, read-only plan/status, partial exit codes, resume using stored inputs, and clone setup without any create calls. Use fixture executable/adapters; prove no real GitHub request occurs in the offline suites. Test a status/resume lookup with only name/owner, and a clone under a parent path with spaces. The input-only failure occurs before authentication/network calls:

```powershell
Test 'CLI reports a missing description without an interactive prompt' {
    $output = & pwsh -NoProfile -File (Join-Path $skillRoot 'scripts/bootstrap.ps1') -Mode create -Name 'Missing Description'
    Assert ($LASTEXITCODE -ne 0) 'Incomplete creation inputs succeeded.'
    Assert (($output -join "`n") -match 'description') 'The missing field was not identified.'
}
```

- [ ] **2. Add the repository's aggregate gate and verify it detects a failing stage.** Invoke each suite in a fresh PowerShell subprocess. Parse repository `.ps1`/`.psm1` files using PowerShell's parser before test execution, excluding temporary fixture output and `.git`; list file/line parse errors. Preserve a failed stage even if a later stage succeeds.

```powershell
$root = Split-Path $PSScriptRoot -Parent
$failed = $false
foreach ($suite in @('tests/run-tests.ps1', 'tests/bootstrap/run-tests.ps1')) {
    & pwsh -NoProfile -File (Join-Path $root $suite)
    if ($LASTEXITCODE -ne 0) { $failed = $true }
}
if ($failed) { exit 1 }
Write-Output 'Verification passed: BA-Skills.'
exit 0
```

Add subprocess coverage against a copied disposable gate with one deliberately failing suite and one passing suite, then both passing. Do not edit the real release tests to manufacture a failure. Run `pwsh -NoProfile -File tools/verify.ps1` and the skill metadata validator. Commit: `test: verify bootstrap commands and aggregate project gates`.

- [ ] **3. Preflight the real bogus-project trial.** Use title `BA Bootstrap Smoke Test`, description `Disposable project for verifying the BA bootstrap foundation.`, owner `Benevolent-Anarchy` and the agreed default parent. Inspect both exact remote names, the local path, authentication and the current journal first. If the name is already in unrelated use, choose and report an unused numeric suffix, rather than adopting it. Invocation of this plan's approved trial authorizes the disposable pair; no repeated creation approval is required. Do not create it until offline checks pass.

```powershell
pwsh -NoProfile -File skills/ba-bootstrap/scripts/bootstrap.ps1 -Mode plan -Name 'BA Bootstrap Smoke Test' -Description 'Disposable project for verifying the BA bootstrap foundation.'
pwsh -NoProfile -File skills/ba-bootstrap/scripts/bootstrap.ps1 -Mode create -Name 'BA Bootstrap Smoke Test' -Description 'Disposable project for verifying the BA bootstrap foundation.'
```

Run the actual skill entry point from this worktree. For authenticated browser-only public settings, load and follow the computer-use tool/skill documentation at that time; act only on the trial repository and verify its setting after saving.

- [ ] **4. Check repository content and the generated gate independently.** Observe the private repository's visibility, Issues/PR support, `main`, origin, 23 labels, exact tracked skeleton, ignored local vault and clean initial commit. Run its own `tools/verify.ps1` from a different working directory. In the disposable project only, add one valid topical note and matching index links, confirm success, deliberately change a link to the wrong file/heading, confirm failure, then restore the initial tree and confirm success. Keep those probes local and unstaged; restore only files owned by the probe after checking the resolved path is this disposable checkout.

Observe the public repository's visibility, `main`, write permission and tree containing only the agreed README; check Issues, PRs, wiki, Discussions, Projects, Actions and exposed optional contribution settings. An inaccessible browser toggle remains a named pending phase. Confirm the same-owner `-release-notes` naming/write contract matches current ba-release; do not publish a release to test it.

- [ ] **5. Check local Obsidian, repeat/resume, and a second clone.** Verify all four installed versions against their resolved latest release manifests, the human title nickname, preserved preferences and absence of workspace/scan state copied from DRRD. Where app control is available, verify plugins loaded and Diagram Popup opens an embedded Mermaid diagram full-screen with pan/zoom. If the environment cannot control the native app, record file/config evidence and ask Cicely for that concrete app check; do not invent a successful human judgement.

Reinvoke `status`/`resume` and verify no duplicate repos or reseeding. Clone only the private repository into a distinct trial path and run `local-setup`; verify the nickname, four plugins and its standalone gate without relying on the original machine's creation journal. Test mutation interruption/resume primarily in the offline fixtures; do not deliberately break ownership or delete remote trial content to simulate a failure.

Cicely tears down both trial repositories and local copies. Report their exact URLs/paths and any pending app/settings check. Do not delete them automatically.

- [ ] **6. Make the completed branch ready for a fresh session.** Re-read the approved spec against the actual implementation; resolve findings, update durable operational guidance and any affected test fixtures, then rerun the full root gate after the last change. Complete the skill behavior checks and metadata validator, inspect `git diff --check` and current status, and record exact verification evidence. The review description covers the delivered foundation, its recovery behavior, the live trial and any actual limitations; no design promises masquerade as shipped checks.

Use the final independent branch review required by the selected execution workflow. If a review fix changes files, rerun the complete gate before declaring it ready. Open the usual BA-Skills PR only after the branch can be handed to a fresh session with no planned non-review changes. Prefix its body `[Codex]`, attach the created PR to this chat, and leave merge to Cicely. Do not merge or switch other chats' worktrees.

- [ ] **7. Install permanent discovery links after integration.** Once Cicely has merged and the canonical `C:\Users\cicel\Dev\BA-Skills` checkout contains the skill, run its named installer there and read back both home junction targets. They point to `C:\Users\cicel\Dev\BA-Skills\skills\ba-bootstrap`, not the development worktree. Preserve existing release links and unrelated skills. If integration has not yet occurred, report installation as pending integration, while the worktree trial is still available; do not copy unmerged files into canonical main to manufacture completion.

```powershell
pwsh -NoProfile -File 'C:\Users\cicel\Dev\BA-Skills\install.ps1' -Skill ba-bootstrap
Get-Item -LiteralPath 'C:\Users\cicel\.agents\skills\ba-bootstrap', 'C:\Users\cicel\.claude\skills\ba-bootstrap' |
    Select-Object FullName,LinkType,Target
```

## Coverage and handoff

| Approved design area | Implementation and verification |
| --- | --- |
| Identity/defaults/name conversion | Task 1 and CLI subprocesses in Task 7 |
| Private/public pair and branch/visibility/write contract | Task 4 and observed live trial in Task 7 |
| Permanent canon, topical indexes, minimal NEXT, agent contract | Task 1 templates and Tasks 2–3 gate |
| Required gate before PR; future Godot stages | Task 3 generated wrapper, Task 7 branch gate; Godot remains the next project phase |
| All DRRD labels without its backlog | Tasks 1 and 4 snapshot/application tests |
| Latest four plugins and DRRD preference recipe | Task 5 fixtures and Task 7 app/file evidence |
| Fresh-clone local setup | Task 5 identity/preservation tests and Task 7 second clone |
| Journal, collisions, lost outcomes and retries | Task 4 failure-injection tests |
| Shared discovery, canonical installation, ba-release preservation | Task 6 installer regressions and Task 7 post-integration readback |
| Bogus project kept for Cicely's teardown | Task 7 receipt/report; no delete operation |

The work is one cohesive bootstrap workflow: the independently tested documentation gate is a required generated asset, and repository/plugin/install stages share its identity and progress contract. There is no separate engine plan in version one. A later Godot plan adds the selectable default starter and engine stages to the existing project gate.

Recommended execution: native implementation in this chat, with the small isolated skill behavior checks and a fresh final branch review. The modules depend closely on shared identity/journal/result shapes; one implementer can keep those consistent without paying for a new context at every task. Subagent-driven execution remains available if Cicely prefers separate implementers and reviewers for each task.

## Sources for implementation details

- Local DRRD source: `C:\Users\cicel\Dev\De-Recta-Rerum-Dispositione\AGENTS.md`, `documentation/_project-meta/DECISIONS.md`, `documentation/_project-meta/JUDGEMENTS.md`, `test/support/record_check.gd`, its unit tests/fixtures, `tools/verify.ps1`, and selected `.obsidian` files. These are development inputs, not installed runtime dependencies.
- [GitHub repository name limits](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-new-repository): ASCII repository characters and maximum 100 characters, applied to both derived names in Task 1.
- [GitHub repository API](https://docs.github.com/en/rest/repos/repos), [contents API](https://docs.github.com/en/rest/repos/contents), [branch API](https://docs.github.com/en/rest/branches/branches), and [Actions permissions](https://docs.github.com/en/rest/actions/permissions): verify supported requests and effective fields when implementing Task 4.
- [GitHub disabling pull requests](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/disabling-pull-requests): browser setting/readback when no supported API exposes it.
- [CommonMark 0.31.2](https://spec.commonmark.org/0.31.2/) and [GitHub section links](https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax#section-links): parser and Markdown-anchor behavior in Tasks 2–3; Obsidian wikilinks retain the exact heading convention from the spec.
- [Official Obsidian plugin registry](https://github.com/obsidianmd/obsidian-releases/blob/master/community-plugins.json), [plugin releases](https://docs.obsidian.md/Plugins/Releasing/Submit%20your%20plugin), and [Obsidian CLI](https://obsidian.md/help/cli): latest-release assets and app verification in Task 5.
- [skill-creator](C:/Users/cicel/.codex/skills/.system/skill-creator/SKILL.md), [writing-skills](C:/Users/cicel/.codex/plugins/cache/claude-plugins-official/superpowers/6.4.1/skills/writing-skills/SKILL.md), and [writing-plans](C:/Users/cicel/.codex/plugins/cache/claude-plugins-official/superpowers/6.4.1/skills/writing-plans/SKILL.md): authoring/behavior checks and this plan's review handoff.

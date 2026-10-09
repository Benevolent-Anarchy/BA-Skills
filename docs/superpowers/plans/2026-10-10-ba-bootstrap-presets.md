# Godot and Tauri Bootstrap Presets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `ba-bootstrap` with runnable Godot and latest-stable Tauri starters, accurate Git ignores, complete project gates and reproducible interrupted-creation recovery.

**Architecture:** Layer engine preparation onto the existing shared foundation and repository-pair workflow. Prepare and verify source in an owned staging directory, retain a byte-exact snapshot and dependency locks, then create the repository pair from that snapshot. Generated projects carry their own verification scripts; they never import an installed BA skill.

**Tech Stack:** PowerShell 7.2+, Git, authenticated GitHub CLI, Godot 4.7/GDScript/GUT 9.7.1 for the initial Godot recipe, latest stable desktop Tauri, vanilla TypeScript, Vite, npm, Rust/MSVC and WebView2 on Windows.

**Spec:** [Approved design](../specs/2026-10-09-ba-bootstrap-presets-design.md).

**Status:** Plan for Cicely's review; product implementation has not started. Preserve Cicely's earlier choice of native execution: implement in this session, then request a fresh whole-branch review. This document supplies the concrete implementation and validation sequence; it does not report those checks as already completed.

## Global Constraints

- “Offer `godot`, `tauri` and `foundation`, with Godot selected by default for a new creation.”
- “For Godot, offer a renderer choice: Compatibility by default, with Forward Plus and Mobile available.”
- “For Tauri, use desktop Tauri latest, plain TypeScript, Vite and npm.” Latest means stable at new-creation resolution, including a new major, with prereleases excluded and no silent older-major fallback.
- “Every project ignores `dist/`”; use the unanchored directory rule to cover root and nested exports.
- “The initial tested recipe targets Godot 4.7, with the locally available 4.7.2 engine and GUT 9.7.1 as the validation baseline.” Do not accept an untested Godot/GUT pairing merely because a newer version exists.
- “Commit `package-lock.json` and `Cargo.lock`.” Retain resolved versions and prepared bytes on retry; existing projects do not automatically upgrade.
- “Keep `plan` and `status` free of persistent project, journal and dependency-installation writes.” Plan may inspect metadata, but must not execute a generator or install dependencies.
- “Run the selected preset's complete native gate in staging” before the first repository POST. Verify the actual checkout separately before reporting completion.
- “Existing version-one journals remain foundation invocations, never implicit Godot projects.” Preserve incompatible unfinished legacy journals with a matching-version recovery instruction.
- “Existing-clone `local-setup` continues to configure local Obsidian tooling; it does not convert engines or rewrite tracked project files.”
- “The bootstrap does not silently replace a global SDK, toolchain or its default selection.” Report prerequisites before either repository creation. Installer/toolchain changes require a concrete authorized setup step; they are not part of normal bootstrap execution.
- Preserve project-name case and whitespace-to-hyphen repository naming, `main`, default owner `Benevolent-Anarchy`, optional `cicely-f`, default parent `C:\Users\cicel\Dev`, private project/public release-notes pair and no public local checkout.
- Preserve the agent-neutral canon/Issues/PR process, session-ready PR rule, four curated Obsidian plugins, standing target-vault authorization and immediate foreground-control cleanup.
- Work in `C:\Users\cicel\.codex\worktrees\ba-bootstrap\BA-Skills`, branch `codex/ba-bootstrap-presets`; permanent aliases continue targeting canonical main. Do not alter another conversation's checkout or remove ignored v1 receipts.
- No automatic engine conversion, Godot C#, additional frontends, release/store configuration, signing or installer publication in this change.

## Review Focus

These conditions need explicit tests in their owning tasks, beyond nominal starter creation:

1. Binary icons, asset bytes and Git line-ending filters must survive snapshot replay and exact-root-commit recovery unchanged (Tasks 1, 3 and 7).
2. Omitted versus explicitly conflicting options on resume must preserve recorded choices; a v1 journal must never acquire the new Godot default (Tasks 2, 3 and 7).
3. A newly published stable Tauri major, a prerelease or metadata transport failure must not produce a silent downgrade or change a resumed creation (Tasks 4 and 6).
4. An upstream generator changing its layout or writing extra files must fail preparation before repository POSTs when BA integration cannot validate it (Tasks 6 and 7).
5. Paths containing spaces, custom global Git excludes, incomplete reports and native commands that return zero despite failure must not conceal failed checks or drop required source (Tasks 1, 5, 6 and 8).

## File Structure and Interfaces

Paths below are relative to this worktree. Keep existing module boundaries and test harness; do not restructure unrelated release tooling.

| File | Responsibility |
| --- | --- |
| `skills/ba-bootstrap/scripts/Project.psm1` | Existing identity/static foundation rendering; add byte-safe manifest writing without changing naming rules. |
| `skills/ba-bootstrap/scripts/Presets.psm1` (new) | Pure preset/options/name resolution, canonical recipe identity and prerequisite inspection. |
| `skills/ba-bootstrap/scripts/Dependencies.psm1` (new) | Upstream stable-release metadata selection and artifact acquisition/integrity receipts. |
| `skills/ba-bootstrap/scripts/Preparation.psm1` (new) | Owned staging, preparation checkpoints, frozen tracked-source snapshots and replay validation. |
| `skills/ba-bootstrap/scripts/GodotPreset.psm1` (new) | Godot rendering, compatible GUT acquisition and source preparation. |
| `skills/ba-bootstrap/scripts/TauriPreset.psm1` (new) | Pinned official generator execution, BA overlay, dependency locks and selected-release validation. |
| `skills/ba-bootstrap/scripts/State.psm1` | v1 reader compatibility plus v2 creation state; keep the existing Obsidian journal contract. |
| `skills/ba-bootstrap/scripts/Bootstrap.psm1` | Existing repository ceremony plus preparation/checkout-verification phases and exact byte manifest use. |
| `skills/ba-bootstrap/scripts/bootstrap.ps1` | Preset collection, explicit-option tracking, stored-choice resume and JSON reporting. |
| `skills/ba-bootstrap/assets/project/tools/Verification.psm1` (new) | Project-owned gate configuration/stage validation and process results. |
| `skills/ba-bootstrap/assets/project/tools/verify.ps1` | Single project gate: documentation plus the selected preset's required stages. |
| `skills/ba-bootstrap/assets/project/tools/verify.json.template` (new) | Explicit foundation preset initially; engine preparation replaces it with the chosen configuration. |
| `skills/ba-bootstrap/assets/project/.gitattributes` (new), `.gitignore` | Shared LF policy and ignores, including `dist/`. |
| `skills/ba-bootstrap/assets/presets/godot/` (new) | Godot source templates, ignore fragment and project-owned engine verification helpers. |
| `skills/ba-bootstrap/assets/presets/tauri/` (new) | BA frontend overlay, ignore additions and project-owned Tauri verification helper; no fixed Tauri backend stub. |
| `tests/bootstrap/*-tests.ps1` | Existing offline harness; add separate preset, preparation, dependency and engine gate suites. |
| `tests/bootstrap/PresetFixture.ps1` (new) | Deterministic metadata/download/process/preparation boundaries shared by offline tests. |
| `tests/bootstrap/fixtures/legacy-foundation-journal.json` (new) | Literal v1 journal fixture; not generated by the new constructor. |
| `tools/test-bootstrap-presets-native.ps1` (new) | Opt-in local native trials, fresh clones and failure probes; no real GitHub creation. |
| `skills/ba-bootstrap/SKILL.md`, `references/operations.md`, `references/presets.md` (new) | Agent-facing preset selection, gate/setup commands, frozen-state recovery and truthful outcome reporting. |

Public module contracts used by later tasks:

```powershell
# Presets.psm1: returns a normalized hashtable; non-applicable fields are null.
Resolve-BootstrapPreset -Identity $Identity -Preset godot -Renderer compatibility
# {name; recipeVersion; renderer; appIdentifier; packageName; crateName}
Assert-BootstrapPresetOverride -Stored $Selection -BoundParameters $ExplicitOptions
Get-BootstrapPrerequisites -Selection $Selection -Probe $Probe
# {passed; checks=@(@{name; passed; version; executable; message})}

# Dependencies.psm1: scriptblocks are test seams, not alternate user workflows.
Get-BootstrapDependencyResolution -Selection $Selection -Request $MetadataRequest
# {schemaVersion=1; preset; selections; artifacts; resolvedAt}
Receive-BootstrapArtifact -Artifact $Artifact -Destination $Path -Download $Download
# {path; sha256; publishedIntegrity; integrityStatus}

# Project.psm1: foundation remains available to v1 consumers and Obsidian.
Write-BootstrapManifest -Repository $Root -Manifest $Entries
# Each new entry: {path; bytes=[byte[]]; sha256}; static entries may retain text.
# Validate every destination/conflict before writing any missing file.

# Preparation.psm1: all paths derived under StateRoot from invocationId.
Get-BootstrapPreparedManifest -Repository $Root -Paths $TrackedPaths
# Sorted byte entries; reject duplicate/case-colliding/non-contained/linked paths.
Save-BootstrapPreparedProject -Journal $Journal -JournalPath $Path -Lock $Lock -Source $Root -Manifest $Entries
Read-BootstrapPreparedProject -Journal $Journal -StateRoot $StateRoot
# {sourcePath; manifest; selection; resolution}; verify stored bytes and hashes.
Initialize-BootstrapPreparation -Identity $Identity -Selection $Selection -Journal $Journal -StateRoot $StateRoot -MetadataRequest $MetadataRequest -Download $Download -Process $Process -Checkpoint $Checkpoint
# {sourcePath; trackedPaths; resolution}; persist each durable preparation phase.

# Engine modules use the same preparation inputs and return declared source paths.
Initialize-GodotPreset -Identity $Identity -Selection $Selection -Resolution $Resolution -Repository $Root -Download $Download -Process $Process
Initialize-TauriPreset -Identity $Identity -Selection $Selection -Resolution $Resolution -Repository $Root -Process $Process
# {trackedPaths; receipts}; includes source metadata but excludes generated output.
Assert-TauriSelectedRelease -Resolution $Resolution -CargoMetadata $CargoMetadata
# Requires the application's resolved direct Tauri dependency to match selection.

# Generated tools: always local to the generated project.
Read-ProjectVerificationConfig -Repository $Root
Invoke-ProjectVerification -Repository $Root -Process $Process
# {Passed; Stages=@(@{Name; Passed; ExitCode; Diagnostics}); Diagnostics}
Invoke-GodotVerification -Repository $Root -Config $Config -Process $Process
Invoke-TauriVerification -Repository $Root -Config $Config -Process $Process

# Common process seam: (executable, argument array, cwd, environment hashtable).
# Return {ExitCode; Output; Executable}; use argument arrays, never evaluated text.
```

`$MetadataRequest` takes `(uri)` and returns parsed metadata; `$Download` takes `(uri, destination)` and writes the acquired bytes; `$Process` takes `(executable, arguments, cwd, environment)` and returns the result above. `$Probe` takes `(prerequisiteName)` and returns `{passed; version; executable; message}`. Default production adapters live with their owning modules. `$Checkpoint` takes `(phase, values)` and atomically updates the creation journal under its existing lock. Do not serialize scriptblocks or process handles into state.

Keep this a single implementation plan: both presets share byte manifests, state and gate contracts. Shipping either through a separate creation workflow would duplicate the most sensitive recovery logic.

## Task 1: Byte-safe source manifests and the shared gate contract

**Files:** Modify `scripts/Project.psm1`, `assets/project/.gitignore`, `assets/project/tools/verify.ps1`; create `assets/project/.gitattributes`, `assets/project/tools/Verification.psm1`, `assets/project/tools/verify.json.template`; extend `tests/bootstrap/project-tests.ps1`; create `tests/bootstrap/gate-tests.ps1` (all skill paths under `skills/ba-bootstrap/`).

**Interfaces:** Retain `Get-ProjectManifest` and `Write-ProjectFoundation`. Produce `Write-BootstrapManifest`, `Read-ProjectVerificationConfig` and `Invoke-ProjectVerification`. Initially only foundation checks are runnable; engine configurations require helpers/stages instead of falling back.

- [x] **Write behavior tests for source bytes, ignore rules and gate corruption.** Add the binary roundtrip test below. Add subcases for a junction parent, path traversal, duplicate paths differing only in case, and a late conflict which must prevent earlier writes.

```powershell
Test 'manifest preserves binary files and preflights all conflicts' {
    $root = New-BootstrapFixture 'binary project with spaces'
    [byte[]]$bytes = @(0, 255, 128, 10, 13, 0)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    $entries = @(@{path='src-tauri/icons/icon.ico'; bytes=$bytes; sha256=$hash})
    Write-BootstrapManifest -Repository $root -Manifest $entries | Out-Null
    Assert ((Get-FileHash -LiteralPath "$root/src-tauri/icons/icon.ico").Hash.ToLowerInvariant() -ceq $hash) 'Binary bytes changed.'
    Write-FixtureText "$root/late.txt" 'existing work'
    $entries += @{path='first-new.txt'; bytes=[Text.Encoding]::UTF8.GetBytes('new'); sha256=(Get-BootstrapContentHash 'new')}
    $entries += @{path='late.txt'; bytes=[Text.Encoding]::UTF8.GetBytes('replacement'); sha256=(Get-BootstrapContentHash 'replacement')}
    Expect-Error {Write-BootstrapManifest -Repository $root -Manifest $entries} 'conflict'
    Assert (-not (Test-Path -LiteralPath "$root/first-new.txt")) 'Earlier file written before late conflict.'
    Assert ([IO.File]::ReadAllText("$root/late.txt") -ceq 'existing work') 'Existing work replaced.'
}
```

- [x] **Establish the red result.** Run `pwsh -NoProfile -File tests/bootstrap/run-tests.ps1 -Filter 'manifest*'`; expect missing byte writer. Run new `gate*` cases separately; missing/invalid config and declared-engine-with-missing-helper must currently fail their assertions.
- [x] **Implement the byte writer and explicit gate schema.** Compute binary hashes from actual bytes, normalize only text templates to LF, and write with `WriteAllBytes`. Do not decode icons, archives or assets as UTF-8. Keep static `.text` for old fixture compatibility, but choose `.bytes` when present. Enforce configuration shape and required stage sets; configuration cannot omit a required stage for its declared preset.

```json
{"schemaVersion":1,"preset":"foundation","requiredChecks":["documentation"]}
```

```gitattributes
* text=auto eol=lf
*.png binary
*.ico binary
*.icns binary
*.jpg binary
*.jpeg binary
*.webp binary
*.woff binary
*.woff2 binary
```

The common ignore adds literal `dist/` and `.test-results/` alongside existing local-tooling rules. Gate failures remain nonzero; report each executed/blocked stage and its diagnostic. Preserve `Test-ProjectDocumentation` and its full index/heading checks.
- [x] **Verify effective Git behavior and text filters.** In isolated fixture Git with system/global configuration and `core.excludesFile` disabled, assert `dist/export.exe` and `nested/dist/export.zip` are ignored while `assets/source.png` and `tools/helper.exe` are addable. Initialize Git, add/commit the binary fixture and LF templates, then compare `git hash-object --no-filters` with committed blobs. Configure `core.autocrlf=true` in a second case to prove the generated attributes preserve intended initial bytes.
- [x] **Run all existing documentation/project tests and the new gate cases**, then commit these cohesive shared changes: `feat: add byte-safe bootstrap manifests and explicit verification configuration`.

## Task 2: Pure preset selection and deterministic tool names

**Files:** Create `scripts/Presets.psm1`, `tests/bootstrap/preset-tests.ps1` and `tests/bootstrap/PresetFixture.ps1`.

**Interfaces:** Produce `Resolve-BootstrapPreset`, `Assert-BootstrapPresetOverride` and `Get-BootstrapPrerequisites`. Do not switch the public CLI default until both engines and state recovery are integrated in Task 7.

- [x] **Add failing selection tests**, including this default/override behavior and renderer/identifier validation.

```powershell
Test 'preset defaults to Godot and restores explicit choices' {
    $id = New-BootstrapIdentity -Name 'Foo Bar Baz' -Description 'Purpose' -Parent $sandbox
    $godot = Resolve-BootstrapPreset -Identity $id
    Assert ($godot.name -ceq 'godot' -and $godot.renderer -ceq 'compatibility') 'Wrong defaults.'
    $tauri = Resolve-BootstrapPreset -Identity $id -Preset tauri -AppIdentifier 'org.benevolent-anarchy.foo-bar-baz'
    Assert ($tauri.name -ceq 'tauri' -and $tauri.appIdentifier -ceq 'org.benevolent-anarchy.foo-bar-baz') 'Identifier changed.'
    Assert-BootstrapPresetOverride -Stored $tauri -BoundParameters @{}
    Expect-Error {Assert-BootstrapPresetOverride -Stored $tauri -BoundParameters @{Preset='godot'}} 'conflict|stored'
    Expect-Error {Resolve-BootstrapPreset -Identity $id -Preset tauri -Renderer mobile} 'renderer|Godot'
}
```

- [x] **Run `preset*` cases and confirm they fail** because the resolver does not exist.
- [x] **Implement canonical selection.** Godot renderer values are `compatibility`, `forward-plus`, `mobile`; foundation/Tauri reject explicitly supplied Godot-only options. Suggest Tauri identifiers as `org.benevolent-anarchy.<package>` or `com.cicely-f.<package>` for the two known owners, with `com.<normalized-owner>.<package>` for another valid owner. Validate at least two nonempty dot-separated segments, each using ASCII letters/digits/hyphens and starting with a letter. Show the suggestion and allow an override. Independently derive lowercase npm package and Rust crate names, handling leading digits and reserved words; use a `project-` prefix for illegal/reserved bases, replace unsupported characters with hyphens and retain human title/repository case unchanged. Validate the resulting names against tool rules instead of assuming the GitHub slug is legal everywhere.

```powershell
$selection = [ordered]@{
    name = $Preset
    recipeVersion = 1
    renderer = $null
    appIdentifier = $null
    packageName = $null
    crateName = $null
}
# Populate only fields belonging to the selected engine; serialize in this order.
```

- [x] **Add boundary cases and prerequisite inspection.** Exercise `1 Project`, `Foo_Bar`, `Foo.Bar`, `fn`, invalid identifiers, explicit non-applicable options, blank values, and personal owner suggestions. A read-only probe checks resolved executable/version and required components without installing anything. Godot supports the recipe's 4.7 family; Tauri reports Node/npm, Rust/cargo, rustfmt/clippy, MSVC and WebView2 separately. A missing executable is a diagnostic, not permission to invoke an installer.
- [x] **Run selection/prerequisite tests**, including a probe that throws if called as a mutation, then commit: `feat: resolve bootstrap presets and inspect native prerequisites`.

## Task 3: Versioned state and frozen prepared-source replay

**Files:** Modify `scripts/State.psm1`; create `scripts/Preparation.psm1`, `tests/bootstrap/preparation-tests.ps1`, `tests/bootstrap/fixtures/legacy-foundation-journal.json`; extend `tests/bootstrap/state-tests.ps1`.

**Interfaces:** `New-BootstrapJournal` and `Get-BootstrapInputHash` gain optional `-PresetSelection`. With it, create schema v2; without it, retain schema v1 for existing Obsidian callers and compatibility fixtures. Produce `Get-BootstrapPreparedManifest`, `Save-BootstrapPreparedProject` and `Read-BootstrapPreparedProject`. Preparation orchestration is added in Task 7.

- [ ] **Add failing frozen-byte/state cases.** Use a literal v1 fixture captured from the old constructor, not the new renderer. Test completed v1 reporting and preserved unfinished v1 recovery, omitted versus conflicting options, corrupted snapshot bytes and a missing snapshot.

```powershell
Test 'preparation replays frozen bytes after upstream and skill changes' {
    $id = New-BootstrapIdentity -Name 'Frozen Project' -Description 'Purpose' -Parent $sandbox
    $selection = Resolve-BootstrapPreset -Identity $id -Preset tauri
    $state = New-BootstrapFixture 'prepared state'
    $source = New-BootstrapFixture 'prepared source'
    Write-FixtureText "$source/package-lock.json" '{"lockfileVersion":3,"packages":{}}'
    $manifest = @(Get-BootstrapPreparedManifest -Repository $source -Paths @('package-lock.json'))
    $journal = New-BootstrapJournal -Identity $id -Manifest @() -PresetSelection $selection
    $path = Get-BootstrapJournalPath -Identity $id -StateRoot $state
    $lock = Enter-BootstrapLock -Path $path
    try {Save-BootstrapPreparedProject -Journal $journal -JournalPath $path -Lock $lock -Source $source -Manifest $manifest}
    finally {$lock.Dispose()}
    Write-FixtureText "$source/package-lock.json" 'upstream changed'
    $read = Read-BootstrapPreparedProject -Journal (Read-BootstrapJournal $path) -StateRoot $state
    Assert ($read.manifest[0].sha256 -ceq $manifest[0].sha256) 'Frozen source was re-resolved.'
}
```

- [ ] **Run `preparation*` and new `state*` cases to establish failure.** Existing v1 atomic-write and exclusive-lock tests must keep passing.
- [ ] **Implement v2 validation and durable checkpoints.** Keep the existing journal key based on owner/repository; hash normalized identity plus canonical selection for v2. Record `presetSelection`, `recipeVersion`, `resolution`, `preparation` and `verification` in addition to existing identity/repository/ref/phases fields. Validate types, required keys and contained relative paths on read; unknown schemas remain preserved/blocked.

```powershell
$journal.schemaVersion = 2
$journal.presetSelection = $Selection
$journal.preparation = @{
    phase = 'frozen'
    snapshot = 'prepared/' + $journal.invocationId + '/source'
    manifestHash = Get-BootstrapTemplateVersion -Manifest $Manifest
    resolvedAt = $journal.resolution.resolvedAt
}
$journal.verification = @{staging=$null;checkout=$null}
```

This records added fields alongside the existing identity/ref data. Store prepared source under the journal's state root; validate every ancestor against reparse points and traversal. Promote snapshots atomically, then record the receipt atomically under the existing invocation lock. A crash after snapshot promotion but before journal publication requires verifying/adopting that invocation-owned snapshot by its identity and hashes, not running the generator again. Never overwrite a differing snapshot.
- [ ] **Verify interruption boundaries.** Interrupt after selection recording, generator output retention, lockfile retention, snapshot promotion and receipt publication. Resume reuses retained output/locks; no moving resolver or generator runs after its phase is durably complete. If an interrupted dependency step has no valid lock/receipt, preserve it and report the exact unresolved preparation rather than substituting a newer set. Completed creation reports must not revalidate the original files against later project work. Incomplete v1 whose original manifest no longer matches gives the matching-skill-version instruction before mutations; local Obsidian v1 journals still work.
- [ ] **Run state, preparation and Obsidian suites**, then commit: `feat: freeze preset preparation and preserve legacy bootstrap state`.

## Task 4: Upstream dependency resolution and artifact integrity

**Files:** Create `scripts/Dependencies.psm1`, `tests/bootstrap/dependency-tests.ps1`; extend `PresetFixture.ps1`.

**Interfaces:** Produce `Get-BootstrapDependencyResolution` and `Receive-BootstrapArtifact`. Selection is pure metadata inspection; acquisition writes only an explicit owned destination. No GitHub repository mutation or global SDK installation.

- [ ] **Add failing stable-selection cases.** Fixture metadata resembles npm's package record and crates.io's versions response. Use versions from two stable majors plus a newer prerelease/yanked release. Exercise this Tauri-major test, transport errors, inconsistent metadata and published integrity mismatch.

```powershell
Test 'dependency resolution selects a new stable Tauri major without a ceiling' {
    $id = New-BootstrapIdentity -Name 'Future Tauri' -Description 'Purpose' -Parent $sandbox
    $selection = Resolve-BootstrapPreset -Identity $id -Preset tauri
    $request = {
        param($uri)
        if ($uri -eq 'https://crates.io/api/v1/crates/tauri') {
            return @{versions=@(@{num='3.0.0';yanked=$false},@{num='3.1.0-beta.1';yanked=$false},@{num='2.99.0';yanked=$false})}
        }
        if ($uri -eq 'https://registry.npmjs.org/create-tauri-app') {
            return @{'dist-tags'=@{latest='4.0.0'};versions=@{'4.0.0'=@{version='4.0.0';dist=@{tarball='https://registry.npmjs.org/create-tauri-app/-/create-tauri-app-4.0.0.tgz';integrity=('sha512-'+[Convert]::ToBase64String([byte[]]::new(64)))}}}}
        }
        throw "Unexpected metadata URI: $uri"
    }
    $result = Get-BootstrapDependencyResolution -Selection $selection -Request $request
    Assert ($result.selections.tauri -ceq '3.0.0') 'Stable major rejected or prerelease selected.'
    Assert ($result.selections.generator -ceq '4.0.0') 'Generator version assumed equal to Tauri.'
}
```

- [ ] **Run `dependency*` cases and establish the missing-resolver failure.** The simulated versions test policy; it is not evidence that Tauri v3 compiles.
- [ ] **Implement resolution/acquisition adapters.** Read stable Tauri crate releases from crates.io metadata, excluding yanked/prerelease versions and comparing SemVer numerically. Resolve a stable official `create-tauri-app` npm release independently, retain its exact version/tarball/SRI metadata and record it before execution. Check that the generated/locked project actually resolves the selected Tauri crate. Do not assume CLI/API/generator versions have identical numbers; upstream compatibility and native build decide compatibility. A transport error is a failure, not a reason to try an older major.

```powershell
$resolution = @{
    schemaVersion = 1
    preset = $Selection.name
    selections = @{}
    artifacts = @()
    resolvedAt = [DateTime]::UtcNow.ToString('o')
}
```

For Godot, the recipe selects released GUT 9.7.1 and checks Godot 4.7 compatibility. Acquire its upstream source archive, preserve licences and retain archive SHA-256 plus any published digest/immutable commit evidence. Validate archive extraction paths and links before extraction; no archive entry may escape staging. Published integrity mismatch fails before inclusion. Missing published proof is reported as such; a locally computed hash proves repeatability, not upstream authorship. npm's normal SRI verification remains enabled for generator/dependencies.
- [ ] **Test retained evidence and retry identity.** Record an acquired artifact, change fixture metadata/bytes, then replay using the recorded resolution and enforce its digest. Test nested archive paths, traversal, symbolic links, missing licence/plugin files and metadata HTTP failure. Never treat the Godot-compatible pin as the Obsidian plugin policy; their release-selection logic remains separate.
- [ ] **Run dependency/preparation suites**, then commit: `feat: resolve stable engine dependencies with retained integrity receipts`.

## Task 5: Godot source and complete GUT gate

**Files:** Create `scripts/GodotPreset.psm1`; create `assets/presets/godot/project.godot.template`, `app/main.tscn.template`, `test/test_main.gd`, `assets/.gitkeep`, `docs/.gdignore`, `gitignore.fragment`, `tools/GodotVerification.psm1`, `tools/check_scripts.gd`, `tools/verify_pre_run.gd`, `tools/verify_post_run.gd`, `tools/verify_selftest.ps1` and focused `tools/verify_probes/` fixtures; create `tests/bootstrap/godot-tests.ps1`.

**Interfaces:** Produce `Initialize-GodotPreset` and project-owned `Invoke-GodotVerification`; consume selection/resolution/artifact acquisition/byte writer. Adapt DRRD's proven verifier without its content, project paths or unconditional rendered-suite requirement.

- [ ] **Add failing starter and gate tests.** Check viewport/version/renderer/title, GUT licence/source, `docs/.gdignore` and source UIDs. Stub native process results to test missing executable, unsupported version, invalid import sidecar, failed compilation, failed GUT, missing XML/totals, zero tests, hook errors and leaked nodes. A configured rendered suite must invoke a real renderer and fail when unavailable; the initial headless-only starter must not require an empty rendered suite.

```powershell
Test 'Godot gate rejects zero tests even when the engine exits zero' {
    $root = New-BootstrapFixture 'zero tests project'
    Write-FixtureText "$root/project.godot" "config_version=5`n"
    Write-FixtureText "$root/addons/gut/gut_cmdln.gd" 'extends SceneTree'
    Write-FixtureText "$root/addons/gut/plugin.cfg" "[plugin]`nversion=`"9.7.1`"`n"
    Write-FixtureText "$root/tools/check_scripts.gd" 'extends SceneTree'
    Write-FixtureText "$root/tools/verify_pre_run.gd" 'extends GutHookScript'
    Write-FixtureText "$root/tools/verify_post_run.gd" 'extends GutHookScript'
    Write-FixtureText "$root/test/test_main.gd" "extends GutTest`nfunc test_main():`n    assert_true(true)`n"
    $config = @{preset='godot';godot=@{versionFamily='4.7';renderedTests=$false}}
    $process = {
        param($exe,$arguments,$cwd,$environment)
        if ($arguments -contains '--version') {return @{ExitCode=0;Output='4.7.2.stable.official';Executable=$exe}}
        if ($environment.ContainsKey('BA_VERIFY_RESULTS')) {
            Write-FixtureText $environment.BA_VERIFY_RESULTS '<testsuites tests="0" failures="0" errors="0" />'
            Write-FixtureText $environment.BA_VERIFY_TOTALS '{"scripts":0,"tests":0,"asserts":0,"seconds":0}'
        }
        return @{ExitCode=0;Output='';Executable=$exe}
    }
    $result = Invoke-GodotVerification -Repository $root -Config $config -Process $process
    Assert (-not $result.Passed) 'Zero-test suite passed.'
    Assert (($result.Diagnostics -join ' ') -match 'no tests|zero tests') 'Missing concrete diagnostic.'
}
```

- [ ] **Run `Godot*` cases to confirm the missing-helper failure.** Keep engine-process seams shared with generated verification, rather than testing a second copy of the gate.
- [ ] **Render a minimal real project and vendor GUT.** Start a full-rect `Control` with a centered child `Label` named `Title`. Use the selected renderer and engine feature tag, viewport 1280×800 and application version `0.0.1`. Encode string values with their Godot file-format escaping; serialize GDScript/config values separately from Markdown. Enable GUT's editor plugin. Import in staging to generate required `.gd.uid`/source import sidecars; declare them as tracked source and exclude `.godot/`. Preserve all upstream GUT files needed by the runner and their licence.

```gdscript
extends GutTest

func test_main_scene_loads_and_shows_the_project_title() -> void:
    var packed := load("res://app/main.tscn") as PackedScene
    assert_not_null(packed)
    if packed == null:
        return
    var main := packed.instantiate()
    add_child_autofree(main)
    var title := main.get_node("Title") as Label
    assert_not_null(title)
    if title != null:
        assert_eq(title.text, ProjectSettings.get_setting("application/config/name"))
```

- [ ] **Implement the complete gate and its real failure probes.** Resolve `GODOT` first, otherwise the available executable; check the supported family. Import headlessly, check invalid import sidecars, compile every project script outside addons/ignored/nested-project directories, then run GUT with owned config/report paths. Discover tests under `test/rendered/` and require a real-renderer stage when such tests exist, even if the original starter's `renderedTests` setting was false. Explicitly configured rendered verification with no tests fails; an unconfigured empty/absent rendered directory creates no requirement. Adapt DRRD's pre/post hooks so unhandled errors in test hooks and orphan nodes fail, preserving legitimately asserted errors. Preserve/restore any pre-existing environment values. Unique ignored report paths prevent stale-result success. Validate result counts and missing/malformed reports; process zero alone never suffices. The closing result lists documentation and each engine stage.

The preset ignore fragment includes `.godot/`, `*.translation`, `export_credentials.cfg`, applicable Android/Mono/editor caches and its verification outputs. Retain `.gd.uid`, source import sidecars and normal `export_presets.cfg`. Do not ignore an entire source directory because DRRD happened not to use it.
- [ ] **Run native Godot probes on local 4.7.2.** Prepare Compatibility, Forward Plus and Mobile configurations; run the common headless starter gate for each. Real probes cover broken script, invalid import, GUT assertion failure, errors in hooks, orphans, no tests, and positive asserted-error/clean-node cases. Test rendered-suite discovery with a real small window only for the configured probe, without taking desktop control for unrelated work. Run fixture checks for effective ignore behavior, UID persistence and title escaping.
- [ ] **Run the focused suite and verifier self-tests**, then commit: `feat: prepare Godot starters with a complete GUT verification gate`.

## Task 6: Current official Tauri starter, locks and native gate

**Files:** Create `scripts/TauriPreset.psm1`; create `assets/presets/tauri/src/main.ts.template`, `src/main.test.ts`, `src/styles.css`, `gitignore.fragment`, `tools/TauriVerification.psm1`; create `tests/bootstrap/tauri-tests.ps1`; extend `PresetFixture.ps1`.

**Interfaces:** Produce `Initialize-TauriPreset`, `Assert-TauriSelectedRelease` and project-owned `Invoke-TauriVerification`; consume recorded selections, owned staging and the common process/gate contracts. Backend configuration, icons and Rust source originate from the recorded official generator, not a BA v2 stub.

- [ ] **Add failing generator/preparation tests.** The process fixture writes representative official starter files, including binary icons, and logs invocation arguments. Test exact generator version, vanilla TypeScript/npm choice, names/identifier, actual locked Tauri release, changed generator layout, ignore merging, source exclusions, and missing/failed package installation or lockfile generation.

```powershell
Test 'Tauri selected-release check rejects the application using an older major' {
    $resolution = @{selections=@{tauri='3.0.0';generator='4.0.0'};artifacts=@()}
    $appId = 'path+file:///fixture/src-tauri#latest-desktop@0.0.1'
    $tauriId = 'registry+https://github.com/rust-lang/crates.io-index#tauri@2.99.0'
    $metadata = @{
        packages = @(@{id=$appId;name='latest-desktop';version='0.0.1'},@{id=$tauriId;name='tauri';version='2.99.0'})
        resolve = @{root=$appId;nodes=@(@{id=$appId;deps=@(@{name='tauri';pkg=$tauriId})})}
    }
    Expect-Error {Assert-TauriSelectedRelease -Resolution $resolution -CargoMetadata $metadata} 'selected|release|major'
}
```

- [ ] **Run `Tauri*` cases to confirm missing-helper failure.** In the generator fixture define all expected layout files for success tests; missing-layout tests deliberately remove one. Never let an unknown fixture request contact the real network.
- [ ] **Execute the recorded upstream generator once and apply the BA overlay.** The initial supported command shape is below, with flags checked against that recorded generator's help; adapt concrete flag/layout changes only after inspection. The version argument comes from state, never a literal `latest` on retry.

```powershell
$arguments = @('exec','--yes',"--package=create-tauri-app@$($Resolution.selections.generator)",'--',
    'create-tauri-app','.', '--template','vanilla-ts','--manager','npm',
    '--identifier',$Selection.appIdentifier,'--yes')
# When the recorded generator supports this option, select its advertised major.
$arguments += @('--tauri-version', ($Resolution.selections.tauri -split '\.')[0])
# Invoke with an argument array in the owned staging working directory.
```

Keep generator acquisition integrity enabled and capture its exact version/digest/output before subsequent steps. Validate that required frontend/backend/permission/icon files exist and that the generator's declared Tauri family matches the recorded stable selection; a generator that cannot provide that family blocks preparation. Preserve upstream format/schema and required Rust features; apply explicit BA title, app version, legal package/crate names, npm scripts, fixed dev port, watch exclusions and root `dist/` integration. Remove upstream demo logos/open-link actions when no longer needed, retaining licence obligations and required app icons. Do not claim support for a changed future schema without the native gate passing.

Use a minimal `h1` created through DOM APIs with the human project title assigned through `textContent`, with JSON-escaped title data supplied to the template. Test the actual entry point under Vitest/jsdom rather than inventing a feature for tests. Retain real Rust entry/build sources; run their normal tests even if the initial starter has no Rust unit tests, and report the actual coverage.

```typescript
import { expect, test } from "vitest";

test("the starter renders the project title", async () => {
  document.body.innerHTML = '<div id="app"></div>';
  await import("./main");
  const title = document.querySelector("#app h1");
  expect(title).not.toBeNull();
  expect(title?.textContent).toBe(document.title);
});
```

- [ ] **Generate locks and validate actual dependencies.** Resolve the selected stable Tauri crate exactly; retain upstream-compatible CLI/API/plugin/build crate selections instead of equating their version numbers. Use npm to produce `package-lock.json` with real integrity/resolved entries, and Cargo to produce `Cargo.lock`; checkpoint and retain these files before installing/running remaining build steps. Verify through Cargo metadata that the application uses the selected Tauri release. Subsequent installation uses `npm ci`; Cargo checks/builds use locked resolution. Unknown upstream incompatibility blocks preparation, never selects an older major.

Merge upstream `.gitignore` entries with shared `dist/`, local tooling and BA verification output. Validate ignored actual `node_modules/`, Rust `target/`, generated schema paths, Vite/TypeScript/test caches and local env files while retaining deliberate examples, icons, locks, permission files and source. Do not put installed package-manager dependencies in the source snapshot.
- [ ] **Implement and test the aggregate Tauri stages.** Required stages are documentation, TypeScript checking, frontend tests, frontend build, Rust formatting, Rust lint, Rust tests and native desktop build without installer bundles. Initial command contracts are:

```powershell
npm run typecheck
npm run test -- --run
npm run build
cargo fmt --manifest-path src-tauri/Cargo.toml --all -- --check
cargo clippy --manifest-path src-tauri/Cargo.toml --locked --all-targets -- -D warnings
cargo test --manifest-path src-tauri/Cargo.toml --locked
npm run tauri -- build --no-bundle --ci -- --locked
```

Project-owned commands retain the selected release's supported invocation. Confirm the CLI accepts the locked Cargo forwarding; never use `--ignore-version-mismatches`. Treat absent rustfmt/clippy, missing node modules, stale/mutated locks, malformed test results and any stage failure as failure. Record the native binary path after build; do not equate a frontend-only build with desktop success. Separate app launch evidence from build evidence.
- [ ] **Run fixture gate cases for each required stage failing alone**, for paths containing spaces and for unavailable native dependencies. Run a real native Tauri starter when Rust/MSVC/WebView2 prerequisites are available; otherwise keep this task's native validation pending and continue independent offline work.
- [ ] **Commit after the meaningful fixture checks pass**, retaining an explicit native-pending record if prerequisites remain: `feat: prepare latest-stable Tauri starters with locked native verification`.

## Task 7: Integrate preparation with the creation, resume and status ceremony

**Files:** Modify `scripts/Bootstrap.psm1`, `scripts/bootstrap.ps1`, `scripts/Preparation.psm1`; extend `tests/bootstrap/github-tests.ps1`, `state-tests.ps1`, `cli-tests.ps1`, `fixtures/cli-driver.ps1`; create `tests/bootstrap/preset-recovery-tests.ps1`.

**Interfaces:** Existing public functions gain optional selection/preparation process seams. `Get-BootstrapPlan` consumes selection but never prepares dependencies. Both plan and creation accept `-PrerequisiteProbe` with the read-only probe contract above, so offline fixtures cannot depend on the host's installed toolchains. `Invoke-Bootstrap` accepts `-PresetSelection` and `-Prepare`; the latter takes `(identity, selection, journal, stateRoot, checkpoint)` and defaults to a wrapper around `Initialize-BootstrapPreparation` using production metadata/download/process adapters. It owns locking/checkpoints and passes the frozen manifest into unchanged repository/ref identity checks. `Get-BootstrapStatus` reports stored selection/resolution/verification, including legacy foundation; `Get-BootstrapStoredIdentity` remains available and gains `Get-BootstrapStoredSelection -Name <string> -Owner <string> -StateRoot <string>`, returning the normalized recorded selection or legacy foundation. CLI passes only explicitly bound overrides for conflict checks.

- [ ] **Add red integration cases**, especially this pre-POST native failure. Extend the existing `New-GitHubFixture` instead of introducing a second repository simulator. Explicitly select foundation in old creation/CLI fixtures so they keep proving v1 behavior independently of new default-Godot preparation.

```powershell
Test 'preset native preparation failure prevents both repository POSTs' {
    . "$PSScriptRoot/GitHubFixture.ps1"
    $api = New-GitHubFixture
    $id = New-BootstrapIdentity -Name 'Fail Before Repos' -Description 'Purpose' -Parent $sandbox
    $selection = Resolve-BootstrapPreset -Identity $id -Preset tauri
    $state = New-BootstrapFixture 'failed preparation state'
    $prepare = {param($identity,$selection,$journal,$stateRoot,$checkpoint) throw 'Native Tauri build failed: unsupported schema'}
    $probe = {param($name) @{passed=$true;version='fixture';executable='fixture';message=''}}
    $report = Invoke-Bootstrap -Identity $id -PresetSelection $selection -StateRoot $state -Request $api.request -Prepare $prepare -PrerequisiteProbe $probe
    Assert ($report.status -in @('blocked','partial')) 'Failed preparation reported complete.'
    Assert (@($api.calls | Where-Object isRepositoryCreate).Count -eq 0) 'Repositories created before native validation.'
    Assert (($report.pending -join ' ') -match 'unsupported schema') 'Actionable failure lost.'
}
```

- [ ] **Run `preset recovery*` cases to establish missing phase/seam failures.** Cover generator/preparation failure, complete v1 status, conflicting explicit selection, source snapshot corruption and later project development after completion.
- [ ] **Implement preflight and locked preparation sequencing.** Read/validate local identity/options/journal first, then perform read-only foundation/docs/options/prerequisite/access/name checks. Do not block completed status/repeated creation on a toolchain no longer installed when no build is being attempted. Under the existing lock, recheck state, resolve/record new selections once, create/retain owned staging and complete prep. Gather intended source paths from foundation plus validated engine output; import/lock generation finishes before freezing. Freeze the source, run the complete gate in staging, verify bytes remain unchanged and verify effective ignores before recording staging verification. Only then enter the existing first repository POST.

```powershell
# Locked creation ordering; implement using existing Save-Phase/journal writes.
# 1. Read and validate identity/selection/state and completion.
# 2. Record dependency resolution; retain generator output and lock checkpoints.
# 3. Prepare source metadata, freeze snapshot, run native gate and assert hashes.
# 4. Record preparation='verified'; create exact private/public repository IDs.
# 5. Replay snapshot into the owned private checkout; install from retained locks.
# 6. Run full checkout gate, assert source hashes, commit/push exact initial tree.
# 7. Finish existing labels/public settings/Obsidian; require every phase for complete.
```

Keep definitive HTTP rejection versus uncertain create outcomes, lost-root-commit recovery, lost-push readback and public README/tree checks intact. Stage only manifest paths; required generated source cannot be globally excluded accidentally. Assert intended generated source is not ignored by the project's own rules even though staging uses `-f` for unrelated global excludes. Native dependencies/caches remain excluded. After checkout gate, source bytes must still match the frozen manifest before commit.
- [ ] **Integrate CLI inputs and reports.** Add `-Preset`, `-Renderer`, `-AppIdentifier`; new plan/create chooses Godot by default. Interactive collection groups missing identity/preset inputs and offers renderer/identifier only when relevant. Status/resume loads recorded selection, tests only supplied overrides and never applies new defaults. Reject engine options in local-setup before invoking its existing vault operation. JSON includes preset, resolution, prerequisite diagnostics, frozen manifest evidence and staging/checkout verification; process output must not contaminate that JSON. No false `complete` if required verification is pending/failed.
- [ ] **Exercise full offline interruption recovery**, including after each retained prep checkpoint, repository create, initial commit before ref receipt, successful push with lost response, public content, labels and app-pending state. Change metadata and skill assets between attempts: a completed v2 snapshot is authoritative, while corrupted/missing snapshots fail with preservation. Repeat on paths with spaces and explicit personal owner. Fresh cloned local-setup changes no tracked engine/config files. `plan`/`status` leave project/state bytes unchanged and never call generator/install/process build boundaries.
- [ ] **Run the entire bootstrap suite**, then commit: `feat: integrate preset preparation with recoverable repository bootstrap`.

## Task 8: Native starters, fresh clones and real repository trials

**Files:** Create `tools/test-bootstrap-presets-native.ps1`; add meaningful native negative fixtures under `tests/bootstrap/fixtures/native/`; store receipts under ignored `.test-results/ba-bootstrap-presets/`. Do not commit machine paths, downloaded SDKs or receipts as source.

**Interfaces:** Exercise the actual generated `tools/verify.ps1` and actual production preparation adapters. The local native runner accepts `-Preset godot|tauri|all` and a fixture parent, checks containment before cleanup and has no GitHub-create capability. Real repository creation uses the ordinary public CLI with explicitly named disposable projects.

- [ ] **Implement the native runner and establish a fail/pass fixture cycle.** Prepare a starter, initialize/commit a local bare repository, clone into a second path with spaces, install only from frozen locks where needed, then run its own gate. Preserve receipts with commands/exit results, versions, source hashes, Git status and test totals. Deliberately break a docs link, source compilation and a required dependency; each must fail, restoration must pass. Godot invokes gate self-tests for zero-success false positives. Tauri exercises frontend failure and native Rust/build failure independently.

```powershell
pwsh -NoProfile -File tools/test-bootstrap-presets-native.ps1 -Preset godot
pwsh -NoProfile -File tools/test-bootstrap-presets-native.ps1 -Preset tauri
```

- [ ] **Resolve the local Rust prerequisite concretely if still missing.** Reinspect installed tools before proposing installation; initial inspection found Godot 4.7.2, Node 25.8.0, npm 11.11.0 and Visual Studio C++ tools but no Rust. Use [Rust's official Windows setup](https://rust-lang.org/tools/install/) for a per-user MSVC toolchain with rustfmt/clippy. Present the actual missing component and installation command for authorization if installation has not already been authorized. Keep existing SDK/default selections intact, use a process-local environment to address the selected tools, and do not silently install it from `bootstrap.ps1`. If installation requires external/manual action, continue independent verification while accurately leaving native Tauri validation pending.
- [ ] **Run both original and fresh-clone native gates.** Validate clean tracked status after dependency install, repeated verification and Godot import. Verify every ignored-output class and every required source class with Git, and compare initial tree blobs to the frozen manifest. Godot checks all three renderer configurations headlessly; only configured rendered probes require a display. Tauri is a Windows validation claim, with no installer/signing claim.
- [ ] **Perform the two real creations only after native local validation.** First run read-only plans and stop on collisions rather than adopting existing repositories. Use the approved default owner and disposable names below; Cicely owns teardown.

```powershell
pwsh -NoProfile -File skills/ba-bootstrap/scripts/bootstrap.ps1 -Mode plan -Name 'BA Bootstrap Godot Smoke Test' -Description 'Disposable Godot preset validation.' -Preset godot
pwsh -NoProfile -File skills/ba-bootstrap/scripts/bootstrap.ps1 -Mode create -Name 'BA Bootstrap Godot Smoke Test' -Description 'Disposable Godot preset validation.' -Preset godot
pwsh -NoProfile -File skills/ba-bootstrap/scripts/bootstrap.ps1 -Mode plan -Name 'BA Bootstrap Tauri Smoke Test' -Description 'Disposable Tauri preset validation.' -Preset tauri
pwsh -NoProfile -File skills/ba-bootstrap/scripts/bootstrap.ps1 -Mode create -Name 'BA Bootstrap Tauri Smoke Test' -Description 'Disposable Tauri preset validation.' -Preset tauri
```

- [ ] **Verify both repository pairs and resume behavior.** Record GitHub returned IDs, private/public visibility and feature settings, main refs, public README-only tree, labels, exact initial private manifests and native gates. Clone each private repo into another local path, apply local-setup and verify fresh-clone gates. Repeat/resume without reselecting versions or creating additional repositories. If source changes after this trial, rerun the affected native trial before claiming that version passed.
- [ ] **Finish any foreground app checks last.** Read `references/operations.md` before app use. Preserve scoped Obsidian authorization, exact target-vault identity and four plugins; use supported CLI readback where available. Check nickname and Diagram Popup's real behavior only if that evidence needs refreshing. Prepare other results first, then release documented control immediately after the final app action or reset the runtime and finish the turn if no release API is exposed. Do not retain desktop control while preparing PR text or running background tests.
- [ ] **Record validation outcomes accurately**, then commit the native runner/fixtures: `test: verify bootstrap presets through native starters and fresh clones`. Ignored receipts stay available to the branch reviewer and user; do not delete user-owned trial projects or repos.

## Task 9: Skill guidance, final review and session-ready PR

**Files:** Modify `skills/ba-bootstrap/SKILL.md`, `references/operations.md`, `assets/project/README.md.template`, `AGENTS.md.template`, and relevant `docs/NEXT.md`/design templates; create `references/presets.md`; update this plan's completed checkboxes and approved spec only when implementation evidence warrants it.

**Interfaces:** Documentation describes actual implemented CLI/setup/gate/recovery behavior. Preset-specific README/agent sections are supplied during preparation, replacing the old docs-only claim without duplicating canon or exposing tooling internals in the starter UI.

- [ ] **Test guidance against actual generated commands.** For each preset, use its documented setup and gate commands from a fresh clone, without importing BA-Skills. Assert generated README identifies its real gate and `AGENTS.md` retains Issues/canon/session-ready PR rules, names the selected gate/setup commands and requires exports under `dist/`.

```powershell
Test 'preset docs keep the full gate and session-ready PR contract' {
    $text = [IO.File]::ReadAllText((Join-Path $assetRoot 'AGENTS.md.template'))
    Assert ($text.Contains('tools/verify.ps1')) 'Single gate disappeared.'
    Assert ($text -match 'fresh session') 'Session-ready handoff rule disappeared.'
    Assert ($text.Contains('dist/')) 'Export location is missing.'
}
```

- [ ] **Update skill instructions concisely.** Collect identity/preset/options together; default Godot, offer foundation, plain TypeScript/Vite/npm for Tauri, visible identifier override and renderer selection. Explain latest stable versus frozen retries, required toolchains, how clone dependencies are installed, complete verification and exact JSON outcomes. Preserve v1/missing-snapshot recovery, no conversion in local-setup, no public local clone and no false build/app evidence. Keep detailed prerequisites/recovery in references so `SKILL.md` remains small.
- [ ] **Run behavioral skill checks before deployment.** Apply the writing-skills workflow: baseline scenarios should expose the old engine-independent guidance, updated scenarios should choose the documented preset/restore stored options and report native failures honestly. Use scoped fresh agents only when that workflow requires behavioral evaluation; they must not create real repositories or mutate canonical aliases. Preserve the chosen native implementation method for product tasks.
- [ ] **Run final branch verification on the finished state.** Run the BA-Skills gate, metadata validator and whitespace check. Source changes after any result invalidate the affected result; rerun only checks justified by the change.

```powershell
pwsh -NoProfile -File tools/verify.ps1
& 'C:\Program Files\Python310\python.exe' -X utf8 'C:\Users\cicel\.codex\skills\.system\skill-creator\scripts\quick_validate.py' skills/ba-bootstrap
git diff --check
```

- [ ] **Request a fresh whole-branch review**, supplying approved spec/plan, implementation range, passed results, native trial receipts and limits. Verify feedback before applying it, fix relevant follow-ups and rerun affected checks. Scope review to this preset change and preserve unrelated release work.
- [ ] **Make the final state ready for another session.** Finish all required code/docs/checks and durable outcomes before opening the PR. Commit final changes, push `codex/ba-bootstrap-presets`, write an identity-prefixed PR body through a real multiline body file and attach the created PR to this chat. Describe the new preset behavior, recovery/byte-manifest changes, exact native trials and genuine remaining limits. Cicely retains merge control.
- [ ] **After Cicely merges and updates canonical main**, run the existing named installer/check-only flow and verify both `.agents` and `.claude` aliases resolve to canonical `skills/ba-bootstrap`. Do not switch aliases to the development branch as a shortcut. This integration step waits for the actual merge; implementation/PR readiness does not claim it has occurred.

## Coverage and Execution Handoff

| Approved design section | Implementing tasks |
| --- | --- |
| Foundation + versioned preset approach | 1–3, 7 |
| Selection, owner/name/path and local-setup scope | 2, 7, 9 |
| Common files, Git ignores and agent rules | 1, 5–6, 8–9 |
| Godot starter, GUT compatibility and metadata | 4–5 |
| Godot full gate, zero-success failures and rendered tests | 1, 5, 8 |
| Current Tauri starter, latest stable, locks and native gate | 4, 6, 8 |
| Prerequisites and truthful native/build/app claims | 2, 5–8 |
| Frozen source, binary assets, pre-POST validation and recovery | 1, 3–4, 7 |
| Legacy journals, completed projects and conflicting resumes | 3, 7 |
| Offline tests, real trials, fresh clones and source exclusions | 1–8 |
| Obsidian standing scope and foreground release | 7–9 |
| Canonical aliases, final gate, independent review and PR | 8–9 |

Run the tasks sequentially because preparation/state interfaces are shared. Preserve native execution as already selected. Present this complete plan for Cicely's review before invoking an implementation skill or writing product code. A missing local prerequisite is recorded separately from a product defect; neither allows a false completion claim or silently skipped native check.

Current primary references: [official Tauri generator](https://github.com/tauri-apps/create-tauri-app), [Tauri project creation](https://tauri.app/start/create-project/), [Tauri CLI build options](https://v2.tauri.app/reference/cli/#build), [Tauri Windows prerequisites](https://v2.tauri.app/start/prerequisites/), [GUT compatibility](https://github.com/bitwes/Gut), and DRRD's local `tools/verify.ps1`, `check_scripts.gd`, `verify_pre_run.gd`, `verify_post_run.gd` and verifier probes. Versioned links document inspected behavior; the Tauri resolution policy has no v2 ceiling.

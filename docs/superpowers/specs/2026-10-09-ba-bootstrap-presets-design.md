# Bootstrap Godot and Tauri presets

Status: approved by Cicely on 2026-10-10. Implementation has not started. The implementation plan is [2026-10-10-ba-bootstrap-presets.md](../plans/2026-10-10-ba-bootstrap-presets.md).

## Intended result

Extend the merged `ba-bootstrap` foundation so a new project can start with a runnable Godot or Tauri skeleton. Keep the shared documentation, topical indexes, agent rules, GitHub repository pair, labels and local Obsidian setup. Every project ignores `dist/`; each preset adds the ignore entries and verification stages appropriate to its stack.

Cicely requested Godot as the default choice and Tauri as another choice, and selected plain TypeScript with Vite for Tauri. Proposed defaults below are distinguished from those choices. Success means both starters can be built and checked from a fresh clone, generated files stay out of Git, and an interrupted bootstrap resumes the same selected preset without replacing project work.

## Approach

Use small, versioned presets layered onto the existing foundation. Keep the Godot starter sources, shared foundation, ignore fragments and project-owned verification helpers in the skill. For Tauri, prepare the current stable official TypeScript/Vite starter in isolated staging, then apply the BA foundation and verification integration. Resolve external dependencies through their normal upstream sources, record exact selections and freeze the complete initial source manifest before creating GitHub repositories. Generated projects own their verification configuration and scripts; they do not require an installed bootstrap skill to run their gate.

A fixed Tauri starter would preserve predictable output but could encode an obsolete major version. The official generator lets new creations follow upstream's current stable starter; freezing its output before repository creation preserves the exact-manifest recovery contract. Record the generator version and acquired integrity evidence, and retain the generated source rather than rerunning a moving `latest` selection on resume. Complete project stubs would duplicate the shared foundation and drift independently. Keep BA additions small and validate their integration with the prepared starter.

## Selection and inputs

Offer `godot`, `tauri` and `foundation`, with Godot selected by default for a new creation. Foundation retains an engine-free option. Add a preset input to the existing name, description, parent and owner collection; keep the current repository naming, owner and path defaults.

For Godot, offer a renderer choice: Compatibility by default, with Forward Plus and Mobile available. Compatibility is a proposed default based on TPF and rainboom; DRRD uses Forward Plus. The initial app does not assume a game genre or scene architecture beyond its starter screen.

For Tauri, use desktop Tauri latest, plain TypeScript, Vite and npm. npm is a proposed default because it is already available alongside Node; this version does not add a package-manager matrix. Collect an application identifier with a visible, validated owner/name-derived reverse-DNS suggestion and an override. The identifier is separate from the human title, GitHub repository name and package/crate names. Preserve valid GitHub naming while generating legal, deterministic names for each tool's configuration.

“Latest” means the latest stable Tauri release at the start of a new creation, including a new major release; exclude prereleases. Select a compatible stable official generator and dependencies, and verify that the resulting project actually uses the selected Tauri release. Do not impose a v2 ceiling or silently substitute an older major if preparation fails. Freeze the resolved selections for that invocation. Retries, resumes and normal verification retain them, and existing projects are not automatically upgraded. A future incompatible upstream change produces a concrete preparation failure before either repository is created; the bootstrap cannot promise compatibility with an unknown release without validating it.

Record the preset, its recipe version and resolved options in the invocation. Resume/status restore these values; omitted options never choose a different engine. A conflicting option on an existing invocation is rejected before mutation. Existing-clone `local-setup` continues to configure local Obsidian tooling; it does not convert engines or rewrite tracked project files.

## Common project files and ignores

Retain the existing foundation and add a project-owned `tools/verify.json` declaring the preset and its required checks, plus `.gitattributes` enforcing LF for text. The gate fails if its configuration is missing or invalid; deleting an engine file cannot quietly downgrade verification to documentation only. Foundation explicitly selects documentation-only verification.

The common `.gitignore` retains the current Obsidian, Vault Inspector and scratch entries and adds `dist/`. This unanchored directory rule covers both a root export folder and nested build folders. Verification receipts go in ignored output directories.

Compose common and preset ignore fragments into one initial `.gitignore`. Test the effective rules with Git itself, isolated from global excludes. Check both that generated output is ignored and that intended source remains addable. Do not use broad executable/archive extension rules that could hide tools or source assets. Every required starter file must survive the initial commit's exact-manifest check.

The generated agent rules explain that exports belong under `dist/`, that cache/build output stays untracked, and that the complete `tools/verify.ps1` gate must pass before opening a PR. They name the chosen preset's setup and verification commands. Preserve the existing rules for Issues, canon, worktrees and session-ready PRs.

## Godot starter

Create a GDScript project with `project.godot` at the repository root, a minimal main scene under `app/`, an `assets/` directory, `test/` and the project-owned verification helpers under `tools/`. The starter screen displays the human project title; a smoke test checks that it loads and displays that title. Avoid speculative autoload managers, gameplay systems and copied DRRD content.

Proposed initial application version is `0.0.1`, matching DRRD. Use a 1280 by 800 viewport and the selected renderer. Add `docs/.gdignore` so Godot treats the documentation vault as documentation rather than project resources.

Install a released GUT version compatible with the supported Godot version, including its licence, into tracked `addons/gut/`. A normal clone therefore has its test runner without requiring submodule initialization or another download. Record the selected release and available upstream integrity evidence; verify acquired bytes before including them in the manifest. Retries retain the exact selection rather than resolving a new release.

The initial tested recipe targets Godot 4.7, with the locally available 4.7.2 engine and GUT 9.7.1 as the validation baseline. Upstream currently lists GUT 9.7.1 for Godot 4.7. Subsequent recipe updates require compatibility validation; Obsidian's separate latest-plugin policy is unchanged. The generated gate resolves Godot from `GODOT` or the available executable, checks the supported version and does not hard-code Cicely's executable path.

Godot ignores include `.godot/`, generated binary translations and export credentials. Include applicable editor, Android-generated-build and Mono cache rules without ignoring source metadata. Track GDScript UID files, import sidecars and usable export preset configuration. Export/store configuration itself remains a later project/release setup concern.

## Godot verification

The aggregate gate runs documentation checks, imports the project, compiles project scripts and executes the GUT suite. Adapt the proven DRRD checks and failure detection rather than copying its project-specific paths and policies wholesale.

Fail on failed imports or compilation, missing Godot/GUT, unsupported engine versions, failed tests, unexpected engine errors, unfreed orphan nodes and a suite that discovers no tests. Godot can return zero for some failed import conditions, so validate the relevant import results; process exit codes alone are insufficient. Keep generated configurations and reports in ignored cache/output locations.

The initial suite runs headlessly. Support the established `test/rendered/` convention when rendered tests are actually introduced: run that suite with a real renderer and require its results. The starter does not require an empty rendered suite to pass. A configured rendered suite must never be silently skipped for lack of a display or GPU.

Keep documentation and engine outcomes visible in the final result. A failed required stage makes the aggregate exit code nonzero. Include focused gate self-tests for the failure conditions that a nominally successful engine process can otherwise conceal.

## Tauri starter

Prepare the current official vanilla TypeScript/Vite starter, with frontend sources under `src/` and Rust/Tauri configuration under `src-tauri/`. Include the frontend entry point, TypeScript and Vite configuration, `package.json`, Rust sources, `Cargo.toml`, Tauri configuration, required starter icon assets and the minimal permissions appropriate to the selected release. Use the human title for the window and starter screen, with configuration values escaped for their actual file formats. Apply BA changes to the generated configuration without replacing it with a hard-coded older-major schema. Currently this includes capabilities files; future upstream layouts are validated during preparation.

Keep Vite and Tauri development settings consistent, including a fixed development port and watch exclusions for Rust sources. Use the standard Vite frontend output at root `dist/` and configure the selected Tauri release to consume it (currently through `frontendDist`). Native intermediate artifacts stay in Cargo's ignored `target/`; eventual distributable exports are placed under `dist/` by the later release workflow.

Commit `package-lock.json` and `Cargo.lock`. Resolve the latest stable Tauri release with mutually compatible dependencies during preparation and freeze their resolved locks for each new project. Record actual generator, CLI, API, crate and frontend dependency versions; related packages need not share identical version numbers. Normal verification uses the recorded dependencies; it does not upgrade them. Include meaningful starter checks without building an application feature merely to demonstrate the test framework.

Compose the current official starter's ignore rules with BA's common rules and verification-output entries. Tauri ignores currently include `node_modules/`, Cargo `target/`, generated `src-tauri/gen/schemas/`, Vite caches, TypeScript incremental build output and test coverage/results. Ignore local environment files while retaining deliberate example files. Keep Rust/TypeScript sources, lockfiles, permission files, configuration and icon sources tracked. Validate actual generated output for the selected release rather than assuming an older major's ignore list is complete. The shared `dist/` rule covers Vite output and later exports.

## Tauri verification and prerequisites

The aggregate gate runs documentation validation, TypeScript checking, frontend tests/build, Rust formatting and lint checks, Rust tests and a native Tauri build without installer bundling. A failure or missing dependency in any required stage fails the gate. The initial native trial targets Windows; do not claim other platforms were tested merely because Tauri supports them.

Use the project's npm scripts and locked Cargo dependencies. Neither a successful frontend build nor a Rust-only compile proves that the complete desktop application builds. Keep build success distinct from observing the application launch or exercising its UI.

Preflight checks the installed Godot toolchain for Godot, or Node/npm, Rust/MSVC and applicable Windows development prerequisites for Tauri. Report missing prerequisites before creating either repository. Package installation belongs to the selected project's dependency preparation; the bootstrap does not silently replace a global SDK, toolchain or its default selection. On this machine, Godot, Node/npm and C++ build tools were found, but Rust was not found in PATH or its usual per-user locations. A real native Tauri trial needs that prerequisite resolved during implementation.

## Preparation, manifest and recovery

Keep `plan` and `status` free of persistent project, journal and dependency-installation writes. Plan renders the static BA foundation in disposable storage and validates documentation as today, checks inputs/options and reports tool prerequisites. It may look up current stable release metadata, but it does not run the Tauri generator, install packages or pretend to have verified a build. Versions shown in a plan are provisional until a creation records its selections.

During authorized creation, record resolved release and generator selections before running their preparation steps. Prepare external source dependencies, the Tauri starter and lockfiles in isolated staging before repository creation. Freeze every intended tracked file and its hash, including GUT sources/licence, generated Tauri sources, lockfiles and required Godot UID metadata. Exclude caches, dependencies installed by package managers, generated schemas and build output. Retain the prepared tracked source and a durable preparation receipt under bootstrap's existing local state storage so an interrupted attempt cannot substitute newly resolved source or dependency bytes. Resume an incomplete preparation with its recorded versions, and reuse the frozen snapshot once complete; never resolve `latest` again for the same invocation.

Validate the complete prepared source, documentation and required ignore behavior before the first repository POST. Run the selected preset's complete native gate in staging so an incompatible newest Tauri release cannot create a repository pair before failing its build. Confirm that verification has not changed the frozen tracked source. The project creation/commit/recovery phases use that frozen manifest. Preserve uncertain repository outcomes, exact identity checks, lost-push readback and the initial-root-commit recovery contract. Native verification of the resulting checkout is a separate recorded phase; report incomplete verification accurately and keep the gate failing until the missing condition is repaired.

Introduce versioned state handling. A new invocation records all preset inputs in its input hash. Existing version-one journals remain foundation invocations, never implicit Godot projects. Completed old invocations can still report their recorded identity and completion without rewriting their project. An unfinished legacy invocation whose original source cannot be reproduced safely remains preserved with a concrete matching-version recovery instruction; do not silently regenerate it from new templates. No automatic engine conversion or ignore-file migration is included for existing projects.

## Validation and integration

Before implementation, establish failing behavior tests for preset selection, effective ignore rules, required gate stages and preset-aware recovery. Use disposable local fixtures with simulated GitHub responses. Cover default Godot and explicit Tauri/foundation, renderer and identifier validation, title escaping, frozen dependency selections, conflicting resume options, legacy state handling and generated-file exclusion from the initial commit. Simulate a stable Tauri major-version change, exclusion of prereleases, an upstream release appearing between preparation and resume, and preparation/build incompatibility that must prevent both repository POSTs. These tests establish selection and recovery behavior, not native compatibility with a hypothetical future release.

Run the generated gates against real local Godot and Tauri starters and fresh clones. Deliberately break source, a documentation link and a required dependency to establish that the relevant gate fails, then restore and verify. Check that engine preparation and builds cannot add unintended tracked files. Preserve existing-clone preferences and test both native skill aliases against the canonical source after integration.

After local validation, perform one real creation per preset using explicitly selected disposable names, such as `BA Bootstrap Godot Smoke Test` and `BA Bootstrap Tauri Smoke Test`, with their usual release-notes companions. Verify GitHub settings and identities, source manifests, native gates, fresh-clone setup and repeat/resume behavior. Name collisions remain blockers; do not adopt an existing repository. Cicely owns teardown. The already-tested Obsidian recipe and its scoped authorization remain in force; perform any needed foreground app checks last and release control promptly.

Work on an isolated branch from current main, run BA-Skills' full gate before opening the new PR, and describe what was actually verified. Existing home aliases continue pointing to canonical main until this preset change is integrated. Tauri release publication, platform-specific packaging/signing, store configuration, other frontends, Godot C# and engine conversion are separate later work.

## Evidence

- Local Godot version: 4.7.2. DRRD uses GDScript and GUT 9.7.1; TPF and rainboom use Compatibility, while DRRD uses Forward Plus. DRRD supplies the gate and export-directory conventions.
- [Godot version-control guidance](https://docs.godotengine.org/en/stable/tutorials/best_practices/version_control_systems.html): generated cache/translation ignores and LF normalization.
- [GUT upstream compatibility table](https://github.com/bitwes/Gut): released GUT/Godot pairings.
- [Tauri project creation](https://tauri.app/start/create-project/) and [official starter generator](https://github.com/tauri-apps/create-tauri-app): current upstream templates and new-project generation. [Vite integration](https://v2.tauri.app/start/frontend/vite/) supplies the currently validated development settings and `dist` integration; this evidence does not impose a v2 selection limit.
- [Tauri prerequisites](https://v2.tauri.app/start/prerequisites/): Rust, MSVC build tools and WebView2 on Windows.
- Upstream starter ignore files: [Rust/Tauri](https://github.com/tauri-apps/create-tauri-app/blob/dev/templates/_base_/src-tauri/_gitignore) and [vanilla TypeScript](https://github.com/tauri-apps/create-tauri-app/blob/dev/templates/template-vanilla-ts/_gitignore).

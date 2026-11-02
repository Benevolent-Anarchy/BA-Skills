# Preset selection and setup

All presets receive the same Issues/canon/agent process, local Obsidian recipe and public release-notes companion. Every preset creates the project repository private; its owner may make it public once bootstrap has published the foundation. Every depth of `dist/` is ignored for exports. The project-owned `tools/verify.sh` runs the complete PR gate without BA-Skills installed.

The table gives the `scripts/bootstrap.sh` options. See [commands, toolchains and state](linux.md) for the SDK checks and recovery paths.

| Selection | New-project option | Starter and gate |
| --- | --- | --- |
| Godot (default) | `--preset godot --renderer compatibility` | Godot 4.7.x, released GUT 9.7.1, a title scene and scene smoke test; docs, import, compilation and GUT with error/orphan checks. |
| Godot renderers | `--renderer forward-plus` or `--renderer mobile` | Same starter and headless gate. Rendered test directories are discovered automatically; those tests need a display. |
| Tauri | `--preset tauri --app-identifier org.benevolent-anarchy.foo-bar-baz` | Latest stable Tauri, official starter with vanilla TypeScript/Vite/npm, an entry-point test and frozen frontend/Rust locks; docs, typecheck, tests, frontend build, rustfmt, Clippy, Rust tests and native build without installer bundling. |
| Foundation | `--preset foundation` | Documentation only; no engine prerequisites. Extend its existing gate as implementation is added. |

Renderer is Godot-only; application identifier is Tauri-only. Empty explicit values and inapplicable options are rejected. Preserve the human project title. Tauri package/crate names are safely normalized independently of the repository name. The visible default identifier uses `org.benevolent-anarchy` for BA and `com.cicely-f` for personal projects; let Cicely override it before creation.

Godot requires an installed 4.7.x executable, found through `GODOT`, `godot` or `godot4`. GUT is vendored with its licence, version and immutable upstream commit receipt. Preserve `.uid` and source `.import` sidecars; ignore `.godot/`, translations and export credentials. This recipe's Godot/GUT family is deliberate; it does not substitute the newest incompatible engine.

Tauri preflight inspects Node/npm, Rust/Cargo, rustfmt, Clippy, a C/C++ compiler, pkg-config, patchelf and the development libraries listed in [commands, toolchains and state](linux.md). Bootstrap does not install or replace global SDKs or change the default toolchain. Resolve any missing prerequisite separately using the [official setup](https://tauri.app/start/prerequisites/).

New Tauri invocations independently resolve the highest stable, non-yanked framework crate and highest stable official `create-tauri-app` npm release. Prereleases are excluded; no major-version ceiling is imposed. Verify the generator archive's published npm integrity before execution. Record npm package version and actual executable help/version separately. Unsupported generator major flags, layouts, schema, dependencies or native builds fail before repository creation; an older stable major is not a fallback.

After dependency preparation, the source, lockfiles and binary icons are frozen. Resume uses recorded versions and bytes even if a newer release appears. A retained generator or completed lock checkpoint is not rerun. Reported generator, lock and GUT preparation failures roll back their owned partial output for a retry with the recorded versions. An interrupted step with an unknown outcome remains protected; use the recovery or explicit unpublished `discard` path in [operations.md](operations.md).

Fresh clone commands run from the clone's root:

```bash
# Tauri only: install exactly the committed frontend lock.
npm ci
# All presets: run the complete gate.
bash tools/verify.sh
```

Godot needs no GUT download after cloning. Open `project.godot` in Godot 4.7.x for development. Tauri's `npm run dev` serves its frontend, and `npm run tauri dev` starts desktop development. Cargo fetches the committed lock's dependencies as needed; gates use locked Cargo commands. Tauri retains icons, capabilities, Rust sources and both lockfiles while ignoring `node_modules/`, native `target/` and generated schemas.

Tauri's committed npm manifest records tested version ranges, including Vitest and jsdom. Its Cargo manifest permits compatible updates while the initial lock selects the exact bootstrap release. A deliberate `cargo update -p tauri --manifest-path src-tauri/Cargo.toml` can advance to a later stable release of the same major; the project gate accepts versions at or above the recorded `tauri.selectedRelease`. To move to another major, deliberately update `tools/verify.json`, Cargo/npm ranges, code and lockfiles together, then run the full gate. Bootstrap staging and checkout verification continue to enforce the exact invocation release.

Fixture tests cover preparation, recovery, command dispatch and validation; run `tools/test-bootstrap-presets-native.sh --preset godot|tauri|all` for actual Linux SDK builds, fresh-clone checks, deliberate failures and retained evidence. Do not infer a successful native Linux build from fixture tests. They do not establish an observed desktop app launch, installer packaging, signing, or other-platform compatibility. The official initial Rust scaffold has zero Rust unit tests; preserve that fact and add meaningful tests with new behavior.

Existing-clone `local-setup` remains Obsidian-only. It does not add presets or convert engines and rejects `--preset`, `--renderer` and `--app-identifier`. Engine conversion is separate project work. It accepts a clone of a private project, or of one its owner made public, and refuses the release-notes companion; see [project repository visibility](operations.md#project-repository-visibility).

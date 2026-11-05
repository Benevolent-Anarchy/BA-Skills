# Commands, toolchains and state

Use `scripts/bootstrap.sh`; it runs a Python 3.10+ implementation with a bundled CommonMark parser. `scripts/install.sh` delegates to the root installer and accepts `--home PATH` and `--check-only`.

| Option | Purpose |
| --- | --- |
| `--mode` | `plan`, `create`, `status`, `resume`, `discard` or `local-setup` |
| `--name`, `--description` | Project identity |
| `--parent`, `--owner` | Where the project is created and who owns it |
| `--repository` | An existing checkout, for `local-setup` |
| `--preset`, `--renderer` | Starter selection; the renderer is Godot-only |
| `--app-identifier` | Tauri application identifier |
| `--interactive`, `--refresh-plugins` | Prompt for inputs; deliberately refresh Obsidian plugins |

Names retain case and replace whitespace with hyphens. The default parent is `~/Dev` (expanded by the helper), owner `Benevolent-Anarchy`, preset Godot and renderer Compatibility. Supply an absolute parent; quote paths containing spaces. Tauri identifiers default to `org.benevolent-anarchy.<package>`, `com.cicely-f.<package>` or `com.<owner>.<package>`.

```bash
scripts/bootstrap.sh --mode plan --name 'New Project' --description 'Useful software' --parent "$HOME/Dev" --preset foundation
scripts/bootstrap.sh --mode create --name 'New Project' --description 'Useful software' --parent "$HOME/Dev" --preset tauri --app-identifier org.example.new-project
scripts/bootstrap.sh --mode resume --name 'New Project'
scripts/bootstrap.sh --mode local-setup --repository "$HOME/Dev/New-Project"
```

All operational results are JSON, including failures. Exit zero means `ready`, `complete` or `discarded`; inspect `pending` and `conflicts` after nonzero exits. `--help` describes the options. `plan` reads GitHub to establish owner access, repository-name availability and any recorded identities, but creates no durable preparation or project files. `create` and `resume` perform the requested repository and local setup mutations. Once an invocation is complete, either command with `--refresh-plugins` blocks and directs the caller to `local-setup --repository PATH --refresh-plugins`; it never reruns remote settings writes or mutates the completed journal.

## Toolchains and generated gates

Foundation needs Bash, Python 3.10+, Git and authenticated GitHub CLI. Godot additionally needs stable Godot 4.7.x (`GODOT` may be a full executable path). It resolves GUT 9.7.1 to an immutable commit, retains archive SHA-256 proof, vendors its source, imports the project and retains UID/import sidecars. Rendered tests require a display.

Tauri additionally checks Node/npm, Rust/Cargo, rustfmt, Clippy, a C/C++ compiler, pkg-config, patchelf and the development libraries exposed as `webkit2gtk-4.1`, `gtk+-3.0`, `ayatana-appindicator3-0.1` and `librsvg-2.0`. Install missing SDKs separately; bootstrap does not install them. The recipe downloads the latest stable official generator with its published SHA-512 integrity, selects the latest non-yanked stable Tauri crate including future majors, checks generator compatibility and freezes npm/Cargo locks. An incompatible generator fails before either repository is created; it never silently downgrades.

Generated projects run their gate with `bash tools/verify.sh`. The helper is standalone. It bundles pinned `markdown-it-py` 4.2.0 and `mdurl` 0.1.2 runtime sources under `tools/_vendor/`, with MIT/Expat notices, origin/version metadata and per-file SHA-256 checksums; it does not require a package download or system Markdown installation. CommonMark block tokens distinguish live nested lists/references from actual indented/fenced code. Native commands handle SIGTERM/SIGINT by granting child groups a bounded termination grace before forced cleanup, including nested gate groups and descendants retaining stdout after their leader exits. It validates documentation and its indexed topical corpora, exact local link paths/headings, decision dates and judgement metadata. Its `git-lfs-pointers` stage fails when a file committed at HEAD that `.gitattributes` sends through Git LFS is a plain file rather than an LFS pointer, naming each one. A plain copy stays in history, and every checkout counts the file as changed, which stopped an integration in [BA-Skills#76](https://github.com/Benevolent-Anarchy/BA-Skills/issues/76). Failing keeps it from staying plain at the tip; the fix is a new commit with `git add --renormalize`. It asks Git which files have `filter=lfs` at HEAD (`git check-attr --source`, Git 2.40 or newer) rather than running `git lfs fsck --pointers`, which in git-lfs 3.8.1 applies a pattern in a subfolder's `.gitattributes` only to files directly in that folder. So it needs no `git-lfs`. A project without a committed `filter=lfs` rule, a copy that is not its own Git checkout, such as the selftest's, and a checkout with no commit yet are reported as not checked. A checkout Git cannot read fails. Godot adds import/compile and GUT headless/rendered tests with fresh JUnit and post-run totals, executed-test/assertion counts, unexpected errors and orphan failures. Tauri adds locked dependency checks, direct stable Tauri version validation, TypeScript, actual frontend test records, frontend build, Rust format/Clippy/tests and the native application binary. A build is not an observed app launch.

Run `bash tools/verify_selftest.sh` in a generated Godot project to run all deliberate verifier probes in disposable copies. `--only 'fails/*'` filters cases. Logs and copies remain in the printed temporary evidence directory.

## State and recovery

Linux journals default to `$XDG_STATE_HOME/BA-Skills/ba-bootstrap/state` or `~/.local/state/BA-Skills/ba-bootstrap/state`. `--state-root PATH` or `BA_BOOTSTRAP_STATE_ROOT` explicitly selects another recovery root. No Windows journal or user vault is migrated implicitly. Journals contain exact identity, selection, dependency resolution, checkpoints, remote IDs, refs and staging/checkout verification. Writes are atomic and invocations take an exclusive local file lock. New native journals record `inputHashFormat: linux-path-v1` and hash project paths case-sensitively. Unmarked older journals retain their original case-folded hashes/receipts, but every retry must still match the stored native parent, project and vault paths exactly; a case-only path change cannot relocate an invocation.

`resume`, `status` and `discard` restore the original identity and selection from name and owner; explicit conflicting parent, description or preset options fail. Frozen source and receipts survive disposable-cache cleanup. Missing/corrupt snapshots, linked paths, modified source, unresolved generator/lock executions and lost repository-create responses preserve their evidence and block unsafe retries. A lost server response is `identity-unconfirmed`; never adopt an observed repository merely because its name matches. Definite client rejections are recorded separately and may be retried with `resume` after the cause is repaired.

`discard` removes only validated invocation-owned preparation and its journal, and refuses once any repository-creation attempt has been recorded. It never deletes project checkouts or remote repositories. Legacy v1 journals remain readable, and matching v1 documentation foundations resume through native validation. As with the original implementation, an incomplete v1 journal whose exact historical template differs blocks and is preserved; recover with its matching recipe rather than replacing its source. Moving a journal between operating systems does not rewrite its recorded absolute project paths.

GitHub APIs that expose `has_pull_requests` are updated and read back. When GitHub does not expose it, the report leaves `pullRequests` pending for authenticated browser verification. Record that exact observation with `--browser-evidence evidence.json` on `status` or `resume`: JSON must include `disabled: true`, `sourceUrl` equal to the companion's exact `/settings` URL, its numeric `repositoryId`, and an ISO `observedAt` timestamp. The helper verifies the recorded remote identity before accepting it. Never fabricate browser evidence.

## Obsidian

`local-setup` resolves the clone's actual Git root and canonical GitHub origin, rejects release-notes companions, verifies the project identity and foundation, and refuses tracked or unignored `docs/.obsidian` files. It does not convert the engine. Public projects must retain their verified public release-notes companion.

The four curated plugins are resolved through the official registry and consistent published releases. The helper stages every asset, checks available digests and release manifests, preserves existing preferences, promotes with a recovery journal and retains backups. Interrupted promotion rolls back before replaying its pinned release bytes. Repeated setup retains valid app-managed plugin updates; `--refresh-plugins` deliberately refreshes them. Reports distinguish verified digests and assets for which upstream provides none.

Linux app settings are read from `$XDG_CONFIG_HOME/obsidian/obsidian.json` or `~/.config/obsidian/obsidian.json`. App enablement requires the target vault registered in the running app, its CLI enabled and `obsidian` on PATH. Compatibility comes from the running CLI version or downloaded `obsidian-<version>.asar` cache. Without that evidence, installed files are reported separately and app verification remains pending. CLI checks never launch a stopped application.

Fixture verification: `tests/bootstrap-linux/run-tests.sh`. Tests use temporary checkouts, injected GitHub/download boundaries and app substitutes; they do not create real repositories or activate plugins in user vaults.

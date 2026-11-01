# Native Linux release operations

On Linux and WSL, use Bash 4+ and Python 3.9+:

```bash
<skill>/scripts/release.sh --mode setup --repository "/path/to/game"
<skill>/scripts/release.sh --mode validate --repository "/path/to/game"
<skill>/scripts/release.sh --mode plan --repository "/path/to/game" --destination itch-linux,notes --version-change patch
<skill>/scripts/release.sh --mode doctor --repository "/path/to/game" --destination itch-linux,notes
<skill>/scripts/release.sh --mode prepare --repository "/path/to/game" --destination itch-linux,notes --version-change patch
<skill>/scripts/release.sh --mode status --state-path "/saved/state/path"
<skill>/scripts/release.sh --mode hold --state-path "/saved/state/path" --destination google-play --hold-reason "Waiting for review."
<skill>/scripts/release.sh --mode unhold --state-path "/saved/state/path" --destination google-play --play-track-reviewed
<skill>/scripts/release.sh --mode extend --state-path "/saved/state/path" --destination steam --migrate-configuration
# Only after explicit approval of the displayed plan and notes:
<skill>/scripts/release.sh --mode publish --state-path "/saved/state/path" --approved-plan-id "<displayed-id>" --approved-notes-sha256 "<displayed-hash>"
<skill>/scripts/release.sh --mode confirm --state-path "/saved/state/path" --receipt-path "/observed/receipt.json"
# Only after explicit authorization to abandon the observed non-live upload:
<skill>/scripts/release.sh --mode abandon --state-path "/saved/state/path" --receipt-path "/observed/abandonment.json" --abandon-authorized
<skill>/scripts/release.sh --mode play-changelogs --state-path "/saved/state/path"
```

The Bash entry points invoke the standard-library Python implementation. They
never invoke PowerShell or translate a release into a model-generated shell
sequence. Windows continues to use the existing `.ps1`/`.psm1` implementation.
All safety and approval requirements in the skill, execution and store references
apply on both hosts. No store is contacted by setup, validation, planning or doctor.

Every `release.ps1` parameter has a native equivalent:

| PowerShell | Linux |
| --- | --- |
| `-Mode`, `-Repository`, `-Destination` | `--mode`, `--repository`, `--destination` |
| `-StateRoot`, `-StatePath` | `--state-root`, `--state-path` |
| `-VersionChange`, `-NewRelease` | `--version-change`, `--new-release` |
| `-AnswersPath`, `-ExpectedConfigSha256`, `-Interactive` | `--answers-path`, `--expected-config-sha256`, `--interactive` |
| `-GodotExecutable`, `-ButlerExecutable` | `--godot-executable`, `--butler-executable` |
| `-GhExecutable`, `-SteamCmdExecutable` | `--gh-executable`, `--steam-cmd-executable` |
| `-TemplateRoot`, `-EditorSettingsPath` | `--template-root`, `--editor-settings-path` |
| `-AndroidSdkPath`, `-JavaSdkPath` | `--android-sdk-path`, `--java-sdk-path` |
| `-ApprovedPlanId`, `-ApprovedNotesSha256` | `--approved-plan-id`, `--approved-notes-sha256` |
| `-ReceiptPath`, `-AbandonAuthorized` | `--receipt-path`, `--abandon-authorized` |
| `-HoldReason`, `-PlayTrackReviewed` | `--hold-reason`, `--play-track-reviewed` |
| `-RetryUncertain`, `-ReplacePlayEdit` | `--retry-uncertain`, `--replace-play-edit` |
| `-MigrateConfiguration` | `--migrate-configuration` |

Destinations can be comma-separated or supplied with repeated `--destination`.
Exit codes remain 0 success, 1 invalid input/precondition, 2 blocked plan/doctor
or missing release selection, 3 incomplete preparation/publication. Output is
JSON except interactive prompts and the authorized child action's own output.
Always quote paths. Relative executable overrides containing `/` are fixed
against the caller's directory before any mode changes working directory.

Configuration stays shared. Native verification hooks can be executable native
scripts, `.sh` files run through Bash, or `.py` files run through the release
engine's Python interpreter. Shell and Python hooks need no execute bit; Python
hooks need no shebang. A configured `.ps1` hook resolves to its
existing `.sh` sibling on Linux; absence is an explicit error. In that case named
`-CamelCase` arguments translate to `--kebab-case`, while values remain exact.
A host must run meaningful functionality checks for its selected exports; Linux
startup checks do not verify Windows runtime behavior. Cross-exporting Windows
requires its configured native check to verify the relevant functionality or
fail. No tool or check is silently skipped.

External commands receive closed input. Exports, uploads and the authorized
wrapper command have no fixed runtime limit; short probes use explicit timeouts.
Timeouts and cancellation send TERM to
the entire owned process group, allow bounded graceful cleanup, then use KILL
and bounded pipe draining/waiting. This also cleans descendants after a launcher
exits. The auth wrapper allows a longer cleanup interval than its release child,
so nested release/gate processes can clean up and save their journals before exiting;
an interrupted upload is persisted as uncertain and stops further publication.

State defaults to `${XDG_STATE_HOME:-$HOME/.local/state}/ba-release/releases`,
outside the source repository. Journals lock with `flock`, write atomically and
retain partial exports for inspection. Shared live/sent records are keyed by
GitHub repository and actual store channel. A newer or divergent live/submitted
source blocks an older upload. Missing/corrupt ledgers fail closed. Plans pin the
source commit, exact release.json text, baseline snapshots and source-tag commit;
approval also binds notes and complete artifact hashes. Failed and uncertain
operations retain progress; completed writes are never repeated on ordinary retry.
The native engine preserves the original ordered plan identity and approval
serialization, including PowerShell's zero/one/many pipeline cardinality for
artifact hashes. Both engines compare artifact files by path, size and hash
without depending on enumeration order; the saved order and approval hash stay
unchanged. Existing prepared journals can resume natively when their sealed
source checkout, configuration, artifacts and notes still match. It completes
only the historical omission of Android `useGradle` after every other plan field
compares equal; approval and remote progress remain unchanged. Status, holds and
observed confirmations preserve existing journal identities. A saved Windows
absolute checkout path is never silently changed to a Linux checkout: if that
sealed source is unavailable, publication refuses it. Read/hold/observed-receipt
operations can still preserve and reconcile its saved evidence; do not hand-edit
source paths, pins or approval hashes to make publication proceed.

A planned source tag is preflighted before store writes and pushed alone, without
force, only after a store is verified live. Steam uploads retain observed build
IDs and still require branch/announcement receipts. Play retains edit/bundle/
track/commit phases and remains submitted until an observed receipt confirms a
non-draft live release; `baselineAdvancesOn: submitted` advances only the channel
comparison, never live evidence. Notes remain immutable and wait for shipment;
the separate availability record can change truthfully as held stores catch up.

Install and verify discovery without creating a release or chat:

```bash
<BA-Skills>/install.sh --skill ba-release --check-only
<BA-Skills>/install.sh --skill ba-release
<skill>/scripts/verify-discovery.sh --directory "/path/to/game"
```

`<skill>/scripts/install.sh` selects only ba-release and forwards the native
installer options (`--home`, `--check-only`). Inventory verification uses bounded
agent control protocols, sends no model prompt and creates no session.

For keyless Google Play, only when Play is selected and not held:

```bash
<skill>/scripts/google-play-auth.sh \
  --account '<approved-email>' \
  --service-account '<approved-service-account-email>' \
  --gcloud-config-directory '/existing/private/cache' \
  --gcloud-executable gcloud \
  -- <skill>/scripts/release.sh --mode publish --state-path '/approved/state'
```

The helper verifies the existing active CLI identity, refuses caches inside Git,
requests only Android Publisher scope from the fixed IAM host and exposes the
short-lived token only to that action. It never logs in or grants permissions.
Provider files and authentication secrets remain outside Git. A cache or provider
file is not authorization to publish or to grant new permissions.

Run `tests/release-linux/run-tests.sh` for local fixtures. Tests replace engines,
store tools and HTTP transport; they do not use real credentials, publish real
stores or run a release against a user's project. Actual exports, signatures,
remote permissions and console publication still require approved real release
verification; fixture coverage does not establish them.

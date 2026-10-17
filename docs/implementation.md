# ba-release architecture and verification

The canonical skill lives in skills/ba-release. User-level links load that same
directory in Codex and Claude Code. Native Windows uses directory junctions;
Linux/WSL uses symbolic links in the Linux user's directories. Installation
preflights every selected link and refuses conflicting files, folders, or links.

release.json belongs to the game repository. Validate its shape and its actual
Godot project, desktop/signed APK/AAB presets, repository paths, verification script
and origin. Steam app/depot IDs come from inspected SDK VDFs; Play package/code
come from the AAB preset. Branch, track, rollout and retained-code decisions are
explicit configuration facts, never agent defaults.
Do not infer publication from a version bump. Unconfirmed release boundaries and
upload targets remain null and block the relevant plan.

Doctor checks only selected local prerequisites with bounded engine version
probes, exact release templates and private Android signing presence. It performs
no exports, network/authentication operations or source writes; present credentials
and signing inputs remain distinct from verified access/signatures.

The optional Google Play auth helper uses an existing per-user CLI login and
service-account impersonation with the Android Publisher scope. It verifies the
active identity, keeps credential caches outside Git, sanitizes provider errors,
and restores the calling environment after the requested action. It does not
create accounts, grant permissions or authorize release publication.

Setup inspects the game and asks missing facts, applying only explicit validated
answers with an optimistic configuration hash. Plan emits JSON without writes,
verification, exports or network calls. It separates missing settings from source
edits. Explicit destinations, HEAD, config and frozen per-channel baselines
identify the plan. Prepare reserves chosen semantic-version settings and selected
Android preset counter changes independently once, requires their local source
commit, runs the complete game gate, and exports shared artifacts once. Standalone checks physically
withhold specific Steam files and verify Butler dry-run selections.
Windows state paths resolve Store app redirection through a native file handle,
making the returned path usable in WSL and external upload tools. Gradle exports
disable persistent daemons only in their own process environment and restore
existing or absent caller variables afterward.
Publish verifies the snapshot and exact plan/notes approval, then journals each
destination separately, including Steam build IDs and Play edit/bundle progress.
Explicit holds keep prepared destinations out of publication and retries without
store or credential calls. Their public reasons survive in availability records;
unhold reuses the approved artifacts and never rebuilds or increments counters.
Older prepared plans can acquire the inspected Android Gradle flag only when
every other saved plan field exactly matches fresh inspection. This compatibility
step preserves plan identity and approval; it cannot change targets or accept a
conflicting stored flag.
Complete plan comparison sorts JSON object keys while retaining every field,
primitive value and array order, so PowerShell hashtable enumeration does not
invalidate unchanged plans across processes.
Completed uploads/submissions are skipped on retry; observed console receipts
close activation/review/announcement work. Interrupted external
operations remain uncertain and require explicit reconciliation or retry.
Explicit extension adds destinations later without bumping the game version or
repeating completed uploads/exports. Canonical notes and submitted variants stay
frozen; new variants and artifacts require expanded approval. A later first Android
counter change retains the actual source commit for each existing/new artifact.
The live ledger advances only confirmed channels, preserving skipped-store ranges.
It is kept per GitHub repository rather than per checkout, so worktrees and clones
sharing a state root plan from what any of them published; ledgers kept per checkout before that are
read alongside, and records on diverged sources are refused rather than guessed.
Exact canonical public notes require shipped-release evidence; a separate owned
availability record describes staggered rollout through ordinary later commits.

`tests/run-tests.ps1` checks installer idempotence/conflicts (including native
Windows and WSL links), real-format Godot/Git fixtures, read-only file/index
invariance, malformed config and credential rejection, path/link boundaries,
explicit selection, same-version preparation and recovery, content-bound
approval, partial failures, Steam late/false success, Play edit replacement and
commit reconciliation, approval-bound console receipts, first-run setup,
version/counter reservations, shared APK/desktop exports, standalone checks,
per-channel baselines, later store inclusion and shipment-gated public records.
Executables and API
responses are local fixtures; the suite never publishes to a real service.

`scripts/verify-discovery.ps1` queries installed Codex's skills/list and Claude
Code's startup inventory without a model prompt. Run it after installation or
when agent discovery behavior changes. Skill frontmatter can also be checked
with the installed skill-creator validator. Actual game setup uses `validate`
and `plan` only; store adapters need authenticated verification at the first
approved release. Fixture success does not claim authenticated store or real-game
standalone functionality was verified during setup.

Setup must not execute prepare/publish against the game, create public notes
repositories, upload builds, or push commits. Tests use disposable local fixtures.

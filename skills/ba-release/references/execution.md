# Execution and recovery

Use `pwsh -NoProfile -File <skill>/scripts/release.ps1`. The following arguments
are passed after the script path. Comma-separated destination IDs work with
`pwsh -File`; an array also works when calling from PowerShell.

```powershell
-Mode doctor -Repository <game-root> -Destination steam,itch-windows,notes
-Mode plan -Repository <game-root> -Destination itch-windows,notes -VersionChange patch
-Mode prepare -Repository <game-root> -Destination itch-windows,notes -VersionChange patch
-Mode extend -StatePath <prepared-state-directory> -Destination google-play
-Mode extend -StatePath <prepared-state-directory> -Destination steam -MigrateConfiguration
-Mode status -StatePath <prepared-state-directory>
-Mode hold -StatePath <prepared-state-directory> -Destination google-play -HoldReason "Waiting for existing review to clear."
-Mode unhold -StatePath <prepared-state-directory> -Destination google-play -PlayTrackReviewed
-Mode publish -StatePath <prepared-state-directory> -ApprovedPlanId <displayed-id> -ApprovedNotesSha256 <displayed-notes-hash>
-Mode confirm -StatePath <prepared-state-directory> -ReceiptPath <observed-store-receipt.json>
```

`validate` checks schema and actual project files. `plan` emits JSON to stdout and
reads only local Git/project data. Exit codes: `0` successful, `1` invalid input
or precondition failure, `2` blocked plan/doctor, `3` incomplete preparation/publication.
Do not redirect plan output into the source repo during a read-only check.

## Runtime readiness

Run `doctor` with the same explicit selection before preparation. It inspects
source/configuration readiness, selected executable paths, a bounded Godot version
probe and that engine's release templates. Project `config/features` supplies the
engine major/minor requirement. Selected Android exports additionally inspect
Godot's configured SDK/JDK, release signing inputs and the Gradle project template
when applicable. Private credentials and keystore names/paths are never emitted.
Unselected destinations need no tools, signing inputs or authentication checks.

Host paths stay out of release.json. Supply `-GodotExecutable`,
`-ButlerExecutable`, `-SteamCmdExecutable`, `-GhExecutable`, `-TemplateRoot`,
`-EditorSettingsPath`, `-AndroidSdkPath` or `-JavaSdkPath` when discovery needs an
explicit override. Godot's normal Windows/Linux/WSL data paths and self-contained
editor mode are supported. This does not translate Windows tools into Linux tools.

The `release.ps1` CLI resolves relative executable overrides containing a directory
against the caller's working directory, once, before any mode runs. Fully qualified
paths stay unchanged, even when their drive is unavailable. The shared Git/GitHub
CLI, Godot, gcloud, Butler and SteamCMD lookup uses PATH for bare names, never an
implicit file in the game or state directory. On Windows it supports only `.exe`, `.com`, `.bat`,
`.cmd` and `.ps1`; association-only scripts are not waited processes.
Both tool execution and bounded probes receive closed stdin. They are non-interactive:
wrappers cannot wait on the agent's open input pipe; sign in separately beforehand.

Each check reports `passed`, `blocked`, `skipped` or `unverified`. `ready` means
no local blockers; `remoteAccessVerified` remains false. Presence of a token or
username cannot prove validity, store access or cached SteamCMD authentication.
SDK/JDK and signing presence cannot prove compatibility or a valid signature.
The complete project gate, real exports and store preflights still supply those
checks. Doctor makes no remote calls, login attempts, exports or source/state writes.
An engine whose version probe cannot start produces a blocked `godot-version`
check without discarding the rest of the report.

Steam and Butler publication errors retain library-generated reasons, including
missing executables/authentication inputs, upload exit codes and missing Steam
completion proof. Notes preflight uses the same policy for missing GitHub CLI,
availability-link, repository-access and conflicting-content checks.
Arbitrary tool output, private runtime paths and unclassified exception text remain
excluded from the release journal because they can contain credentials.

## Prepared destination holds

Use `hold` with explicit prepared destination IDs and `-HoldReason`. The reason
is single-line public availability text of 1 to 1000 characters; credentials,
control characters and private discussion do not belong there. The script rejects
credential-like values before journal writes and checks older reasons again before
publication. Holds survive ordinary
publish, retry and preparation. They preserve the sealed plan, notes, artifacts,
version and counter reservations. Held stores receive no credential checks or
API calls. Other approved destinations proceed independently.

Use `unhold` only after verifying the user's release condition has been met or
receiving explicit authorization to proceed. For Play, first inspect the current
live track and review active releases, rollout and `retainVersionCodes` with the
user. Pass `-PlayTrackReviewed` only after that review; unhold refuses Play without
it and records the acknowledgement. If the reviewed retention or release settings
need to change, stop and obtain a revised approved plan through the release workflow.
Do not edit the journal to bypass approval. An older unhold that still needs Play
publication must repeat `unhold -PlayTrackReviewed` before publishing. Already
submitted or completed Play destinations remain skipped on independent retries.
If an older unhold already attempted Play publication, the same acknowledgement
command records the review while preserving its failed, interrupted or uncertain
status, attempts and remote evidence. It performs no store calls and does not
authorize a retry; reconcile that attempt through the ordinary recovery workflow.

Unhold returns that destination to pending; overall `prepared` means at least
one selected destination is ready to resume, with other destinations retaining
their own statuses. Failures or interrupted operations take precedence; an
`in-progress`/`uncertain` destination keeps the overall `needs-reconciliation`
status. The next publish reuses the approved release and skips
completed stores. Neither hold command contacts stores. A definitive `failed`
destination can be held only after confirming there was no store-side effect and
its remote record contains only local `sourceCommit`/`notesHashes` bookkeeping.
Notes waiting for shipment can also be held. Store identifiers, phases, live or
ambiguous evidence, unknown remote fields, and `uncertain`/`in-progress` operations
require reconciliation. Attempts and recorded provenance are preserved. `on-hold` reports
remaining intentional holds once other selected operations have completed;
failures and outstanding console actions retain their own statuses.

Holding notes defers their publication. Their selected repository still receives
the read-only visibility, write-permission and canonical-content preflight before
any store upload. A failed preflight preserves the hold, records the failure and
blocks store publication; retry checks it again.

Release execution and tests require PowerShell 7.3 or newer so deserialized journal
objects preserve key order, retaining existing artifact approval hashes. See
[Microsoft's JSON ordering documentation](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/convertfrom-json#-ashashtable).
The installer itself remains compatible with PowerShell 7.2.

## Local preparation

Prepare requires explicit selection; omission returns a chooser without writes,
or prompts with `-Interactive`. Version operations are `patch`, `minor`, `major`,
`current` (default); plan previews the requested operation consistently in its
version, labels and notes paths. `sourceVersion` is the actual Godot setting;
`preview` identifies a projected version that still requires a source commit.
`exports` inventories configured presets; `requiredExports` lists only the union
needed for the explicit selection. Automatic bumps
require a plain semantic version; select prereleases explicitly in the project.
New version settings and each first selected Android preset's independent counter
increment are journaled before edits. `increment-selected` covers itch APK and
Play AAB independently; holding Play leaves its AAB counter unchanged.
Prepare returns `source-update-required` before checks/exports: review and commit
those settings locally, then repeat the same request. Retries reuse the reservation,
including interrupted file writes. `-NewRelease` explicitly starts a later bump
after the previous reservation is committed; ordinary retries never do.

With clean source, prepare runs the configured complete verification script,
then Godot's `--headless --path <project> --export-release <existing-preset>
<staged-filename>` for the union of selected itch, Steam depot and Play presets.
Each shared preset exports once. It writes into per-user state,
leaving existing `dist/` exports untouched. It exports no builds for a notes-only
selection. `-GodotExecutable` can specify an inspected engine when PATH does not
select the correct one; that machine-specific path is not release.json data.
Gradle exports append `-Dorg.gradle.daemon=false` to their process's existing
`GRADLE_OPTS`, then restore the caller's environment. This prevents an idle
Gradle child from keeping Godot's Windows console wrapper alive after export;
it changes neither the project's Gradle files nor other export processes.
It then runs selected itch desktops' standalone functionality checks with specific
excluded files physically unavailable, restores the common artifacts and checks
Butler `push --dry-run` output. `selection.<id>.txt` records the preview for review.
Supply `-ButlerExecutable` if needed. These checks do not upload; an ordinary push
is live publication and is approval gated. Failed checks prevent publication.
For Android, both dry-run and publication pass the signed APK itself to Butler.
The optional `.apk.idsig` sidecar remains in the sealed local artifact; additional
payload files require explicit distribution support rather than being discarded.

State defaults to `%LOCALAPPDATA%/ba-release/releases/` on Windows and
`${XDG_STATE_HOME:-~/.local/state}/ba-release/releases/` on Linux. `-StateRoot`
overrides it but must remain outside the source tree, including linked ancestors.
A native Windows file-handle lookup resolves Store app filesystem redirection
and links before returning the state path. Use that returned physical path for
WSL checks, browser uploads and agents outside the Store app; the logical Local
AppData path can point somewhere different in those processes.
A source identity/version
directory contains `state.json`, `notes.md`, build snapshots and an exclusive
lock. HEAD, config bytes, version, previous-release commit and sorted selection
identify the plan. A different plan for the same version is refused; resolve it
explicitly instead of bumping a version to retry. Do not edit state.json by hand.

## Extending a prepared release

`extend` explicitly adds destinations while retaining canonical notes, artifact
provenance, previous plan/approval history and completed operations. It exports
only missing presets and requires approval of the expanded plan/new note variants.
Source/config/version stay the same, except a first later Android inclusion may
reserve that new artifact's counter-only source change. Commit it before export; existing
desktops retain their original source commit. Unrelated source changes are refused
before any counter edit. Extend never bumps the game version. Repeat it after
failure to reuse added destinations. Use the original checkout/state to distribute
an older release instead of silently selecting newer source.

Ordinary `extend` works only when each added destination was already declared in
release.json when the release was prepared (or last migrated), and release.json is
unchanged since.
In every extension, each added destination's confirmed baseline must precede the
release's original source commit, never a later settings commit.
A store, or itch channel, first configured after preparation needs a configuration
migration. Add it through setup (see [configuration](configuration.md#adding-a-store-to-a-prepared-release)),
review the release.json diff with the user and commit it by itself. Then repeat
`extend` with `-MigrateConfiguration`. Without the switch, extend refuses and
names the destinations the change would add.

Migration accepts only additions: new destination IDs with their baselines, export
aliases, and standalone checks for presets that had none. It adopts every added
destination, selected or not, and freezes it with the release, so each one must
already be complete: a confirmed baseline that precedes the original source commit
and every setting its store needs. Leave a store that is not ready out of the
committed change and migrate it later. Migration refuses all of the following,
leaving state.json unchanged; prepare a new version instead:

- an uncommitted change, any other changed file, or source that does not descend
  from the prepared commit;
- any change to an existing destination or its baseline, root `previousRelease`
  (or the commit it resolves to), `verification.gate`, an existing standalone
  check, `androidVersionCodePolicy` or `project`;
- changed artifacts or published notes, as for any extension;
- a source or release.json change that arrives while migration runs: the saved
  plans must come from the exact commit and configuration it validated.

Migration reads the prepared release.json back from Git and checks it against the
recorded configuration hash; only line endings may differ. It appends the original
plan and approval to `history` with a `configurationMigration` record of both heads,
both configuration hashes and what was added. It then rebinds the original
selection to the new commit with its frozen baselines, and verification runs again.
An ordinary extension of the migrated release follows, including any counter
reservation for a newly configured Android store. If interrupted, repeat the same
command; it resumes from the last saved step. Publication needs approval of the
expanded plan.

## Approval, publication and recovery

Review the returned state path, plan, staged artifact manifest and notes. Replace
the raw commit draft in `notes.md` with reviewed player-facing text; retain its
source provenance comment. Each selected Play destination has a plain-text
`notes.<id>.txt` for its configured locale (1–500 characters); review it alongside
the full notes without silent truncation. `status` displays an approval digest of
all selected notes (the file SHA-256 when no Play destination is selected). First
publication requires approval of the concrete plan and notes plus both matching
hash arguments. Approval persists for unchanged retries and is bound to the
artifact manifest. Changed notes, added/deleted/changed build files, a dirty
source tree or changed HEAD/config invalidate publication. Reapproval cannot
change notes after a destination has started store publication.
Canonical text and already-started Play locale variants remain frozen across
extensions. Catch-up variants use the channel's older baseline and previous
approved canonical notes to cover changes its players missed. Inspect full diffs,
direct commits and reversions; raw titles are evidence rather than public claims.

Publication uses argument arrays, existing Butler/GitHub login and no stored
credentials. Butler receives `--userversion` from Godot and one `--ignore` per
pattern. Public notes preflight checks visibility, write permission and existing
canonical content before any selected store publication. It copies the exact
approved `releases/<version>.md` only after at least one store is actually live,
or a matching live receipt already exists; until then notes are `awaiting-release`.
Keep `[Release availability](../availability/<version>.json)` in canonical notes.
Separate owned JSON records live, held, submitted and pending destinations;
updates create ordinary subsequent commits. Re-run publish after console
confirmation to refresh availability without repeating uploads. Identical notes
count as complete; different
content is a failure. No source repository commit, tag or push operation exists
in this workflow. Publication of notes does create a commit in the public notes
repository, only after release approval.

Read [store operations](stores.md) for SteamCMD invocation, Play edit/track
publication, runtime authentication and required console steps. Override
`-SteamCmdExecutable` at runtime to point at the inspected SDK executable. The
test-only module transport injects disposable Play responses; the CLI always
uses the fixed Android Publisher host.

Play's reviewed text is also packaged locally as
`fastlane/metadata/android/<configured-language>/changelogs/<numeric-code>.txt`.
The adapter uses that same text; no fastlane command or listing update is
implicitly run. Steam's build description is internal version metadata; public
announcements remain a separate verified console operation.
Available browser tools can complete these approved console steps and supply
observed receipts; follow [browser completion](browser-completion.md). Missing
browser access or pending review remains an explicit incomplete state.

Retry `prepare` with the same repository and destination selection to reuse
verified exports. Retry `publish -StatePath <same-directory>` to reuse approval
and skip successful destinations. Failed local export output is retained in a
separate staging folder for inspection; only successful manifests can publish.

| Destination status | Meaning |
| --- | --- |
| `not-selected` | No operation requested for this destination. |
| `pending` | Prepared, awaiting approved publication. |
| `held` | Prepared but explicitly withheld; no store or credential operations occur until unheld. |
| `in-progress` | Journal saved before invoking the external command. |
| `succeeded` | External tool returned success, or existing public notes matched. |
| `awaiting-store-action` | Store upload completed; activation/announcement or draft publication still needs console work. |
| `awaiting-release` | Notes are ready but no matching store release is live yet. |
| `submitted` | Play edit committed; review/managed publishing/rollout still needs verification. |
| `failed` | The attempt failed; other destinations retain their own results. |
| `uncertain` | An external operation was interrupted; its remote outcome needs inspection. |

An interrupted `in-progress` operation becomes `uncertain` on resume and is not
automatically repeated. Inspect the remote channel/file before deciding whether
to retry. `-RetryUncertain` explicitly authorizes another attempt at the same
version after that inspection; require user authorization for that retry. A
failed command can also have ambiguous remote effects: reconcile before retrying
when needed. Repeating a note attempt recognizes already-published identical
content. A Butler success means the ordinary pushed update is available to players;
configured page labels can still need an Edit game action. It does not establish
untested runtime behavior. Steam/Play uploads remain separate from observed live
activation/review completion.

Overall status is `prepared`, `preparation-failed`, `published`, `on-hold`, `submitted`,
`needs-store-action`, `partial-failure`, `publication-failed`, or
`needs-reconciliation`, or `awaiting-release`. Report the
individual destinations and errors alongside that status. Never convert a
partial failure into a whole-release success claim.

An invalidated/expired Play edit can be replaced only with explicit
`-ReplacePlayEdit` authorization after remote reconciliation. Confirmed HTTP 404
is required; ordinary retries and other API failures never replace edits. The
same bundle/code/approval is retained. For uncertain operations combine it with
`-RetryUncertain`; see the store reference before authorizing this recovery.

Store completion uses a local `confirm` receipt after observing the actual
console result. It checks the plan and notes approval, unchanged artifacts,
matching app/build/branch or package/code/track/rollout, and store evidence URL.
It performs no remote writes or uploads. Only record what the user or agent has
actually verified. A receipt can also reconcile an uncertain store operation
whose exact remote result is known. See the receipt shapes in the store reference.
Overall `submitted` and `needs-store-action` preserve pending store work; only
all verified/completed destinations become `published`.

Local `live.json` advances only channels with live evidence, keyed by exact Butler
target, Steam app/branch or Play package/track. Held/submitted stores retain their
older baseline and the actual artifact source commit. Later plans use that baseline
for missed-change evidence; frozen plans keep their original baselines on retry.
Do not roll a channel backwards without explicit reconciliation. Canonical note
corrections belong in explicit subsequent public-repo commits, preserving history
instead of duplicate entries. The automatic writer refuses conflicting canonical
content and foreign availability files.

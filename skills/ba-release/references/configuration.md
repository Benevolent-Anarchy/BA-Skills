# Per-game release.json

Keep one human-edited JSON file at the source Git root. Schema version 1 groups
settings by store and maps short export aliases to exact existing Godot preset
names. Inspect the actual project before proposing values. Paths and executable
filenames come from `export_presets.cfg`; they are not repeated in this file.
PowerShell's built-in JSON support avoids another parser dependency.

Validation rejects unknown/duplicate keys, credential-like settings, escaping
paths and nonexistent presets. Valid configuration can still have planning
blockers, including deliberately unknown publication facts.

## Structure

| Field | Meaning |
| --- | --- |
| `schemaVersion` | Integer `1`. |
| `project` | Relative Godot directory inside the source Git root. |
| `previousRelease` | Confirmed previous published source commit/ref, or `null` until confirmed; must be an ancestor of the selected source when a release is first planned. Canonical notes count from the newer of this and the game's newest release in the shared live ledger, so it is needed only until a release is recorded there; a game whose earlier releases were recorded per checkout sets it once to its last release's source. |
| `exports` | Object mapping lowercase aliases such as `windows`, `linux`, `apk`, `aab` to distinct, exact inspected preset names. |
| `verification.gate` | `{script, arguments?}`: inspected repository-relative PowerShell script and string arguments, defaulting to `[]`. |
| `verification.standalone` | Shared `{exports, script, arguments?}` hook, or array of those objects for different scripts. `exports` contains aliases. An unknown script may remain `null`. |
| `distributions` | Store settings below. Declaring a store makes operations available; nothing is selected automatically. |
| `androidVersionCodePolicy` | Default `increment-selected`: reserve each selected Android preset's existing code + 1 once. `existing` preserves a separately managed valid scheme. Never derive codes by removing version dots. |

Godot `application/config/version` supplies the human-readable version. Operations
remain `patch`, `minor`, `major` and `current`; a retry or later destination
extension reuses the reserved version. Configuration cannot override that source.

Standalone hooks verify the same desktop exports without Steam files; they are
not a distribution. Arguments support `{artifact}` (directory), `{platform}`
(Godot platform), `{repository}` and `{filename}` (inspected export filename).
Scripts withhold Butler-excluded files, exercise the actual export, restore the
files, verify its hashes and check Butler's dry-run selection. Use meaningful
Windows and Linux checks; Windows startup alone is insufficient.

## Store settings and overrides

**itch:** `game` is an inspected `owner/game`, or `null`. Define `ignore` and
optional `displayNameTemplate` once, plus a `channels` object:

```json
"channels": {
  "windows": "windows",
  "linux": "linux",
  "android": "apk"
}
```

Keys are logical channel identifiers; values are export aliases. Destination IDs
are `itch-windows`, `itch-linux` and `itch-android`. A channel can instead be
`{export, channel?, ignore?, displayNameTemplate?, previousRelease?}`. Overrides
replace defaults, including empty arrays and explicit nulls:

```json
"linux": {
  "export": "linux",
  "channel": "linux-beta",
  "previousRelease": null
}
```

Logical identifiers use lowercase letters, numbers and hyphens. Remote channel
names may also use underscores and dots. Confirm existing channels or explicitly
approve proposed channels for manual-upload migration. A page URL identifies the
game, not its channels. Android on itch uses a signed APK.

Butler lists use specific basename patterns with `*` and `?`, without path globs,
`**` or character classes. Include the Steam exclusions:

```json
["steam_api*.dll", "libsteam_api.so", "libgodotsteam.*", "steam_appid.txt"]
```

Patterns become separate `--ignore` arguments. There are no obligatory staging
copies or separate itch desktop presets; other DLLs remain available. See the
[Butler manual](https://itch.io/docs/butler/pushing.html#appendix-c-ignoring-files).
Display templates support `{title}`, `{version}` and `{os}`, for example
`{title} {version} ({os})`. Butler has no display-name flag: the plan includes a
separate Edit game page action. Page labels do not control archive filenames.

**Steam:** configure inspected integer `appId`, explicit `branch` (or `null`),
optional common `exclude` (default `[]`) and a `depots` object. Each numeric depot
ID maps to a desktop export alias, or `{export, exclude?}` for an override.
Inspect actual Steamworks build files to map depots to exports. There is one
`steam` operation per app, retaining its build ID and separate activation and
public-announcement steps. A build description is internal metadata.

**Google Play:** configure `export` using a signed Gradle AAB alias, `track`,
`releaseStatus`, `language` and `retainVersionCodes`. Unknown facts may be `null`;
they block only selected Play releases. Status is `draft`, `completed` or
`inProgress`. Only `inProgress` uses optional `userFraction`, strictly between
zero and one. `language` is the project's verified BCP-47 notes locale.
`retainVersionCodes` is an explicit array of existing code strings; `[]` retains
none. Inspect the track first because its update replaces releases. Use one
edit/track per app per plan. Package name and code come from the preset.

**Public notes:** `"notes": true` makes `notes` available for explicit selection.
Its repository is derived from the configured GitHub origin as
`<owner>/<source-repo-name>-release-notes`, independently of the checkout folder.
Exact approved notes go to `releases/<version>.md` on the default branch, with a
separate availability record. The repository must exist, be public and permit
writing. Different existing content is not overwritten. Publish notes only after
a selected storefront is verified live.

## Single-store games

Declare only the stores a game uses. An itch-only game omits `steam`; nothing
Steam-specific is then planned, checked or required. Two itch rules still apply.
The itch `ignore` list must keep the four Steam patterns above, or validation
rejects it. Setup adds them, and when the export has no Steam files they match
nothing: the standalone check withholds nothing and the Butler dry-run passes.
Each selected itch desktop channel also needs a `verification.standalone` check
with an inspected script, or the plan blocks; it runs on the export as built.

## Baselines and source metadata

Each store may override `previousRelease`; an itch channel may override it again.
Omission inherits the enclosing baseline. Explicit `null` remains unknown and
never falls back. The live ledger tracks destination/channel history separately,
for every checkout of the game that shares a state root, and supplies subsequent baselines,
including stores that skipped versions. Null
does not mean publish all development history. First-ever releases need a
reviewed baseline policy.

The canonical notes, and the plan's top-level `previousCommit`, `changes` and
`changedFiles`, count from the newest of the root `previousRelease` and every
source the ledger records live for another version, on any channel, among the
selected source's ancestors. Each store's own catch-up range still runs from
its channel baseline. Two recorded sources that neither contains block the plan
as ambiguous until `previousRelease` names a commit containing both. A prepared
release keeps the boundary it was prepared with, even after its ref moves or is
deleted.

Paths resolve inside the repository, including link ancestors. Nested Godot
export paths may use `..` only when they stay inside the Git root. Do not commit
absolute machine paths or credentials. Windows file/product version overrides
must be empty or follow the source version (`.0` accepted). Android `version/name`
must be empty (Godot fallback) or match it. Reservation updates matching explicit
metadata and selected Android counters once; commit those source settings locally
before exporting. Scripts do not create source commits, tags or pushes. See
[execution](execution.md).

## First-run setup

```powershell
-Mode setup -Repository <root>
-Mode setup -Repository <root> -Destination steam,itch-windows
-Mode setup -Repository <root> -AnswersPath <answers.json> -ExpectedConfigSha256 <reported-hash>
```

Setup reports actual Godot/Git facts, a grouped proposal, missing questions and
explicit destination choices as JSON. It asks when project/preset mappings are
ambiguous. `-Interactive` gathers human answers; agents use reported questions
with their input tools. Nothing verifies, exports, bumps or contacts stores.

Answer keys use public dotted paths: `previousRelease`, `verification.gate.script`,
`verification.standalone`, `distributions.itch.game`, `distributions.itch.channels`,
`distributions.steam.depots`, `distributions.google-play.track` or
`distributions.itch.channels.linux.previousRelease`. Whole `exports` and
`distributions` objects are accepted. `stores` is an array of `itch`, `steam`,
`google-play` and/or `notes`; to change it later, see
[adding or removing stores](#adding-or-removing-stores). Objects and arrays use
JSON, not shell commands.

Before first configuring an itch game, or changing to another game, explicitly
confirm `distributions.itch.channels`; proposed mappings are not established facts.
Writes require validated explicit answers and the inspected configuration hash.
Invalid, secret or stale answers leave the file unchanged. `validate`, `plan` and
`doctor` read the same structure. Plan makes no network calls and cannot claim
remote permissions or publication have been checked.

## Adding or removing stores

Which stores `release.json` configures is a setup choice; which configured
destinations a release includes is chosen for each release. Setup reports the
configured stores as `stores.configured`, apart from the release `selection`.
Inspection never adds a store or selects a destination by itself. Asked about a
destination of a store the file does not configure, such as `-Destination steam`
for an itch-only game, it returns a `stores` question instead.

Interactive setup of an existing configuration starts with its stores:

```powershell
-Mode setup -Repository <root> -Interactive
```

Enter a store to add it, or a configured store with a leading `-`, such as
`-notes`, to remove it and its settings. A blank answer keeps the stores, and
adding one never removes another. After a change, setup asks for every missing
fact, including the new store's settings and its own baseline, then validates
the whole configuration and writes it once. For an itch-only game, answering
`steam` keeps itch and asks for Steam's `appId`, `branch`, `depots` and
`previousRelease`.

In an answers file, `stores` replaces the store list: name every store to keep
as well as the new ones, because `["steam"]` alone removes itch. This adds Steam
to a game that publishes on itch with notes:

```json
{
  "stores": ["itch", "notes", "steam"],
  "distributions.steam.appId": 1234560,
  "distributions.steam.branch": "default",
  "distributions.steam.depots": {"1234561": "windows", "1234562": "linux"},
  "distributions.steam.previousRelease": "v1.4.0"
}
```

Retained stores keep their whole settings, including channel overrides and
explicit `null` baselines. Existing export aliases, verification hooks and
`androidVersionCodePolicy` stay as they are, also when a store is removed. A
new store's facts start unknown (`null`), apart from proposed itch channels that
still need confirming, and it gets its own `null` baseline, which never falls
back to the shared one. Leave a fact blank to keep it unknown.

## Adding a store to a prepared release

A version prepared before a store was configured can still ship there. Answer
setup's `stores` with the complete retained list, such as `["itch", "steam",
"notes"]`, plus the new store's inspected settings and its own confirmed
`previousRelease`. Leave every existing setting as it is: a migration may only
add stores or itch channels, export aliases, and standalone checks for presets
that had none. Every added store is adopted, selected or not, so add only stores
whose settings and baseline are confirmed. Commit that release.json change by
itself, then run `extend` with `-MigrateConfiguration`.
[Execution](execution.md#extending-a-prepared-release) states exactly when
ordinary `extend` is enough and what migration refuses. Anything else needs a
new release.

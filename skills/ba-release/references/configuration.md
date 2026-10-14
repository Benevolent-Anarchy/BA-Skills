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
| `previousRelease` | Confirmed previous published source commit/ref, or `null` until confirmed; must be an ancestor of the selected source. |
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

## Baselines and source metadata

Each store may override `previousRelease`; an itch channel may override it again.
Omission inherits the enclosing baseline. Explicit `null` remains unknown and
never falls back. The live ledger tracks destination/channel history separately
and supplies subsequent baselines, including stores that skipped versions. Null
does not mean publish all development history. First-ever releases need a
reviewed baseline policy.

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
`google-play` and/or `notes`. Objects and arrays use JSON, not shell commands.
Changing stores preserves retained store objects, custom aliases, hooks and policy.

Before first configuring an itch game, or changing to another game, explicitly
confirm `distributions.itch.channels`; proposed mappings are not established facts.
Writes require validated explicit answers and the inspected configuration hash.
Invalid, secret or stale answers leave the file unchanged. `validate`, `plan` and
`doctor` read the same structure. Plan makes no network calls and cannot claim
remote permissions or publication have been checked.

## Adding a store to a prepared release

A version prepared before a store was configured can still ship there. Answer
setup's `stores` with the complete retained list, such as `["itch", "steam",
"notes"]`, plus the new store's inspected settings and its own confirmed
`previousRelease`. Leave every existing setting as it is: a migration may only
add stores or itch channels, export aliases, and standalone checks for presets
that had none. Commit that release.json change by itself, then run `extend` with
`-MigrateConfiguration`. [Execution](execution.md#extending-a-prepared-release)
states exactly when ordinary `extend` is enough and what migration refuses.
Anything else needs a new release.

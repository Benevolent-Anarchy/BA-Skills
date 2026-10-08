# Per-game release.json

Place this file at the source Git root. Inspect the game before proposing values.
Run `pwsh -NoProfile -File <skill>/scripts/release.ps1 -Mode validate -Repository
<root>`. Validation rejects unknown/duplicate keys and credential-like settings;
valid configuration may still have planning blockers.

## First-run setup

```powershell
-Mode setup -Repository <root>
-Mode setup -Repository <root> -Destination steam,itch-windows
-Mode setup -Repository <root> -AnswersPath <answers.json> -ExpectedConfigSha256 <reported-hash>
```

Without answers, setup reports actual Godot/Git facts, configuration proposals,
missing questions and explicit destination choices as JSON. It detects nested
projects and asks when multiple projects exist. `-Interactive` gathers human
answers, including questions exposed by choosing a new store. Agents use the
JSON questions with their user-input tools. No verification, export, bump or
store call runs. Writes require explicit validated answers and the inspected
hash; invalid, secret or stale answers leave the file unchanged.

Answer keys: `stores` (array of `itch`, `steam`, `google-play`, `notes`), `project`,
`previousReleaseRef`, `baseline.<destination-id>`, `<destination-id>.<field>`,
`verification.script`, `verification.arguments`, `standalone`, `exports`,
`destinations`, `androidVersionCodePolicy`. Arrays/objects use JSON, not shell
commands. Unknown facts may stay null; required IDs/mappings must validate.
Changing store choices preserves retained destinations' settings and policy.

| Field | Meaning |
| --- | --- |
| `schemaVersion` | Integer `1`. |
| `project` | Relative Godot project directory, inside the Git root. |
| `previousReleaseRef` | Actual previous published release source commit/ref; `null` until confirmed. Must resolve to an ancestor of HEAD. |
| `exports` | Exact existing Windows/Linux desktop and signed Android APK/AAB preset names. Paths and filenames come from export_presets.cfg. |
| `verification.script` | Existing, inspected PowerShell verification script, relative to the Git root. |
| `verification.arguments` | Array of string arguments for that script. No shell command strings or credentials. |
| `destinations` | Array of entries described below. Nothing is selected by default. |
| `destinationBaselines` | Destination IDs mapped to last **live** source refs or null. New setups include this map; the live ledger supplies future baselines. Frozen plans retain the initial comparison. Legacy configs fall back to previousReleaseRef, so confirm per-store history when adopting the map. |
| `androidVersionCodePolicy` | `increment-selected` reserves each selected Android preset's own code + 1 once; held APK/AAB counters remain unchanged. New setup uses this policy. `increment-once` preserves the older Play-only behavior. `existing` preserves a separately managed valid scheme; omission means existing for compatibility. Never derive the counter by removing version dots. |
| `standalone` | Array of `{preset, script, arguments}` checks for itch desktop exports. A null unknown script blocks its selected desktop. |

Paths resolve within the repository, including link ancestors. Output paths may
use `..` from a nested Godot project when the result remains inside the Git root.
Absolute machine paths are not committed. Godot `application/config/version` is
the version source; release.json cannot override it. Version format is three
numeric components with an optional prerelease/build suffix.

A Butler entry has `id`, `type: "itch"`, `preset`, `target`, and `ignore`.
Use an exact `owner/game:channel` target, or `null` until verified. IDs identify
individual destination/channel operations so one platform's failure cannot hide
another's success. Presets must also occur in `exports`.

Itch Android uses a signed APK; Play uses a signed Gradle AAB. Optional
`displayNameTemplate` supports `{title}`, `{version}`, `{os}`, for example
`{title} {version} ({os})`. The plan includes the approved page label and a
separate Edit game action. Butler has no display-name flag; page labels do not
control downloaded archive filenames. A page URL confirms owner/game, not a
channel; manual-upload migration requires explicit new channel names.

`ignore` contains basename patterns with `*` and `?`; no path globs, `**`, or
character classes. Each Butler entry must include these Steam exclusions:

```json
["steam_api*.dll", "libsteam_api.so", "libgodotsteam.*", "steam_appid.txt"]
```

These are passed as separate Butler `--ignore` arguments; staged and source
builds retain their files. Check the target build's non-Steam behavior before
approving it. The [Butler manual](https://itch.io/docs/butler/pushing.html#appendix-c-ignoring-files)
documents pattern semantics and dry-run inspection.

A public notes entry has only `id` and `type: "notes"`. The script derives
`<owner>/<source-repo-name>-release-notes` from the credential-free GitHub origin,
independently of the source checkout's local folder name. Publication creates
`releases/<Godot-version>.md` through GitHub's contents API in the repository's
default branch. The repository must already exist and be public. It never
overwrites different existing content or silently creates a repository.

A Steam entry has `id`, `type: "steam"`, the inspected integer `appId`, `branch`
(explicit name or `null`), and `depots`. Each depot has inspected integer `id`,
an existing configured desktop `preset`, and `exclude` basename patterns. Read
existing Steamworks AppBuild/DepotBuildConfig files to map content roots to the
game's actual exports; do not commit absolute SDK paths or copy login config.
There is one Steam destination per app, with all selected depots in one build.

A Google Play entry has `id`, `type: "google-play"`, a configured signed Gradle
AAB `preset`, `track`, `releaseStatus`, `userFraction`, `language`, and
`retainVersionCodes`. Unknown publication fields stay `null` and block selected
plans. `releaseStatus` is `draft`, `completed`, or `inProgress`; only `inProgress`
uses a numeric fraction strictly between zero and one. `language` is the verified
BCP-47 notes locale. `retainVersionCodes` is an explicit array of existing version
code strings; `[]` deliberately retains none. Inspect the actual track before
choosing it; the API track update replaces its releases. One edit/track per app
per plan avoids edits invalidating each other.

The Android package and integer version code come from preset options. The
preset must use Gradle AAB format, signing, and an `.aab` export path. Its
`version/name` must be empty (Godot project fallback) or equal the Godot version.
Existing Windows file/product version overrides must be empty or follow the
source version (a trailing `.0` is accepted). Reservation updates explicit
metadata already following the old version. Android code reservation is journaled
before source edits and reused on retries. Commit those settings locally before
exporting; a conflicting consumed code is reconciled separately, never silently
changed during publication recovery. See [execution](execution.md).

Standalone arguments support `{artifact}` (export directory), `{platform}` and
`{repository}`. Supply an inspected script exercising relevant exported-game
functionality on the actual OS; exit zero means success. Checks physically
withhold exactly the Butler-excluded files, restore them, then verify the complete
common artifact and Butler dry-run selection. There is no separate itch desktop
preset or obligatory copy just to remove Steam files. Keep other DLLs. Linux needs
its own working checking route; Windows startup is insufficient.

Other destination types are rejected until a tested adapter is implemented.

Do not infer a release boundary from version history alone. Confirm the source
commit of the last published release, or a release tag that points to it. A
first-ever release needs a separately reviewed baseline policy; null does not
mean all history. Complete Git history is required. Plan reports local edits
separately; preparation/publication require reviewed, committed source.
It performs no network calls and does not claim that remote
repositories, credentials or channels have been checked.

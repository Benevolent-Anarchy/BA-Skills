# Store publication and observed completion

Every published store belongs in the game's configuration. Selection remains
explicit on each plan; public notes are a separate selectable destination.
Inspect store state before approval. A local plan validates project facts and
does not claim remote targets, login, review state or retained releases are checked.
Use [browser completion](browser-completion.md) for approved console operations
when browser tools and account access are available. A console requirement does
not automatically require the user to perform the clicks.

## itch.io

Use each configured Butler target and the shared desktop artifact. Specific
`--ignore` patterns remove Steam files during upload; the standalone check and
Butler dry-run must pass first. Android uses the game's signed APK preset.
Butler gets Godot's `--userversion`. An ordinary push makes the update available
to players; it is never a harmless staging step before approval. See the
[Butler manual](https://itch.io/docs/butler/pushing.html).

Optional display names are resolved from project title/version/platform. Set
that exact label on Edit game after the push. Butler's
[push options](https://github.com/itchio/butler/blob/master/cmd/push/push.go) have
no display-name parameter, and the [maintainer's explanation](https://github.com/itchio/butler/issues/174#issuecomment-456374195)
distinguishes page labels from downloaded ZIP filenames. The journal records the
upload as live, with `awaiting-store-action` until the label is observed.

Use a common approval-bound `confirm` receipt with `destination`, `planId`,
`notesSha256`, `observedAt`, `live: true`, plus `target`, `displayName` and
`evidenceUrl` (the exact `https://<owner>.itch.io/<game>` page). Observe the live
slot and label; do not fabricate this receipt. The exact approved target/label
and recorded live upload are required. Manual uploads are not assumed to have
Butler channels; approve new channels explicitly when migrating them.

## Steam

Inspect existing Steamworks app/depot VDFs and match their ContentRoots to real
Godot desktop exports. Publication generates new VDFs under the release state,
using only prepared artifacts, approved IDs/branch and inspected exclusions.
Original SDK scripts are untouched. Supply the installed SteamCMD executable
with `-SteamCmdExecutable`, and the existing account name through runtime
`BA_STEAM_USERNAME`. Establish cached SteamCMD authentication separately; never
put a password, Guard code or login config into the skill/config/arguments.

The adapter requires an AppID/BuildID completion record as well as a zero exit
code. Completion followed by a nonzero exit retains that build ID as `uncertain`;
ordinary resume does not reupload it. After reconciliation, `-RetryUncertain`
resumes its console work using the known build. It records the build ID and
Steamworks build page, then returns
`awaiting-store-action`. For a selected beta branch it includes `SetLive`; for
`default`, Steamworks requires activation through the app admin panel. Verify
the exact build on the approved branch, then publish the approved `notes.md`
text as a Steam announcement through Steamworks Events & Announcements. Verify
the announcement URL and any scheduled publication before recording completion.
Console publication is covered by approval of the displayed destination and
notes, and still requires any ordinary account permissions.

These constraints and VDF keys follow the
[SteamPipe upload documentation](https://partner.steamgames.com/doc/sdk/uploading).
An uploaded build alone does not establish live activation or announcement.

After observing both, create this receipt under the release state and run
`release.ps1 -Mode confirm -StatePath <state> -ReceiptPath <receipt>`:

```json
{
  "destination": "<configured Steam ID>",
  "planId": "<approved plan ID>",
  "notesSha256": "<approved notes digest>",
  "observedAt": "<actual observation timestamp with timezone>",
  "live": true,
  "appId": 123,
  "buildId": "<observed build ID>",
  "branch": "<approved branch>",
  "announcementUrl": "https://store.steampowered.com/news/app/123/view/<observed ID>"
}
```

These are receipt placeholders, not project defaults. Steam Community game
announcement URLs are also accepted when their app ID matches.

## Google Play

Use the existing signed Gradle AAB preset. Godot's empty Android version name
[falls back to the project version](https://docs.godotengine.org/en/stable/classes/class_editorexportplatformandroid.html).
The API verifies the staged bundle SHA-256 and preset version code. With the
configured increment-selected policy, preparation reserves the existing AAB code + 1
once when Play is first included, independently of semantic version. Commit
those source settings before export. Publication, failure recovery and retries
never increment it. The itch APK uses its own independently selected counter.
Holding Play leaves the AAB counter, account, review and listing
alone. A pending review is inspected before any authorized Play edit/recovery.

At publication supply `BA_GOOGLE_PLAY_ACCESS_TOKEN` only in the process runtime,
from an authorized Android Publisher OAuth account. Never commit or copy tokens,
service-account JSON, keystores, signing passwords or credential-bearing logs.
The adapter calls only `androidpublisher.googleapis.com` over HTTPS and stores
sanitized operation status, edit ID, bundle hash/code and track metadata.

Confirm the app already exists in Play Console, and no other edit for this
account is being worked on: [creating an edit invalidates its previous open
edit](https://developers.google.com/android-publisher/edits). Confirm the exact
track, rollout status/fraction, note locale, and version codes that must be
retained before approval. Updating a [track replaces its release
list](https://developers.google.com/android-publisher/api-ref/rest/v3/edits.tracks).
An explicit empty retained-code array is a deliberate replacement, not a guess.

The script reuses its saved edit and an identical previously uploaded bundle,
updates the approved track with the reviewed locale text, validates the edit and
commits using `changesInReviewBehavior=ERROR_IF_IN_REVIEW` so it cannot silently
cancel existing review work. See the [commit API](https://developers.google.com/android-publisher/api-ref/rest/v3/edits/commit?hl=en).
If the commit response is lost, status stays `uncertain` and is not automatically
retried. Inspect Play Console/edit state before `-RetryUncertain`; an expired or
committed edit is not silently replaced with a new edit or version code.

If the saved edit is confirmed missing (HTTP 404), separately authorize
`-ReplacePlayEdit` after inspecting the remote track and ensuring no other open
work will be invalidated. For an uncertain operation also supply
`-RetryUncertain`. Replacement retains the old edit ID/phase, original artifact
hash, Android code and approval. It creates a new edit only after that confirmed
404, then [lists bundles](https://developers.google.com/android-publisher/api-ref/rest/v3/edits.bundles/list)
and reuses an identical existing code/hash. Conflicting hashes fail without a
bump. A fresh edit that already matches the deployed approved track/notes is
recognized without another commit; its unused edit is deleted. Otherwise the
original approved change resumes. Replacement is refused for authentication,
network errors or a still-valid edit. Normal retries never authorize it.
Failed inspection-edit cleanup is recorded separately; it never changes the
proven deployed match into a publication failure or triggers resubmission.

A successful non-draft commit returns `submitted`. Verify review completion,
managed publishing and the actual approved track/rollout in Play Console, taking
any remaining approved publication steps there. A draft stays
`awaiting-store-action`; committing a draft is not approval to promote it to a
different status/track. Approval of a new publication intent must precede that
promotion. Record live completion only after the console actually shows it:

```json
{
  "destination": "<configured Play ID>",
  "planId": "<approved plan ID>",
  "notesSha256": "<approved notes digest>",
  "observedAt": "<actual observation timestamp with timezone>",
  "live": true,
  "packageName": "<inspected package>",
  "versionCode": 123,
  "track": "<approved track>",
  "releaseStatus": "completed",
  "userFraction": null,
  "evidenceUrl": "https://play.google.com/console"
}
```

For an approved staged rollout use `inProgress` and its observed approved
fraction. A console receipt records an observation; it does not itself query or
publish to the store. The journal must already hold the matching API-verified
bundle hash/code and commit or deployed-track evidence; early interruptions need
adapter reconciliation before confirmation. Steam also requires its recorded
build ID. Confirming a draft as live is refused.

Notes locales come from release.json. Reviewed text is also packaged as
`fastlane/metadata/android/<language>/changelogs/<version-code>.txt`, following
the [fastlane changelog convention](https://docs.fastlane.tools/actions/upload_to_play_store/#changelogs-whats-new).
The implemented Publisher adapter submits the same text without invoking fastlane
or changing other listing metadata. Approve canonical notes first, then review
shortening/translation and catch-up evidence from this track's last-live baseline.

## Public release record

The current repository suffix is `-release-notes`. Canonical approved text is
copied exactly to `releases/<version>.md` only after live-store evidence. The
separate `availability/<version>.json` states which stores are live, held or
pending; it does not imply simultaneous rollout. Preflight verifies public
visibility, write permissions and conflicting canonical content before selected
stores start. Retries recognize identical notes. Availability updates preserve
history through later commits; different canonical content is not overwritten.
Steam activation/announcement and Play review are separately observed; leave
ready-to-use local documents and report outstanding console work.

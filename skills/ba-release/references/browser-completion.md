# Browser completion

Use available browser tools for store operations that the adapters leave pending.
This continues the same approved release; it does not start another build, bump,
upload or independent release. Keep deterministic operations and receipt
validation in the scripts. Browser controls and login access depend on the
current agent environment. Keep agent-specific connection requirements in their
explicitly scoped sections while sharing the release workflow.
Every agent must apply the shared [Chrome account guard](../SKILL.md#chrome-account-guard)
before every Chrome step: read the signed-in email in a new
`https://myaccount.google.com` tab, close it, and act only in the profile signed
in as `cicely@benevolentanarchy.com`. Stop Chrome work if it does not match or
cannot be verified. Profile-name and connection-selection details never replace
this check. [For Claude Code](../SKILL.md#for-claude-code) contains only Claude's
preferred-device selection details; Codex uses the same shared account guard.

Run `release.ps1 -Mode status -StatePath <state>` first. Use its sealed selection,
approval, version, store identifiers and recorded remote results. Read
[store operations](stores.md) for the receipt fields and required console states.
Only act on selected destinations. Before publication, the displayed plan and
canonical notes must already have the user's approval, including the intended
branch, track, rollout and announcement. That approval covers the corresponding
console steps; do not request it again for the same approved operation. A changed
destination, rollout or publication intent needs a revised plan and approval.

Use the agent's supported browser connection and the user's authorized store
session in their designated BA/work Chrome profile. Inventory connected profiles
and bind the actual matching browser/profile identity; a browser named Chrome,
the first connection, or the only available profile does not establish that it
is the BA profile. A profile previously identified in this session is a candidate,
not an exemption from checking its current signed-in account before acting.
For the current BA installation, that profile is `benevolentanarchy.com`.
Use its returned profile name and current connection identity to locate the
candidate, then verify its account. Do not persist numeric browser IDs. Codex
and Claude connections are verified separately:
see [connection verification](installation.md#browser-connection-verification).
If it is not exposed, ask the user to open/connect the BA profile through the
current browser integration. Do not use the private profile as a fallback or copy
credentials/cookies between profiles. Re-inventory after a connection change;
runtime browser IDs are not permanent configuration.

Inspect the current page and exact game before choosing controls; do not
rely on saved coordinates or assumed page structure. If tools, account access or
required permissions are unavailable, report that specific gap and leave the
ready-to-use notes and identifiers for the user. Request user participation for
authentication or security challenges when needed; never store credentials or
session material in configuration, notes, receipts or screenshots retained with
the release. Browser access does not imply permission to change account settings.
Browser sign-in does not establish Butler, SteamCMD or Publisher API authentication;
use their authorized runtime login separately, without extracting browser session
secrets into the release scripts.

## Steam

Open the approved app's Steamworks build page. Match the recorded BuildID and
approved branch before activating it. Verify the branch now points to that exact
build. Publish the approved canonical notes through Events & Announcements,
preserving their claims when formatting. Inspect existing announcements first
on retries to avoid duplicates. Verify the resulting public announcement URL and
actual publication, rather than merely a saved draft or scheduled event. Record
both the observed activation and announcement in the Steam receipt.

Steam's documented operations are [build activation](https://partner.steamgames.com/doc/sdk/uploading)
and [Events & Announcements](https://partner.steamgames.com/doc/marketing/event_tools).

## itch.io

On the approved game's Edit game page, identify the Butler-managed slot for the
exact channel. Set its approved display label and save, then verify that label
on the public game page. Do not rename an unrelated manual upload or remove
existing uploads as part of this step. The receipt records the observed target,
label and public game URL. Changing a slot label does not rename its downloaded
archive. Uploads still go through the prepared Butler adapter and its exclusions.

## Google Play

Open the exact package and approved track in Play Console. Match the recorded
numeric version code, release and rollout. Inspect review and managed-publishing
state before taking any remaining approved publication step. Never cancel or
replace existing review work, change retained versions or alter rollout to make
the release appear complete. If changes are still in review, report `submitted`
with that reason; browser use cannot finish Google's review. If approved changes
are waiting for managed publishing, inspect the entire pending change set before
publishing: unrelated queued changes are outside this release's approval.

Verify the approved release is actually live on the intended track and rollout
before recording a Play receipt. A console label such as ready-to-publish is not
live evidence. The receipt still requires the adapter's matching bundle/code and
commit evidence; browser actions cannot bypass that prerequisite.
See [Play review and managed publishing](https://support.google.com/googleplay/android-developer/answer/9859654?hl=en).

## Record and resume

After observing the required results, save a factual receipt under the release
state and run `release.ps1 -Mode confirm -StatePath <state> -ReceiptPath <receipt>`.
Include the approved plan ID, notes digest, actual observation timestamp and
observed identifiers/URLs. Never manufacture evidence to clear a pending status.
If only part of a console step completes, preserve its evidence locally and report
that progress while leaving the destination pending. On retry inspect that result
first rather than repeating it.

Run `status` again to verify the recorded result. Re-run `publish` with the same
state to update the public availability record after confirmation; completed
store operations remain skipped. Keep browser failures, missing access and review
delays distinct from failed uploads. During installation/setup these procedures
are read-only: do not activate builds, edit public labels or publish announcements.

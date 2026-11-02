# Keyless Google Play authentication

Read this only when Google Play is selected and an Android Publisher token is
needed. Holding Play must not run this setup or contact Google.

Reuse an authorized provider if one exists. For a keyless Google CLI login,
inspect the game's actual Cloud project and Play app. A service account needs
Play permissions for that app: view app information and the selected release
track. Production permission can include dependent policy and deep-link grants
in Play Console. Leave account-wide, finance, user administration and unrelated
apps unselected. Give the approved human identity Service Account Token Creator
on that service account, with no broad project role for the uploader. Enable
Android Publisher and IAM Credentials APIs only as authorized.

New security access and API agreements need the applicable tool's confirmation.
Present the exact project, service account, identity and permissions together.
Use the shared Chrome account guard throughout console setup. Do not download
a service-account key, weaken an organization key policy, or copy browser
cookies into a script. Device/passkey verification remains a user action.

Install the official Google Cloud CLI. Keep its credential cache outside Git,
separate from existing user logins. HWB's setup uses `~/.config/ba-release/gcloud`. Set `CLOUDSDK_CONFIG` for the login
process and authenticate the explicitly approved account. Avoid overwriting
Application Default Credentials. Open OAuth URLs through the verified BA
profile; do not let a default-browser launch select the private profile.
The CLI's loopback callback can complete authorization without copying its
authorization code or tokens through the agent conversation.
Keep credential-free provider arguments in a private per-user runtime file when
needed across agents, outside Git. HWB's approved provider is recorded at
`~/.config/ba-release/google-play/How-to-Wait-for-the-Bus.json`. It contains only
the helper's account, service account, actual cache path and CLI path; the CLI
owns its separate credential cache. Do not treat an arbitrary profile file as
authorization to grant new access, and do not copy its paths into release.json.

Wrap the selected operation with `scripts/google-play-auth.sh`, taking the
values from the inspected private provider file where one exists:

```bash
<skill>/scripts/google-play-auth.sh \
  --account '<approved-email>' \
  --service-account '<approved-service-account-email>' \
  --gcloud-config-directory '<existing-private-cache>' \
  --gcloud-executable '<installed-gcloud>' \
  -- <skill>/scripts/release.sh --mode doctor --repository <game> --destination <selected-ids>
```

The helper checks the active CLI identity, refuses a cache inside Git, then
requests a one-hour token from the fixed IAM Credentials host with only the
Android Publisher scope. It makes that token available to the action alone, as
`BA_GOOGLE_PLAY_ACCESS_TOKEN`, and sanitizes provider errors. It neither logs in
nor grants permissions.

Use a fresh invocation before an approved publish/resume; never persist the
token or set a dummy token to satisfy doctor. Authentication alone authorizes no
release, upload, listing edit or review cancellation. A read-only access probe
can list generated-APK metadata for a known existing bundle code without
creating an edit. Successful read access does not prove an untested upload.
Expiry during a long operation remains an ordinary adapter failure; reconcile
the recorded remote result and resume with fresh credentials and the same
version, artifact and approval.

Primary references: [Play API setup](https://developers.google.com/android-publisher/getting_started),
[short-lived token method](https://docs.cloud.google.com/iam/docs/reference/credentials/rest/v1/projects.serviceAccounts/generateAccessToken),
[generated-APK read method](https://developers.google.com/android-publisher/api-ref/rest/v3/generatedapks/list).

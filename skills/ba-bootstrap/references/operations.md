# Bootstrap operations

## Outcomes and recovery

| Result | Meaning and next action |
| --- | --- |
| `ready` | Read-only preflight succeeded; creation still needs an actual user request. |
| `complete` | Required phases have verified receipts. Status rechecks remote identity/settings; browser/app receipts retain their observation time. |
| `partial` | Some work succeeded. Explain the reported pending items; repair that concrete condition and resume by name/owner. |
| `blocked` | Conflicting paths, inputs, identity, access or state. Preserve existing material and explain the specific conflict. |
| `identity-unconfirmed` | A create result was lost or unresolved. An observed name/ID alone cannot bind that repository to this invocation. Ask Cicely to resolve the named repository and ID; do not clear the journal or retry automatically. |
| `missing-input` | Collect the listed inputs; no creation has started. |

Creation journals live under `%LOCALAPPDATA%/BA-Skills/ba-bootstrap/state/`; vault journals are separately keyed by actual vault path under `vaults/`. Use the result's exact `journalPath`. These files contain identity, generated hashes, returned repository IDs and phase/ref receipts, never authentication tokens. Atomic snapshots and an exclusive lock protect retries. Preserve unreadable or incompatible journals; use a matching skill version or resolve the concrete conflict before continuing.

`plan` and `status` inspect without creating state, repositories, checkouts or plugins. `resume` restores the original inputs. A recorded-ID retry reuses both repositories; lost push/README responses are checked by ref/content readback. A completed invocation preserves later project development. Do not force-push, stage unrelated files, replace differing README content, or delete partial results as cleanup.

A definitive repository-create rejection (HTTP 4xx except timeout 408) is recorded as `failed`, with GitHub's status, message and error details. Correct the reported policy/access/validation condition, then explicitly resume with the stored inputs. Preflight must still find the rejected name absent; an existing repository is a collision, never adopted. Transport loss, timeout, server failure or a malformed success leaves `creating` unresolved and requires identity recovery instead of another POST.

If the initial commit succeeded before its SHA was journalled, preflight can recognise it only in the recorded checkout/origin on `main`: it must be a single root commit with exactly the manifest paths and matching blob hashes, backed by the validated local foundation bytes. `plan` remains read-only. `resume` records that existing SHA under the journal lock and continues without another commit. Extra files, changed blobs or additional history remain blocked.

The generated documentation gate checks Markdown links in root-level `.md` entry points as well as the vault notes. Root links resolve from the repository root; topical index and record requirements apply to their existing vault corpora. Broken links report the source file and line.

Preflight renders the foundation, including the supplied description, in a disposable temporary directory and runs that same documentation validator before creating either repository or a journal. The directory is removed after validation. A broken description link reports `blocked`; correct the description and plan/create again. Local links must resolve within the initial foundation, while external links remain allowed.

After bootstrap is complete, use `local-setup -Repository <actual checkout> -RefreshPlugins` for a deliberate plugin update. Creation/resume rejects a refresh request on a completed journal with that concrete instruction; it does not report an ignored update as successful.

## Public release-notes repository

The public companion contains only its initial README, has `main`, remains writable by its owner and is never archived. Issues, wiki, projects, discussions, auto-merge and Actions are disabled through supported APIs and read back. Pages must be absent. The current update API and repository readback omit the legacy `has_downloads` field; its omission is not an enabled contribution feature. Private description/canon never belongs here.

GitHub's [current repository API](https://docs.github.com/en/rest/repos/repos#update-a-repository) supports `has_pull_requests`. When repository readback exposes it, the helper disables and verifies it; status checks that it stays disabled. If a host omits the field and the result says `needs-browser`, use authenticated browser tools for the exact public repository's **Settings → General → Features** page. Uncheck **Pull requests**; reopen/read the page and verify the unchecked state. If browser access is unavailable, keep that phase pending. Check the live surface for optional contribution/automation features; preserve security protections and owner publication access. Record any additional setting verified there in the trial receipt.

Record the actual browser observation through the helper; this is an agent operation, not a user prompt:

```powershell
Import-Module ./scripts/Bootstrap.psm1 -Force
Import-Module ./scripts/State.psm1 -Force
$identity = Get-BootstrapStoredIdentity -Name 'Foo Bar Baz'
# repositoryId must be the observed/journalled public ID; observedAt is the actual readback time.
$evidence = @{repositoryId=$observedRepositoryId; disabled=$true;
    sourceUrl="https://github.com/$($identity.notesFullName)/settings";
    observedAt=$observedAt}
Set-BootstrapBrowserEvidence -Identity $identity -Setting pullRequests -Evidence $evidence
```

The helper checks identity against both the journal and GitHub. A URL, timestamp or presumed API success does not prove the UI setting. Status labels this as stored browser evidence, not a fresh API check. Resume after readback to finish any remaining phases.

The existing `ba-release` tooling derives this companion from the private repository's GitHub origin plus `-release-notes`. Bootstrap supplies that repository; engine exports, `release.json`, store IDs and release publication belong to their later setup/release workflow.

## Obsidian installation and app checks

The curated IDs are `dataview`, `mermaid-popup` (Diagram Popup), `vault-inspector` and `vault-nickname`. Resolve their repositories from the official community registry. Choose the newest published non-draft, non-prerelease release with consistent required assets and manifest ID/tag/version. Report every skipped inconsistent release and reason. A network failure is unresolved transport, not a reason to downgrade. Dataview's 0.5.70 release was found to contain a 0.5.68 manifest; the approved fallback reports that skip and selects a consistent release.

Verify minimum-app compatibility, `manifest.json`, `main.js` and an optional published stylesheet. Installation stages outside active plugin directories; refresh retains preferences and backups and restores prior binaries if promotion fails. An interrupted refresh retries its recorded releases. Ordinary setup preserves extra plugins, existing settings, nickname customisation and workspace/history. `.obsidian` must be ignored and untracked in the actual checkout.

Carry each selected asset's published [GitHub SHA-256 digest](https://docs.github.com/en/rest/releases/assets) in the release journal and verify the staged bytes before promoting any plugin. A mismatch preserves the active installation; interrupted retries use the recorded digest rather than fetching replacement metadata. Plugin receipts report `digestVerification` as `verified`, `partial` or `unverified-by-digest`, with `assetsWithoutDigest` naming any missing proofs. Older releases without digests still install and must be reported explicitly. Ordinary setup rechecks matching-version journalled assets; app-managed versions without a matching release record remain unverified by digest and are preserved.

Compatibility uses the running app's official CLI version when available, otherwise the newest numerically valid `obsidian-<version>.asar` in the application cache. The executable's product version is the installer version and cannot establish app compatibility. If neither source is available, installation may proceed but compatibility/app verification stays pending.

New vaults use **Files and links → New link format → Absolute path in vault** and **Automatically update internal links** so editor-created wikilinks match the gate's vault-root paths. Use exact file and directory casing; the gate rejects links that only work through Windows' case-insensitive lookup. Existing vaults retain their preferences: set these two options manually if needed and update old shortest-path links to explicit vault-root paths.

Dataview's normal queries remain available; DataviewJS and inline DataviewJS start disabled. Canon does not require JavaScript execution from notes. Enable either setting only as a deliberate project-specific choice. Existing clones retain their Dataview settings; disable both JavaScript options manually if adopting these defaults.

Vault Inspector exports stay in the preset's `Vault Inspector Reports` folder under `docs/`. The generated ignore rule and gate exclude that exact folder; reports are local tooling output. Move durable conclusions to the appropriate canon or Issue. The plugin's [Markdown exporter](https://github.com/rogerdigital/vault-inspector/blob/HEAD/src/report/markdown-export.ts) includes finding messages and link evidence, which should not become project records by accident. Existing clones retain their plugin preferences: ensure the report folder is `Vault Inspector Reports`, add `docs/Vault Inspector Reports/` to the project's `.gitignore`, and adopt the updated gate. If you choose another export folder, ignore and exclude it explicitly as well. Preserve any previously tracked reports and review their removal from tracking separately.

Installed files and configured IDs are separate from loaded plugins. When the official CLI is registered/enabled and the exact vault is registered, the helper addresses its ID, enables the plugins and reads back loaded IDs/versions. Never use the foreground vault as a substitute. Without that app access, report the exact first-use step: open this project's `docs` as a vault, enable Community plugins and all four plugins, then rerun local setup/resume for supported readback. Do not edit the global vault registry to simulate registration.

On first use, Obsidian may ask the user to trust the vault's plugin authors and to allow Mermaid diagrams in this vault. Leave those choices to the user; explain the pending app check and continue after they answer. Do not suppress trust prompts or treat installed files as permission.

Check that Vault Nickname identifies the project and Diagram Popup opens an embedded Mermaid diagram with fullscreen pan/zoom. CLI plugin presence alone does not prove that visual behavior. If this environment cannot operate Obsidian, leave those app checks explicit for Cicely instead of claiming them verified.

## Shared installation

Run `pwsh -NoProfile -File scripts/install.ps1` from the canonical skill after integration. It dispatches to BA-Skills' named installer. Bootstrap always requests both native aliases (`~/.agents/skills/ba-bootstrap`, `~/.claude/skills/ba-bootstrap`, respecting `CLAUDE_CONFIG_DIR`) pointing to one canonical source. On Windows the established directory-junction pattern provides those aliases. Optional WSL discovery uses each distribution's own home. Existing wrong links, real folders/files and selected-skill legacy Codex conflicts are reported before installing anything.

Keep permanent aliases aimed at `C:\Users\cicel\Dev\BA-Skills\skills\ba-bootstrap`, not an unmerged development worktree. Other agents can use that source directly if their discovery convention differs.

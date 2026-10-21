---
name: ba-bootstrap
description: Use when starting a new Benevolent Anarchy or personal project, or applying the standard local Obsidian setup to an existing project clone.
---

# Project bootstrap

Create the documentation and working-process foundation plus a selected starter: **Godot by default**, **Tauri** with plain TypeScript/Vite/npm, or explicit **foundation** for documentation only. Release/store configuration remains a later workflow.

Collect missing identity and preset inputs together: name, description, parent (default `C:\Users\cicel\Dev`), owner (default `Benevolent-Anarchy`, with `cicely-f` available) and preset. Godot offers Compatibility by default, Forward Plus or Mobile. For Tauri, show the proposed application identifier and allow an override. Read [presets.md](references/presets.md) for supported toolchains, exact options and fresh-clone setup.

Preserve name case and replace whitespace with hyphens: “Foo Bar Baz” becomes the project repository `Foo-Bar-Baz`, always created private, and its public companion `Foo-Bar-Baz-release-notes`. Only the project repository has a local checkout. Once bootstrap has published the foundation, its owner may make the project public; status, resume and local setup accept that and report it. See [project repository visibility](references/operations.md#project-repository-visibility).

Discussion about a future project authorizes inspection. An actual request to create the named pair authorizes its routine creation steps without repeated approvals. Existing-clone setup authorizes local tooling only.

Cicely's standing authorization covers installing, activating and using the four curated Obsidian plugins, accepting their author-trust prompt and allowing Mermaid viewing in the verified target vault. Read the scope and desktop-release procedure in [operations.md](references/operations.md) before app checks; tool-enforced permissions still apply.

Resolve this skill's directory and run its helpers using PowerShell 7.2+, Git and an authenticated GitHub CLI. These examples run from that directory:

```powershell
pwsh -NoProfile -File scripts/bootstrap.ps1 -Mode plan -Name 'Foo Bar Baz' -Description 'A useful project'
pwsh -NoProfile -File scripts/bootstrap.ps1 -Mode create -Name 'Foo Bar Baz' -Description 'A useful project'
pwsh -NoProfile -File scripts/bootstrap.ps1 -Mode status -Name 'Foo Bar Baz'
pwsh -NoProfile -File scripts/bootstrap.ps1 -Mode resume -Name 'Foo Bar Baz'
pwsh -NoProfile -File scripts/bootstrap.ps1 -Mode local-setup -Repository 'C:\Users\cicel\Dev\Foo-Bar-Baz'
```

Add `-Preset tauri` or `-Preset foundation` when selected, and relevant options only. `-Interactive` prompts; normal agent use supplies the collected inputs. Status/resume restore stored identity, preset, options and exact dependency versions from name/owner; omitted options keep those recorded values. New Tauri projects select the latest stable release, including future majors. Retries replay retained source and locks. An incompatible newest release blocks before either repository is created; preserve the result and report the native failure rather than downgrade or report completion from partial checks.

For status/resume or discard of a non-default owner, pass the original `-Owner`. If it is unknown, read the recorded invocation metadata first; an application identifier does not establish the GitHub owner.

Local setup configures Obsidian in the clone's actual Git root and verified project remote, private or public; it refuses a release-notes companion or unrelated repository. It performs no engine conversion and rejects engine options. Add `-RefreshPlugins` for a deliberate plugin update; ordinary repeated setup preserves preferences. Missing SDKs are reported, with installation handled separately.

Read JSON even after a nonzero exit. Report URLs, path, selection/versions, native staging and checkout verification, `projectVisibility` when the project is public, and actionable pending items. A build is distinct from an observed app launch. Report installed plugin versions, skipped inconsistent releases, digest status and assets without digests; installed files do not prove loaded plugins.

For failures, legacy v1 state, missing/corrupt frozen snapshots, public settings or app enablement, read [operations.md](references/operations.md). Preserve conflicts/journals and unconfirmed identities. An explicit request to abandon preparation before any repository attempt can use the guarded `discard` mode described there, then start the same name again. Completed invocations remove disposable staging and preserve recovery snapshots and later development.

Generated `AGENTS.md` owns project rules. GitHub Issues track work; topical documentation holds canon. `tools/verify.ps1` is the project gate and must pass before opening a session-ready PR.

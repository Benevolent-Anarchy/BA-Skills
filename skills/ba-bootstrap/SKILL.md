---
name: ba-bootstrap
description: Use when starting a new Benevolent Anarchy or personal project, or applying the standard local Obsidian setup to an existing project clone.
---

# Project foundation

Create an engine-independent documentation and working-process foundation. Engine presets, including Godot as the future default, are a second step; this version does not generate engine files or release/store configuration.

Collect missing inputs together: project name, description, parent directory (default `C:\Users\cicel\Dev`) and owner (default `Benevolent-Anarchy`, with `cicely-f` available). Preserve name case and replace whitespace with hyphens: “Foo Bar Baz” becomes private `Foo-Bar-Baz` and public `Foo-Bar-Baz-release-notes`. Only the private repository has a local checkout.

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

Add `-Parent`/`-Owner` when overridden. `-Interactive` prompts for missing inputs; normal agent use supplies them explicitly. Status/resume restore recorded inputs from name/owner. Local setup uses the clone's actual Git root and private remote identity; it never creates repositories. Add `-RefreshPlugins` for a deliberate update; ordinary repeated setup preserves installed plugins and preferences.

Read the JSON result even after a nonzero exit. Report project URLs, local path, verified work and actionable pending items. `partial` means useful work remains; installed/configured plugin files do not establish that Obsidian loaded them. Report installed plugin versions, skipped inconsistent releases, each plugin's digest verification status and any assets without a published digest.

For failures, recovery, public Pull requests settings or app enablement, read [operations.md](references/operations.md). Preserve conflicts and journals; never improvise rollback, overwrite a differing file, delete a repository, or adopt an unconfirmed repository identity.

Generated `AGENTS.md` owns project rules. GitHub Issues track work; topical documentation holds canon. `tools/verify.ps1` is the project gate and must pass before opening a session-ready PR.

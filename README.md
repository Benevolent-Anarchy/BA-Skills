# BA-Skills
BA's shared agent skills and deterministic tooling. The same canonical skill folders can be used by Codex, Claude Code and other agents.

The [bootstrap skill](skills/ba-bootstrap/SKILL.md) creates a private project, its public release-notes companion, topical documentation, agent rules and an ignored local Obsidian vault. Choose Godot (the default), Tauri or the documentation-only foundation; see [preset setup and prerequisites](skills/ba-bootstrap/references/presets.md). Existing clones can receive the same vault setup without creating repositories.

The [integration skill](skills/ba-integrate/SKILL.md) merges a project's ready pull requests, the ones no longer drafts, in an order that works. Its [survey](skills/ba-integrate/scripts/survey.ps1) finds which pull requests conflict or build on each other without checking anything out. The skill then rehearses every merge and conflict resolution against the project's gate in a scratch worktree, and merges only after the plan is approved. Its scripts bring each branch up to date by replaying the rehearsed resolutions, land it with a merge commit only while GitHub still shows the pull request ready and every push replaces exactly the value inspected, and delete a merged branch only while it is still at the merged tip and no open pull request targets it. Afterwards it checks every issue the merged pull requests should have closed and, for any still open, investigates why rather than closing it. Each project's rules for this live in an `Integrating pull requests` section of its `AGENTS.md`; see [project notes](skills/ba-integrate/references/project-notes.md).

The [release skill](skills/ba-release/SKILL.md) prepares and publishes Godot releases.
Use PowerShell 7.3 or newer for release operations and repository verification;
installation also supports PowerShell 7.2:

```powershell
pwsh -NoProfile -File ./install.ps1 -IncludeWsl
pwsh -NoProfile -File ./install.ps1 -Skill ba-bootstrap
pwsh -NoProfile -File ./install.ps1 -Skill ba-release -CheckOnly
pwsh -NoProfile -File ./skills/ba-release/scripts/verify-discovery.ps1
pwsh -NoProfile -File ./tools/verify.ps1
```

The root installer defaults to all three skills and preflights all selected aliases before creating any. Bootstrap and integration request both native `.agents` and `.claude` aliases even without their command-line executables; release keeps its existing executable-based discovery. Each points to one canonical source; unrelated skills and conflicting files are preserved. Permanent installation should use this canonical checkout after integration, not an unmerged worktree.

Game settings live in that game's root release.json. See the skill's concise
[configuration](skills/ba-release/references/configuration.md),
[installation](skills/ba-release/references/installation.md), and
[execution](skills/ba-release/references/execution.md) references. Setup inspects
configuration and runs read-only plans; writes require explicit validated answers.
Publication requires explicit destination
selection and approval of the concrete plan and notes.

First use: run `scripts/release.ps1 -Mode setup -Repository <game-root>` from
the canonical skill directory for inspected facts and missing questions, or add
`-Interactive` for a terminal wizard. Configuration writes use explicit answers
and the reported hash. Each new release chooses its destinations and
patch/minor/major/current version handling; retries reuse the reservation.
`extend` later adds stores that release.json declared when the release was
prepared, retaining existing artifacts and completed uploads. A store configured
afterwards needs that release.json change committed by itself and
`extend -MigrateConfiguration`, which accepts only additions.
Run `doctor` with the intended selection before preparation to find local tool,
engine/template and selected Android signing prerequisites. It remains read-only
and distinguishes local presence from unverified remote authentication.

The release scripts cover itch.io (Butler), Steam (SteamCMD and verified console
completion), Google Play (Android Publisher edits and verified rollout), and the
derived public release-notes repository. See
[store operations](skills/ba-release/references/stores.md) for pending review,
activation and announcement steps. Upload and submission statuses remain distinct
from verified publication.
When browser tools and account access are available, the skill also guides
approved console completion for Steam activation/announcements, itch labels and
Play publishing checks. See [browser completion](skills/ba-release/references/browser-completion.md).

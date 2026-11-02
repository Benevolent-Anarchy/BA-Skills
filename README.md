# BA-Skills
BA's shared agent skills and deterministic tooling. The same canonical skill folders can be used by Codex, Claude Code and other agents.

The [bootstrap skill](skills/ba-bootstrap/SKILL.md) creates a private project, its public release-notes companion, topical documentation, agent rules and an ignored local Obsidian vault. Choose Godot (the default), Tauri or the documentation-only foundation; see [preset setup and prerequisites](skills/ba-bootstrap/references/presets.md). Existing clones can receive the same vault setup without creating repositories, including clones of a project its owner later made public.

The [integration skill](skills/ba-integrate/SKILL.md) merges a project's ready pull requests, the ones no longer drafts, in an order that works. Its [survey](skills/ba-integrate/scripts/survey.sh) finds which pull requests conflict or build on each other without checking anything out. The skill then rehearses every merge and conflict resolution against the project's gate in a scratch worktree, and merges only after the plan is approved. Its scripts bring each branch up to date by replaying the rehearsed resolutions, land it with a merge commit only while GitHub still shows the pull request ready and every push replaces exactly the value inspected, and delete a merged branch only while it is still at the merged tip and no open pull request targets it. Afterwards it checks every issue the merged pull requests should have closed and, for any still open, investigates why rather than closing it. Each project's rules for this live in an `Integrating pull requests` section of its `AGENTS.md`; see [project notes](skills/ba-integrate/references/project-notes.md).

The [cross-review skill](skills/ba-crossreview/SKILL.md) lets Claude and Codex review each other's pull requests without Cicely carrying findings between them. The pull request's author runs it. Its [script](skills/ba-crossreview/scripts/crossreview.py) runs the other agent's CLI headless and read-only, in a detached worktree at the pushed head, and posts that review on the pull request under the reviewer's tag. The author answers every finding: fixed and pushed, or declined with reasons. Whenever either agent needs Cicely to make a decision or settle a point of uncertainty, the cross-review pauses and the author gives her a briefing: where things stand, what the decision is, why it matters, and what each option implies. Her answer goes on the pull request word for word under `[Cee, via the skill]`, together with what she was asked, and back to the reviewer. When a round leaves only minor findings and small fixes, it also asks her whether another round is worth its cost. Each later round resumes the reviewer's session to check the fixes and weigh the reasons, until nothing is open or she stops it. Once three rounds are used, it asks her before any more, listing the commits nobody has reviewed, and records that answer too. It also asks her before reviewing a few new commits that answer no finding, pushed after the cross-review settled. Whenever it asks, she can choose a focused check instead: the reviewer checks only the answers, or only those new commits, in a fresh session, within a token and time limit, and what it can't verify comes back to her. Once a cross-review is done, the author adds nothing new to the pull request: new work goes into an Issue or a new pull request. Either reviewer may run the tests for a check, in a sandbox with no network: Claude's commands run in Codex's sandbox, so a Claude check also needs the Codex CLI. In a review or a check, the reviewer's commands can't read the keys and logins in your home folder, and whatever a reviewer leaves running when it ends is stopped. A status comment on the pull request, kept up to date, shows where the cross-review stands, including what the reviewer is doing while it works. It runs on Linux with Python 3.10 or newer and needs the reviewer's CLI logged in.

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

On Linux, use `bash ./install.sh --check-only`, then `bash ./install.sh` from the canonical checkout. Native Bash entry points use Python 3.10+ and standard Linux tools without PowerShell; the Windows scripts remain supported. The installer links all four skills into `~/.agents/skills` and `~/.claude/skills`, preflights every target, and preserves conflicting paths by refusing the installation. `--skill ba-integrate` selects one skill; `--home <path>` provides an alternate home for controlled installation. Run `bash ./tools/verify.sh` for the three Linux fixture suites and the cross-review suite. Tests use temporary homes, local remotes and service substitutes; they do not publish or merge on GitHub.

On Windows, the root installer defaults to all three skills and preflights all selected aliases before creating any. Bootstrap and integration request both native `.agents` and `.claude` aliases even without their command-line executables; release keeps its existing executable-based discovery. Each points to one canonical source; unrelated skills and conflicting files are preserved. Permanent installation should use this canonical checkout after integration, not an unmerged worktree.

Game settings live in that game's root release.json. See the skill's concise
[configuration](skills/ba-release/references/configuration.md),
[installation](skills/ba-release/references/installation.md), and
[execution](skills/ba-release/references/execution.md) references. Setup inspects
configuration and runs read-only plans; writes require explicit validated answers.
Publication requires explicit destination
selection and approval of the concrete plan and notes. A game whose release.json
sets `sourceTag`, as a new setup does, also gets an annotated `v<version>` tag on
each release's source, pushed to origin once a store is live and never moved.

First use: run `scripts/release.sh --mode setup --repository <game-root>` from
the canonical skill directory for inspected facts and missing questions, or add
`--interactive` to answer them at the terminal. Configuration writes use explicit answers
and the reported hash. Each new release chooses its destinations and
patch/minor/major/current version handling; retries reuse the reservation.
`extend` later adds stores that release.json declared when the release was
prepared, retaining existing artifacts and completed uploads. A store configured
afterwards needs that release.json change committed by itself and
`extend --migrate-configuration`, which accepts only additions.
Run `doctor` with the intended selection before preparation to find local tool,
engine/template and selected Android signing prerequisites. It remains read-only
and distinguishes local presence from unverified remote authentication.

The release scripts cover itch.io (Butler), Steam (SteamCMD and verified console
completion), Google Play (Android Publisher edits and verified rollout), and the
derived public release-notes repository. See
[store operations](skills/ba-release/references/stores.md) for pending review,
activation and announcement steps. Upload and submission statuses remain distinct
from verified publication. A release never replaces a newer one already sent to
or live on a store channel. A sent build that never went live is set aside only
through `abandon`, with the user's authorization.
When browser tools and account access are available, the skill also guides
approved console completion for Steam activation/announcements, itch labels and
Play publishing checks. See [browser completion](skills/ba-release/references/browser-completion.md).

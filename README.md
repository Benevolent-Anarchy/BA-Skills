# BA-Skills
BA's shared agent skills and deterministic tooling for Codex and Claude Code.

The canonical release skill is [skills/ba-release/SKILL.md](skills/ba-release/SKILL.md).
Install its user-level links from PowerShell 7.2 or newer:

```powershell
pwsh -NoProfile -File ./install.ps1 -IncludeWsl
pwsh -NoProfile -File ./skills/ba-release/scripts/verify-discovery.ps1
pwsh -NoProfile -File ./tests/run-tests.ps1
```

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
`extend` adds stores later, retaining existing artifacts and completed uploads.
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

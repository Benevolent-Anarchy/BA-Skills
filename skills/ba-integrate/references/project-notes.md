# Project notes for integration

Each project keeps its integration rules in a `## Integrating pull requests` section of its `AGENTS.md`, so every agent reads the same thing. Keep it short. Point to the project's own recording rules rather than repeating them.

The section answers:

- **Gate:** the command that must pass, anything it needs (such as an environment variable), and whether every step must pass or only the last. Every step is the default.
- **Hotspots:** the files most pull requests touch, and how each one merges. For example, "append both entries in merge order, as `DECISIONS.md` says", or "rewrite as one map true of the merged tree".
- **Generated files:** how to regenerate anything that should not be merged by hand.
- **Posting:** the author prefix for comments and descriptions, and whether merged branches are deleted.
- **After merging:** the project's handoff rule for sessions, worktrees and tasks attached to merged branches.

A template:

```markdown
## Integrating pull requests

Gate: `<command>`, with `<requirement>`; every step must pass.

Hotspots: `<file>` (<how it merges>); `<file>` (<how it merges>).

Post as `[Claude]` or `[Codex]`. Keep merged branches.

After merging, <handoff rule>.
```

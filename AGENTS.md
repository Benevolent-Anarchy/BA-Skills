# BA-Skills agent notes

## Integrating pull requests

When Cicely asks for the ready pull requests, the ones no longer drafts, to be merged together, use the `ba-integrate` skill from this repository. It rehearses every merge in a scratch worktree before anything lands, and merges once she approves the plan. What it needs to know about this project:

- **Gate:** `pwsh -NoProfile -File tools/verify.ps1` must pass at every step. It runs the release, bootstrap and integration suites in parallel and takes about a quarter of an hour. Steps can be gated at the same time, each in its own detached worktree.
- **Skill references:** pull requests often add sections side by side to a skill's `references/` documents, such as `skills/ba-release/references/configuration.md`. Keep every section either side adds, the earlier-merged one's first, and check each claim against the combined scripts. Two sections that contradict each other are a question for Cicely.
- **`README.md`:** one paragraph per skill. Keep each pull request's change to its own skill's paragraph; where two changed the same paragraph, rewrite it to be true of the merged tree.
- **Tests:** keep both sides' tests in `tests/run-tests.ps1` and the other suites.
- **Posting:** begin every comment and description with `[Claude]` or `[Codex]`. Each pull request's `Closes #N` lines close their issues when it merges.
- **Branches:** delete each merged branch on GitHub, and leave local ones.
- **After merging,** list the worktrees, sessions and Codex tasks still on the merged branches, and offer to clean them up; don't remove them unasked.

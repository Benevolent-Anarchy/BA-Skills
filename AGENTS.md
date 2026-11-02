# BA-Skills agent notes

## Working principles

- **Mistakes and dead-ends:** the aim is the best software we can build, not being right or looking good. Record mistakes and dead-ends as plainly as successes, in the pull request, the Issue or the skill's documentation: what was tried, what went wrong, why, and what changed, so that every agent and person working here can learn from them. Never hide or soften a mistake, and don't erase its trace when you fix it.
- **On the record:** keep Cicely's decisions and words on the record, so that a decision which later proves wrong can be traced and undone. "On the record" means somewhere durable she can see: the pull request, an Issue, or a committed file. A scratch file, a local or faked test fixture, a temporary folder or an agent's private memory is never the record. When her words land in one, for example during a test, say so plainly at the time, and copy them somewhere durable before it goes. Never delete or overwrite a record of her decisions or words; if in doubt, ask her.
- **Privacy:** BA projects never upload crash reports, telemetry or analytics automatically, as rule 19 of the [generated project contract](skills/ba-bootstrap/assets/project/AGENTS.md.template) states. The skills here follow it too.
- **Finishing a cross-review:** once a pull request's cross-review (the `ba-crossreview` skill) reaches `done`, its author adds nothing new to it. New work, however small, goes into an Issue or a new pull request, and only fixes for what a review found go into it. Until then, gaps in the pull request's own code are fixed in it. Each new commit reopens the review: on #65 it was the author's new work after `done`, not the reviews, that kept the cross-review going. This holds whichever agent is the author, Claude or Codex.

## Integrating pull requests

When Cicely asks for the ready pull requests, the ones no longer drafts, to be merged together, use the `ba-integrate` skill from this repository. It rehearses every merge in a scratch worktree before anything lands, and merges once she approves the plan. What it needs to know about this project:

- **Gate:** `bash tools/verify.sh` runs the bootstrap, integration, release and cross-review suites. It must pass at every step; steps can be gated at the same time, each in its own detached worktree.
- **Skill references:** pull requests often add sections side by side to a skill's `references/` documents, such as `skills/ba-release/references/configuration.md`. Keep every section either side adds, the earlier-merged one's first, and check each claim against the combined scripts. Two sections that contradict each other are a question for Cicely.
- **`README.md`:** one paragraph per skill. Keep each pull request's change to its own skill's paragraph; where two changed the same paragraph, rewrite it to be true of the merged tree.
- **Tests:** keep both sides' tests in every suite under `tests/`.
- **Posting:** begin every comment and description with `[Claude]` or `[Codex]`. The one exception is the comments where the cross-review skill records Cicely's decisions in her own words: those begin with `[Cee, via the skill]`. Each pull request's `Closes #N` lines close their issues when it merges.
- **Branches:** delete each merged branch on GitHub, and leave local ones. This repository deletes merged head branches itself, and GitHub then moves the pull requests stacked on them to the base. So `delete-branch.sh` reports the branch `absent`, and `retarget.sh` lists the stacked ones under `alreadyRetargeted`.
- **After merging,** list the worktrees, sessions and Codex tasks still on the merged branches, and offer to clean them up; don't remove them unasked.

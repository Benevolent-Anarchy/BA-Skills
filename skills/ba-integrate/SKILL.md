---
name: ba-integrate
description: Use when a project has several ready (non-draft) pull requests to merge, or Cicely asks to integrate, land or merge "the ready PRs" in a project. Surveys them, rehearses every merge and conflict resolution against the project's gate in a scratch worktree, then merges them in order once she approves the plan.
---

# Integrating ready pull requests

Cicely keeps pull requests as drafts until all their reviews are in, then marks them ready. The ready ones are the queue. This skill merges that queue into the base branch in an order that works, resolving conflicts the way the project records things, so she approves one plan instead of untangling merges herself.

## Authority

A request to integrate a project authorizes the survey, the rehearsal and a scratch worktree of its own. Pushing to pull-request branches, editing their descriptions, commenting on them and merging them wait for Cicely's approval of the concrete plan. That approval covers exactly the pull requests and head commits in it. Anything that differs from the plan stops the run for a new approval.

Never mark a pull request ready, never merge a draft, never force-push, and never rebase or rewrite a pull-request branch: bring it up to date by merging the base into it. Leave review threads as they are. Never touch Cicely's main checkout beyond a fast-forward pull at the end, and only when it is clean.

## 1. Prepare

Read the project's `AGENTS.md` (or `CLAUDE.md`) and its `## Integrating pull requests` section: the gate command, the hotspot files and how each merges, and anything else it says. Read the project's own rules for the files that conflict, such as how a decision or judgement is recorded. If the section is missing, read [project-notes.md](references/project-notes.md), ask for the gate command, and propose a section once the run is done.

## 2. Survey

Run, from this skill's directory, with PowerShell 7.2+, Git 2.38+ and an authenticated GitHub CLI:

```powershell
pwsh -NoProfile -File scripts/survey.ps1 -Repository 'C:\Users\cicel\Dev\<project>'
```

It fetches, lists the open pull requests, skips drafts, forks and anything targeting neither the base nor another ready pull request, and reports for each ready one its head commit, files, commits, how far it is behind the base, conflicts with the base, review decision and unresolved review threads. It also reports which pairs conflict and in which files, which pull requests build on others, and an order: those it builds on first, then the fewest conflicts, oldest first. Read the JSON even after a nonzero exit. The order is a starting point: change it when the content says so, such as one pull request's decision relying on another's, and say why in the plan.

With nothing ready, report the skipped ones and stop. One ready pull request still goes through the rehearsal.

## 3. Rehearse

Create the rehearsal from the surveyed base commit, in the project's worktree folder, on a branch of its own that keeps the rehearsed commits while the merge step uses the worktree:

```powershell
git -C <root> worktree add -b integration/<yyyymmdd> <root>\.claude\worktrees\integration-<yyyymmdd> <base sha>
```

Use whatever the project's notes say a checkout there needs, such as Git's long-path support on Windows (`-c core.longpaths=true` on every git command). Merge each pull request's surveyed head commit in order, with conflict resolutions recorded for replay:

```powershell
git -c rerere.enabled=true -c rerere.autoUpdate=true merge --no-ff --no-edit <head sha>
```

Resolve each conflict as [resolving.md](references/resolving.md) and the project's notes say. Stage the result and commit it with `git -c rerere.enabled=true commit --no-edit`: Git records a resolution for replay only when recording is also on for the commit. Then record the step's tree with `git rev-parse HEAD^{tree}`. Then check for the conflicts text cannot show, as resolving.md describes, and run the project's gate. Every step becomes the base at some point, so each one has to pass, unless the project's notes allow gating only the last. A failing gate is a finding for the plan, not something to fix silently. After the last step, re-read the hotspot files whole against the combined tree.

## 4. Plan, then wait

Present the plan and wait for Cicely's approval:

- the order, with the reason for each position
- for each pull request: number, title, head commit, what it changes, and each conflict with how it was resolved; show the resolved text for prose, and explain code resolutions with their diff
- the gate's result at every step
- questions only she can answer, such as two decisions that contradict each other, a resolution that needs new code, or a semantic doubt
- what will happen to each pull request: a merge commit bringing it up to date where it is behind, a comment recording any resolutions, and a merge commit into the base

If her answers change a resolution, redo the rehearsal from that step and show what changed.

## 5. Merge

For each pull request in the approved order:

1. Check it is still open, still not a draft, and still at the approved head with `gh pr view <n> --json state,isDraft,headRefOid,baseRefName`. Otherwise stop.
2. If it builds on another pull request that has now merged, retarget it first: `gh pr edit <n> --base <base>`.
3. If it is behind the base, bring it up to date in the rehearsal worktree: check out its head with `git checkout --detach <head sha>`, then `git -c rerere.enabled=true -c rerere.autoUpdate=true merge --no-ff --no-edit origin/<base>`. The recorded resolutions replay and are staged, though `git merge` still exits as though it conflicted. Check that `git diff --name-only --diff-filter=U` lists nothing, then commit with `git -c rerere.enabled=true commit --no-edit`. A path still unmerged is a conflict the rehearsal did not have, and stops the run. The result's tree must equal the rehearsed step's tree. If it does, the step's gate result stands; if not, stop and show the difference. Push without force: `git push origin HEAD:refs/heads/<branch>`. A rejected push means someone else pushed, so stop.
4. If the step resolved conflicts, comment on the pull request with the resolutions, using the project's author prefix. Update its description if it no longer describes the change.
5. Merge with a merge commit, pinned to the commit just checked: `gh pr merge <n> --merge --match-head-commit <sha>`. If the project's notes say merged branches are deleted, delete only the remote one, with `git push origin --delete <branch>`. Leave local branches: one may be checked out in a session's worktree.
6. Fetch, and check the base's new tree equals the rehearsed step's tree.

When a run stops, report which pull requests merged, which did not, and the state of any branch already pushed, so nothing is left half done without a word.

## 6. Finish

Fast-forward Cicely's main checkout with `git pull --ff-only` if it is clean and on the base. Otherwise say why you left it. Re-read the files several pull requests changed, such as a handoff map, on the new base against the tree. A correction goes into a new draft pull request, never straight onto the base.

Report the merges and their commits, the issues they closed, and the comments posted. List the worktrees, Claude sessions and Codex tasks still attached to the merged branches, and follow the project's handoff rule for them. Offer to clean those up, but don't do it unasked. Remove the rehearsal worktree and its `integration/<yyyymmdd>` branch, which are the skill's own.

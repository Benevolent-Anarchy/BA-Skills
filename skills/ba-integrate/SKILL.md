---
name: ba-integrate
description: Use when a project has several ready (non-draft) pull requests to merge, or Cicely asks to integrate, land or merge "the ready PRs" in a project. Surveys them, rehearses every merge and conflict resolution against the project's gate in a scratch worktree, then merges them in order once she approves the plan.
---

# Integrating ready pull requests

Cicely keeps pull requests as drafts until all their reviews are in, then marks them ready. The ready ones are the queue. This skill merges that queue into the base branch in an order that works, resolving conflicts the way the project records things, so she approves one plan instead of untangling merges herself.

## Authority

A request to integrate a project authorizes the survey, the rehearsal and a scratch worktree and branch of its own. Pushing to pull-request branches or the base, editing pull-request descriptions, commenting on pull requests and deleting merged branches all wait for Cicely's approval of the concrete plan. That approval covers exactly the pull requests, head commits and base commit in it. Anything that differs from the plan stops the run for a new approval.

Never mark a pull request ready, never merge a draft, never force-push, and never rebase or rewrite a pull-request branch: bring it up to date by merging the base into it. Leave review threads as they are. Never touch Cicely's main checkout beyond a fast-forward pull at the end, and only when it is clean.

The scripts below run from this skill's directory with PowerShell 7.2+, Git 2.38+ and an authenticated GitHub CLI. Each writes one JSON document. Read it even after a nonzero exit: a failure carries an `error` member saying what was and was not changed.

## 1. Prepare

Read the project's `AGENTS.md` (or `CLAUDE.md`) and its `## Integrating pull requests` section: the gate command, the hotspot files and how each merges, and anything else it says. Read the project's own rules for the files that conflict, such as how a decision or judgement is recorded. If the section is missing, read [project-notes.md](references/project-notes.md), ask for the gate command, and propose a section once the run is done.

## 2. Survey

```powershell
pwsh -NoProfile -File scripts/survey.ps1 -Repository 'C:\Users\cicel\Dev\<project>'
```

It fetches and reads every open pull request, across all of GitHub's pages. It skips drafts, forks and anything targeting neither the base nor another ready pull request. For each ready one it reports its head commit, files, commits, how far it is behind the base, conflicts with the base, review decision and unresolved review threads. It also reports which pairs conflict and in which files, which pull requests build on others, and an order: those it builds on first, then the fewest conflicts, oldest first. The order is a starting point: change it when the content says so, such as one pull request's decision relying on another's, and say why in the plan.

A ready pull request built on one that is not ready would land that work too. The survey names it in `includesUnready`, with why it was skipped. Leave such a pull request out of the run unless Cicely explicitly approves including that work, and put both, prominently, in the plan. `uncheckedSkipped` lists skipped pull requests whose heads could not be fetched, so nothing was checked against them. Say so in the plan if it is not empty.

With nothing ready, report the skipped ones and stop. One ready pull request still goes through the rehearsal.

## 3. Rehearse

Create the rehearsal from the surveyed base commit, in the project's worktree folder. Give it a branch of its own, which keeps the rehearsed commits while the scripts check out other commits there:

```powershell
git -C <root> worktree add -b integration/<yyyymmdd> <root>\.claude\worktrees\integration-<yyyymmdd> <base sha>
```

Use whatever the project's notes say a checkout there needs, such as Git's long-path support on Windows (`-c core.longpaths=true` on every git command). Then, for each pull request in order:

1. Merge its surveyed head with `git merge --no-ff --no-commit <head sha>`.
2. Resolve each conflict as [resolving.md](references/resolving.md) and the project's notes say, and commit with `git commit --no-edit`. The step's commit, from `git rev-parse HEAD`, is what the merge step will reproduce. Put every change the step needs into this commit.
3. Rehearse the branch update the merge step will make, so a step whose resolution cannot replay shows up now rather than halfway through merging. Use the previous step's commit as the base, or the surveyed base commit for the first step:

   ```powershell
   pwsh -NoProfile -File scripts/update.ps1 -Worktree <rehearsal> -Head <head sha> -Base <previous step commit> -Rehearsed <step commit>
   git -C <rehearsal> checkout integration/<yyyymmdd>
   ```

   It merges the base into the head and takes every conflicted path from the step's commit, whatever kind of conflict it was. It must report `matches: true`. A mismatch means the step changed a path no conflict touched, which the merge step cannot reproduce. Take that change out of the step and keep it for a follow-up draft pull request.
4. Check for the conflicts text cannot show, as resolving.md describes, then run the project's gate. Every step becomes the base at some point, so each one has to pass, unless the project's notes allow gating only the last. A failing gate is a finding for the plan, not something to fix silently.

After the last step, re-read the hotspot files whole against the combined tree. List anything no longer true as a follow-up correction for after the run.

## 4. Plan, then wait

Present the plan and wait for Cicely's approval:

- the base commit the rehearsal started from, which the merge step requires the remote base to still be at
- any ready pull request that contains unmerged work that is not ready, from `includesUnready`, with the choice to leave it out or include that work
- the order, with the reason for each position
- for each pull request: number, title, head commit, what it changes, and each conflict with how it was resolved; show the resolved text for prose, and explain code resolutions with their diff
- the gate's result and the rehearsed update's match at every step
- questions only she can answer, such as two decisions that contradict each other, a resolution that needs new code, or a semantic doubt
- follow-up corrections found on re-reading, which go into a new draft pull request after the run
- what will happen to each pull request: a merge commit bringing it up to date where it is behind, a merge commit on the base, a comment recording any resolutions, and deletion of its branch if the project's notes ask for it

If her answers change a resolution, redo the rehearsal from that step. Reset the rehearsal branch to the previous step's commit, merge again, and take earlier resolutions from the old step commits where they still apply. Show what changed.

## 5. Merge

The expected base starts as the rehearsal's base commit and becomes each landing's merge commit. For each pull request in the approved order:

1. Check it is still open, still not a draft, and still at the approved head with `gh pr view <n> --json state,isDraft,headRefOid,baseRefName`. Otherwise stop.
2. If it builds on another pull request that has now merged, retarget it first: `gh pr edit <n> --base <base>`.
3. Bring it up to date in the rehearsal worktree. It must exit 0 with `matches: true`:

   ```powershell
   pwsh -NoProfile -File scripts/update.ps1 -Worktree <rehearsal> -Head <approved head> -Base <expected base> -Rehearsed <step commit> -Message 'Merge <base> into <branch> for integration'
   ```

4. Land it. It refuses, before pushing anything, when the update does not hold the rehearsed tree, or when the remote base or branch is not where the plan expects. It pushes the update to the branch, makes the merge commit on the expected base, and pushes that to the base without force. So a base that moved, a ruleset or a merge-queue requirement fails the push instead of landing something unrehearsed. It then waits for GitHub to report the pull request `MERGED`:

   ```powershell
   pwsh -NoProfile -File scripts/land.ps1 -Worktree <rehearsal> -Branch <branch> -ApprovedHead <approved head> -Updated <update's commit> -BaseBranch <base> -ExpectedBase <expected base> -Rehearsed <step commit> -Message "Merge pull request #<n> from <owner>/<branch>`n`n<title>" -PullRequest <n>
   ```

   Its `mergeCommit` is the next step's expected base.
5. Once it reports `MERGED`, comment on the pull request with any resolutions, using the project's author prefix. Update its description if it no longer describes the change.
6. If the project's notes say merged branches are deleted, delete it. The script deletes only while the branch is still at the merged tip, and reports a branch someone has pushed to since as `moved`:

   ```powershell
   pwsh -NoProfile -File scripts/delete-branch.ps1 -Repository <root> -Branch <branch> -MergedTip <land's branchTip> -BaseBranch <base>
   ```

   Leave local branches: one may be checked out in a session's worktree.

When a run stops, report which pull requests merged, which did not, and what each script's JSON says was pushed. Nothing should be left half done without a word.

## 6. Finish

Fast-forward Cicely's main checkout with `git pull --ff-only` if it is clean and on the base. Otherwise say why you left it. Check that the issues in each landing's `closingIssues` are closed. Close any that are still open, with a comment naming the merge.

Report the merges and their commits, the issues they closed, the comments posted, and each branch deletion's outcome. Put the follow-up corrections into a new draft pull request, or list them for Cicely if she prefers. List the worktrees, Claude sessions and Codex tasks still attached to the merged branches, and follow the project's handoff rule for them. Offer to clean those up, but don't do it unasked. Remove the rehearsal worktree and its `integration/<yyyymmdd>` branch, which are the skill's own.

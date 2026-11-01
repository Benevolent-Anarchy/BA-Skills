---
name: ba-crossreview
description: Use when a pull request Claude or Codex wrote needs the other agent's review, or Cicely asks to cross-review a pull request, have Codex (or Claude) review it, or stop relaying reviews between the two. Run as the pull request's author. It has the other agent review the pushed head headlessly and read-only, posts each review and each answer on the pull request, pauses for Cicely whenever either agent needs her decision, and repeats until nothing is open or the rounds run out.
---

# Cross-reviewing a pull request

Claude and Codex review each other's pull requests. The agent that wrote a pull request is its author and runs this skill. The other agent is its reviewer: the script runs it headless and read-only on the pull request's pushed head. Each review, each answer and each of Cicely's decisions goes on the pull request as a comment, so Cicely reads one record and doesn't have to carry findings from one agent to the other.

It works the same in both directions: when Claude is the author the script runs `codex`, and when Codex is the author it runs `claude`.

## Authority

A request to cross-review a pull request authorizes, for that pull request only:
- running the reviewer
- posting the reviewer's comments, your own answers and Cicely's decisions through the script
- committing fixes and pushing them to the pull request's branch as new commits

Never force-push, rebase or rewrite its history. Never mark it ready, never merge it, and never resolve review threads or close issues. Never decide for Cicely: anything that needs her goes to her (step 4).

Run this only as the pull request's author. If the other agent wrote it (judge by its branch prefix, such as `claude/` or `codex/`, and its commits), tell Cicely that agent should run it. If she asked you for a review rather than a cross-review, review it yourself instead.

## Requirements

You need Linux, Python 3.10 or newer, Git, an authenticated GitHub CLI, and the reviewer's CLI installed and logged in: `codex` when you are Claude, `claude` when you are Codex. A project that uses Git LFS also needs `git lfs`. Run the script from this skill's directory:

```bash
python3 scripts/crossreview.py <command> --repository <clone> --pull-request <n>
```

Each command writes one JSON document. Read it even after a nonzero exit: a failure carries an `error` member, and then nothing was posted or recorded, unless the error says it posted a comment. In that case don't run the command again; tell Cicely. The script reads the GitHub repository from the remote's configured URL and names it in every `gh` call, so `GH_REPO` never redirects it. A remote that isn't on github.com is refused. Only one command at a time runs for a pull request; another is refused until it finishes.

Your progress is kept in the clone's Git directory, under `ba-crossreview/`. It is never committed, and it belongs to that machine.

## 1. Prepare

Read the project's `AGENTS.md` or `CLAUDE.md`; the reviewer is told to read it too. Commit and push everything. The reviewer sees only the head on GitHub, never your working tree.

## 2. Review

```bash
python3 scripts/crossreview.py review --repository <clone> --pull-request <n> --author claude
```

Pass `--author codex` when you are Codex. A review can take a long time: Codex at high effort may take half an hour on a large change. Where your shell limits how long a command may run, run it in the background and wait for it to finish. The time limit is 90 minutes by default, and `--timeout-minutes` changes it.

The script:
1. fetches the pull request's head and checks it out in a detached worktree of its own under the system temp folder; that worktree stays put between rounds
2. pulls the head's Git LFS objects into it if the project uses LFS, and refuses to go on while any file is still a pointer
3. writes the change and its commits to files beside that worktree for the reviewer to read
4. runs the reviewer there, in a fresh session in round 1 and resuming that session in later rounds
5. posts the review on the pull request word for word, under the reviewer's `[Codex]` or `[Claude]` tag
6. reports the findings that are open, and the questions only Cicely can answer

The reviewer can only read. Codex runs in its read-only sandbox without your Codex configuration and rules, so no plugin, MCP server or command allowance acts outside the sandbox; it keeps the model and reasoning effort your configuration names. Claude runs in restricted mode with only its Read, Grep and Glob tools, confined to the worktree and the change, and with no MCP servers or connectors.

Findings are numbered `F1`, `F2` and so on across the whole cross-review, most severe first, with severities `blocker`, `major`, `minor` and `nit`. If the reviewer's session can't be resumed, the script starts a new one with the history in the prompt and reports `resumed: false`.

## 3. Answer every open finding

Check each finding against the code yourself, and give it one of three answers:
- **fixed:** it's right. Fix it, add a test where the project expects one, run the project's gate, then commit and push. Name the commit in the note.
- **declined:** it's wrong, or not worth changing. Say why with evidence: the code, a test, or a project rule. Don't decline to avoid work.
- **escalated:** only Cicely can decide it, for example a question of design, scope or priority, or a point you're unsure of that the code and the project's notes can't settle. Use it too for a finding the reviewer still holds after you have declined it twice; don't argue a third time. Say what decision is needed.

A finding that carries Cicely's decision is answered by what she decided: fix it her way, or decline it where she said to leave it.

Write the answers to a JSON file outside the repository, such as in your scratch folder, and post them:

```json
[{"id": "F1", "action": "fixed", "note": "Adds now, with a test, in 1a2b3c4."},
 {"id": "F2", "action": "declined", "note": "test_widget already covers this: widget.py:40."}]
```

```bash
python3 scripts/crossreview.py reply --repository <clone> --pull-request <n> --replies <file>
```

It refuses unless every open finding has exactly one answer, and refuses a `fixed` answer while the pull request is still at the reviewed head, since the reviewer could not see the fix. It posts your answers as your own comment.

## 4. Pause for Cicely

When a command reports the turn `cicely`, the cross-review is paused: the reviewer asked a question only she can answer, or you escalated a finding. Stop and call for her attention. Use your harness's notification or question tool if it has one, and ask her in the session, quoting each finding's id, title and the decision it needs. Don't run another round, and don't guess her answer. Wait for her.

Record her answers in her own words, one for each finding waiting for her, in a JSON file:

```json
[{"id": "F3", "decision": "Keep the plugin out of this change; I'll file it separately."}]
```

```bash
python3 scripts/crossreview.py decide --repository <clone> --pull-request <n> --decisions <file>
```

It refuses unless every finding waiting for her has exactly one decision. It posts her decisions on the pull request under your tag. A question she answered comes back to you as an open finding carrying her decision, to answer in step 3. A finding you escalated goes back to the reviewer with her decision in the next round. Act on what she decided before that round: push any change she asked for.

## 5. Repeat until it settles

Each command's `turn` says what comes next:
- `review`: run the next round. The reviewer checks your fixes in the code, weighs your reasons for declining, holds both of you to Cicely's decisions, and may raise new problems that your changes introduced.
- `reply`: answer the open findings.
- `cicely`: pause for Cicely's decisions (step 4).
- `done`: nothing is left between you and the reviewer at the reviewed head. If you push more commits later, `review` reviews them as another round.
- `limit`: the rounds are used up. There are three by default; pass `--max-rounds` to `review` for more only when Cicely asks for them.

## 6. Report

```bash
python3 scripts/crossreview.py status --repository <clone> --pull-request <n>
python3 scripts/crossreview.py finish --repository <clone> --pull-request <n>
```

`status` lists the rounds, the reviewed head, what's open, what waits for Cicely, her decisions, and every comment. `finish` removes the review worktree and the change files and keeps the record.

Tell Cicely:
- how many rounds it took
- what you fixed
- what you declined, and whether the reviewer accepted your reasons
- what she decided, and how each decision was carried out
- anything still open at the limit, with both positions
- links to the comments

The pull request stays a draft: marking it ready is her call.

---
name: ba-crossreview
description: Use when a pull request Claude or Codex wrote needs the other agent's review, or Cicely asks to cross-review a pull request, have Codex (or Claude) review it, or stop relaying reviews between the two. Run as the pull request's author. It has the other agent review the pushed head headlessly and read-only, posts each review and each answer on the pull request, and repeats until nothing is open or the rounds run out, bringing Cicely only what the two couldn't settle.
---

# Cross-reviewing a pull request

Claude and Codex review each other's pull requests. The agent that wrote a pull request is its author and runs this skill. The other agent is its reviewer: the script runs it headless and read-only on the pull request's pushed head. Each review and each answer goes on the pull request as a comment, so Cicely reads one record and doesn't have to carry findings from one agent to the other.

It works the same in both directions: when Claude is the author the script runs `codex`, and when Codex is the author it runs `claude`.

## Authority

A request to cross-review a pull request authorizes, for that pull request only:
- running the reviewer
- posting the reviewer's comments and your own answers through the script
- committing fixes and pushing them to the pull request's branch as new commits

Never force-push, rebase or rewrite its history. Never mark it ready, never merge it, and never resolve review threads or close issues. Escalate anything that would change what the pull request is for, such as a different design, a dropped feature, or a decision the project's notes leave to Cicely.

Run this only as the pull request's author. If the other agent wrote it (judge by its branch prefix, such as `claude/` or `codex/`, and its commits), tell Cicely that agent should run it. If she asked you for a review rather than a cross-review, review it yourself instead.

## Requirements

You need Python 3.10 or newer, Git, an authenticated GitHub CLI, and the reviewer's CLI installed and logged in: `codex` when you are Claude, `claude` when you are Codex. Run the script from this skill's directory. Use `python3` on Linux and `py -3` on Windows:

```bash
python3 scripts/crossreview.py <command> --repository <clone> --pull-request <n>
```

Each command writes one JSON document. Read it even after a nonzero exit: a failure carries an `error` member, and then nothing was posted or recorded. The script reads the GitHub repository from the remote's configured URL and names it in every `gh` call, so `GH_REPO` never redirects it. A remote that isn't on github.com is refused.

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
2. runs the reviewer there, in a fresh session in round 1 and resuming that session in later rounds
3. posts the review on the pull request word for word, under the reviewer's `[Codex]` or `[Claude]` tag
4. reports the findings that are still open

Findings are numbered `F1`, `F2` and so on across the whole cross-review, most severe first, with severities `blocker`, `major`, `minor` and `nit`. If the reviewer's session can't be resumed, the script starts a new one with the history in the prompt and reports `resumed: false`.

## 3. Answer every open finding

Check each finding against the code yourself, and give it one of three answers:
- **fixed:** it's right. Fix it, add a test where the project expects one, run the project's gate, then commit and push. Name the commit in the note.
- **declined:** it's wrong, or not worth changing. Say why with evidence: the code, a test, or a project rule. Don't decline to avoid work.
- **escalated:** only Cicely can decide it, for example a question of design, scope or priority. Use it too for a finding the reviewer still holds after you have declined it twice; don't argue a third time. Say what decision is needed.

Write the answers to a JSON file outside the repository, such as in your scratch folder, and post them:

```json
[{"id": "F1", "action": "fixed", "note": "Adds now, with a test, in 1a2b3c4."},
 {"id": "F2", "action": "declined", "note": "test_widget already covers this: widget.py:40."}]
```

```bash
python3 scripts/crossreview.py reply --repository <clone> --pull-request <n> --replies <file>
```

It refuses unless every open finding has exactly one answer, and refuses a `fixed` answer while the pull request is still at the reviewed head, since the reviewer could not see the fix. It posts your answers as your own comment. Escalated findings leave the loop: the reviewer isn't asked about them again.

## 4. Repeat until it settles

Each command's `turn` says what comes next:
- `review`: run the next round. The reviewer checks your fixes in the code, weighs your reasons for declining, and may raise new problems that your changes introduced.
- `reply`: answer the open findings.
- `done`: nothing is left between you and the reviewer.
- `limit`: the rounds are used up. There are three by default; pass `--max-rounds` to `review` for more only when Cicely asks for them.

## 5. Report

```bash
python3 scripts/crossreview.py status --repository <clone> --pull-request <n>
python3 scripts/crossreview.py finish --repository <clone> --pull-request <n>
```

`status` lists the rounds, what's open, what was escalated with your notes, and every comment. `finish` removes the review worktree and keeps the record.

Tell Cicely:
- how many rounds it took
- what you fixed
- what you declined, and whether the reviewer accepted your reasons
- each escalated finding, with the decision it needs
- anything still open at the limit, with both positions
- links to the comments

The pull request stays a draft: marking it ready is her call.

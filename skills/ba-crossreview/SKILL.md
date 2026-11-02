---
name: ba-crossreview
description: Use when a pull request Claude or Codex wrote needs the other agent's review, or Cicely asks to cross-review a pull request, have Codex (or Claude) review it, or stop relaying reviews between the two. Run as the pull request's author. It has the other agent review the pushed head headlessly and read-only, posts each review, each answer and each of Cicely's decisions on the pull request, keeps a status comment there up to date, pauses with a briefing whenever Cicely's decision is needed, including whether to have another round, a cheaper focused check of the answers or of a few new commits, or neither when a round looks not worth its cost or the rounds have run out, and repeats until nothing is open or she stops it.
---

# Cross-reviewing a pull request

Claude and Codex review each other's pull requests. The agent that wrote a pull request is its author and runs this skill. The other agent is its reviewer: the script runs it headless and read-only on the pull request's pushed head. Each review, each answer and each of Cicely's decisions goes on the pull request as a comment, so Cicely reads one record and doesn't have to carry findings from one agent to the other. One more comment, the status comment, is edited as the cross-review moves, and always says where it stands.

It works the same in both directions: when Claude is the author the script runs `codex`, and when Codex is the author it runs `claude`.

Neither agent is trying to win. The aim is the best software, not being right or looking good: concede a finding that's right, and decline one only on the evidence, never to save face. Mistakes and dead-ends go on the record as plainly as fixes, whether they are yours, the reviewer's, or the skill's own, such as a round that cost far more than it found.

## Authority

A request to cross-review a pull request authorizes, for that pull request only:
- running the reviewer
- posting and editing, through the script, the reviewer's comments, your own answers, Cicely's decisions and the status comment
- committing fixes and pushing them to the pull request's branch as new commits

Never force-push, rebase or rewrite its history. Never mark it ready, never merge it, and never resolve review threads or close issues. Never decide for Cicely: anything that needs her goes to her (step 4).

Run this only as the pull request's author. If the other agent wrote it (judge by its branch prefix, such as `claude/` or `codex/`, and its commits), tell Cicely that agent should run it. If she asked you for a review rather than a cross-review, review it yourself instead.

## Requirements

You need Linux, Python 3.10 or newer, Git, an authenticated GitHub CLI, and the reviewer's CLI installed and logged in: `codex` when you are Claude, `claude` when you are Codex. When Claude is the reviewer, a focused check also needs `codex` installed, logged in or not, because Claude's commands run in Codex's sandbox. A project that uses Git LFS also needs `git lfs`. Run the script from this skill's directory:

```bash
python3 scripts/crossreview.py <command> --repository <clone> --pull-request <n>
```

Each command writes one JSON document. Read it even after a nonzero exit: a failure carries an `error` member, and then nothing was posted or recorded, beyond a note on the status comment, unless the error says it posted a comment. In that case don't run the command again; tell Cicely. The script reads the GitHub repository from the remote's configured URL and names it in every `gh` call, so `GH_REPO` never redirects it. A remote that isn't on github.com is refused. Only one command at a time changes a pull request's cross-review; another is refused until it finishes. `status` only reads, so it runs any time.

Your progress is kept in the clone's Git directory, under `ba-crossreview/`. It is never committed, and it belongs to that machine.

## Where things stand

A cross-review can run for half a day, and Cicely may come back to it without remembering where it was. Two things show her where it stands at any moment, from any machine or app:
- **The status comment** on the pull request, posted when the first round starts and edited at every step. While the reviewer works, it shows for how long and what it did last, such as the file it read or the command it ran. At every other moment it holds the briefing below.
- **`status`**, which either agent can run in its own session, even while a review is running. It doesn't ask GitHub, so it knows of commits only as far as the last command saw them:

```bash
python3 scripts/crossreview.py status --repository <clone> --pull-request <n>
```

Commands that reach a stopping point return a `briefing` too: Markdown written for Cicely, who may not have followed the review. It says where the cross-review stands, what each finding came to, what each round cost in time and tokens, and, when something needs her, what it is, why it matters, and what each option implies. When she asks where things are, run `status` and give her its `briefing`.

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
4. runs the reviewer there, in a fresh session in round 1 and resuming that session in later rounds, except that the round after a focused check starts a fresh one, and shows its progress on the status comment
5. posts the review on the pull request word for word, under the reviewer's `[Codex]` or `[Claude]` tag
6. reports the findings that are open, the questions only Cicely can answer, the tokens the reviewer used, and the briefing

The reviewer can only read. Codex runs in its read-only sandbox without your Codex configuration and rules, so no plugin, MCP server or command allowance acts outside the sandbox; it keeps the model and reasoning effort your configuration names. Claude runs in restricted mode with only its Read, Grep and Glob tools, confined to the worktree and the change, and with no MCP servers or connectors.

A reviewer's commands, in a review or a check, can't read the places in your home folder that hold keys and logins: `~/.ssh`, `~/.gnupg`, the logins of Codex, Claude and the GitHub CLI, cloud and container logins, keyrings and browser profiles (`SECRETS` in the script lists them all). Without a network the commands couldn't use them anyway, but a reviewer could quote one in its review, which goes on GitHub. A project whose tests need one of them fails its check with "permission denied" on that path. A folder that holds the checkout, the change or the clone's Git folder stays readable, because hiding it would hide them too. Everything else on the machine can still be read, so a secret kept elsewhere, such as a project's `.env` file, isn't hidden.

Findings are numbered `F1`, `F2` and so on across the whole cross-review, most severe first, with severities `blocker`, `major`, `minor` and `nit`. A question for Cicely comes with why it matters, its options and what each implies, and the reviewer's recommendation. If the reviewer's session can't be resumed, the script starts a new one with the history in the prompt and reports `resumed: false`.

## 3. Answer every open finding

Check each finding against the code yourself, and give it one of three answers:
- **fixed:** it's right. Fix it, add a test where the project expects one, run the project's gate, then commit and push. Name the commit in the note.
- **declined:** it's wrong, or not worth changing. Say why with evidence: the code, a test, or a project rule. Don't decline to avoid work or to save face.
- **escalated:** only Cicely can decide it, for example a question of design, scope or priority, or a point you're unsure of that the code and the project's notes can't settle. Use it too for a finding the reviewer still holds after you have declined it twice; don't argue a third time. Say in the note what she has to decide, then give `stakes`, why it matters, and two to four `options`, each with what it implies, and your `recommendation` if you have one. Write them for someone who hasn't followed the review.

A finding that carries Cicely's decision is answered by what she decided: fix it her way, or decline it where she said to leave it.

Write the answers to a JSON file outside the repository, such as in your scratch folder, and post them:

```json
[{"id": "F1", "action": "fixed", "note": "Adds now, with a test, in 1a2b3c4."},
 {"id": "F2", "action": "declined", "note": "test_widget already covers this: widget.py:40."},
 {"id": "F3", "action": "escalated", "note": "Should the widget be a plugin, or stay a module?",
  "stakes": "A published plugin's interface is hard to change later.",
  "options": [{"choice": "Module", "implies": "Ships now; a plugin can follow."},
              {"choice": "Plugin", "implies": "About a week of packaging before this merges."}],
  "recommendation": "Module, for now: nothing outside the project uses it yet."}]
```

```bash
python3 scripts/crossreview.py reply --repository <clone> --pull-request <n> --replies <file>
```

It refuses unless every open finding has exactly one answer, refuses an escalation without its stakes or without at least two options that each say what they imply, and refuses a `fixed` answer while the pull request is still at the reviewed head, since the reviewer could not see the fix. It posts your answers as your own comment.

**When another round may not be worth it.** If every finding you answered was minor or a nit, and your answers changed fewer than 200 lines, the next round would mostly confirm small fixes and could turn up more small points. Then `reply` doesn't go straight on: it asks Cicely, as the decision `next-round`, whether to have another round, a focused check or neither, with what the last round cost. A blocker or major finding, or bigger changes, go straight to another round.

**When the rounds are used up.** There are three by default. Once they are used, another round is always Cicely's decision, asked as `next-round` too, with what is left and what the last round cost: `reply` asks it when you answer the last round, and `review` asks it, without running the reviewer, when commits are pushed after the cross-review ended at the limit. `--max-rounds` can't raise the limit once it's reached; it's for when Cicely asks for more rounds before they run out. The question lists the commits nobody has reviewed, by short hash and subject, and says what stopping means: those commits stay unreviewed, and anything pushed after them is reviewed, or put to her first, together with them.

**When a few commits come after it settled.** Commits that answer no finding, pushed after a round or check that left nothing to check, such as once the cross-review is `done`, don't go straight to another round when they change fewer than 200 lines. `review` asks her first, as `next-round`, listing them: another round, a focused check of just those commits, or neither. A check she chooses reviews only the commits she was shown; any pushed after she chose come after it, and are reviewed or put to her as usual. Larger ones go straight to another round, or, past the limit, to her as above. Once she has chosen a round, `review` runs it.

**A focused check.** Whenever `next-round` is asked and there are answers to check, or findings an earlier check couldn't verify, one of Cicely's options is a focused check instead of a round. The reviewer checks only those findings and your answers to them, in a fresh session, and gives each a verdict: `verified` resolves it, `problem` opens it again for you to answer, and `not verified` leaves it for her. It may also report a problem that those fixes, or the commits since, introduced, as a new finding. With nothing of that kind to check, the option is a check of the new commits, when they change fewer than 200 lines: the reviewer reviews only those commits, for problems they introduce, and each problem it reports is a new finding for you to answer. A check doesn't count as a round. It runs within limits Cicely set: 1M tokens, cached ones included, and 20 minutes by default. When she sets others for a check, pass them with `--budget-tokens` and `--timeout-minutes`. A check that reaches either limit is stopped and recorded with nothing verified or reviewed, and the next check reads from the last step that ran to the end. The running count can lag by a step, so a check may finish past its token limit: it keeps what it found, and its comment and the briefing say it overran. A Codex check whose running count can't be read fails rather than run without its token limit.

A check may run the project's tests, in a sandbox: the reviewer can write only in its checkout and a temp folder of its own, Git can't write, and there is no network, nor any Unix socket such as D-Bus. What it leaves behind is cleared afterwards. Codex checks in its own sandbox. Claude has its Bash tool for a check, and each command runs in Codex's sandbox, set up the same way, because Claude Code's own sandbox doesn't start headless on Linux here; its other tools only read, confined to the checkout and the change. When a reviewer ends, however it ends, whatever it started that is still running is stopped before the checkout is cleared, as Codex and Claude Code start commands in sessions of their own, which stopping the reviewer doesn't reach. Before a Claude check, a trial command shows that Claude Code runs commands through that sandbox. If it doesn't, the check fails without starting, and says why. The trial takes a few seconds and about a cent, outside the check's limits. After a check, what follows is Cicely's decision again: `reply` asks her once you have answered the problems it found, and `review` asks her at once when it found none to answer but couldn't verify everything. A check that verifies everything, with nothing new, ends the cross-review as `done`, as does a check of new commits that finds no problem in them. A full round after a check starts the reviewer afresh, with the history in its prompt, and reviews every commit since the last full round, as a check looks only at the answers or the new commits.

## 4. Pause for Cicely

When a command reports the turn `cicely`, the cross-review is paused: the reviewer asked a question only she can answer, you escalated a finding, another round may not be worth it, the rounds are used up, or a check she chose has run. Stop and call for her attention: use your harness's notification tool if it has one. Then give her the command's `briefing` as it is, since it is written for her, and add your own view where you have one. Don't run another round, and don't guess her answer. Wait for her.

She decides with your view in front of her, so it goes on the record with her answer: put it, word for word as you gave it to her, in that item's `view`.

Record her answers exactly as she wrote them: don't summarize, tidy or translate them. A decision that later proves wrong has to be traceable to what she was told and what she said. The record is the real pull request. When the cross-review runs against a test or a faked GitHub, her answers land only in that fixture: tell her so at the time, and copy them, with what she was asked, to the real pull request or an Issue before the fixture goes. One answer for each item waiting for her, in a JSON file:

```json
[{"id": "F3", "decision": "Keep it a module for now; I'll plan plugins separately."},
 {"id": "next-round", "decision": "Stop there, the rest is polish.", "choice": "stop",
  "view": "I'd stop: both answers are one-line fixes, and the tests cover them."}]
```

For `next-round`, also give `choice`: `review` for another round, `check` for a focused check, or `stop` to end the cross-review. Past the limit, `review` raises it by one round. If she sets limits for a check, note them for the `review` that runs it. If her answer leaves any of that unclear, ask her again.

```bash
python3 scripts/crossreview.py decide --repository <clone> --pull-request <n> --decisions <file>
```

It refuses unless every item waiting for her has exactly one decision. It posts them on the pull request under the tag `[Cee, via the skill]`, each with what she was asked: the question, why it mattered, the options and the recommendations, and your view, labelled as yours. A question she answered comes back to you as an open finding carrying her decision, to answer in step 3. A finding you escalated goes back to the reviewer with her decision in the next round. When she chooses another round or a focused check, the reviewer gets her words too, since what she says there can settle a finding. Wherever you gave a view, the reviewer gets it with her answer, marked as yours, as her answer may lean on it. Act on what she decided before that round: push any change she asked for.

## 5. Repeat until it settles

Each command's `turn` says what comes next:
- `review`: run the next round. The reviewer checks your fixes in the code, weighs your reasons for declining, holds both of you to Cicely's decisions, and may raise new problems that your changes introduced. It treats a reasoned decline of a minor point as settled unless the reason is wrong on the facts. When all that is left is a few new commits that answer no finding, `review` puts them to Cicely first and returns `cicely` (step 3).
- `check`: Cicely chose a focused check. Run `review`, with her limits if she set any: it runs the check rather than a round.
- `reply`: answer the open findings.
- `cicely`: pause for Cicely's decisions (step 4).
- `done`: nothing is left between you and the reviewer at the reviewed head. From here, add nothing new to the pull request, whichever agent is its author: new work, however small, goes into an Issue or a new pull request, and only fixes for what a review found go into it. Each new commit reopens the review, and it is the author's new work after `done`, not the reviews, that keeps a cross-review going. Commits pushed anyway are reviewed as another round, or first put to Cicely when they are few or the rounds are used up (step 3).
- `stopped`: Cicely ended it rather than have another round. New commits make `review` possible again; past the limit, or when they are few and nothing else is left to check, `review` then asks her first, listing them.
- `limit`: the rounds are used up and something is left unreviewed, but she hasn't been asked yet. Run `review`: it doesn't run the reviewer, but puts the question to her and returns `cicely`.

## 6. Report

```bash
python3 scripts/crossreview.py status --repository <clone> --pull-request <n>
python3 scripts/crossreview.py finish --repository <clone> --pull-request <n>
```

`status` lists the rounds, the reviewed head, what's open, what waits for Cicely, her decisions, every comment, and the briefing. `finish` removes the review worktree and the change files and keeps the record.

At `done` or `stopped`, give Cicely the briefing, then tell her:
- what you fixed
- what you declined, and whether the reviewer accepted your reasons
- what she decided, and how each decision was carried out
- anything still open, with both positions
- any mistake along the way, yours or the reviewer's, and any round that cost much more than it found, said plainly

The pull request stays a draft: marking it ready is her call.

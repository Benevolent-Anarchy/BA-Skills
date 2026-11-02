#!/usr/bin/env python3
"""Has one agent review, headless and read-only, a pull request the other agent wrote, and keeps the ledger.

Claude and Codex review each other's pull requests. The author runs this script; the reviewer is the
other agent's command-line tool, run in a detached worktree at the pull request's pushed head. Every
review, every answer and every one of Cicely's decisions is posted on the pull request, and one status
comment there, edited as things move, says where the cross-review stands. Each command prints one JSON
document; a failure carries an `error` member and has posted nothing but a note on the status comment,
unless the error says it did.
"""
from __future__ import annotations

import argparse
import contextlib
import ctypes
import fcntl
import glob
import hashlib
import json
import os
import queue
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

AGENTS = {'claude': 'Claude', 'codex': 'Codex'}
CICELY = '[Cee, via the skill]'  # The tag on the comments that record Cicely's decisions.
SEVERITIES = ['blocker', 'major', 'minor', 'nit']
# `unverified`: a focused check couldn't tell whether the author's answer holds; Cicely decides what follows.
STATUSES = ['open', 'question', 'unverified', 'resolved']
ACTIONS = {'fixed': 'fixed', 'declined': 'declined', 'escalated': 'for Cicely'}
CHECKPOINT = 'next-round'  # The id of the question whether another round is worth it.
CHOICES = {'review': 'another round', 'check': 'a focused check of the answers', 'stop': 'the cross-review stops here'}
VERDICTS = {'verified': 'resolved', 'problem': 'open', 'not verified': 'unverified'}  # A check's verdict: the status.
TALLIES = {'verified': 'verified', 'problem': 'with a problem', 'not verified': 'not verified'}
FOUND = {'verified': 'The check verified it', 'problem': 'The check found a problem',
         'not verified': "The check couldn't verify it"}
# Answers to only minor or nit findings, or new commits that answer no finding, that change fewer lines make the
# script ask Cicely before another round, and such commits can have a focused check of their own.
SMALL_CHANGE = 200
COMMITS_LISTED = 10  # At most this many unreviewed commits are listed for Cicely; the rest are counted.
# Stopping leaves the commits a question lists unreviewed, and only those: what is pushed later isn't skipped.
LATER_COMMITS = 'Anything pushed after them is reviewed, or put to you first, together with them.'
STATUS_SECONDS = 120  # At most this often, the status comment shows what a running reviewer is doing.
DEFAULT_MAX_ROUNDS = 3
DEFAULT_TIMEOUT_MINUTES = 90
DEFAULT_CHECK_TOKENS = 1_000_000  # Cicely's default limits for a focused check.
DEFAULT_CHECK_MINUTES = 20
STATE_VERSION = 2
LOCKS = []  # Open lock files, held until the process ends.

# Strict structured-output schema: every property required and nothing else allowed, as both
# Codex's --output-schema and Claude's --json-schema accept it.
OPTION_SCHEMA = {
    'type': 'object',
    'additionalProperties': False,
    'required': ['choice', 'implies'],
    'properties': {'choice': {'type': 'string'}, 'implies': {'type': 'string'}},
}
FINDING_SCHEMA = {
    'type': 'object',
    'additionalProperties': False,
    'required': ['id', 'status', 'severity', 'file', 'line', 'title', 'detail', 'stakes', 'options',
                 'recommendation', 'reply'],
    'properties': {
        'id': {'type': ['string', 'null']},
        'status': {'type': 'string', 'enum': ['open', 'question', 'resolved']},
        'severity': {'type': 'string', 'enum': SEVERITIES},
        'file': {'type': ['string', 'null']},
        'line': {'type': ['integer', 'null']},
        'title': {'type': 'string'},
        'detail': {'type': 'string'},
        'stakes': {'type': ['string', 'null']},
        'options': {'type': ['array', 'null'], 'items': OPTION_SCHEMA},
        'recommendation': {'type': ['string', 'null']},
        'reply': {'type': ['string', 'null']},
    },
}
REVIEW_SCHEMA = {
    'type': 'object',
    'additionalProperties': False,
    'required': ['summary', 'findings'],
    'properties': {'summary': {'type': 'string'}, 'findings': {'type': 'array', 'items': FINDING_SCHEMA}},
}
CHECK_SCHEMA = {
    'type': 'object',
    'additionalProperties': False,
    'required': ['summary', 'verdicts', 'problems'],
    'properties': {
        'summary': {'type': 'string'},
        'verdicts': {'type': 'array', 'items': {
            'type': 'object',
            'additionalProperties': False,
            'required': ['id', 'verdict', 'evidence'],
            'properties': {'id': {'type': 'string'}, 'verdict': {'type': 'string', 'enum': list(VERDICTS)},
                           'evidence': {'type': 'string'}},
        }},
        'problems': {'type': 'array', 'items': {
            'type': 'object',
            'additionalProperties': False,
            'required': ['severity', 'file', 'line', 'title', 'detail'],
            'properties': {'severity': {'type': 'string', 'enum': SEVERITIES}, 'file': {'type': ['string', 'null']},
                           'line': {'type': ['integer', 'null']}, 'title': {'type': 'string'},
                           'detail': {'type': 'string'}},
        }},
    },
}

INTRO = """You are {reviewer}, reviewing pull request #{number} in {repository}, "{title}", which {author} wrote. \
Your findings go to {author}, who will fix what it agrees with and answer the rest. What you two can't settle \
goes to Cicely, who owns the project.

Your working directory is a detached checkout of the pull request's head, {head}. It targets {base_branch}, \
which is at {base}. The whole change, `git diff {merge_base}...{head}`, is in `{change}`, and its commits, \
`git log --stat {merge_base}..{head}`, are in `{commits}`.

The pull request's description:

{body}
"""

LOOK = """
Read the project's AGENTS.md or CLAUDE.md first and hold the change to its rules. Then read the whole change \
and the code around it. Look for:
- bugs: wrong results, crashes, lost data, races, security holes, broken error handling
- behaviour the description promises that the change doesn't deliver, or changes it doesn't mention
- missing or wrong tests for what changed, and documentation the change makes untrue
- anything the project's notes require that the change skips

Check each suspicion against the code before reporting it, and drop it if it doesn't hold. {tools} Don't \
edit, commit, push or post anything: your answer is only the JSON.
"""

REPORT = """
Report each problem once: its file and line, a short title, and in `detail` what goes wrong, a concrete case \
that shows it, and the fix if it's clear. Severity: `blocker` must not merge as it is, `major` should be fixed \
before merging, `minor` is worth fixing, `nit` is optional. Leave out style preferences the project doesn't state.

When only Cicely can settle a point, because it turns on intent, scope or priority, or you're unsure and the \
code and the project's notes can't tell you, report it with `status` "question". The cross-review pauses until \
she answers. She may come to it hours later without having followed the review, so make it stand on its own: in \
`detail`, what she has to decide and the background she needs; in `stakes`, why it matters: what goes wrong, or \
what it costs, if it's decided badly; in `options`, two to four real alternatives, each with what it implies for \
the code, the work and the people who use it; and in `recommendation`, the one you'd pick and why, or null if you \
have no lean. For every other finding, `stakes`, `options` and `recommendation` are null.
"""

FIRST_ROUND = """
Give every finding `id` null, `status` "open" (or "question") and `reply` null. If the change holds up, return \
no findings and say so in `summary`.
"""

LATER_ROUND = """This is round {round} of your review of pull request #{number}. Since your last review its head \
moved from {previous_head} to {head}, and your working directory is now at {head}. The new commits, \
`git log --first-parent --stat {previous_head}..{head}`, are in `{since_commits}`, and their changes, \
`git diff {previous_head} {head}`, are in `{since}`. `{change}` and `{commits}` now hold the whole change \
against {base_branch}, as of {head}.

{author} answered your open findings:

{answers}

Re-list each finding answered above, keeping its id. Mark it `resolved` when the fix is in {head} and is right, \
or when the answer shows the finding was wrong. Otherwise keep it `open` and say in `reply` why it still \
stands. A minor or nit finding that {author} declined with a reason is settled unless the reason is wrong on the \
facts; don't keep one open over a matter of taste. Judge fixes by the code, not by the answer. Cicely owns the project, so her decisions settle what they \
cover: mark such a finding `resolved` once {head} follows her decision, and don't argue it again. Add a new \
finding, with `id` null and `reply` null, only for a problem the changes since {previous_head} introduced, a \
blocker you missed before, or a question only Cicely can settle. Don't raise new minor points on code you \
already reviewed. As before, only read, and answer only with the JSON.
"""

RESUME_LOST = """
You reviewed this pull request before, in a session that can no longer be resumed. Where it stands is below.

"""

AFTER_CHECK = """
You reviewed this pull request before. Since then a focused check ran in another session, so this review starts \
afresh. Where it stands is below.

"""

CHECK = """You are {reviewer}. {author} wrote pull request #{number} in {repository}, "{title}", and you reviewed \
it. {author} has answered the findings below. Cicely, who owns the project, chose a focused check of those answers \
instead of another full review, and this is that check. It runs in a fresh session, so what you need is here.

Your working directory is a detached checkout of the pull request's head, {head}. The answers came after \
{previous_head}: the commits since, `git log --first-parent --stat {previous_head}..{head}`, are in \
`{since_commits}`, and their changes, `git diff {previous_head} {head}`, are in `{since}`. `{change}` holds the \
whole change against {base_branch}. Read the project's AGENTS.md or CLAUDE.md where it bears on these answers.

The findings, and {author}'s answers:

{answers}

Check only these. Give each its id and a verdict: `verified` when the fix is in {head} and is right, or the \
answer shows the finding was wrong; `problem` when it isn't, saying why; `not verified` when you couldn't tell. \
Cicely's decisions settle what they cover, and a minor or nit finding declined with a reason is settled unless the \
reason is wrong on the facts. In `evidence`, cite files and lines, and the tests you ran and what they showed.

A fix that is missing or wrong is that finding's `problem` verdict: don't list it again in `problems`. List there only \
a new problem that one of these fixes, or the commits since {previous_head}, introduced, and leave everything else out.

{tools}

You have about {budget} tokens, cached ones included, and {minutes} minutes. A check that runs past either is \
stopped and reports nothing, so check the answers that matter most first, and answer while you have room to: mark \
what you didn't reach `not verified`. Don't commit, push or post anything: your answer is only the JSON.
"""

CHECK_COMMITS = """You are {reviewer}. {author} wrote pull request #{number} in {repository}, "{title}", and you \
reviewed it up to {previous_head}. Since then, commits that answer no finding have been pushed. Cicely, who owns \
the project, chose a focused check of those commits instead of another full review, and this is that check. It \
runs in a fresh session, so what you need is here.

Your working directory is a detached checkout of the pull request's head, {head}. The commits since \
{previous_head}, `git log --first-parent --stat {previous_head}..{head}`, are in `{since_commits}`, and their \
changes, `git diff {previous_head} {head}`, are in `{since}`. `{change}` holds the whole change against \
{base_branch}. Read the project's AGENTS.md or CLAUDE.md where it bears on these commits.

The pull request's description:

{body}{said}

Review only these commits. In `problems`, list each problem they introduce: a bug, behaviour the description \
promises that they break, a missing or wrong test for what they change, documentation they make untrue, or \
something the project's notes require that they skip. Check each suspicion against the code before you report \
it, and in `detail` cite files and lines, and the tests you ran and what they showed. Leave out everything else, \
points on code you reviewed before among them, and leave `verdicts` empty. If the commits hold up, report no \
problems and say so in `summary`.

{tools}

You have about {budget} tokens, cached ones included, and {minutes} minutes. A check that runs past either is \
stopped and reports nothing, so look at what matters most first, and answer while you have room to. Don't \
commit, push or post anything: your answer is only the JSON.
"""


class Refusal(Exception):
    """A refusal or failure, reported as the command's `error`; nothing was posted unless it says so."""


class TimedOut(Refusal):
    """A command ran past its time limit and was stopped."""


class LimitReached(Refusal):
    """A focused check ran into its token or time limit and was stopped; `usage` is what it had used by then."""

    def __init__(self, message: str, limit: str, usage: dict) -> None:
        super().__init__(message)
        self.limit, self.usage = limit, usage


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec='seconds')


def run(args: list[str], cwd: Path | None = None, input: str | None = None, env: dict | None = None,
        timeout: float | None = None) -> subprocess.CompletedProcess:
    """Runs a command to completion with UTF-8 text streams; on timeout ends it and everything it started."""
    process = subprocess.Popen(args, cwd=cwd, env=env, text=True, encoding='utf-8', errors='replace',
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    try:
        stdout, stderr = process.communicate(input, timeout=timeout)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise TimedOut(f'{Path(args[0]).name} did not finish within {timeout / 60:g} minutes and was stopped.')
    return subprocess.CompletedProcess(args, process.returncode, stdout, stderr)


PR_SET_CHILD_SUBREAPER = 36  # From <linux/prctl.h>.


@contextlib.contextmanager
def adopting():
    """While it lasts, a process whose parent ends is handed to this one, rather than to the system, so whatever a
    reviewer starts stays among this process's descendants, however it was started and whenever its parent ends."""
    prctl = ctypes.CDLL(None, use_errno=True).prctl
    if prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0):
        raise Refusal('The reviewer wasn\'t started: what it starts couldn\'t be kept in reach, to be stopped when it '
                      f'ends ({os.strerror(ctypes.get_errno())}).')
    try:
        yield
    finally:
        prctl(PR_SET_CHILD_SUBREAPER, 0, 0, 0, 0)


@adopting()
def run_streaming(args: list[str], cwd: Path, input: str, env: dict | None, timeout: float,
                  on_line) -> subprocess.CompletedProcess:
    """Runs a reviewer like `run`, handing each line it prints to `on_line` as it comes, and None after a few
    quiet seconds, so its progress can be shown while it works. However the reviewer ends, whatever it started that
    is still running is stopped: see `end_strays`."""
    process = subprocess.Popen(args, cwd=cwd, env=env, text=True, encoding='utf-8', errors='replace',
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    lines, errors = queue.Queue(), []

    def feed() -> None:
        with contextlib.suppress(OSError):
            try:
                process.stdin.write(input)
            finally:
                process.stdin.close()

    def read() -> None:
        for line in process.stdout:
            lines.put(line)
        lines.put(None)

    threads = [threading.Thread(target=feed, daemon=True), threading.Thread(target=read, daemon=True),
               threading.Thread(target=lambda: errors.append(process.stderr.read()), daemon=True)]
    for thread in threads:
        thread.start()
    deadline, output = time.monotonic() + timeout, []
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(args, timeout)
            try:
                line = lines.get(timeout=min(remaining, 5))
            except queue.Empty:
                on_line(None)
                continue
            if line is None:
                break
            output.append(line)
            on_line(line)
        process.wait(max(deadline - time.monotonic(), 0.1))
    except BaseException as error:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        end_strays()
        if isinstance(error, subprocess.TimeoutExpired):
            raise TimedOut(f'{Path(args[0]).name} did not finish within {timeout / 60:g} minutes and was stopped.')
        raise
    end_strays()
    for thread in threads:
        thread.join(5)
    return subprocess.CompletedProcess(args, process.returncode, ''.join(output), ''.join(errors))


def processes() -> dict[int, tuple[int, str]]:
    """Each live process's parent and start time, by process id."""
    found = {}
    for entry in Path('/proc').iterdir():
        if entry.name.isdigit():
            with contextlib.suppress(OSError, ValueError, IndexError):
                stat = (entry / 'stat').read_text(encoding='utf-8', errors='replace')
                fields = stat[stat.rindex(')') + 2:].split()  # The name, in parentheses, may hold anything.
                if fields[0] != 'Z':
                    found[int(entry.name)] = (int(fields[1]), fields[19])
    return found


def descendants(roots: set[int], running: dict[int, tuple[int, str]]) -> dict[int, str]:
    """The `running` processes that `roots` started, and those started in turn, with their start times."""
    found = {}
    while True:
        more = {pid: start for pid, (parent, start) in running.items()
                if (parent in roots or parent in found) and pid not in roots and pid not in found}
        if not more:
            return found
        found.update(more)


def end_strays(seconds: float = 10) -> None:
    """Stops whatever is still running of what this process's children started, now that the reviewer, the one
    child it waits for, has ended, and waits for it to go. Codex and Claude Code start commands in sessions of their
    own, which ending them doesn't reach, and one could go on writing to the checkout after it is cleared. While
    `adopting`, all of them are this process's descendants, so it is done once this process has no child left. The
    system says so, not the list of processes, which can miss a process that starts another and ends while it is
    read."""
    me, deadline = os.getpid(), time.monotonic() + seconds
    while True:
        for pid in descendants({me}, processes()):
            with contextlib.suppress(OSError):
                os.kill(pid, signal.SIGKILL)
        try:
            while os.waitpid(-1, os.WNOHANG)[0]:  # The ended are this process's children now, to be waited for.
                pass
        except ChildProcessError:  # None is left.
            return
        if time.monotonic() > deadline:
            return
        time.sleep(0.05)


def end_processes(noted: dict[int, str], seconds: float = 10) -> None:
    """Stops the `noted` processes that are still running, and whatever they started, and waits for them to go. A
    process is known by its start time as well as its id, so one that took over a finished process's id is left
    alone."""
    if not noted:
        return
    running = processes()
    doomed = {pid: start for pid, start in noted.items() if running.get(pid, (0, None))[1] == start}
    doomed.update(descendants(set(doomed), running))
    for pid in doomed:
        with contextlib.suppress(OSError):
            os.kill(pid, signal.SIGKILL)
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        running = processes()
        if not any(running.get(pid, (0, None))[1] == start for pid, start in doomed.items()):
            break
        time.sleep(0.1)


def tail(text: str, lines: int = 20) -> str:
    return '\n'.join(text.strip().splitlines()[-lines:])


def git(repo: Path, *args: str) -> str:
    result = run(['git', '-C', str(repo), *args])
    if result.returncode != 0:
        raise Refusal(f'git {" ".join(args)} failed: {tail(result.stderr)}')
    return result.stdout.strip()


def github_repository(repo: Path, remote: str) -> str:
    """Owner and name of the GitHub repository the remote's configured URL names; never echoes the URL."""
    result = run(['git', '-C', str(repo), 'config', '--get', f'remote.{remote}.url'])
    url = result.stdout.strip()
    match = re.match(r'^(?:https://(?:[^@/]+@)?github\.com/|ssh://git@github\.com/|ssh://git@ssh\.github\.com:443/'
                     r'|git@github\.com:)'
                     r'([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+?)(?:\.git)?/?$', url)
    if result.returncode != 0 or not match:
        raise Refusal(f'Remote {remote} is not a github.com repository.')
    return f'{match.group(1)}/{match.group(2)}'


def gh(repository: str | None, *args: str, input: str | None = None) -> str:
    """Runs the GitHub CLI against the named repository, so GH_REPO and the CLI's default never redirect it.
    `gh api` takes no repository; its path names one."""
    executable = shutil.which('gh')
    if not executable:
        raise Refusal('The GitHub CLI (gh) is not on PATH.')
    result = run([executable, *args, *(['--repo', repository] if repository else [])], input=input)
    if result.returncode != 0:
        raise Refusal(f'gh {" ".join(args[:2])} failed: {tail(result.stderr)}')
    return result.stdout.strip()


def pull_request(repository: str, number: int) -> dict:
    fields = 'number,title,body,state,isDraft,headRefOid,headRefName,baseRefName,url'
    return json.loads(gh(repository, 'pr', 'view', str(number), '--json', fields))


def current_head(repository: str, number: int, state: dict) -> tuple[str | None, str | None]:
    """The pull request's head as GitHub has it now, so commits pushed since the last command count, or, if GitHub
    can't say, the head that command saw, with a warning saying so."""
    try:
        return pull_request(repository, number)['headRefOid'], None
    except Refusal as error:
        seen = state.get('pullRequestHead')
        return seen, (f'GitHub couldn\'t be asked for the pull request\'s head, so this goes by the head the last '
                      f'command saw{f", `{seen[:7]}`" if seen else ""}, and knows of no commit pushed since. {error}')


def post(repository: str, number: int, body: str) -> str:
    output = gh(repository, 'pr', 'comment', str(number), '--body-file', '-', input=body).splitlines()
    return output[-1] if output else None


def edit(repository: str, comment: int, body: str) -> None:
    gh(None, 'api', '--method', 'PATCH', f'repos/{repository}/issues/comments/{comment}', '--input', '-',
       input=json.dumps({'body': body}))


def fetch(repo: Path, remote: str, ref: str, into: str) -> str:
    """Fetches `ref` into the local ref `into`, which only this pull request's cross-review writes. FETCH_HEAD is
    shared by every fetch in the clone, so cross-reviews of other pull requests running at the same time could
    change it between this fetch and its read; it is left as it was."""
    git(repo, 'fetch', '--quiet', '--no-tags', '--no-write-fetch-head', remote, f'+{ref}:{into}')
    return git(repo, 'rev-parse', '--verify', f'{into}^{{commit}}')


def fetched(path: Path, name: str) -> str:
    """The local ref a cross-review fetches its pull request's `name`, head or base, into: named after its ledger,
    whose lock keeps any other command from writing it meanwhile. A ledger's name may hold dots, which a ref name
    can't always, and may be long, while each part of a ref name is a file name. So the ref keeps a readable part
    of the ledger's name, with a hash of all of it: two ledgers never share refs, and the part stays short."""
    readable = re.sub(r'[^A-Za-z0-9_-]', '_', path.stem)[:64]
    digest = hashlib.sha256(path.stem.encode('utf-8')).hexdigest()[:16]
    return f'refs/ba-crossreview/{readable}-{digest}/{name}'


def common_dir(repo: Path) -> Path:
    path = Path(git(repo, 'rev-parse', '--git-common-dir'))
    return (path if path.is_absolute() else repo / path).resolve()


def state_path(repo: Path, repository: str, number: int) -> Path:
    slug = re.sub(r'[^A-Za-z0-9._-]', '_', repository.replace('/', '-'))
    return common_dir(repo) / 'ba-crossreview' / f'{slug}-{number}.json'


def load_state(path: Path) -> dict | None:
    if not path.exists():
        return None
    state = json.loads(path.read_text(encoding='utf-8'))
    if state.get('version') == 1:
        migrate(state)
    if state.get('version') != STATE_VERSION:
        raise Refusal(f'{path} was written by another version of this script.')
    return state


def migrate(state: dict) -> None:
    """Brings a version 1 ledger up to date. Version 1 kept the one question whether to have another round, which
    was only ever asked after answers to minor findings, in the round's answers; version 2 lists every such
    question on the round, with why it was asked and at what head."""
    for round in state['rounds']:
        asked = (round.get('answers') or {}).pop('checkpoint', None)
        if asked and 'checkpoints' not in round:
            round['checkpoints'] = [dict(asked, reason='small', round=round['round'], head=round['answers']['head'])]
    state['version'] = 2


def lock(path: Path) -> None:
    """Holds the pull request's lock until the command ends, so two commands can't both change its ledger or move
    its checkout. The operating system releases it however the process ends."""
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = open(path.with_suffix('.lock'), 'a+b')
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.close()
        raise Refusal('Another cross-review command is running for this pull request; wait for it to finish.')
    LOCKS.append(handle)


def write_temporary(path: Path, state: dict) -> str:
    handle, temporary = tempfile.mkstemp(dir=path.parent, prefix=path.name, suffix='.tmp')
    try:
        with os.fdopen(handle, 'w', encoding='utf-8') as stream:
            json.dump(state, stream, indent=2, ensure_ascii=False)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(temporary)
        raise
    return temporary


def save(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = write_temporary(path, state)
    try:
        os.replace(temporary, path)
    except OSError:
        with contextlib.suppress(OSError):
            os.unlink(temporary)
        raise


def post_and_save(path: Path, state: dict, record: dict, repository: str, number: int, body: str) -> None:
    """Posts a comment and records it, with its link in `record`, in the ledger.

    The ledger is written before the comment is posted, so a folder that can't be written or a full disk stops
    the command with nothing posted. If adding the link then fails, the record is kept without it."""
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        staged = write_temporary(path, state)
    except OSError as error:
        raise Refusal(f'Could not write the record in {path.parent}: {error}')
    try:
        record['commentUrl'] = post(repository, number, body)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(staged)
        raise
    try:
        final = write_temporary(path, state)
    except OSError:
        final = staged
    else:
        with contextlib.suppress(OSError):
            os.unlink(staged)
    try:
        os.replace(final, path)
    except OSError as error:
        raise Refusal(f'Posted {record["commentUrl"]}, but could not record it in {path}: {error}. '
                      "Don't run the command again; tell Cicely.")


def review_worktree(repo: Path, repository: str, number: int) -> Path:
    """One fixed checkout per pull request and clone, because a resumed reviewer session runs where it began."""
    clone = hashlib.sha1(str(common_dir(repo)).encode('utf-8')).hexdigest()[:8]
    slug = re.sub(r'[^A-Za-z0-9._-]', '_', repository.replace('/', '-'))
    return Path(tempfile.gettempdir()) / 'ba-crossreview' / f'{slug}-{number}-{clone}'


def change_folder(worktree: Path) -> Path:
    return worktree.with_name(worktree.name + '.change')


def same_path(left: str | Path, right: str | Path) -> bool:
    return os.path.realpath(left) == os.path.realpath(right)


def listed_worktrees(repo: Path) -> list[str]:
    return [line[9:] for line in git(repo, 'worktree', 'list', '--porcelain').splitlines() if line.startswith('worktree ')]


def scratch_folder(worktree: Path) -> Path:
    """The private temp folder a focused check may write in, besides its checkout."""
    return worktree.with_name(worktree.name + '.tmp')


def check_out(repo: Path, worktree: Path, head: str) -> None:
    """Puts the review checkout at `head`, with nothing in it that isn't in that commit, such as what a focused check's
    tests left behind."""
    if worktree.exists() and any(same_path(worktree, listed) for listed in listed_worktrees(repo)):
        git(worktree, 'checkout', '--quiet', '--force', '--detach', head)
        git(worktree, 'clean', '-ffdxq')
        return
    git(repo, 'worktree', 'prune')
    if worktree.exists():
        shutil.rmtree(worktree)
    worktree.parent.mkdir(parents=True, exist_ok=True)
    git(repo, 'worktree', 'add', '--quiet', '--detach', str(worktree), head)


def hydrate(worktree: Path, remote: str) -> None:
    """Pulls the head's Git LFS objects, which the read-only reviewer can't, and refuses to review pointers.

    LFS is in use when a tracked .gitattributes file or the clone's info/attributes names its filter, or when
    Git LFS, if installed, lists any file in the checkout."""
    found = run(['git', '-C', str(worktree), 'grep', '-q', '-e', 'filter=lfs', '--', ':(glob)**/.gitattributes'])
    if found.returncode not in (0, 1):
        raise Refusal(f'Could not check the checkout for Git LFS: {tail(found.stderr)}')
    info = common_dir(worktree) / 'info' / 'attributes'
    configured = found.returncode == 0 or (info.is_file() and 'filter=lfs' in info.read_text(errors='replace'))
    installed = run(['git', '-C', str(worktree), 'lfs', 'version']).returncode == 0
    if installed and not configured:
        configured = bool(git(worktree, 'lfs', 'ls-files'))
    if not configured:
        return
    if not installed:
        raise Refusal('The pull request uses Git LFS, but Git LFS is not installed.')
    git(worktree, 'lfs', 'pull', remote)
    # Each line is "<oid> <marker> <path>": "*" for a full object, "-" for a pointer.
    pointers = [line.split(' ', 2)[2] for line in git(worktree, 'lfs', 'ls-files').splitlines()
                if len(line.split(' ', 2)) == 3 and line.split(' ', 2)[1] == '-']
    if pointers:
        raise Refusal(f'Git LFS left {len(pointers)} files as pointers, such as {pointers[0]}; the reviewer would '
                      'not see their content.')


def write_change(repo: Path, folder: Path, context: dict) -> None:
    """Writes the change and its commits to files the reviewer reads, as Claude's reviewer can't run Git."""
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True)
    head, merge_base = context['head'], context['merge_base']
    files = {'change': ('change.diff', ['diff', '--no-color', '--no-ext-diff', f'{merge_base}...{head}']),
             'commits': ('commits.txt', ['log', '--no-color', '--stat', f'{merge_base}..{head}'])}
    if 'previous_head' in context:
        previous = context['previous_head']
        files['since'] = ('since.diff', ['diff', '--no-color', '--no-ext-diff', previous, head])
        files['since_commits'] = ('since.txt', ['log', '--no-color', '--first-parent', '--stat', f'{previous}..{head}'])
    for key, (name, args) in files.items():
        (folder / name).write_text(git(repo, *args) + '\n', encoding='utf-8')
        context[key] = str(folder / name)


def remove_worktree(repo: Path, worktree: Path) -> bool:
    if not any(same_path(worktree, listed) for listed in listed_worktrees(repo)):
        return False
    git(repo, 'worktree', 'remove', '--force', str(worktree))
    return True


def codex_settings() -> list[str]:
    """The model and reasoning effort Codex's own configuration names, which --ignore-user-config would drop."""
    home = Path(os.environ.get('CODEX_HOME') or Path.home() / '.codex')
    try:
        text = (home / 'config.toml').read_text(encoding='utf-8')
    except OSError:
        return []
    top = re.split(r'(?m)^[ \t]*\[', text, maxsplit=1)[0]  # Top-level keys come before the first table.
    settings = []
    for key in ('model', 'model_reasoning_effort'):
        # A TOML basic ("...") or literal ('...') string.
        match = re.search(rf'(?m)^[ \t]*{key}[ \t]*=[ \t]*(["\'])([A-Za-z0-9._:/-]+)\1[ \t]*(?:#.*)?$', top)
        if match:
            settings += ['-c', f'{key}="{match.group(2)}"']
    return settings


HIDDEN = 'The files and folders in your home that hold keys and logins, such as `~/.ssh`, can\'t be read.'
TOOLS = {
    'codex': 'You may run commands that only read, such as `git show`. You cannot write files, so don\'t rely on '
             'builds or tests that write. ' + HIDDEN,
    'claude': 'You have only the Read, Grep and Glob tools, limited to your working directory and the folder holding '
              'the change, so you can\'t run commands or tests.',
}
# Cicely's decision: a check may run tests, sandboxed. Claude's commands run in Codex's sandbox, set up as for
# Codex's own checks: see `sandbox_shell`.
SANDBOX = ('in a sandbox: you can write only in your working directory and in the temp folder `$TMPDIR` names, Git '
           'can\'t write, and there is no network. ' + HIDDEN + ' You may undo a fix to see whether a test catches it, '
           'but put it back. Whatever you leave in your working directory is discarded after the check.')
# Cicely's decision (2 November 2026): a reviewer's commands can't read the keys and logins in your home folder, as
# a reviewer could quote one in its review, which goes on GitHub. Without a network, commands couldn't use them
# anyway. Patterns, relative to your home folder; one that holds a path the reviewer needs isn't hidden.
SECRETS = ('.ssh', '.gnupg', '.password-store', '.local/share/keyrings', '.pki', '.netrc', '.git-credentials',
           '.config/gh', '.codex', '.claude', '.claude.json', '.aws', '.azure', '.config/gcloud', '.kube', '.docker',
           '.mozilla', '.config/google-chrome*', '.config/chromium*', '.config/BraveSoftware',
           '.config/microsoft-edge*')
CHECK_TOOLS = {
    'codex': 'You may run commands, the project\'s tests among them, ' + SANDBOX,
    'claude': 'You have the Read, Grep and Glob tools, limited to your working directory and the folder holding the '
              'change, and the Bash tool, whose commands, the project\'s tests among them, run ' + SANDBOX,
}
SANDBOX_PROFILE = 'ba_crossreview_check'  # The name of the Codex permissions profile a reviewer's commands run in.
SANDBOX_TRIAL = 'Run the command `true` once with the Bash tool, then reply "done". Do nothing else.'
SANDBOX_TRIAL_MINUTES = 3


def event_of(line: str | None) -> dict:
    try:
        event = json.loads(line) if line else None
    except ValueError:
        return {}
    return event if isinstance(event, dict) else {}


def short(text: str, length: int = 100) -> str:
    """One line of at most `length` characters, safe inside Markdown code spans."""
    text = ' '.join(str(text).split()).replace('`', "'")
    return text if len(text) <= length else text[:length - 1] + '…'


def codex_activity(event: dict) -> str | None:
    item = event.get('item') if isinstance(event.get('item'), dict) else {}
    if event.get('type') == 'item.started' and item.get('type') == 'command_execution':
        # Codex wraps each command in `bash -lc '...'`.
        command = str(item.get('command') or '')
        inner = re.fullmatch(r'\S*/(?:ba)?sh -lc ([\'"])(.*)\1', command.strip(), re.S)
        return f'ran `{short(inner.group(2) if inner else command)}`'
    if event.get('type') == 'item.completed' and item.get('type') == 'reasoning' and str(item.get('text') or '').strip():
        return f'thinking: {short(str(item["text"]).strip().splitlines()[0].strip("*# "))}'
    if event.get('type') == 'item.completed' and item.get('type') == 'agent_message':
        # Notes along the way are prose; the review itself is the JSON answer.
        text = str(item.get('text') or '').strip()
        return 'writing up the review' if text.startswith('{') or not text else f'noted: {short(text)}'
    return None


def claude_activity(event: dict, worktree: Path) -> str | None:
    content = (event.get('message') or {}).get('content') if event.get('type') == 'assistant' else None
    for part in reversed(content if isinstance(content, list) else []):
        if not isinstance(part, dict) or part.get('type') != 'tool_use':
            continue
        name, input = part.get('name'), part.get('input') if isinstance(part.get('input'), dict) else {}
        if name == 'Read':
            path = str(input.get('file_path') or '')
            with contextlib.suppress(ValueError):
                path = str(Path(path).relative_to(worktree))
            return f'read `{short(path)}`'
        if name in ('Grep', 'Glob'):
            return f'{"searched for" if name == "Grep" else "listed"} `{short(input.get("pattern") or "", 60)}`'
        if name == 'Bash':
            return f'ran `{short(str(input.get("command") or ""))}`'
        if name == 'StructuredOutput':
            return 'writing up the review'
    return None


class Progress:
    """What a running reviewer is doing. It's kept in a file beside the ledger, which `status` reads, and shown on
    the status comment at its first step and at most every STATUS_SECONDS after."""

    def __init__(self, path: Path, work: dict, head: str, publish) -> None:
        """`work` says what runs: its `round`, what it is `doing`, such as "reviewing round 2", and its `verb`."""
        self.path, self.publish, self.shown = path.with_name(path.stem + '.progress.json'), publish, None
        self.now = dict(work, pid=os.getpid(), head=head, startedAt=now(), latest=None, steps=0)
        self.write()

    def write(self) -> None:
        with contextlib.suppress(OSError):
            temporary = self.path.with_suffix('.tmp')
            temporary.write_text(json.dumps(self.now), encoding='utf-8')
            os.replace(temporary, self.path)

    def step(self, activity: str | None) -> None:
        if activity:
            self.now.update(latest=activity, steps=self.now['steps'] + 1, updatedAt=now())
            self.write()
        if self.now['latest'] and (self.shown is None or time.monotonic() - self.shown >= STATUS_SECONDS):
            self.shown = time.monotonic()
            self.publish(dict(self.now))

    def close(self) -> None:
        with contextlib.suppress(OSError):
            self.path.unlink()


def running(path: Path) -> dict | None:
    """The reviewer at work for this pull request, if a review is running."""
    try:
        progress = json.loads(path.with_name(path.stem + '.progress.json').read_text(encoding='utf-8'))
        os.kill(progress['pid'], 0)
    except (OSError, ValueError, KeyError, TypeError):
        return None
    return progress


def tokens(usage: dict) -> int:
    """Tokens in and out, cached ones included, as a round's cost counts them."""
    return usage['input'] + usage['output']


def over_budget(budget: int | None, usage: dict) -> None:
    """Stops a focused check that has used more than its budget, by raising inside the reader of its output."""
    if budget and tokens(usage) > budget:
        raise LimitReached(f'The check used about {amount(tokens(usage))} tokens, past its limit of {amount(budget)}, '
                           'and was stopped.', 'token', dict(usage))


def rollout_home() -> Path:
    return Path(os.environ.get('CODEX_HOME') or Path.home() / '.codex')


def rollout(thread: str) -> Path | None:
    """The file Codex logs a session to as it runs, which has its running token count."""
    return next(iter(sorted(rollout_home().glob(f'sessions/*/*/*/rollout-*-{glob.escape(thread)}.jsonl'))), None)


def run_codex(executable: str, worktree: Path, change: Path, prompt: str, session: str | None,
              timeout: float, progress: Progress, check: dict | None = None) -> tuple[str, dict, dict]:
    """Runs Codex as the reviewer, or, given a `check` with its token `budget` and `scratch` folder, as a focused
    check that may run tests."""
    with tempfile.TemporaryDirectory(prefix='ba-crossreview-') as scratch:
        schema, last = Path(scratch) / 'schema.json', Path(scratch) / 'review.json'
        schema.write_text(json.dumps(CHECK_SCHEMA if check else REVIEW_SCHEMA), encoding='utf-8')
        # A review only reads, and a check may write only in its checkout and its own temp folder, never in /tmp at
        # large: see `sandbox_profile`. `exec resume` takes no --sandbox, so the sandbox is set as configuration for
        # both. Leaving out the user's configuration and rules leaves out its plugins, MCP servers and command
        # allowances, which act outside the sandbox.
        profile = sandbox_profile([change, common_dir(worktree)], [worktree, check['scratch']] if check else [])
        sandbox = ['-c', profile, '-c', f'default_permissions="{SANDBOX_PROFILE}"']
        args = [executable, 'exec', *(['resume', session] if session else []),
                '--ignore-user-config', '--ignore-rules', *codex_settings(), *sandbox, '-c', 'approval_policy="never"',
                '--output-schema', str(schema), '-o', str(last), '--json', '-']
        env = dict(os.environ, TMPDIR=str(check['scratch'])) if check else None
        found = {'thread': None, 'usage': {'input': 0, 'cached': 0, 'output': 0},
                 'live': {'input': 0, 'cached': 0, 'output': 0}, 'log': None, 'read': 0}

        def count() -> None:
            # Codex's JSON output gives the tokens only at the end, but its session log has a running total. The
            # budget is checked as Codex logs it, so a check can overrun it by a step; one that finishes past it
            # keeps what it found, with a warning.
            if not found['log'] and found['thread']:
                found['log'] = rollout(found['thread'])
            if not found['log']:
                return
            try:
                with open(found['log'], 'rb') as stream:
                    stream.seek(found['read'])
                    data = stream.read()
            except OSError:
                return
            complete = data.rfind(b'\n') + 1
            found['read'] += complete
            for line in data[:complete].decode('utf-8', 'replace').splitlines():
                payload = event_of(line).get('payload')
                info = payload.get('info') if isinstance(payload, dict) and payload.get('type') == 'token_count' else None
                total = info.get('total_token_usage') if isinstance(info, dict) else None
                if isinstance(total, dict):
                    found['live'] = {'input': int(total.get('input_tokens') or 0),
                                     'cached': int(total.get('cached_input_tokens') or 0),
                                     'output': int(total.get('output_tokens') or 0)}

        def on_line(line: str | None) -> None:
            event = event_of(line)
            if event.get('type') == 'thread.started':
                found['thread'] = event.get('thread_id')
            if event.get('type') == 'turn.completed' and isinstance(event.get('usage'), dict):
                for key, name in (('input', 'input_tokens'), ('cached', 'cached_input_tokens'),
                                  ('output', 'output_tokens')):
                    found['usage'][key] += int(event['usage'].get(name) or 0)
            progress.step(codex_activity(event))
            if check and isinstance(found['thread'], str):
                count()
                # Codex starts the log with the session, before its first step, so a log still missing once a step
                # is done can't be read, and the check would run without its token limit.
                if not found['log'] and event.get('type') == 'item.completed':
                    raise Refusal('The check was stopped before it could run past its token limit unseen: Codex\'s '
                                  'session log, which has its running token count, wasn\'t found under '
                                  f'{rollout_home()}/sessions.')
                over_budget(check['budget'], found['live'])

        try:
            result = run_streaming(args, worktree, prompt, env, timeout, on_line)
        except TimedOut as error:
            if check:
                count()
                raise LimitReached(str(error), 'time', found['live']) from None
            raise
        if result.returncode != 0 or not last.exists() or not found['thread']:
            raise Refusal(f'Codex failed (exit {result.returncode}): {tail(result.stderr or result.stdout)}')
        try:
            return (found['thread'], json.loads(last.read_text(encoding='utf-8')),
                    found['usage'] if tokens(found['usage']) or not check else found['live'])
        except ValueError:
            raise Refusal('Codex did not answer with JSON.')


def claude_usage(usage: dict) -> dict:
    cached = int(usage.get('cache_read_input_tokens') or 0)
    return {'input': int(usage.get('input_tokens') or 0) + int(usage.get('cache_creation_input_tokens') or 0) + cached,
            'cached': cached, 'output': int(usage.get('output_tokens') or 0)}


def toml_string(text: str) -> str:
    """`text` as a TOML basic string."""
    return '"' + ''.join(f'\\u{ord(char):04x}' if char in '"\\' or ord(char) < 32 or ord(char) == 127 else char
                         for char in text) + '"'


def secrets(needed: list[Path]) -> list[str]:
    """The paths SECRETS names that are there, resolved, but for any that holds a path the reviewer needs, such as
    the checkout, which hiding it would hide too."""
    found = {os.path.realpath(path) for pattern in SECRETS for path in Path.home().glob(pattern)}
    needed = [os.path.realpath(path) for path in needed]
    return sorted(path for path in found if not any(need == path or need.startswith(path + os.sep) for need in needed))


def sandbox_profile(needed: list[Path], writable: list[Path]) -> str:
    """The configuration of the Codex permissions profile a reviewer's commands run in: everything can be read but
    SECRETS, only the `writable` folders written, Git can't write, and there is no network, nor any Unix socket such
    as D-Bus. `needed` are the other paths the reviewer reads, such as the change."""
    entries = {':root': 'read', **{path: 'deny' for path in secrets([*needed, *writable])},
               **{str(path): 'write' for path in writable}}
    return (f'permissions.{SANDBOX_PROFILE}={{filesystem={{'
            + ','.join(f'{toml_string(path)}={toml_string(access)}' for path, access in entries.items())
            + '},network={enabled=false}}')


@contextlib.contextmanager
def sandbox_shell(codex: str, worktree: Path, change: Path, scratch: Path):
    """Yields a wrapper for Claude Code to run each of a check's commands with, given as one command line, in Codex's
    sandbox, set up as for Codex's own checks: see `sandbox_profile`. Outside the sandbox, it notes each command's
    process in `commands` beside it, and when the check ends, however it ends, whatever is still running of them is
    stopped, as Claude Code starts each in a session of its own. Its folder is out of the sandbox's reach and holds an
    empty Codex home, so neither your Codex configuration nor anything a command writes can change the sandbox."""
    # Claude Code's own sandbox (2.1.316) doesn't start headless on Cicely's Linux (kernel 7.3, bubblewrap 0.12): its
    # seccomp helper sets up a user namespace inside its bubblewrap sandbox, which gets no capabilities there, so the
    # helper fails and the sandbox fails closed. Bubblewrap alone would start, but would let commands reach D-Bus, and
    # through it have systemd start a process outside. Codex sets its seccomp filter, which blocks such sockets,
    # without a namespace of its own.
    with tempfile.TemporaryDirectory(prefix='ba-crossreview-') as folder:
        folder = Path(folder)
        home = folder / 'codex'
        home.mkdir()
        profile = sandbox_profile([change, common_dir(worktree)], [worktree, scratch])
        wrapper = folder / 'shell'
        # The wrapper notes its process id and start time, the 22nd field of its stat, as `processes` reads them; the
        # process goes on as Codex's sandbox.
        wrapper.write_text('#!/bin/sh\n'
                           'command=$1\n'
                           'read -r stat < /proc/$$/stat\n'
                           "set -- ${stat##*') '}\n"
                           f'echo "$$ ${{20}}" >> {shlex.quote(str(folder / "commands"))}\n'
                           f'exec env CODEX_HOME={shlex.quote(str(home))} {shlex.quote(codex)} sandbox '
                           f'-P {SANDBOX_PROFILE} -C {shlex.quote(str(worktree))} -c {shlex.quote(profile)} '
                           '-- bash -c "$command"\n', encoding='utf-8')
        wrapper.chmod(0o700)
        try:
            yield wrapper
        finally:
            try:
                noted = (folder / 'commands').read_text(encoding='utf-8').splitlines()
            except OSError:  # No command ran.
                noted = []
            end_processes({int(pid): start for pid, start in map(str.split, noted)})


def sandbox_trial(executable: str, env: dict, wrapper: Path) -> None:
    """Has Claude run one harmless command before a check, and refuses the check unless it went through the
    `wrapper`: should Claude Code stop running commands through CLAUDE_CODE_SHELL_PREFIX, the check's would run
    outside the sandbox. The trial runs in the wrapper's folder, where nothing from the pull request, such as its
    CLAUDE.md, can steer it."""
    try:
        result = run([executable, '-p', '--output-format', 'json', '--no-session-persistence',
                      '--permission-mode', 'dontAsk', '--restricted', '--strict-mcp-config',
                      '--tools', 'Bash', '--allowedTools', 'Bash'],
                     wrapper.parent, SANDBOX_TRIAL, env, SANDBOX_TRIAL_MINUTES * 60)
        failure = f' The trial failed (exit {result.returncode}): {tail(result.stderr or result.stdout, 5)}' \
            if result.returncode else ''
    except TimedOut as error:
        failure = f' {error}'
    if not (wrapper.parent / 'commands').exists():
        raise Refusal('The check wasn\'t started: Claude\'s trial command never reached Codex\'s sandbox, so its '
                      'commands might run outside it. Claude Code may no longer run commands through '
                      f'CLAUDE_CODE_SHELL_PREFIX.{failure}')


def run_claude(executable: str, worktree: Path, change: Path, prompt: str, session: str | None,
               timeout: float, progress: Progress, check: dict | None = None) -> tuple[str, dict, dict]:
    """Runs Claude as the reviewer, read-only, or, given a `check` with its token `budget` and `scratch` folder, as a
    focused check that may also run commands, in Codex's sandbox."""
    # A Claude Code session's marker in the environment would make this look like a nested session.
    env = {name: value for name, value in os.environ.items() if name != 'CLAUDECODE'}
    answer, messages = {}, {}

    def used() -> dict:
        # Each message's usage comes with every event of it, so it's counted once per message.
        totals = [claude_usage(usage) for usage in messages.values()]
        return {key: sum(total[key] for total in totals) for key in ('input', 'cached', 'output')}

    def on_line(line: str | None) -> None:
        event = event_of(line)
        if event.get('type') == 'result':
            answer.clear()
            answer.update(event)
        message = event.get('message') if event.get('type') == 'assistant' else None
        if isinstance(message, dict) and message.get('id') and isinstance(message.get('usage'), dict):
            messages[str(message['id'])] = message['usage']
        progress.step(claude_activity(event, worktree))
        if check:
            over_budget(check['budget'], used())

    with contextlib.ExitStack() as stack:
        if check:
            codex = shutil.which('codex')
            if not codex:
                raise Refusal('Claude\'s check runs its commands in Codex\'s sandbox, but the Codex CLI (codex) is not '
                              'on PATH.')
            wrapper = stack.enter_context(sandbox_shell(codex, worktree, change, check['scratch']))
            env.update(TMPDIR=str(check['scratch']), CLAUDE_CODE_SHELL_PREFIX=str(wrapper))
            sandbox_trial(executable, env, wrapper)
        # Only the reading tools, confined to the checkout and the change, and a check's Bash, whose commands run in
        # the sandbox. Restricted mode ignores settings that could allow more, and no MCP server or connector is
        # loaded.
        tools = ['--tools', 'Read,Grep,Glob,Bash', '--allowedTools', 'Bash'] if check else ['--tools', 'Read,Grep,Glob']
        args = [executable, '-p', *(['--resume', session] if session else []),
                '--output-format', 'stream-json', '--verbose',
                '--json-schema', json.dumps(CHECK_SCHEMA if check else REVIEW_SCHEMA),
                '--permission-mode', 'dontAsk', '--restricted', '--strict-mcp-config', *tools, '--add-dir', str(change)]
        try:
            result = run_streaming(args, worktree, prompt, env, timeout, on_line)
        except TimedOut as error:
            if check:
                raise LimitReached(str(error), 'time', used()) from None
            raise
    if result.returncode != 0 or answer.get('is_error') or not isinstance(answer.get('structured_output'), dict) \
            or not answer.get('session_id'):
        message = answer.get('result') if isinstance(answer.get('result'), str) else None
        raise Refusal(f'Claude failed (exit {result.returncode}): {message or tail(result.stderr or result.stdout, 5)}')
    usage = answer.get('usage') if isinstance(answer.get('usage'), dict) else {}
    return answer['session_id'], answer['structured_output'], dict(
        claude_usage(usage),
        cost=answer.get('total_cost_usd') if isinstance(answer.get('total_cost_usd'), (int, float)) else None)


REVIEWERS = {'codex': run_codex, 'claude': run_claude}


def location(finding: dict) -> str:
    if not finding.get('file'):
        return 'general'
    return finding['file'] + (f':{finding["line"]}' if finding.get('line') else '')


def indented(text: str, prefix: str = '  ') -> list[str]:
    return [prefix + line if line.strip() else '' for line in text.strip().splitlines()]


def in_item(text: str) -> list[str]:
    """Paragraphs that continue the list item above them, after a blank line."""
    return ['', *indented(text)] if text.strip() else []


def number_of(identifier: str) -> int:
    match = re.fullmatch(r'F(\d+)', identifier or '')
    return int(match.group(1)) if match else 0


def order(finding: dict) -> tuple:
    return STATUSES.index(finding['status']), SEVERITIES.index(finding['severity']), number_of(finding['id'])


def all_ids(state: dict) -> list[str]:
    ids = [finding['id'] for round in state['rounds'] for finding in round['findings']]
    return ids + [finding['id'] for finding in state['escalated']]


def reviews(state: dict) -> int:
    """How many full rounds of review there have been. Focused checks, kept in the same list, don't count."""
    return sum('check' not in round for round in state['rounds'])


def label(step: dict) -> str:
    """A round, or a focused check, or a record of either, by name: "round 2", "the check after round 2"."""
    if not step.get('check'):
        return f'round {step["round"]}'
    return (f'the check after round {step["round"]}' if step['check'] == 1
            else f'check {step["check"]} after round {step["round"]}')


def capital(text: str) -> str:
    return text[:1].upper() + text[1:]


def step_of(round: dict) -> dict:
    """What ties a record to a round or a check: the round's number, and the check's after it."""
    return {'round': round['round'], **({'check': round['check']} if round.get('check') else {})}


def same_step(item: dict, round: dict) -> bool:
    return step_of(item) == step_of(round)


def turn(state: dict | None, head: str | None = None) -> str:
    """Whose move it is: review, reply, cicely (her decisions are needed first), check (she chose a focused check),
    done (nothing left between the two at the reviewed head), stopped (she ended it rather than have another round)
    or limit (the rounds are used up and something is left unreviewed, but she hasn't been asked yet; `review` asks
    her). Given the pull request's head, a cross-review done or stopped at an earlier head is due another review."""
    if not state or not state['rounds']:
        return 'review'
    if pending(state):
        return 'cicely'
    last = state['rounds'][-1]
    if last['answers'] is None and open_findings(last):
        return 'reply'
    # Her stop comes first: after a clean last round, she may have stopped before commits pushed since.
    asked = checkpoint(last)
    if asked and asked.get('choice') == 'stop' and (not head or head == asked['head']):
        return 'stopped'
    if asked and asked.get('choice') == 'check':
        return 'check'
    # A check stopped at its limit reviewed nothing, so it never ends the cross-review.
    if last['answers'] is None and not unverified(last) and not last.get('stopped') \
            and (not head or head == last['head']):
        return 'done'
    return 'limit' if reviews(state) >= state['maxRounds'] else 'review'


def open_findings(round: dict) -> list[dict]:
    return [finding for finding in round['findings'] if finding['status'] == 'open']


def questions(round: dict) -> list[dict]:
    return [finding for finding in round['findings'] if finding['status'] == 'question']


def unverified(round: dict) -> list[dict]:
    return [finding for finding in round['findings'] if finding['status'] == 'unverified']


def checkable(state: dict) -> dict[str, dict]:
    """What the next round or check looks at again: the findings the author answered since the last one, and those
    a check couldn't verify, each with Cicely's decision where she made one."""
    last = state['rounds'][-1]
    answered = {reply['id'] for reply in (last['answers'] or {}).get('replies', [])}
    found = {finding['id']: finding for finding in last['findings']
             if finding['id'] in answered or finding['status'] == 'unverified'}
    for finding in state['escalated']:
        if same_step(finding, last) and finding['id'] in found:
            found[finding['id']] = dict(found[finding['id']], decision=finding.get('decision'),
                                        view=finding.get('view'))
    return found


def answer_to(state: dict, identifier: str) -> dict | None:
    """The author's latest answer to a finding."""
    for round in reversed(state['rounds']):
        for reply in (round['answers'] or {}).get('replies', []):
            if reply['id'] == identifier:
                return reply
    return None


def checkpoint(round: dict) -> dict | None:
    """The latest question to Cicely whether to have another round, a focused check or neither after this one.
    `reply` asks it after answers to only minor findings, after answers to the last round and after answers to a
    check; `review` asks it after a check that left findings unverified or was stopped, when the rounds are used up
    and new commits are left unreviewed, and before it reviews a few new commits that answer no finding. Earlier ones
    stay in the list."""
    return (round.get('checkpoints') or [None])[-1]


def ask_next_round(state: dict, reason: str, head: str, commits: dict | None = None) -> dict:
    """Puts the question what follows to Cicely: `small` after answers to only minor findings, `limit` when the
    rounds are used up, `check` after a focused check, `commits` before a few new commits that answer no finding are
    reviewed. `head` is what another round would review, and `commits`, as `unreviewed` gives them, what the
    question lists as unreviewed."""
    last = state['rounds'][-1]
    titles = {'small': f'Another round after {label(last)}?',
              'limit': f'Another round after {label(last)}, past the limit of {state["maxRounds"]}?',
              'check': f'What follows {label(last)}?',
              'commits': f'Review the commits pushed since {label(reviewed(state))}?'}
    item = dict({'id': CHECKPOINT, 'reason': reason}, **step_of(last), head=head, title=titles[reason], decision=None,
                choice=None, **({'commits': commits} if commits else {}))
    last.setdefault('checkpoints', []).append(item)
    return item


def pending(state: dict) -> list[dict]:
    """What waits for Cicely: the reviewer's questions in the last round, the findings taken to her, and whether
    to have another round, until she decides them."""
    if not state['rounds']:
        return []
    last = state['rounds'][-1]
    waiting = questions(last) + [finding for finding in state['escalated'] if not finding.get('decision')]
    asked = checkpoint(last)
    return waiting + ([asked] if asked and not asked.get('choice') else [])


def waiting_for_cicely(state: dict) -> str:
    ids = ', '.join(dict.fromkeys(item['id'] for item in pending(state)))
    return f'Cicely has to decide {ids} first: give her the briefing, then record her answers with `decide`.'


def words(value: object) -> str | None:
    return value.strip() if isinstance(value, str) and value.strip() else None


def choices(value: object) -> list[dict]:
    """The well-formed {choice, implies} options in `value`."""
    return [{'choice': words(option['choice']), 'implies': words(option.get('implies')) or ''}
            for option in (value if isinstance(value, list) else [])
            if isinstance(option, dict) and words(option.get('choice'))]


def finding_from(raw: dict) -> dict:
    """A finding as the reviewer gave it, with what is malformed set to a safe default."""
    return {
        'id': raw.get('id') if isinstance(raw.get('id'), str) else None,
        # `unverified` is only ever a check's verdict.
        'status': raw.get('status') if raw.get('status') in ('open', 'question', 'resolved') else 'open',
        'severity': raw.get('severity') if raw.get('severity') in SEVERITIES else 'minor',
        'file': raw.get('file') if isinstance(raw.get('file'), str) and raw.get('file').strip() else None,
        'line': raw.get('line') if type(raw.get('line')) is int and raw.get('line') > 0 else None,
        'title': str(raw['title']).strip(),
        'detail': str(raw.get('detail') or '').strip(),
        'stakes': words(raw.get('stakes')),
        'options': choices(raw.get('options')),
        'recommendation': words(raw.get('recommendation')),
        'reply': words(raw.get('reply')),
        'new': False,
    }


def number_new(findings: list[dict], next_number: int) -> list[dict]:
    """Numbers new findings most severe first, keeping the reviewer's order within a severity."""
    for finding in sorted(findings, key=lambda finding: SEVERITIES.index(finding['severity'])):
        finding['id'] = f'F{next_number}'
        next_number += 1
    return findings


def normalize(output: object, expected: dict[str, dict], next_number: int,
              first: bool) -> tuple[str, list[dict], list[str]]:
    """Checks the reviewer's answer and gives new findings ids; an expected finding left out stays open."""
    if not isinstance(output, dict) or not isinstance(output.get('findings'), list):
        raise Refusal('The reviewer answered without a findings list.')
    findings, new, seen = [], [], set()
    for raw in output['findings']:
        if not isinstance(raw, dict) or not str(raw.get('title') or '').strip():
            continue
        finding = finding_from(raw)
        if not first and finding['id'] in expected and finding['id'] not in seen:
            seen.add(finding['id'])
            # Cicely's decision, and the author's view she read with it, stay with the finding while it is open.
            for key in ('decision', 'view'):
                if expected[finding['id']].get(key):
                    finding[key] = expected[finding['id']][key]
            findings.append(finding)
        elif finding['status'] != 'resolved':
            new.append(dict(finding, new=True, reply=None))
    findings += number_new(new, next_number)
    unlisted = [identifier for identifier in expected if identifier not in seen]
    for identifier in unlisted:
        # A check's verdict on it is out of date once a round has looked again.
        kept = {key: value for key, value in expected[identifier].items() if key != 'verdict'}
        findings.append(dict(kept, status='open', new=False,
                             reply="The reviewer didn't re-list this finding, so it stays open."))
    findings.sort(key=order)
    return str(output.get('summary') or '').strip(), findings, unlisted


def judge(output: object, expected: dict[str, dict], next_number: int) -> tuple[str, list[dict]]:
    """Checks a focused check's answer. Each finding it checked takes the status its verdict gives, one it left out
    stays unverified, and the problems it found become new open findings."""
    if not isinstance(output, dict) or not isinstance(output.get('verdicts'), list):
        raise Refusal('The check answered without a verdicts list.')
    findings, seen = [], set()
    for raw in output['verdicts']:
        identifier = raw.get('id') if isinstance(raw, dict) else None
        if not isinstance(identifier, str) or identifier not in expected or identifier in seen \
                or raw.get('verdict') not in VERDICTS:
            continue
        seen.add(identifier)
        findings.append(dict(expected[identifier], status=VERDICTS[raw['verdict']], verdict=raw['verdict'], new=False,
                             reply=words(raw.get('evidence')) or 'It gave no evidence.'))
    for identifier in expected:
        if identifier not in seen:
            findings.append(dict(expected[identifier], status='unverified', verdict='not verified', new=False,
                                 reply="The check didn't report on this finding."))
    problems = output.get('problems') if isinstance(output.get('problems'), list) else []
    findings += number_new([dict(finding_from(raw), id=None, status='open', new=True) for raw in problems
                            if isinstance(raw, dict) and str(raw.get('title') or '').strip()], next_number)
    findings.sort(key=order)
    return str(output.get('summary') or '').strip(), findings


def add_block(lines: list[str], *text: str) -> None:
    # A blank line first, or Markdown would run the block into the list above it.
    if lines[-1]:
        lines.append('')
    lines.extend(text)


def review_comment(state: dict, round: dict) -> str:
    lines = [f'[{AGENTS[state["reviewer"]]}] Cross-review of #{state["pullRequest"]}, round {round["round"]}, '
             f'at {round["head"][:7]}', '']
    if round['summary']:
        lines += [round['summary'], '']
    open_now, asked = open_findings(round), questions(round)
    resolved = [finding for finding in round['findings'] if finding['status'] == 'resolved']

    if open_now:
        add_block(lines, '**Open**')
        for finding in open_now:
            new = ' *(new)*' if finding['new'] and round['round'] > 1 else ''
            lines.append(f'- **{finding["id"]}** · {finding["severity"]} · `{location(finding)}` · {finding["title"]}{new}')
            lines += indented(finding['detail'])
            if finding['reply']:
                lines += indented(finding['reply'], '  > ')
    if asked:
        add_block(lines, '**For Cicely to decide**')
        for finding in asked:
            new = ' *(new)*' if finding['new'] and round['round'] > 1 else ''
            lines.append(f'- **{finding["id"]}** · `{location(finding)}` · {finding["title"]}{new}')
            lines += indented(finding['detail'])
            lines += in_item(considerations(finding, 'Recommends'))
            if finding['reply']:
                lines += indented(finding['reply'], '  > ')
    if resolved:
        add_block(lines, '**Resolved**')
        for finding in resolved:
            lines.append(f'- **{finding["id"]}** · {finding["title"]}')
            lines += indented(finding['detail'])
            if finding['reply']:
                lines += indented(finding['reply'], '  > ')
    if not open_now and not asked:
        add_block(lines, 'Nothing is open.')
    return '\n'.join(lines) + '\n'


def check_comment(state: dict, round: dict) -> str:
    reviewer = AGENTS[state['reviewer']]
    lines = [f'[{reviewer}] Cross-review of #{state["pullRequest"]}: {label(round)}, at {round["head"][:7]}', '']
    if round['summary']:
        lines += [round['summary'], '']
    limits, commits = round['limits'], round.get('commits')
    what = (f'{counted(len(commits["list"]), "commit")} pushed since `{commits["since"][:7]}`' if commits
            else 'the answers')
    lines.append(f'Cicely chose this focused check of {what} instead of another round. It ran in a fresh session '
                 f'with limits of {amount(limits["tokens"])} tokens and {limits["minutes"]:g} min, and took '
                 f'{cost(round) or "no time to speak of"}. ' + tested(state['reviewer'], True))
    if commits:
        lines += ['', *commit_lines(commits)]
    if round.get('stopped'):
        lines += ['', f'**It was stopped at its {round["stopped"]} limit** before it reported, so '
                      + ('those commits stay unreviewed.' if commits else 'nothing it was to check is verified.')]
    if round.get('overran'):
        lines += ['', f'**It finished past its token limit,** at about {amount(tokens(round["usage"]))} tokens: the '
                      'running count lags by a step, so it wasn\'t stopped in time. What it found is kept.']
    sections = [('Verified', [finding for finding in round['findings'] if finding.get('verdict') == 'verified']),
                ('Problems', [finding for finding in round['findings']
                              if finding.get('verdict') == 'problem' or finding['new']]),
                ('Not verified', unverified(round))]
    for title, findings in sections:
        if findings:
            add_block(lines, f'**{title}**')
        for finding in findings:
            new = ' *(new)*' if finding['new'] else ''
            lines.append(f'- **{finding["id"]}** · {finding["severity"]} · `{location(finding)}` · {finding["title"]}{new}')
            lines += indented(finding['detail'] if finding['new'] else finding['reply'])
    if commits and not round.get('stopped') and not round['findings']:
        add_block(lines, 'It found no problems in them.')
    return '\n'.join(lines) + '\n'


def tested(reviewer: str, done: bool) -> str:
    """What a focused check by this reviewer may do, or, once `done`, could do."""
    sandbox = "Codex's sandbox, which" if reviewer == 'claude' else 'a sandbox that'
    return (f'{AGENTS[reviewer]} {"could" if done else "may"} run the tests, in {sandbox} writes only to its checkout '
            'and a temp folder of its own, with no network, and hides your keys and logins.')


def considerations(item: dict, recommends: str) -> str:
    """Why a decision matters, its options and the recommendation, as Markdown."""
    lines = []
    if item.get('stakes'):
        lines += ['', f'**Why it matters:** {item["stakes"]}']
    if item.get('options'):
        lines += ['', '**Options:**']
        lines += [f'{number}. **{option["choice"]}:** {option["implies"]}'
                  for number, option in enumerate(item['options'], 1)]
    if item.get('recommendation'):
        lines += ['', f'**{recommends}:** {item["recommendation"]}']
    return '\n'.join(lines)


def decisions_comment(state: dict, record: dict) -> str:
    author = AGENTS[state['author']]
    views = any(decision.get('view') for decision in record['decisions'])
    lines = [f'{CICELY} Decisions on the cross-review of #{state["pullRequest"]}, after {label(record)}', '',
             f'{author} paused the cross-review to ask her. What she was asked is below, each with her answer word for '
             'word' + (f', and with {author}\'s own view where {author} gave her one.' if views else '.')]
    for decision in record['decisions']:
        lines += ['', *decision['asked']]
        if decision.get('view'):
            lines += ['', f'**{author}\'s view, given with it:**', *quoted(decision['view'])]
        lines += ['', '**Her answer:**', *quoted(decision['decision'])]
        if decision.get('choice'):
            # With no answers or unverified findings to check, a check is of the new commits.
            so = ('a focused check of the new commits' if decision['choice'] == 'check' and not checkable(state)
                  else CHOICES[decision['choice']])
            lines += ['', f'**So:** {so}.']
    return '\n'.join(lines) + '\n'


def quoted(text: str) -> list[str]:
    return ['> ' + line if line.strip() else '>' for line in text.strip().splitlines()]


def answers_comment(state: dict, round: dict) -> str:
    answers = round['answers']
    lines = [f'[{AGENTS[state["author"]]}] Answers to {label(round)}'
             + (' of the cross-review' if not round.get('check') else '') + f', at {answers["head"][:7]}', '']
    titles = {finding['id']: finding['title'] for finding in round['findings']}
    for reply in answers['replies']:
        note = reply['note'].strip().splitlines()
        lines.append(f'- **{reply["id"]}** · {ACTIONS[reply["action"]]} · {titles[reply["id"]]} — {note[0]}')
        lines += indented('\n'.join(note[1:]))
        lines += in_item(considerations(reply, f'{AGENTS[state["author"]]} recommends'))
    asked = checkpoint(round)
    if asked and asked['reason'] == 'check':
        lines += ['', 'The check was Cicely\'s choice, so the cross-review pauses for her to decide what follows it.']
    elif asked and asked['reason'] == 'limit':
        lines += ['', f'Round {round["round"]} was the last of {state["maxRounds"]}, so the cross-review pauses for '
                      'Cicely to decide whether to have another round.']
    elif asked:
        lines += ['', f'Only minor or nit findings were left, and these answers change {answers["changedLines"]} '
                      'lines, so the cross-review pauses for Cicely to decide whether another round is worth it.']
    return '\n'.join(lines) + '\n'


def clock(stamp: str) -> str:
    """A recorded time in this machine's time zone, such as "2026-11-01 14:05 CET"."""
    return datetime.fromisoformat(stamp).astimezone().strftime('%Y-%m-%d %H:%M %Z')


def minutes_between(start: str, end: str) -> int:
    return max(round((datetime.fromisoformat(end) - datetime.fromisoformat(start)).total_seconds() / 60), 0)


def amount(number: float) -> str:
    if number >= 1e6:
        return f'{number / 1e6:.1f}'.removesuffix('.0') + 'M'
    return f'{round(number / 1e3)}k' if number >= 1e3 else str(round(number))


def cost(round: dict) -> str | None:
    """What a round or a check took, such as "12 min and about 1.2M tokens (900k cached)"."""
    parts = []
    if round.get('startedAt'):
        parts.append(f'{minutes_between(round["startedAt"], round["reviewedAt"])} min')
    usage = round.get('usage') or {}
    if usage.get('input') or usage.get('output'):
        price = f', ${usage["cost"]:.2f}' if usage.get('cost') else ''
        parts.append(f'about {amount(usage["input"] + usage["output"])} tokens '
                     f'({amount(usage.get("cached") or 0)} cached{price})')
    return ' and '.join(parts) or None


def last_review(state: dict) -> dict:
    """The latest full round, leaving out the focused checks since."""
    return next(round for round in reversed(state['rounds']) if not round.get('check'))


def reviewed(state: dict) -> dict:
    """The latest round or check that ran to the end. A check stopped at its limit reviewed nothing, so what came
    after the step before it is still unreviewed."""
    return next(round for round in reversed(state['rounds']) if not round.get('stopped'))


def counted(number: int, noun: str) -> str:
    return f'{number} {noun}' + ('' if number == 1 else 's')


def commit_lines(commits: dict) -> list[str]:
    """Commits that nobody has reviewed, as `unreviewed` gives them, listed by short hash and subject."""
    listed = commits['list'][:COMMITS_LISTED]
    more = len(commits['list']) - len(listed)
    return ([f'- `{commit["sha"][:7]}` {commit["subject"]}' for commit in listed]
            + ([f'- and {more} more'] if more else []))


def few_commits(commits: dict | None) -> dict | None:
    """The unreviewed commits, as `unreviewed` gives them, when they change little enough for a focused check of
    their own."""
    return commits if commits and commits['list'] and commits['changedLines'] < SMALL_CHANGE else None


def link(text: str, url: str | None) -> str:
    return f'[{text}]({url})' if url else text


def item_lines(state: dict, item: dict) -> list[str]:
    """One thing waiting for Cicely, told so that she can decide it without having followed the review."""
    reviewer, author = AGENTS[state['reviewer']], AGENTS[state['author']]
    if item['id'] == CHECKPOINT:
        return {'limit': limit_lines, 'small': checkpoint_lines, 'check': after_check_lines,
                'commits': commits_lines}[item['reason']](state, item)
    lines = [f'#### {item["id"]} · {item["title"]}']
    if 'note' in item:
        who = author
        lines += [f'{reviewer} raised this {item["severity"]} finding at `{location(item)}` in {label(item)}, '
                  f'and {author} took it to you.', '', f'**{reviewer}:** {item["detail"]}']
        if item.get('reply'):
            lines += ['', f'**{reviewer}, after {author}\'s last answer:** {item["reply"]}']
        lines += ['', f'**{author}\'s question:** {item["note"]}']
    else:
        who = reviewer
        about = f' about `{location(item)}`' if item.get('file') else ''
        lines += [f'{reviewer} asks you this{about}, in {label(state["rounds"][-1])}.', '', item['detail']]
    extra = considerations(item, f'{who} recommends')
    return lines + (extra.splitlines() if item.get('options') else
                    [*extra.splitlines(), '', f'*{who} gave no options; ask {author} to spell them out.*'])


def numbered(options: list[str]) -> list[str]:
    return [f'{number}. {option}' for number, option in enumerate(options, 1)]


def check_option(state: dict, found: dict, commits: dict | None = None) -> str:
    """A focused check of what is left, as one of Cicely's options: of the findings to look at again, or, when there
    are none, of the few new `commits` listed above it."""
    reviewer = AGENTS[state['reviewer']]
    limits = (f'in a fresh session, within {amount(DEFAULT_CHECK_TOKENS)} tokens and {DEFAULT_CHECK_MINUTES} min '
              f'unless you set other limits. {tested(state["reviewer"], False)} It doesn\'t count as a round')
    if found:
        return (f'**A focused check** of {", ".join(sorted(found, key=number_of))}: {reviewer} checks only '
                f'{"that" if len(found) == 1 else "those"}, {limits}, and what it can\'t verify comes back to you.')
    one = len(commits['list']) == 1
    return (f'**A focused check** of {"that commit" if one else "those commits"}: {reviewer} reviews only '
            f'{"it" if one else "them"}, for problems {"it introduces" if one else "they introduce"}, {limits}. If it '
            'finds none, the cross-review is done.')


def limit_lines(state: dict, item: dict) -> list[str]:
    """Whether to have another round when the rounds are used up and something is left unreviewed."""
    reviewer, author = AGENTS[state['reviewer']], AGENTS[state['author']]
    last, review = state['rounds'][-1], last_review(state)
    step, took, answers, found = label(last), cost(review), last['answers'], checkable(state)
    # A question asked before the commits were listed names only the head they reach.
    commits = item.get('commits')
    listed = bool(commits and commits['list'])
    lines = [f'#### {item["title"]}']
    if answers:
        left = f'{author}\'s answers to {step} unchecked'
        notes = {reply['id']: reply for reply in answers['replies']}
        lines.append(f'All {state["maxRounds"]} rounds are used, and {reviewer} hasn\'t checked {author}\'s answers to '
                     f'{step}:')
        for finding in open_findings(last):
            lines.append(f'- **{finding["id"]}** · {finding["severity"]} · {finding["title"]}')
            lines.append(f'  - {reviewer}: {short(finding.get("reply") or finding["detail"], 300)}')
            if finding['id'] in notes:
                reply = notes[finding['id']]
                lines.append(f'  - {author} {reply["action"]} it: {short(reply["note"], 300)}')
        if listed:
            left = f'{author}\'s answers to {step} unchecked, and the commits listed unreviewed'
            lines += ['', f'Nor has {reviewer} reviewed {counted(len(commits["list"]), "commit")} pushed since {step}:',
                      *commit_lines(commits)]
        elif answers['head'] != item['head']:
            left = f'{author}\'s answers to {step}, and the commits since, unchecked'
            lines += ['', f'Nor has {reviewer} reviewed the commits pushed since those answers, up to and including '
                          f'`{item["head"][:7]}`.']
    else:
        since = label(reviewed(state))
        left = f'the commits since {since} unreviewed'
        if listed:
            lines += [f'All {state["maxRounds"]} rounds are used, and {reviewer} hasn\'t reviewed '
                      f'{counted(len(commits["list"]), "commit")} pushed since {since}:', *commit_lines(commits)]
        else:
            lines.append(f'All {state["maxRounds"]} rounds are used, and the commits pushed since {since}, up to and '
                         f'including `{item["head"][:7]}`, haven\'t been reviewed.')
    if unverified(last):
        ids = ', '.join(finding['id'] for finding in unverified(last))
        lines += ['', f'{capital(step)} couldn\'t verify {ids}.']
        left += f', and {ids} unverified'
    options = [f'**Another round** (round {reviews(state) + 1}): {reviewer} checks what is above, and may raise new '
               'points only on what changed.']
    if found or few_commits(commits):
        options.append(check_option(state, found, commits))
    options.append(f'**Stop here:** the cross-review ends at `{item["head"][:7]}`. What is open stays open on the '
                   'record; decide any of it yourself, or leave it. '
                   + (f'The commits listed stay unreviewed. {LATER_COMMITS} ' if listed else '')
                   + 'Marking the pull request ready stays your call.')
    return lines + ['', f'**Why it matters:** the rounds limit caps what the cross-review spends. Another round is '
                        f'another review by {reviewer}' + (f'; round {review["round"]} took {took}.' if took else '.')
                        + f' Stopping leaves {left}.',
                    '', '**Options:**', *numbered(options)]


def commits_lines(state: dict, item: dict) -> list[str]:
    """Whether to review a few new commits that answer no finding, pushed after a step that left nothing open: with
    a round, with a focused check of just those commits, or not at all."""
    reviewer, commits, review = AGENTS[state['reviewer']], item['commits'], last_review(state)
    took, one = cost(review), len(commits['list']) == 1
    these = 'this commit' if one else 'these commits'
    return [f'#### {item["title"]}',
            f'Nothing was left open after {label(reviewed(state))}, at `{commits["since"][:7]}`. Since then, '
            f'{counted(len(commits["list"]), "commit")} {"has" if one else "have"} been pushed that '
            f'{"answers" if one else "answer"} no finding, changing {commits["changedLines"]} lines, and {reviewer} '
            f'hasn\'t reviewed {"it" if one else "them"}:', *commit_lines(commits),
            '', f'The cross-review asks you before it reviews commits like these whenever they change fewer than '
                f'{SMALL_CHANGE} lines, as a focused check of them costs less than a round.',
            '', f'**Why it matters:** another round is a full review by {reviewer} of everything since round '
                f'{review["round"]}' + (f'; round {review["round"]} took {took}.' if took else '.')
                + f' A check looks only at {these}, within its limits.',
            '', '**Options:**',
            *numbered([f'**Another round** (round {reviews(state) + 1} of {state["maxRounds"]}): {reviewer} reviews '
                       f'everything since round {review["round"]}, {these} included, and may raise new points only on '
                       'what changed.',
                       check_option(state, {}, commits),
                       f'**Stop here:** the cross-review ends at `{item["head"][:7]}`. The commits listed stay '
                       f'unreviewed. {LATER_COMMITS} Marking the pull request ready stays your call.'])]


def checkpoint_lines(state: dict, item: dict) -> list[str]:
    """Whether another round is worth it, after a round that left only minor findings."""
    reviewer, author = AGENTS[state['reviewer']], AGENTS[state['author']]
    last = state['rounds'][-1]
    answers, number = last['answers'], last['round']
    severity = {finding['id']: finding['severity'] for finding in last['findings']}
    replies = answers['replies']
    answered = ', '.join(f'{reply["id"]} ({severity[reply["id"]]}, {ACTIONS[reply["action"]]})' for reply in replies)
    fixed = [reply['id'] for reply in replies if reply['action'] == 'fixed']
    declined = [reply['id'] for reply in replies if reply['action'] == 'declined']
    took, changed = cost(last), answers['changedLines']
    stop = [f'The cross-review ends at `{answers["head"][:7]}`.']
    if fixed:
        stop.append(f'{reviewer} won\'t check the fixes to {", ".join(fixed)}.')
    if declined:
        stop.append(f'The declines of {", ".join(declined)} stand.')
    stop.append('All of it stays on the record, and marking the pull request ready stays your call.')
    return [f'#### {item["title"]}',
            f'Round {number} left only minor or nit findings to answer: {answered}. {author}\'s answers changed '
            f'{changed} lines. The cross-review asks you before another round whenever a round\'s open findings were '
            f'all minor or nits and the answers changed fewer than {SMALL_CHANGE} lines.',
            '', f'**Why it matters:** another round would mostly confirm small fixes, and could turn up more small '
            f'points, for the cost of another review by {reviewer}'
            + (f': round {number} took {took}.' if took else '.') + f' Stopping leaves {author}\'s last answers '
            'unchecked.',
            '', '**Options:**',
            *numbered([f'**Another round** (round {number + 1} of {state["maxRounds"]}): {reviewer} checks the answers '
                       f'to {", ".join(reply["id"] for reply in replies)}'
                       + (f' and the {changed} changed lines' if changed else '')
                       + ', and may raise new points only on what changed.',
                       check_option(state, checkable(state)),
                       f'**Stop here:** {" ".join(stop)}'])]


def after_check_lines(state: dict, item: dict) -> list[str]:
    """What follows a focused check: a full round, another check, or neither."""
    reviewer, author = AGENTS[state['reviewer']], AGENTS[state['author']]
    last, review, found = state['rounds'][-1], last_review(state), checkable(state)
    notes = {reply['id']: reply for reply in (last['answers'] or {}).get('replies', [])}
    ran = (f'{capital(label(last))}, at `{last["head"][:7]}`, took {cost(last) or "no time to speak of"}'
           + (f', past its token limit of {amount(last["limits"]["tokens"])}' if last.get('overran') else '')
           + (f', and reached its {last["stopped"]} limit before it reported.' if last.get('stopped') else '.'))
    if last.get('commits'):
        checked = last['commits']
        lines = [f'#### {item["title"]}', f'You chose a focused check of {counted(len(checked["list"]), "commit")} '
                 f'pushed since `{checked["since"][:7]}`:', *commit_lines(checked), '', ran]
    else:
        lines = [f'#### {item["title"]}', f'You chose a focused check of {author}\'s answers. {ran}']
    verified = [finding['id'] for finding in last['findings'] if finding.get('verdict') == 'verified']
    if verified:
        lines.append(f'- Verified: {", ".join(verified)}')
    for title, findings in ((f'Problems it found, which {author} has answered:',
                             [finding for finding in last['findings']
                              if finding.get('verdict') == 'problem' or finding['new']]),
                            ('Not verified:', unverified(last))):
        if findings:
            lines.append(f'- {title}')
        for finding in findings:
            new = ' *(new)*' if finding['new'] else ''
            lines.append(f'  - **{finding["id"]}** · {finding["severity"]} · {finding["title"]}{new}: '
                         f'{short(finding["detail"] if finding["new"] else finding["reply"], 300)}')
            if finding['id'] in notes:
                reply = notes[finding['id']]
                lines.append(f'    - {author} {reply["action"]} it: {short(reply["note"], 300)}')
    ids, took = ', '.join(sorted(found, key=number_of)), cost(review)
    past = reviews(state) >= state['maxRounds']
    # A check of new commits that was stopped leaves those commits, and nothing else, to check.
    commits = None if found else item.get('commits')
    options = [f'**Another round** (round {reviews(state) + 1}'
               + (f', past the limit of {state["maxRounds"]}' if past else f' of {state["maxRounds"]}')
               + f'): a full review by {reviewer}, in a fresh session, of ' + (f'{ids} and ' if ids else '')
               + f'all the commits since round {review["round"]}'
               + (f'; round {review["round"]} took {took}.' if took else '.')]
    if found or few_commits(commits):
        options.append(check_option(state, found, commits))
    options.append(f'**Stop here:** the cross-review ends at `{item["head"][:7]}`. What is left above stays as it is on '
                   'the record; decide any of it yourself, or leave it. '
                   + (f'The commits listed stay unreviewed. {LATER_COMMITS} ' if commits else '')
                   + 'Marking the pull request ready stays your call.')
    return lines + ['', f'**Why it matters:** what is left above isn\'t settled until something checks it. Another '
                        f'check looks only at {ids or "those commits"}, within its limits; a full round looks at '
                        'everything again, at a full round\'s cost.',
                    '', '**Options:**', *numbered(options)]


def findings_lines(state: dict) -> list[str]:
    reviewer, author = AGENTS[state['reviewer']], AGENTS[state['author']]
    found = {}  # Each finding as the last round that listed it has it.
    for round in state['rounds']:
        for finding in round['findings']:
            found[finding['id']] = finding
    if not found:
        return []
    severities = Counter(finding['severity'] for finding in found.values())
    last = state['rounds'][-1]
    answered = {reply['id']: reply['action'] for reply in (last['answers'] or {}).get('replies', [])}
    ids = sorted(found, key=number_of)
    groups = [('Resolved', [id for id in ids if found[id]['status'] == 'resolved']),
              (f'Answered, for {reviewer} to check', [f'{id} ({ACTIONS[answered[id]]})' for id in ids
                                                     if found[id]['status'] == 'open' and id in answered]),
              (f'Open, for {author} to answer', [id for id in ids
                                                 if found[id]['status'] == 'open' and id not in answered]),
              ('Asked of you', [id for id in ids if found[id]['status'] == 'question']),
              ('Not verified by a check', [id for id in ids if found[id]['status'] == 'unverified'])]
    return ['', f'**Findings:** {len(found)} in all, '
                + ', '.join(f'{severities[severity]} {severity}' for severity in SEVERITIES if severities[severity])
                + '.'] + [f'- {name}: {", ".join(group)}' for name, group in groups if group]


def next_lines(state: dict, move: str) -> list[str]:
    reviewer, author = AGENTS[state['reviewer']], AGENTS[state['author']]
    rounds = state['rounds']
    last = rounds[-1] if rounds else None
    if move == 'cicely':
        lines = ['', '### What needs you']
        for item in pending(state):
            lines += ['', *item_lines(state, item)]
        return lines + ['', f'Answer in {author}\'s session, in your own words. {author} posts them on the pull '
                            f'request word for word, under `{CICELY}`, so they stay on the record.']
    if move == 'reply':
        return ['', f'**Next:** {author} answers {", ".join(finding["id"] for finding in open_findings(last))}.']
    if move == 'review':
        # After a step that left nothing to answer, only new commits bring another round.
        head = state.get('pullRequestHead')
        since = f' The pull request has moved on to `{head[:7]}` since {label(last)}.' \
            if last and last['answers'] is None and head and head != last['head'] else ''
        return ['', f'**Next:** {reviewer} reviews round {reviews(state) + 1} of {state["maxRounds"]}.{since}']
    if move == 'check':
        found = checkable(state)
        what = (', '.join(sorted(found, key=number_of)) if found
                else f'the commits pushed since `{checkpoint(last)["commits"]["since"][:7]}`')
        return ['', f'**Next:** {reviewer} runs the focused check you chose, of {what}.']
    if move == 'done':
        return ['', f'**Next:** nothing is open between {author} and {reviewer} at `{last["head"][:7]}`. Marking the '
                    'pull request ready is your call.']
    if move == 'stopped':
        asked, answers, step = checkpoint(last), last['answers'], label(last)
        commits = asked.get('commits') if (asked.get('commits') or {}).get('list') else None
        left = []
        if answers:
            unchecked = ', '.join(f'{reply["id"]} ({ACTIONS[reply["action"]]})' for reply in answers['replies'])
            left.append(f'{reviewer} didn\'t check {author}\'s last answers: {unchecked}.')
        if unverified(last):
            left.append(f'{capital(step)} couldn\'t verify {", ".join(finding["id"] for finding in unverified(last))}.')
        since = label(reviewed(state))
        if not left:
            left.append(f'{reviewer} didn\'t review the commits since {since}' + (':' if commits else '.'))
        elif commits:
            left.append(f'Nor did {"it" if answers else reviewer} review the commits pushed since {since}:')
        elif (answers or last)['head'] != asked['head']:
            left.append('Nor did it review the commits pushed since them.' if answers
                        else f'Nor did {reviewer} review the commits pushed since.')
        stopped, ready = f'**You stopped it** after {step}, at `{asked["head"][:7]}`. {" ".join(left)}', \
            'Marking the pull request ready is your call.'
        if not commits:
            return ['', f'{stopped} {ready}']
        return ['', stopped, *commit_lines(commits), '', f'{LATER_COMMITS} {ready}']
    # The rounds are used up, and she hasn't been asked yet.
    return ['', f'**Next:** all {state["maxRounds"]} rounds are used, and something is left that {reviewer} hasn\'t '
                f'reviewed. Another round is your decision: {author} asks you, with what is left, before any more '
                'review.']


def rounds_table(state: dict) -> list[str]:
    lines = ['| Round | Head | Took | Found | Answers |', '|---|---|---|---|---|']
    for round in state['rounds']:
        new = Counter(finding['severity'] for finding in round['findings'] if finding.get('new'))
        found = ', '.join(f'{new[severity]} {severity}' for severity in SEVERITIES if new[severity]) or 'nothing new'
        if round.get('commits'):
            # A check of new commits has only what it found in them.
            found = ('nothing reviewed' if round.get('stopped')
                     else f'{found} in {counted(len(round["commits"]["list"]), "commit")}')
        elif round.get('check'):
            verdicts = Counter(finding['verdict'] for finding in round['findings'] if finding.get('verdict'))
            found = ', '.join(f'{verdicts[verdict]} {TALLIES[verdict]}' for verdict in VERDICTS if verdicts[verdict])
            found = ('; '.join(part for part in (found, f'{sum(new.values())} new' if new else '') if part)
                     or 'nothing checked')
        if round.get('stopped'):
            found += f' (stopped at its {round["stopped"]} limit)'
        if round.get('overran'):
            found += ' (past its token limit)'
        resolved = sum(finding['status'] == 'resolved' for finding in round['findings'])
        if resolved and not round.get('check'):
            found += f'; {resolved} resolved'
        answers, answered = round['answers'], '—'
        if answers:
            actions = Counter(reply['action'] for reply in answers['replies'])
            answered = link(', '.join(f'{actions[action]} {ACTIONS[action]}' for action in ACTIONS if actions[action]),
                            answers.get('commentUrl'))
        name = str(round['round']) if not round.get('check') else label(round).removeprefix('the ')
        lines.append(f'| {link(name, round.get("commentUrl"))} | `{round["head"][:7]}` | '
                     f'{cost(round) or "—"} | {found} | {answered} |')
    return lines


def briefing(state: dict, move: str, live: dict | None = None) -> str:
    """Where the cross-review stands and what, if anything, needs Cicely, for someone who hasn't followed it."""
    reviewer, author = AGENTS[state['reviewer']], AGENTS[state['author']]
    rounds = state['rounds']
    step = label(rounds[-1]) if rounds else None
    headlines = {'cicely': 'paused for your decision', 'reply': f'waiting for {author} to answer {step}',
                 'review': f'{reviewer} reviews round {reviews(state) + 1} next',
                 'check': f'{reviewer} runs a focused check next', 'done': 'done, with nothing open',
                 'limit': f'all {state["maxRounds"]} rounds are used', 'stopped': f'stopped by you after {step}'}
    headline = f'{reviewer} is {live["doing"]}' if live else headlines[move]
    about = f'{author} wrote this pull request and {reviewer} reviews it, in up to {state["maxRounds"]} rounds.'
    if rounds:
        about += (f' {capital(step)} {"checked" if rounds[-1].get("check") else "reviewed"} '
                  f'`{rounds[-1]["head"][:7]}`.')
    began = state.get('startedAt') or (rounds[0].get('startedAt') or rounds[0]['reviewedAt'] if rounds else None)
    if began:
        about += f' The cross-review began {clock(began)}.'
    lines = [f'### Cross-review of #{state["pullRequest"]}: {headline}', '', about]
    if live:
        latest = f' Latest: {live["latest"]}.' if live.get('latest') else ''
        lines += ['', f'**Now:** {reviewer} has been {live["verb"]} `{live["head"][:7]}` for '
                      f'{minutes_between(live["startedAt"], now())} min.{latest}']
    elif state.get('failure'):
        failure = state['failure']
        lines += ['', f'**{capital(failure.get("what") or label(failure))} failed** at {clock(failure["at"])}: '
                      f'{failure["error"]}']
    lines += findings_lines(state)
    decided = [link(f'{decision["id"]}, after {label(record)}', record.get('commentUrl'))
               for record in state.get('decisions', []) for decision in record['decisions']]
    if decided:
        lines += ['', f'**Your decisions:** {"; ".join(decided)}.']
    if not live:
        lines += next_lines(state, move)
    if rounds:
        lines += ['', *rounds_table(state)]
    return '\n'.join(lines) + '\n'


def show_status(path: Path, state: dict, move: str, live: dict | None = None) -> str | None:
    """Puts the briefing in the pull request's status comment, posting that comment the first time. A failure here
    never stops the command; it comes back as a warning."""
    body = (f'[{AGENTS[state["author"]]}] Cross-review status for #{state["pullRequest"]}\n\n'
            f'*The cross-review skill keeps this comment up to date. Last updated {clock(now())}.*\n\n'
            + briefing(state, move, live))
    comment = state.get('statusComment')
    try:
        if comment and not comment.get('id'):
            return 'The status comment can\'t be edited: its link names no comment.'
        if comment:
            try:
                edit(state['repository'], comment['id'], body)
                return None
            except Refusal as error:
                if 'Not Found' not in str(error) and '404' not in str(error):
                    raise
        url = post(state['repository'], state['pullRequest'], body)
        match = re.search(r'#issuecomment-(\d+)$', url or '')
        state['statusComment'] = {'url': url, 'id': int(match.group(1)) if match else None}
        save(path, state)
    except (Refusal, OSError) as error:
        return f'Could not update the status comment: {error}'
    return None


def first_prompt(context: dict) -> str:
    return INTRO.format(**context) + LOOK.format(**context) + REPORT + FIRST_ROUND


def history(state: dict, found: dict[str, dict], author: str, fresh: bool) -> str:
    """The findings to look at again, each with what a check found, the author's latest answer and Cicely's decision.
    A `fresh` session also needs the reviewer's own last word on each."""
    lines = []
    for finding in sorted(found.values(), key=lambda finding: number_of(finding['id'])):
        lines.append(f'- {finding["id"]} ({finding["severity"]}, {location(finding)}): {finding["title"]}')
        lines += indented(finding['detail'], '    ')
        if finding.get('verdict'):
            lines.append(f'  {FOUND[finding["verdict"]]}: {finding["reply"]}')
        elif fresh and finding.get('reply'):
            lines.append(f'  Your last word on it: {finding["reply"]}')
        reply = answer_to(state, finding['id'])
        if reply and reply['action'] == 'escalated':
            lines.append(f'  {author} took it to Cicely: {reply["note"]}')
        if finding.get('view'):
            lines.append(f'  {author}\'s view, which she read before deciding: {finding["view"]}')
        if finding.get('decision'):
            lines.append(f'  Cicely decided: {finding["decision"]}')
        if reply and reply['action'] != 'escalated':
            lines.append(f'  {author} {reply["action"]} it: {reply["note"]}')
    return '\n'.join(lines)


def said(state: dict) -> str:
    """Cicely's own words when she chose the round or check about to run. What she said there about a finding, such
    as how a fix should work, settles it as her decisions on findings do, so the reviewer reads them too."""
    asked = checkpoint(state['rounds'][-1])
    if not asked or asked.get('choice') in (None, 'stop') or not asked.get('decision'):
        return ''
    author = AGENTS[state['author']]
    view = ('\n\n' + f'{author} gave her this view with the question, and she read it before she chose:\n\n'
            + '\n'.join(quoted(asked['view']))) if asked.get('view') else ''
    return (view + '\n\nWhen Cicely chose this, she said, word for word:\n\n' + '\n'.join(quoted(asked['decision']))
            + '\n\nWhat she says there settles what it covers'
            + (f'; {author}\'s view settles nothing unless she takes it up.' if view else '.'))


def later_prompt(context: dict, state: dict, fresh: str | None) -> str:
    """The prompt for a later round: to resume the reviewer's session, or, with a `fresh` start's opening, such as
    RESUME_LOST, to start a new one."""
    answered = (history(state, checkable(state), context['author'], fresh is not None)
                or '(None: nothing was open after your last review.)') + said(state)
    later = LATER_ROUND.format(**context, answers=answered)
    if fresh is None:
        return later
    return INTRO.format(**context) + LOOK.format(**context) + REPORT + fresh.format(**context) + later


def check_prompt(context: dict, state: dict, found: dict[str, dict], budget: int, minutes: float) -> str:
    """A focused check's prompt: of the answers to the findings `found`, or, with none, of the new commits."""
    limits = dict(context, tools=CHECK_TOOLS[state['reviewer']], budget=amount(budget), minutes=f'{minutes:g}')
    if not found:
        return CHECK_COMMITS.format(**limits, said=said(state))
    return CHECK.format(**limits, answers=history(state, found, context['author'], True) + said(state))


def command_review(arguments: argparse.Namespace) -> dict:
    repo = Path(arguments.repository).resolve()
    repository = github_repository(repo, arguments.remote)
    path = state_path(repo, repository, arguments.pull_request)
    lock(path)
    state = load_state(path)
    reviewer = 'codex' if arguments.author == 'claude' else 'claude'
    if state and state['author'] != arguments.author:
        raise Refusal(f'This cross-review has {AGENTS[state["author"]]} as the author; run it as that agent.')
    if state is None:
        state = {'version': STATE_VERSION, 'repository': repository, 'pullRequest': arguments.pull_request,
                 'author': arguments.author, 'reviewer': reviewer, 'maxRounds': DEFAULT_MAX_ROUNDS,
                 'session': None, 'worktree': str(review_worktree(repo, repository, arguments.pull_request)),
                 'startedAt': now(), 'rounds': [], 'escalated': []}
    if arguments.max_rounds is not None and arguments.max_rounds < 1:
        raise Refusal('--max-rounds must be at least 1.')
    if arguments.budget_tokens is not None and arguments.budget_tokens < 1:
        raise Refusal('--budget-tokens must be at least 1.')
    if arguments.timeout_minutes is not None and arguments.timeout_minutes <= 0:
        raise Refusal('--timeout-minutes must be more than 0.')
    if turn(state) == 'cicely':
        raise Refusal(waiting_for_cicely(state))
    if turn(state) == 'reply':
        raise Refusal(f'{capital(label(state["rounds"][-1]))} has open findings; answer them with `reply` first.')
    if arguments.max_rounds is not None:
        # Past the limit, another round is Cicely's decision, recorded with `decide`, never the author's flag.
        if state['rounds'] and reviews(state) >= state['maxRounds'] and arguments.max_rounds > state['maxRounds']:
            raise Refusal(f'All {state["maxRounds"]} rounds are used, so another round is Cicely\'s decision. Run '
                          '`review` without --max-rounds to put it to her, and record her answer with `decide`.')
        state['maxRounds'] = arguments.max_rounds
    pr = pull_request(repository, arguments.pull_request)
    if pr.get('state') != 'OPEN':
        raise Refusal(f'Pull request #{arguments.pull_request} is {str(pr.get("state")).lower()}, not open.')
    move = turn(state, pr['headRefOid'])
    if move == 'done':
        raise Refusal(f'Nothing is left between the author and the reviewer at {pr["headRefOid"][:7]}, the pull '
                      'request\'s head; the cross-review is done.')
    if arguments.budget_tokens is not None and move != 'check':
        raise Refusal(f'--budget-tokens limits only a focused check, which Cicely hasn\'t chosen; it is the turn to '
                      f'{move}.')
    if move == 'stopped':
        raise Refusal(f'Cicely stopped the cross-review after {label(state["rounds"][-1])}; it reviews again only '
                      'when new commits are pushed.')
    head = fetch(repo, arguments.remote, f'refs/pull/{arguments.pull_request}/head', fetched(path, 'head'))
    if head != pr['headRefOid']:
        raise Refusal(f'The pull request head moved while it was fetched ({pr["headRefOid"][:7]} on GitHub, '
                      f'{head[:7]} fetched); run again.')
    # The pull request's head as last seen, which a check may not reach: `status` falls back on it when it can't ask
    # GitHub.
    state['pullRequestHead'] = head
    last = state['rounds'][-1] if state['rounds'] else None
    # Past the limit, and before a few new commits that answer no finding are reviewed, the reviewer doesn't run:
    # what follows is put to Cicely, with the commits nobody has reviewed. Once she has chosen a round, it runs.
    if move == 'limit' or (move == 'review' and last and not checkable(state)
                           and (checkpoint(last) or {}).get('choice') != 'review'):
        commits = unreviewed(repo, reviewed(state)['head'], head)
        if move == 'limit' or few_commits(commits):
            ask_next_round(state, 'commits' if move == 'review' else 'limit', head, commits)
            save(path, state)
            move = turn(state, head)
            warning = show_status(path, state, move)
            return dict({'pullRequest': arguments.pull_request, 'reviewed': False, 'turn': move,
                         'pending': [item['id'] for item in pending(state)], 'briefing': briefing(state, move)},
                        **reported(state, [warning]))
    checking = move == 'check'
    if checking and not checkable(state):
        # A check of new commits reviews the ones Cicely was shown, up to the head she was asked at. Any pushed since
        # come after the check, and are reviewed or put to her as usual: never added to a check she didn't choose.
        head = checkpoint(last)['head']
    executable = shutil.which(reviewer)
    if not executable:
        raise Refusal(f'The {AGENTS[reviewer]} CLI ({reviewer}) is not on PATH.')
    base = fetch(repo, arguments.remote, f'refs/heads/{pr["baseRefName"]}', fetched(path, 'base'))
    merge_base = git(repo, 'merge-base', base, head)
    worktree = Path(state['worktree'])
    check_out(repo, worktree, head)
    hydrate(worktree, arguments.remote)
    context = {'reviewer': AGENTS[reviewer], 'author': AGENTS[state['author']], 'number': pr['number'],
               'repository': repository, 'title': pr['title'], 'head': head, 'base_branch': pr['baseRefName'],
               'base': base, 'merge_base': merge_base, 'body': (pr.get('body') or '').strip() or '(none)',
               'round': reviews(state) + 1, 'tools': TOOLS[reviewer]}
    expected = checkable(state) if last else {}
    commits = None
    if last:
        # A check reads what came after the last step that ran to the end; a full round reads everything since the
        # last full review, as a check looks only at the answers, or at the new commits.
        context['previous_head'] = reviewed(state)['head'] if checking else last_review(state)['head']
        if checking and not expected:
            # With no answers to check, Cicely chose a check of the commits since.
            commits = unreviewed(repo, context['previous_head'], head)
    change = change_folder(worktree)
    write_change(repo, change, context)
    # A check is numbered after the round it follows; Cicely's limits for it apply unless she set others.
    step = {'round': last['round'], 'check': last.get('check', 0) + 1} if checking else {'round': context['round']}
    minutes = arguments.timeout_minutes or (DEFAULT_CHECK_MINUTES if checking else DEFAULT_TIMEOUT_MINUTES)
    budget = arguments.budget_tokens or DEFAULT_CHECK_TOKENS
    warnings = []
    # Saved before anything is published, so that `status` finds the review even when the status comment fails.
    save(path, state)
    work = {'round': step['round'], 'doing': f'running {label(step)}' if checking else f'reviewing {label(step)}',
            'verb': 'checking' if checking else 'reviewing'}
    progress = Progress(path, work, head, lambda live: warnings.append(show_status(path, state, move, live)))
    progress.publish(dict(progress.now))
    before = json.loads(json.dumps(state))  # The record as it stands, to note a failure in.
    try:
        next_number = max([number_of(identifier) for identifier in all_ids(state)] + [0]) + 1
        if checking:
            round = run_check(state, step, context, expected, executable, worktree, change, minutes, budget,
                              next_number, progress, commits)
            comment = check_comment(state, round)
        else:
            round = run_round(state, step, context, expected, executable, worktree, change, minutes, next_number,
                              progress)
            comment = review_comment(state, round)
        state.pop('failure', None)
        post_and_save(path, state, round, repository, arguments.pull_request, comment)
    except Exception as error:
        # The status comment says the round failed; the record gains only that note.
        before['failure'] = dict(step, what=label(step), at=now(),
                                 error=str(error) if isinstance(error, Refusal) else f'{type(error).__name__}: {error}')
        with contextlib.suppress(OSError):
            save(path, before)
        show_status(path, before, move)
        raise
    finally:
        progress.close()
        if checking:
            warnings.append(tidy(repo, worktree, head))
    # The head may have moved while the reviewer read; then a clean review isn't the end. If GitHub can't say, the
    # head fetched before the review stands, which a check of the commits Cicely was shown may not have reached.
    try:
        state['pullRequestHead'] = pull_request(repository, arguments.pull_request)['headRefOid']
        save(path, state)
    except Refusal:
        pass
    except OSError as error:
        warnings.append(f'Could not record the pull request\'s head: {error}')
    move = turn(state, state['pullRequestHead'])
    warnings.append(show_status(path, state, move))
    result = {'pullRequest': arguments.pull_request, 'round': round['round'], 'author': state['author'],
              'reviewer': reviewer, 'head': head, 'session': round['session'], 'commentUrl': round['commentUrl'],
              'summary': round['summary'], 'open': open_findings(round), 'usage': round['usage'], 'turn': move,
              'pending': [item['id'] for item in pending(state)], 'maxRounds': state['maxRounds']}
    if checking:
        result.update(check=round['check'], stopped=round['stopped'], overran=round['overran'],
                      commits=[commit['sha'] for commit in (round.get('commits') or {}).get('list', [])],
                      verified=[finding['id'] for finding in round['findings'] if finding.get('verdict') == 'verified'],
                      unverified=[finding['id'] for finding in unverified(round)])
    else:
        result.update(resumed=round['resumed'], questions=questions(round), unlisted=round['unlisted'],
                      resolved=[finding['id'] for finding in round['findings'] if finding['status'] == 'resolved'])
    return dict(result, briefing=briefing(state, move), **reported(state, warnings))


def run_round(state: dict, step: dict, context: dict, expected: dict, executable: str, worktree: Path, change: Path,
              minutes: float, next_number: int, progress: Progress) -> dict:
    """Runs a full round of review and adds it to the record."""
    reviewer, timeout, last = state['reviewer'], minutes * 60, state['rounds'][-1] if state['rounds'] else None
    resumed = None
    if not last:
        session, output, usage = REVIEWERS[reviewer](executable, worktree, change, first_prompt(context), None,
                                                     timeout, progress)
    elif last.get('check'):
        # The reviewer's session didn't see the check, so the round after one starts afresh, with the history.
        session, output, usage = REVIEWERS[reviewer](executable, worktree, change,
                                                     later_prompt(context, state, AFTER_CHECK), None, timeout, progress)
        resumed = False
    else:
        try:
            session, output, usage = REVIEWERS[reviewer](executable, worktree, change,
                                                         later_prompt(context, state, None), state['session'],
                                                         timeout, progress)
            resumed = True
        except TimedOut:
            raise
        except Refusal as lost:
            # A session that can't be resumed is started again with the history in the prompt.
            try:
                session, output, usage = REVIEWERS[reviewer](executable, worktree, change,
                                                             later_prompt(context, state, RESUME_LOST), None, timeout,
                                                             progress)
            except Refusal as failed:
                raise Refusal(f'{failed} Resuming the earlier session failed first: {lost}')
            resumed = False
    summary, findings, unlisted = normalize(output, expected, next_number, not last)
    round = dict(step, head=context['head'], base=context['base'], mergeBase=context['merge_base'],
                 startedAt=progress.now['startedAt'], reviewedAt=now(), usage=usage, session=session, resumed=resumed,
                 summary=summary, findings=findings, unlisted=unlisted, commentUrl=None, answers=None)
    state['session'] = session
    state['rounds'].append(round)
    return round


def run_check(state: dict, step: dict, context: dict, expected: dict, executable: str, worktree: Path, change: Path,
              minutes: float, budget: int, next_number: int, progress: Progress, commits: dict | None) -> dict:
    """Runs the focused check Cicely chose and adds it to the record: of the answers to the `expected` findings, or,
    with none, of the new `commits`, which the record keeps with it. A check stopped at its token or time limit is
    recorded too, with nothing verified or reviewed; one that finished past its token limit, which the running count
    can miss by a step, keeps what it found, marked as having overrun. When nothing it found is for the author to
    answer but something is left unverified or unreviewed, what follows goes to Cicely at once."""
    scratch = scratch_folder(worktree)
    shutil.rmtree(scratch, ignore_errors=True)
    scratch.mkdir(parents=True)
    stopped = session = None
    try:
        session, output, usage = REVIEWERS[state['reviewer']](
            executable, worktree, change, check_prompt(context, state, expected, budget, minutes), None, minutes * 60, progress,
            {'budget': budget, 'scratch': scratch})
        summary, findings = judge(output, expected, next_number)
    except LimitReached as reached:
        stopped, usage, summary = reached.limit, reached.usage, str(reached)
        findings = sorted((dict(finding, status='unverified', verdict='not verified', new=False,
                                reply=f'The check was stopped at its {stopped} limit before it reported.')
                           for finding in expected.values()), key=order)
    # The check's own session is kept with it: the reviewer's review session goes on without it.
    round = dict(step, head=context['head'], base=context['base'], mergeBase=context['merge_base'],
                 startedAt=progress.now['startedAt'], reviewedAt=now(), usage=usage, session=session,
                 limits={'tokens': budget, 'minutes': minutes}, stopped=stopped,
                 overran=not stopped and tokens(usage) > budget, **({'commits': commits} if commits else {}),
                 summary=summary, findings=findings, commentUrl=None, answers=None)
    state['rounds'].append(round)
    if not open_findings(round) and (unverified(round) or stopped):
        ask_next_round(state, 'check', context['head'], commits)
    return round


def tidy(repo: Path, worktree: Path, head: str) -> str | None:
    """Clears what a focused check left in the review checkout, and its temp folder. A failure comes back as a
    warning; the next round's checkout clears it again."""
    shutil.rmtree(scratch_folder(worktree), ignore_errors=True)
    try:
        check_out(repo, worktree, head)
    except (Refusal, OSError) as error:
        return f'Could not clear what the check left in {worktree}: {error}'
    return None


def reported(state: dict, warnings: list) -> dict:
    """The status comment's link, and what went wrong updating it, for a command's result."""
    result = {'statusComment': (state.get('statusComment') or {}).get('url')}
    warnings = list(dict.fromkeys(warning for warning in warnings if warning))
    if warnings:
        result['warnings'] = warnings
    return result


def command_reply(arguments: argparse.Namespace) -> dict:
    repo = Path(arguments.repository).resolve()
    repository = github_repository(repo, arguments.remote)
    path = state_path(repo, repository, arguments.pull_request)
    lock(path)
    state = load_state(path)
    if turn(state) == 'cicely':
        raise Refusal(waiting_for_cicely(state))
    if turn(state) != 'reply':
        raise Refusal(f'There are no unanswered findings to reply to; it is the turn to {turn(state)}.')
    try:
        replies = json.loads(Path(arguments.replies).read_text(encoding='utf-8'))
    except (OSError, ValueError) as error:
        raise Refusal(f'Could not read the replies: {error}')
    last = state['rounds'][-1]
    open_ids = [finding['id'] for finding in open_findings(last)]
    if not isinstance(replies, list) or not all(isinstance(reply, dict) for reply in replies):
        raise Refusal('The replies must be a JSON array of {"id", "action", "note"} objects.')
    for reply in replies:
        if reply.get('action') not in ACTIONS:
            raise Refusal(f'Reply {reply.get("id")} has action {reply.get("action")!r}; use fixed, declined or escalated.')
        if not isinstance(reply.get('note'), str) or not reply['note'].strip():
            raise Refusal(f'Reply {reply.get("id")} needs a note.')
        options = reply.get('options')
        if reply['action'] == 'escalated' and (
                not words(reply.get('stakes')) or not isinstance(options, list) or len(options) < 2
                or not all(isinstance(option, dict) and words(option.get('choice')) and words(option.get('implies'))
                           for option in options)):
            raise Refusal(f'Escalation {reply.get("id")} needs `stakes`, why it matters, and at least two `options`, '
                          'each {"choice", "implies"} with both filled in, so that Cicely can decide it without '
                          'having followed the review.')
    ids = [reply.get('id') for reply in replies]
    missing = [identifier for identifier in open_ids if identifier not in ids]
    extra = [identifier for identifier in ids if identifier not in open_ids or ids.count(identifier) > 1]
    if missing or extra:
        raise Refusal('Answer every open finding exactly once. '
                      + (f'Unanswered: {", ".join(missing)}. ' if missing else '')
                      + (f'Not open or repeated: {", ".join(map(str, dict.fromkeys(extra)))}.' if extra else ''))
    pr = pull_request(repository, arguments.pull_request)
    if pr.get('state') != 'OPEN':
        raise Refusal(f'Pull request #{arguments.pull_request} is {str(pr.get("state")).lower()}, not open.')
    if any(reply['action'] == 'fixed' for reply in replies) and pr['headRefOid'] == last['head']:
        raise Refusal(f'The pull request is still at the reviewed head {last["head"][:7]}; push the fixes first.')
    changed = changed_lines(repo, arguments.remote, arguments.pull_request, last['head'], pr['headRefOid'],
                            fetched(path, 'head'))
    state['pullRequestHead'] = pr['headRefOid']
    replies = [dict({'id': reply['id'], 'action': reply['action'], 'note': reply['note'].strip()},
                    **({'stakes': words(reply['stakes']), 'options': choices(reply['options']),
                        'recommendation': words(reply.get('recommendation'))} if reply['action'] == 'escalated' else {}))
               for reply in replies]
    last['answers'] = {'head': pr['headRefOid'], 'answeredAt': now(), 'replies': replies, 'changedLines': changed,
                       'commentUrl': None}
    findings = {finding['id']: finding for finding in last['findings']}
    # Another round is a question for Cicely after the last round, after answers to a check she chose, and after
    # answers to only minor findings that change little.
    if last.get('check'):
        ask_next_round(state, 'check', pr['headRefOid'])
    elif reviews(state) >= state['maxRounds']:
        ask_next_round(state, 'limit', pr['headRefOid'], unreviewed(repo, last['head'], pr['headRefOid']))
    elif changed < SMALL_CHANGE and all(findings[reply['id']]['severity'] in ('minor', 'nit') for reply in replies):
        ask_next_round(state, 'small', pr['headRefOid'])
    for reply in replies:
        if reply['action'] == 'escalated':
            state['escalated'].append(dict(findings[reply['id']], note=reply['note'], stakes=reply['stakes'],
                                           options=reply['options'], recommendation=reply['recommendation'],
                                           **step_of(last), decision=None))
    post_and_save(path, state, last['answers'], repository, arguments.pull_request, answers_comment(state, last))
    move = turn(state, pr['headRefOid'])
    warning = show_status(path, state, move)
    return dict({'pullRequest': arguments.pull_request, 'round': last['round'], 'head': pr['headRefOid'],
                 'commentUrl': last['answers']['commentUrl'], 'replies': replies, 'changedLines': changed,
                 'pending': [item['id'] for item in pending(state)], 'turn': move,
                 'briefing': briefing(state, move)}, **reported(state, [warning]))


def changed_lines(repo: Path, remote: str, number: int, reviewed: str, head: str, into: str) -> int:
    """How many lines the commits since the reviewed head add or remove."""
    if head == reviewed:
        return 0
    got = fetch(repo, remote, f'refs/pull/{number}/head', into)
    if got != head:
        raise Refusal(f'The pull request head moved while it was fetched ({head[:7]} on GitHub, {got[:7]} '
                      'fetched); run again.')
    return lines_between(repo, reviewed, head)


def lines_between(repo: Path, old: str, new: str) -> int:
    """How many lines the change from `old` to `new` adds or removes."""
    total = 0
    for line in git(repo, 'diff', '--numstat', old, new).splitlines():
        # Binary files count "-" lines.
        total += sum(int(count) for count in line.split('\t')[:2] if count.isdigit())
    return total


def unreviewed(repo: Path, since: str, head: str) -> dict:
    """The commits after `since` up to `head`, oldest first along the branch, and the lines they change: what
    nobody has reviewed, for Cicely to see by name."""
    log = git(repo, 'log', '--first-parent', '--reverse', '--format=%H%x09%s', f'{since}..{head}')
    commits = [{'sha': line.partition('\t')[0], 'subject': line.partition('\t')[2]} for line in log.splitlines()
               if line]
    return {'since': since, 'list': commits, 'changedLines': lines_between(repo, since, head)}


def command_decide(arguments: argparse.Namespace) -> dict:
    repo = Path(arguments.repository).resolve()
    repository = github_repository(repo, arguments.remote)
    path = state_path(repo, repository, arguments.pull_request)
    lock(path)
    state = load_state(path)
    if turn(state) != 'cicely':
        raise Refusal(f'Nothing is waiting for Cicely; it is the turn to {turn(state)}.')
    try:
        decisions = json.loads(Path(arguments.decisions).read_text(encoding='utf-8'))
    except (OSError, ValueError) as error:
        raise Refusal(f'Could not read the decisions: {error}')
    if not isinstance(decisions, list) or not all(isinstance(decision, dict) for decision in decisions):
        raise Refusal('The decisions must be a JSON array of {"id", "decision"} objects, each with "choice" for '
                      f'{CHECKPOINT} and "view" where you gave her one.')
    for decision in decisions:
        if not isinstance(decision.get('decision'), str) or not decision['decision'].strip():
            raise Refusal(f'Decision {decision.get("id")} needs Cicely\'s answer.')
        if 'view' in decision and (not isinstance(decision['view'], str) or not decision['view'].strip()):
            raise Refusal(f'Decision {decision.get("id")} has an empty `view`: give the view you gave her, word for '
                          'word, or leave `view` out.')
        if decision.get('id') == CHECKPOINT and decision.get('choice') not in CHOICES:
            raise Refusal(f'Decision {CHECKPOINT} needs `choice`: "review" for another round, "check" for a focused '
                          'check of the answers, or "stop" to end the cross-review here, as Cicely chose.')
        if decision.get('id') == CHECKPOINT and decision['choice'] == 'check' and not checkable(state) \
                and not few_commits((checkpoint(state['rounds'][-1]) or {}).get('commits')):
            raise Refusal('A focused check would have nothing to check: there are no answers since the last round, '
                          f'nothing a check left unverified, and no new commits that change fewer than {SMALL_CHANGE} '
                          'lines. Ask Cicely again, with "review" and "stop" as her options.')
    waiting = {item['id']: item for item in pending(state)}
    ids = [decision.get('id') for decision in decisions]
    missing = [identifier for identifier in waiting if identifier not in ids]
    extra = [identifier for identifier in ids if identifier not in waiting or ids.count(identifier) > 1]
    if missing or extra:
        raise Refusal('Record a decision for everything waiting for Cicely, once each. '
                      + (f'Undecided: {", ".join(missing)}. ' if missing else '')
                      + (f'Not waiting or repeated: {", ".join(map(str, dict.fromkeys(extra)))}.' if extra else ''))
    pr = pull_request(repository, arguments.pull_request)
    if pr.get('state') != 'OPEN':
        raise Refusal(f'Pull request #{arguments.pull_request} is {str(pr.get("state")).lower()}, not open.')
    state['pullRequestHead'] = pr['headRefOid']
    last = state['rounds'][-1]
    # What she was asked is kept as it was put to her, before her answers change it.
    record = {**step_of(last), 'decidedAt': now(), 'commentUrl': None,
              'decisions': [dict({'id': decision['id'], 'title': waiting[decision['id']]['title'],
                                  'decision': decision['decision'].strip(),
                                  'asked': item_lines(state, waiting[decision['id']])},
                                 **({'choice': decision['choice']} if decision['id'] == CHECKPOINT else {}),
                                 **({'view': decision['view'].strip()} if 'view' in decision else {}))
                            for decision in decisions]}
    for decision in record['decisions']:
        item = waiting[decision['id']]
        item['decision'] = decision['decision']
        if decision.get('view'):
            item['view'] = decision['view']
        if decision['id'] == CHECKPOINT:
            item['choice'] = decision['choice']
            # Past the limit, her choice of another round raises it by one.
            if decision['choice'] == 'review' and reviews(state) >= state['maxRounds']:
                state['maxRounds'] = reviews(state) + 1
        # A question she has answered comes back to the author as an open finding carrying her decision.
        elif item['status'] == 'question':
            item['status'] = 'open'
    last['findings'].sort(key=order)
    state.setdefault('decisions', []).append(record)
    post_and_save(path, state, record, repository, arguments.pull_request, decisions_comment(state, record))
    move = turn(state, pr['headRefOid'])
    warning = show_status(path, state, move)
    return dict({'pullRequest': arguments.pull_request, 'round': last['round'], 'commentUrl': record['commentUrl'],
                 'decisions': [{key: value for key, value in decision.items() if key != 'asked'}
                               for decision in record['decisions']],
                 'open': open_findings(last), 'turn': move, 'briefing': briefing(state, move)},
                **reported(state, [warning]))


def command_status(arguments: argparse.Namespace) -> dict:
    repo = Path(arguments.repository).resolve()
    repository = github_repository(repo, arguments.remote)
    path = state_path(repo, repository, arguments.pull_request)
    state = load_state(path)
    if state is None:
        return {'pullRequest': arguments.pull_request, 'rounds': 0, 'turn': 'review', 'running': running(path)}
    last = state['rounds'][-1] if state['rounds'] else None
    # GitHub's head, so commits pushed since the last command count; `status` only reads, so it isn't recorded.
    head, warning = current_head(repository, arguments.pull_request, state)
    state = dict(state, pullRequestHead=head)
    move, live = turn(state, head), running(path)
    result = {'pullRequest': arguments.pull_request, 'author': state['author'], 'reviewer': state['reviewer'],
              'rounds': reviews(state), 'checks': len(state['rounds']) - reviews(state),
              'maxRounds': state['maxRounds'], 'turn': move, 'running': live,
              'head': last['head'] if last else None, 'pullRequestHead': head,
              'open': open_findings(last) if last else [],
              'unverified': unverified(last) if last else [],
              'pending': pending(state), 'escalated': state['escalated'], 'decisions': state.get('decisions', []),
              'comments': [url for round in state['rounds']
                           for url in (round['commentUrl'], (round['answers'] or {}).get('commentUrl')) if url]
                          + [record['commentUrl'] for record in state.get('decisions', []) if record['commentUrl']],
              'statusComment': (state.get('statusComment') or {}).get('url'), 'briefing': briefing(state, move, live),
              'worktree': state['worktree'], 'state': str(path)}
    if warning:
        result['warnings'] = [warning]
    return result


def command_finish(arguments: argparse.Namespace) -> dict:
    repo = Path(arguments.repository).resolve()
    repository = github_repository(repo, arguments.remote)
    path = state_path(repo, repository, arguments.pull_request)
    lock(path)
    state = load_state(path)
    if state is None:
        raise Refusal(f'There is no cross-review of #{arguments.pull_request} here.')
    worktree = Path(state['worktree'])
    removed = remove_worktree(repo, worktree)
    for folder in (worktree, change_folder(worktree), scratch_folder(worktree)):
        if folder.exists():
            shutil.rmtree(folder)
            removed = True
    for name in ('head', 'base'):
        ref = fetched(path, name)
        if git(repo, 'for-each-ref', '--format=%(refname)', ref) == ref:
            git(repo, 'update-ref', '-d', ref)
            removed = True
    head, warning = current_head(repository, arguments.pull_request, state)
    result = {'pullRequest': arguments.pull_request, 'worktree': str(worktree), 'removed': removed,
              'turn': turn(state, head)}
    if warning:
        result['warnings'] = [warning]
    return result


def main(argv: list[str]) -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('review', 'reply', 'decide', 'status', 'finish'):
        command = commands.add_parser(name)
        command.add_argument('--repository', required=True, help='the clone the pull request belongs to')
        command.add_argument('--pull-request', type=int, required=True)
        command.add_argument('--remote', default='origin')
        if name == 'review':
            command.add_argument('--author', choices=sorted(AGENTS), required=True, help='the agent running this')
            command.add_argument('--max-rounds', type=int, help=f'reviews in all (default {DEFAULT_MAX_ROUNDS})')
            command.add_argument('--timeout-minutes', type=float, help=f'default {DEFAULT_TIMEOUT_MINUTES}, or '
                                 f'{DEFAULT_CHECK_MINUTES} for a focused check')
            command.add_argument('--budget-tokens', type=int, help='tokens a focused check may use, cached ones '
                                 f'included (default {DEFAULT_CHECK_TOKENS})')
        if name == 'reply':
            command.add_argument('--replies', required=True, help='JSON array of {"id", "action", "note"}, and for '
                                 'an escalation "stakes", "options" and "recommendation"')
        if name == 'decide':
            command.add_argument('--decisions', required=True, help='JSON array of {"id", "decision"}, her words '
                                 f'exactly; {CHECKPOINT} also takes "choice": review, check or stop, and any '
                                 'takes "view", the view you gave her with it')
    arguments = parser.parse_args(argv)
    handler = {'review': command_review, 'reply': command_reply, 'decide': command_decide,
               'status': command_status, 'finish': command_finish}[arguments.command]
    try:
        result, code = handler(arguments), 0
    except Refusal as refusal:
        result, code = {'error': str(refusal)}, 1
    except Exception as error:  # Still one JSON document, saying what broke.
        result, code = {'error': f'{type(error).__name__}: {error}'}, 1
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return code


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

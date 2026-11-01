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
import fcntl
import hashlib
import json
import os
import queue
import re
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
STATUSES = ['open', 'question', 'resolved']
ACTIONS = {'fixed': 'fixed', 'declined': 'declined', 'escalated': 'for Cicely'}
CHECKPOINT = 'next-round'  # The id of the question whether another round is worth it.
CHOICES = {'review': 'another round', 'stop': 'the cross-review stops here'}
SMALL_ANSWERS = 200  # Answers to only minor or nit findings that change fewer lines make the script ask first.
STATUS_SECONDS = 120  # At most this often, the status comment shows what a running reviewer is doing.
DEFAULT_MAX_ROUNDS = 3
DEFAULT_TIMEOUT_MINUTES = 90
STATE_VERSION = 1
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


class Refusal(Exception):
    """A refusal or failure, reported as the command's `error`; nothing was posted unless it says so."""


class TimedOut(Refusal):
    """A command ran past its time limit and was stopped."""


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


def run_streaming(args: list[str], cwd: Path, input: str, env: dict | None, timeout: float,
                  on_line) -> subprocess.CompletedProcess:
    """Runs a reviewer like `run`, handing each line it prints to `on_line` as it comes, and None after a few
    quiet seconds, so its progress can be shown while it works."""
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
        if isinstance(error, subprocess.TimeoutExpired):
            raise TimedOut(f'{Path(args[0]).name} did not finish within {timeout / 60:g} minutes and was stopped.')
        raise
    for thread in threads:
        thread.join(5)
    return subprocess.CompletedProcess(args, process.returncode, ''.join(output), ''.join(errors))


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


def post(repository: str, number: int, body: str) -> str:
    output = gh(repository, 'pr', 'comment', str(number), '--body-file', '-', input=body).splitlines()
    return output[-1] if output else None


def edit(repository: str, comment: int, body: str) -> None:
    gh(None, 'api', '--method', 'PATCH', f'repos/{repository}/issues/comments/{comment}', '--input', '-',
       input=json.dumps({'body': body}))


def fetch(repo: Path, remote: str, ref: str) -> str:
    git(repo, 'fetch', '--quiet', '--no-tags', remote, ref)
    return git(repo, 'rev-parse', 'FETCH_HEAD^{commit}')


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
    if state.get('version') != STATE_VERSION:
        raise Refusal(f'{path} was written by another version of this script.')
    return state


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


def check_out(repo: Path, worktree: Path, head: str) -> None:
    if worktree.exists() and any(same_path(worktree, listed) for listed in listed_worktrees(repo)):
        git(worktree, 'checkout', '--quiet', '--force', '--detach', head)
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


TOOLS = {
    'codex': 'You may run commands that only read, such as `git show`. You cannot write files, so don\'t rely on '
             'builds or tests that write.',
    'claude': 'You have only the Read, Grep and Glob tools, limited to your working directory and the folder holding '
              'the change, so you can\'t run commands or tests.',
}


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
        if name == 'StructuredOutput':
            return 'writing up the review'
    return None


class Progress:
    """What a running reviewer is doing. It's kept in a file beside the ledger, which `status` reads, and shown on
    the status comment at its first step and at most every STATUS_SECONDS after."""

    def __init__(self, path: Path, round: int, head: str, publish) -> None:
        self.path, self.publish, self.shown = path.with_name(path.stem + '.progress.json'), publish, None
        self.now = {'pid': os.getpid(), 'round': round, 'head': head, 'startedAt': now(), 'latest': None, 'steps': 0}
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


def run_codex(executable: str, worktree: Path, change: Path, prompt: str, session: str | None,
              timeout: float, progress: Progress) -> tuple[str, dict, dict]:
    with tempfile.TemporaryDirectory(prefix='ba-crossreview-') as scratch:
        schema, last = Path(scratch) / 'schema.json', Path(scratch) / 'review.json'
        schema.write_text(json.dumps(REVIEW_SCHEMA), encoding='utf-8')
        # Read-only: the sandbox stops writes, and leaving out the user's configuration and rules leaves out its
        # plugins, MCP servers and command allowances, which act outside the sandbox. `exec resume` takes no
        # --sandbox, so the sandbox is set as configuration for both.
        args = [executable, 'exec', *(['resume', session] if session else []),
                '--ignore-user-config', '--ignore-rules', *codex_settings(),
                '-c', 'sandbox_mode="read-only"', '-c', 'approval_policy="never"',
                '--output-schema', str(schema), '-o', str(last), '--json', '-']
        found = {'thread': None, 'usage': {'input': 0, 'cached': 0, 'output': 0}}

        def on_line(line: str | None) -> None:
            event = event_of(line)
            if event.get('type') == 'thread.started':
                found['thread'] = event.get('thread_id')
            if event.get('type') == 'turn.completed' and isinstance(event.get('usage'), dict):
                for key, name in (('input', 'input_tokens'), ('cached', 'cached_input_tokens'),
                                  ('output', 'output_tokens')):
                    found['usage'][key] += int(event['usage'].get(name) or 0)
            progress.step(codex_activity(event))

        result = run_streaming(args, worktree, prompt, None, timeout, on_line)
        if result.returncode != 0 or not last.exists() or not found['thread']:
            raise Refusal(f'Codex failed (exit {result.returncode}): {tail(result.stderr or result.stdout)}')
        try:
            return found['thread'], json.loads(last.read_text(encoding='utf-8')), found['usage']
        except ValueError:
            raise Refusal('Codex did not answer with JSON.')


def run_claude(executable: str, worktree: Path, change: Path, prompt: str, session: str | None,
               timeout: float, progress: Progress) -> tuple[str, dict, dict]:
    # Read-only: only the reading tools exist, confined to the checkout and the change. Restricted mode ignores
    # settings that could allow more, and no MCP server or connector is loaded.
    args = [executable, '-p', *(['--resume', session] if session else []),
            '--output-format', 'stream-json', '--verbose', '--json-schema', json.dumps(REVIEW_SCHEMA),
            '--permission-mode', 'dontAsk', '--restricted', '--strict-mcp-config',
            '--tools', 'Read,Grep,Glob', '--add-dir', str(change)]
    # A Claude Code session's marker in the environment would make this look like a nested session.
    env = {name: value for name, value in os.environ.items() if name != 'CLAUDECODE'}
    answer = {}

    def on_line(line: str | None) -> None:
        event = event_of(line)
        if event.get('type') == 'result':
            answer.clear()
            answer.update(event)
        progress.step(claude_activity(event, worktree))

    result = run_streaming(args, worktree, prompt, env, timeout, on_line)
    if result.returncode != 0 or answer.get('is_error') or not isinstance(answer.get('structured_output'), dict) \
            or not answer.get('session_id'):
        message = answer.get('result') if isinstance(answer.get('result'), str) else None
        raise Refusal(f'Claude failed (exit {result.returncode}): {message or tail(result.stderr or result.stdout, 5)}')
    usage = answer.get('usage') if isinstance(answer.get('usage'), dict) else {}
    cached = int(usage.get('cache_read_input_tokens') or 0)
    return answer['session_id'], answer['structured_output'], {
        'input': int(usage.get('input_tokens') or 0) + int(usage.get('cache_creation_input_tokens') or 0) + cached,
        'cached': cached, 'output': int(usage.get('output_tokens') or 0),
        'cost': answer.get('total_cost_usd') if isinstance(answer.get('total_cost_usd'), (int, float)) else None}


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


def turn(state: dict | None, head: str | None = None) -> str:
    """Whose move it is: review, reply, cicely (her decisions are needed first), done (nothing left between the
    two at the reviewed head), stopped (she ended it rather than have another round) or limit (rounds used up).
    Given the pull request's head, a cross-review done or stopped at an earlier head is due another review."""
    if not state or not state['rounds']:
        return 'review'
    if pending(state):
        return 'cicely'
    last = state['rounds'][-1]
    if last['answers'] is None and open_findings(last):
        return 'reply'
    if last['answers'] is None and (not head or head == last['head']):
        return 'done'
    asked = checkpoint(last)
    if asked and asked.get('choice') == 'stop' and (not head or head == last['answers']['head']):
        return 'stopped'
    return 'limit' if len(state['rounds']) >= state['maxRounds'] else 'review'


def open_findings(round: dict) -> list[dict]:
    return [finding for finding in round['findings'] if finding['status'] == 'open']


def questions(round: dict) -> list[dict]:
    return [finding for finding in round['findings'] if finding['status'] == 'question']


def checkpoint(round: dict) -> dict | None:
    """The question whether another round is worth it, which `reply` puts to Cicely after answers to only minor
    findings."""
    return (round.get('answers') or {}).get('checkpoint')


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


def normalize(output: object, expected: dict[str, dict], next_number: int,
              first: bool) -> tuple[str, list[dict], list[str]]:
    """Checks the reviewer's answer and gives new findings ids; an expected finding left out stays open."""
    if not isinstance(output, dict) or not isinstance(output.get('findings'), list):
        raise Refusal('The reviewer answered without a findings list.')
    findings, new, seen = [], [], set()
    for raw in output['findings']:
        if not isinstance(raw, dict) or not str(raw.get('title') or '').strip():
            continue
        finding = {
            'id': raw.get('id') if isinstance(raw.get('id'), str) else None,
            'status': raw.get('status') if raw.get('status') in STATUSES else 'open',
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
        if not first and finding['id'] in expected and finding['id'] not in seen:
            seen.add(finding['id'])
            if expected[finding['id']].get('decision'):
                finding['decision'] = expected[finding['id']]['decision']
            findings.append(finding)
        elif finding['status'] != 'resolved':
            new.append(dict(finding, new=True, reply=None))
    # New findings are numbered most severe first, keeping the reviewer's order within a severity.
    for finding in sorted(new, key=lambda finding: SEVERITIES.index(finding['severity'])):
        finding['id'] = f'F{next_number}'
        next_number += 1
        findings.append(finding)
    unlisted = [identifier for identifier in expected if identifier not in seen]
    for identifier in unlisted:
        findings.append(dict(expected[identifier], status='open', new=False,
                             reply="The reviewer didn't re-list this finding, so it stays open."))
    findings.sort(key=order)
    return str(output.get('summary') or '').strip(), findings, unlisted


def review_comment(state: dict, round: dict) -> str:
    lines = [f'[{AGENTS[state["reviewer"]]}] Cross-review of #{state["pullRequest"]}, round {round["round"]}, '
             f'at {round["head"][:7]}', '']
    if round['summary']:
        lines += [round['summary'], '']
    open_now, asked = open_findings(round), questions(round)
    resolved = [finding for finding in round['findings'] if finding['status'] == 'resolved']

    def block(*text: str) -> None:
        # A blank line first, or Markdown would run the block into the list above it.
        if lines[-1]:
            lines.append('')
        lines.extend(text)

    if open_now:
        block('**Open**')
        for finding in open_now:
            new = ' *(new)*' if finding['new'] and round['round'] > 1 else ''
            lines.append(f'- **{finding["id"]}** · {finding["severity"]} · `{location(finding)}` · {finding["title"]}{new}')
            lines += indented(finding['detail'])
            if finding['reply']:
                lines += indented(finding['reply'], '  > ')
    if asked:
        block('**For Cicely to decide**')
        for finding in asked:
            new = ' *(new)*' if finding['new'] and round['round'] > 1 else ''
            lines.append(f'- **{finding["id"]}** · `{location(finding)}` · {finding["title"]}{new}')
            lines += indented(finding['detail'])
            lines += in_item(considerations(finding, 'Recommends'))
            if finding['reply']:
                lines += indented(finding['reply'], '  > ')
    if resolved:
        block('**Resolved**')
        for finding in resolved:
            lines.append(f'- **{finding["id"]}** · {finding["title"]}')
            lines += indented(finding['detail'])
            if finding['reply']:
                lines += indented(finding['reply'], '  > ')
    if not open_now and not asked:
        block('Nothing is open.')
    return '\n'.join(lines) + '\n'


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
    lines = [f'{CICELY} Decisions on the cross-review of #{state["pullRequest"]}, after round {record["round"]}', '',
             f'{AGENTS[state["author"]]} paused the cross-review to ask her. What she was asked is below, each with her '
             'answer word for word.']
    for decision in record['decisions']:
        lines += ['', *decision['asked'], '', '**Her answer:**', *quoted(decision['decision'])]
        if decision.get('choice'):
            lines += ['', f'**So:** {CHOICES[decision["choice"]]}.']
    return '\n'.join(lines) + '\n'


def quoted(text: str) -> list[str]:
    return ['> ' + line if line.strip() else '>' for line in text.strip().splitlines()]


def answers_comment(state: dict, round: dict) -> str:
    answers = round['answers']
    lines = [f'[{AGENTS[state["author"]]}] Answers to round {round["round"]} of the cross-review, '
             f'at {answers["head"][:7]}', '']
    titles = {finding['id']: finding['title'] for finding in round['findings']}
    for reply in answers['replies']:
        note = reply['note'].strip().splitlines()
        lines.append(f'- **{reply["id"]}** · {ACTIONS[reply["action"]]} · {titles[reply["id"]]} — {note[0]}')
        lines += indented('\n'.join(note[1:]))
        lines += in_item(considerations(reply, f'{AGENTS[state["author"]]} recommends'))
    if checkpoint(round):
        lines += ['', f'Only minor or nit findings were left, and these answers change {answers["changedLines"]} '
                      'lines, so the cross-review pauses for Cicely to decide whether another round is worth it.']
    return '\n'.join(lines) + '\n'


def clock(stamp: str) -> str:
    """A recorded time in this machine's time zone, such as "2026-11-01 14:05 CET"."""
    return datetime.fromisoformat(stamp).astimezone().strftime('%Y-%m-%d %H:%M %Z')


def minutes_between(start: str, end: str) -> int:
    return max(round((datetime.fromisoformat(end) - datetime.fromisoformat(start)).total_seconds() / 60), 0)


def amount(number: float) -> str:
    return f'{number / 1e6:.1f}M' if number >= 1e6 else f'{round(number / 1e3)}k' if number >= 1e3 else str(round(number))


def cost(round: dict) -> str | None:
    """What a round's review took, such as "12 min and about 1.2M tokens (900k cached)"."""
    parts = []
    if round.get('startedAt'):
        parts.append(f'{minutes_between(round["startedAt"], round["reviewedAt"])} min')
    usage = round.get('usage') or {}
    if usage.get('input') or usage.get('output'):
        price = f', ${usage["cost"]:.2f}' if usage.get('cost') else ''
        parts.append(f'about {amount(usage["input"] + usage["output"])} tokens '
                     f'({amount(usage.get("cached") or 0)} cached{price})')
    return ' and '.join(parts) or None


def link(text: str, url: str | None) -> str:
    return f'[{text}]({url})' if url else text


def item_lines(state: dict, item: dict) -> list[str]:
    """One thing waiting for Cicely, told so that she can decide it without having followed the review."""
    reviewer, author = AGENTS[state['reviewer']], AGENTS[state['author']]
    if item['id'] == CHECKPOINT:
        return checkpoint_lines(state)
    lines = [f'#### {item["id"]} · {item["title"]}']
    if 'note' in item:
        who = author
        lines += [f'{reviewer} raised this {item["severity"]} finding at `{location(item)}` in round {item["round"]}, '
                  f'and {author} took it to you.', '', f'**{reviewer}:** {item["detail"]}']
        if item.get('reply'):
            lines += ['', f'**{reviewer}, after {author}\'s last answer:** {item["reply"]}']
        lines += ['', f'**{author}\'s question:** {item["note"]}']
    else:
        who = reviewer
        about = f' about `{location(item)}`' if item.get('file') else ''
        lines += [f'{reviewer} asks you this{about}, in round {state["rounds"][-1]["round"]}.', '', item['detail']]
    extra = considerations(item, f'{who} recommends')
    return lines + (extra.splitlines() if item.get('options') else
                    [*extra.splitlines(), '', f'*{who} gave no options; ask {author} to spell them out.*'])


def checkpoint_lines(state: dict) -> list[str]:
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
    return [f'#### Another round after round {number}?',
            f'Round {number} left only minor or nit findings to answer: {answered}. {author}\'s answers changed '
            f'{changed} lines. The cross-review asks you before another round whenever a round\'s open findings were '
            f'all minor or nits and the answers changed fewer than {SMALL_ANSWERS} lines.',
            '', f'**Why it matters:** another round would mostly confirm small fixes, and could turn up more small '
            f'points, for the cost of another review by {reviewer}'
            + (f': round {number} took {took}.' if took else '.') + f' Stopping leaves {author}\'s last answers '
            'unchecked.',
            '', '**Options:**',
            f'1. **Another round** (round {number + 1} of {state["maxRounds"]}): {reviewer} checks the answers to '
            f'{", ".join(reply["id"] for reply in replies)}' + (f' and the {changed} changed lines' if changed else '')
            + ', and may raise new points only on what changed.',
            f'2. **Stop here:** {" ".join(stop)}']


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
              ('Asked of you', [id for id in ids if found[id]['status'] == 'question'])]
    return ['', f'**Findings:** {len(found)} in all, '
                + ', '.join(f'{severities[severity]} {severity}' for severity in SEVERITIES if severities[severity])
                + '.'] + [f'- {label}: {", ".join(group)}' for label, group in groups if group]


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
        return ['', f'**Next:** {reviewer} reviews round {len(rounds) + 1} of {state["maxRounds"]}.']
    if move == 'done':
        return ['', f'**Next:** nothing is open between {author} and {reviewer} at `{last["head"][:7]}`. Marking the '
                    'pull request ready is your call.']
    replies = (last['answers'] or {}).get('replies', [])
    unchecked = ', '.join(f'{reply["id"]} ({ACTIONS[reply["action"]]})' for reply in replies)
    if move == 'stopped':
        return ['', f'**You stopped it** after round {last["round"]}, at `{last["answers"]["head"][:7]}`. {reviewer} '
                    f'didn\'t check {author}\'s last answers: {unchecked}. Marking the pull request ready is your call.']
    # The rounds are used up.
    took = cost(last)
    lines = ['', f'### All {state["maxRounds"]} rounds are used']
    open_now = open_findings(last) if replies else []
    if open_now:
        notes = {reply['id']: reply for reply in replies}
        lines.append(f'{reviewer} hasn\'t checked {author}\'s answers to round {last["round"]}:')
        for finding in open_now:
            lines.append(f'- **{finding["id"]}** · {finding["severity"]} · {finding["title"]}')
            lines.append(f'  - {reviewer}: {short(finding.get("reply") or finding["detail"], 300)}')
            if finding['id'] in notes:
                reply = notes[finding['id']]
                lines.append(f'  - {author} {reply["action"]} it: {short(reply["note"], 300)}')
    else:
        lines.append(f'Commits pushed since round {last["round"]} haven\'t been reviewed.')
    return lines + ['', '**Options:**',
                    f'1. **One more round** (`--max-rounds {state["maxRounds"] + 1}`): {reviewer} checks what is above'
                    + (f'. Expect about what round {last["round"]} took: {took}.' if took else '.'),
                    '2. **Stop here:** what is open stays open on the record. Decide any of it yourself, or leave '
                    'it; marking the pull request ready is your call.']


def rounds_table(state: dict) -> list[str]:
    lines = ['| Round | Head | Review took | Found | Answers |', '|---|---|---|---|---|']
    for round in state['rounds']:
        new = Counter(finding['severity'] for finding in round['findings'] if finding.get('new'))
        found = ', '.join(f'{new[severity]} {severity}' for severity in SEVERITIES if new[severity]) or 'nothing new'
        resolved = sum(finding['status'] == 'resolved' for finding in round['findings'])
        if resolved:
            found += f'; {resolved} resolved'
        answers, answered = round['answers'], '—'
        if answers:
            actions = Counter(reply['action'] for reply in answers['replies'])
            answered = link(', '.join(f'{actions[action]} {ACTIONS[action]}' for action in ACTIONS if actions[action]),
                            answers.get('commentUrl'))
        lines.append(f'| {link(str(round["round"]), round.get("commentUrl"))} | `{round["head"][:7]}` | '
                     f'{cost(round) or "—"} | {found} | {answered} |')
    return lines


def briefing(state: dict, move: str, live: dict | None = None) -> str:
    """Where the cross-review stands and what, if anything, needs Cicely, for someone who hasn't followed it."""
    reviewer, author = AGENTS[state['reviewer']], AGENTS[state['author']]
    rounds = state['rounds']
    count = len(rounds)
    headlines = {'cicely': 'paused for your decision', 'reply': f'waiting for {author} to answer round {count}',
                 'review': f'{reviewer} reviews round {count + 1} next', 'done': 'done, with nothing open',
                 'limit': f'stopped at the limit of {state["maxRounds"]} rounds',
                 'stopped': f'stopped by you after round {count}'}
    headline = f'{reviewer} is reviewing round {live["round"]}' if live else headlines[move]
    about = f'{author} wrote this pull request and {reviewer} reviews it, in up to {state["maxRounds"]} rounds.'
    if rounds:
        about += f' Round {count} reviewed `{rounds[-1]["head"][:7]}`.'
    began = state.get('startedAt') or (rounds[0].get('startedAt') or rounds[0]['reviewedAt'] if rounds else None)
    if began:
        about += f' The cross-review began {clock(began)}.'
    lines = [f'### Cross-review of #{state["pullRequest"]}: {headline}', '', about]
    if live:
        latest = f' Latest: {live["latest"]}.' if live.get('latest') else ''
        lines += ['', f'**Now:** {reviewer} has been reviewing `{live["head"][:7]}` for '
                      f'{minutes_between(live["startedAt"], now())} min.{latest}']
    elif state.get('failure'):
        failure = state['failure']
        lines += ['', f'**Round {failure["round"]} failed** at {clock(failure["at"])}: {failure["error"]}']
    lines += findings_lines(state)
    decided = [link(f'{decision["id"]}, after round {record["round"]}', record.get('commentUrl'))
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


def later_prompt(context: dict, state: dict, fresh: bool) -> str:
    last = state['rounds'][-1]
    findings = {finding['id']: finding for finding in last['findings']}
    taken = {finding['id']: finding for finding in state['escalated'] if finding['round'] == last['round']}
    answers = []
    for reply in (last['answers'] or {}).get('replies', []):
        finding = findings[reply['id']]
        answers.append(f'- {finding["id"]} ({finding["severity"]}, {location(finding)}): {finding["title"]}')
        answers += indented(finding['detail'], '    ')
        decision = finding.get('decision')
        if reply['action'] == 'escalated':
            answers.append(f'  {context["author"]} took it to Cicely: {reply["note"].strip()}')
            decision = taken[reply['id']].get('decision')
        if decision:
            answers.append(f'  Cicely decided: {decision}')
        if reply['action'] != 'escalated':
            answers.append(f'  {context["author"]} {reply["action"]} it: {reply["note"].strip()}')
    answered = '\n'.join(answers) or '(None: nothing was open after your last review.)'
    later = LATER_ROUND.format(**context, answers=answered)
    return INTRO.format(**context) + LOOK.format(**context) + REPORT + RESUME_LOST + later if fresh else later


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
    if arguments.max_rounds is not None:
        if arguments.max_rounds < 1:
            raise Refusal('--max-rounds must be at least 1.')
        state['maxRounds'] = arguments.max_rounds
    if turn(state) == 'cicely':
        raise Refusal(waiting_for_cicely(state))
    if turn(state) == 'reply':
        raise Refusal(f'Round {len(state["rounds"])} has open findings; answer them with `reply` first.')
    pr = pull_request(repository, arguments.pull_request)
    if pr.get('state') != 'OPEN':
        raise Refusal(f'Pull request #{arguments.pull_request} is {str(pr.get("state")).lower()}, not open.')
    move = turn(state, pr['headRefOid'])
    if move == 'done':
        raise Refusal(f'Nothing is left between the author and the reviewer at {pr["headRefOid"][:7]}, the pull '
                      'request\'s head; the cross-review is done.')
    if move == 'limit':
        raise Refusal(f'All {state["maxRounds"]} rounds are used; bring what is still open to Cicely.')
    if move == 'stopped':
        raise Refusal(f'Cicely stopped the cross-review after round {len(state["rounds"])}; it reviews again only '
                      'when new commits are pushed.')
    executable = shutil.which(reviewer)
    if not executable:
        raise Refusal(f'The {AGENTS[reviewer]} CLI ({reviewer}) is not on PATH.')
    head = fetch(repo, arguments.remote, f'refs/pull/{arguments.pull_request}/head')
    if head != pr['headRefOid']:
        raise Refusal(f'The pull request head moved while it was fetched ({pr["headRefOid"][:7]} on GitHub, '
                      f'{head[:7]} fetched); run again.')
    base = fetch(repo, arguments.remote, f'refs/heads/{pr["baseRefName"]}')
    merge_base = git(repo, 'merge-base', base, head)
    worktree = Path(state['worktree'])
    check_out(repo, worktree, head)
    hydrate(worktree, arguments.remote)
    context = {'reviewer': AGENTS[reviewer], 'author': AGENTS[state['author']], 'number': pr['number'],
               'repository': repository, 'title': pr['title'], 'head': head, 'base_branch': pr['baseRefName'],
               'base': base, 'merge_base': merge_base, 'body': (pr.get('body') or '').strip() or '(none)',
               'round': len(state['rounds']) + 1, 'tools': TOOLS[reviewer]}
    expected = {}
    if state['rounds']:
        last = state['rounds'][-1]
        context['previous_head'] = last['head']
        answered = {reply['id'] for reply in (last['answers'] or {}).get('replies', [])}
        expected = {finding['id']: finding for finding in last['findings'] if finding['id'] in answered}
        for finding in state['escalated']:
            if finding['round'] == last['round'] and finding['id'] in expected:
                expected[finding['id']] = dict(expected[finding['id']], decision=finding.get('decision'))
    change = change_folder(worktree)
    write_change(repo, change, context)
    timeout = arguments.timeout_minutes * 60
    warnings = []
    progress = Progress(path, context['round'], head,
                        lambda live: warnings.append(show_status(path, state, 'review', live)))
    progress.publish(dict(progress.now))
    before = json.loads(json.dumps(state))  # The record as it stands, to note a failure in.
    try:
        resumed = None
        if not state['rounds']:
            session, output, usage = REVIEWERS[reviewer](executable, worktree, change, first_prompt(context), None,
                                                         timeout, progress)
        else:
            try:
                session, output, usage = REVIEWERS[reviewer](executable, worktree, change,
                                                             later_prompt(context, state, False), state['session'],
                                                             timeout, progress)
                resumed = True
            except TimedOut:
                raise
            except Refusal as lost:
                # A session that can't be resumed is started again with the history in the prompt.
                try:
                    session, output, usage = REVIEWERS[reviewer](executable, worktree, change,
                                                                 later_prompt(context, state, True), None, timeout,
                                                                 progress)
                except Refusal as failed:
                    raise Refusal(f'{failed} Resuming the earlier session failed first: {lost}')
                resumed = False
        next_number = max([number_of(identifier) for identifier in all_ids(state)] + [0]) + 1
        summary, findings, unlisted = normalize(output, expected, next_number, not state['rounds'])
        round = {'round': context['round'], 'head': head, 'base': base, 'mergeBase': merge_base,
                 'startedAt': progress.now['startedAt'], 'reviewedAt': now(), 'usage': usage, 'resumed': resumed,
                 'summary': summary, 'findings': findings, 'unlisted': unlisted, 'commentUrl': None, 'answers': None}
        state['session'] = session
        state['rounds'].append(round)
        state.pop('failure', None)
        post_and_save(path, state, round, repository, arguments.pull_request, review_comment(state, round))
    except Exception as error:
        # The status comment says the round failed; the record gains only that note.
        before['failure'] = {'round': context['round'], 'at': now(),
                             'error': str(error) if isinstance(error, Refusal) else f'{type(error).__name__}: {error}'}
        with contextlib.suppress(OSError):
            save(path, before)
        show_status(path, before, 'review')
        raise
    finally:
        progress.close()
    # The head may have moved while the reviewer read; then a clean review isn't the end.
    try:
        current = pull_request(repository, arguments.pull_request)['headRefOid']
    except Refusal:
        current = None
    move = turn(state, current)
    warnings.append(show_status(path, state, move))
    return dict({'pullRequest': arguments.pull_request, 'round': round['round'], 'author': state['author'],
                 'reviewer': reviewer, 'head': head, 'session': session, 'resumed': resumed,
                 'commentUrl': round['commentUrl'], 'summary': summary, 'open': open_findings(round),
                 'questions': questions(round),
                 'resolved': [finding['id'] for finding in findings if finding['status'] == 'resolved'],
                 'unlisted': unlisted, 'usage': usage, 'turn': move, 'maxRounds': state['maxRounds'],
                 'briefing': briefing(state, move)}, **reported(state, warnings))


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
        if reply['action'] == 'escalated' and (not words(reply.get('stakes')) or len(choices(reply.get('options'))) < 2):
            raise Refusal(f'Escalation {reply.get("id")} needs `stakes`, why it matters, and at least two `options`, '
                          'each {"choice", "implies"}, so that Cicely can decide it without having followed the review.')
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
    changed = changed_lines(repo, arguments.remote, arguments.pull_request, last['head'], pr['headRefOid'])
    replies = [dict({'id': reply['id'], 'action': reply['action'], 'note': reply['note'].strip()},
                    **({'stakes': words(reply['stakes']), 'options': choices(reply['options']),
                        'recommendation': words(reply.get('recommendation'))} if reply['action'] == 'escalated' else {}))
               for reply in replies]
    last['answers'] = {'head': pr['headRefOid'], 'answeredAt': now(), 'replies': replies, 'changedLines': changed,
                       'commentUrl': None}
    findings = {finding['id']: finding for finding in last['findings']}
    # Answers to only minor findings that change little make another round a question for Cicely.
    if len(state['rounds']) < state['maxRounds'] and changed < SMALL_ANSWERS \
            and all(findings[reply['id']]['severity'] in ('minor', 'nit') for reply in replies):
        last['answers']['checkpoint'] = {'id': CHECKPOINT, 'title': f'Another round after round {last["round"]}?',
                                         'decision': None, 'choice': None}
    for reply in replies:
        if reply['action'] == 'escalated':
            state['escalated'].append(dict(findings[reply['id']], note=reply['note'], stakes=reply['stakes'],
                                           options=reply['options'], recommendation=reply['recommendation'],
                                           round=last['round'], decision=None))
    post_and_save(path, state, last['answers'], repository, arguments.pull_request, answers_comment(state, last))
    move = turn(state, pr['headRefOid'])
    warning = show_status(path, state, move)
    return dict({'pullRequest': arguments.pull_request, 'round': last['round'], 'head': pr['headRefOid'],
                 'commentUrl': last['answers']['commentUrl'], 'replies': replies, 'changedLines': changed,
                 'pending': [item['id'] for item in pending(state)], 'turn': move,
                 'briefing': briefing(state, move)}, **reported(state, [warning]))


def changed_lines(repo: Path, remote: str, number: int, reviewed: str, head: str) -> int:
    """How many lines the commits since the reviewed head add or remove."""
    if head == reviewed:
        return 0
    fetched = fetch(repo, remote, f'refs/pull/{number}/head')
    if fetched != head:
        raise Refusal(f'The pull request head moved while it was fetched ({head[:7]} on GitHub, {fetched[:7]} '
                      'fetched); run again.')
    total = 0
    for line in git(repo, 'diff', '--numstat', reviewed, head).splitlines():
        # Binary files count "-" lines.
        total += sum(int(count) for count in line.split('\t')[:2] if count.isdigit())
    return total


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
        raise Refusal('The decisions must be a JSON array of {"id", "decision"} objects.')
    for decision in decisions:
        if not isinstance(decision.get('decision'), str) or not decision['decision'].strip():
            raise Refusal(f'Decision {decision.get("id")} needs Cicely\'s answer.')
        if decision.get('id') == CHECKPOINT and decision.get('choice') not in CHOICES:
            raise Refusal(f'Decision {CHECKPOINT} needs `choice`: "review" for another round or "stop" to end the '
                          'cross-review here, as Cicely chose.')
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
    last = state['rounds'][-1]
    # What she was asked is kept as it was put to her, before her answers change it.
    record = {'round': last['round'], 'decidedAt': now(), 'commentUrl': None,
              'decisions': [dict({'id': decision['id'], 'title': waiting[decision['id']]['title'],
                                  'decision': decision['decision'].strip(),
                                  'asked': item_lines(state, waiting[decision['id']])},
                                 **({'choice': decision['choice']} if decision['id'] == CHECKPOINT else {}))
                            for decision in decisions]}
    for decision in record['decisions']:
        item = waiting[decision['id']]
        item['decision'] = decision['decision']
        if decision['id'] == CHECKPOINT:
            item['choice'] = decision['choice']
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
        return {'pullRequest': arguments.pull_request, 'rounds': 0, 'turn': 'review'}
    last = state['rounds'][-1] if state['rounds'] else None
    move, live = turn(state), running(path)
    return {'pullRequest': arguments.pull_request, 'author': state['author'], 'reviewer': state['reviewer'],
            'rounds': len(state['rounds']), 'maxRounds': state['maxRounds'], 'turn': move, 'running': live,
            'head': last['head'] if last else None, 'open': open_findings(last) if last else [],
            'pending': pending(state), 'escalated': state['escalated'], 'decisions': state.get('decisions', []),
            'comments': [url for round in state['rounds']
                         for url in (round['commentUrl'], (round['answers'] or {}).get('commentUrl')) if url]
                        + [record['commentUrl'] for record in state.get('decisions', []) if record['commentUrl']],
            'statusComment': (state.get('statusComment') or {}).get('url'), 'briefing': briefing(state, move, live),
            'worktree': state['worktree'], 'state': str(path)}


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
    for folder in (worktree, change_folder(worktree)):
        if folder.exists():
            shutil.rmtree(folder)
            removed = True
    return {'pullRequest': arguments.pull_request, 'worktree': str(worktree), 'removed': removed, 'turn': turn(state)}


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
            command.add_argument('--timeout-minutes', type=float, default=DEFAULT_TIMEOUT_MINUTES)
        if name == 'reply':
            command.add_argument('--replies', required=True, help='JSON array of {"id", "action", "note"}, and for '
                                 'an escalation "stakes", "options" and "recommendation"')
        if name == 'decide':
            command.add_argument('--decisions', required=True, help='JSON array of {"id", "decision"}, her words '
                                 f'exactly; {CHECKPOINT} also takes "choice", review or stop')
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

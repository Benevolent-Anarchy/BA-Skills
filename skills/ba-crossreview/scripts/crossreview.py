#!/usr/bin/env python3
"""Has one agent review, headless and read-only, a pull request the other agent wrote, and keeps the ledger.

Claude and Codex review each other's pull requests. The author runs this script; the reviewer is the
other agent's command-line tool, run in a detached worktree at the pull request's pushed head. Every
review and every answer is posted on the pull request. Each command prints one JSON document; a failure
carries an `error` member and has posted nothing, unless the error says it did.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

AGENTS = {'claude': 'Claude', 'codex': 'Codex'}
SEVERITIES = ['blocker', 'major', 'minor', 'nit']
STATUSES = ['open', 'question', 'resolved']
ACTIONS = {'fixed': 'fixed', 'declined': 'declined', 'escalated': 'for Cicely'}
DEFAULT_MAX_ROUNDS = 3
DEFAULT_TIMEOUT_MINUTES = 90
STATE_VERSION = 1
LOCKS = []  # Open lock files, held until the process ends.

# Strict structured-output schema: every property required and nothing else allowed, as both
# Codex's --output-schema and Claude's --json-schema accept it.
FINDING_SCHEMA = {
    'type': 'object',
    'additionalProperties': False,
    'required': ['id', 'status', 'severity', 'file', 'line', 'title', 'detail', 'reply'],
    'properties': {
        'id': {'type': ['string', 'null']},
        'status': {'type': 'string', 'enum': ['open', 'question', 'resolved']},
        'severity': {'type': 'string', 'enum': SEVERITIES},
        'file': {'type': ['string', 'null']},
        'line': {'type': ['integer', 'null']},
        'title': {'type': 'string'},
        'detail': {'type': 'string'},
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
code and the project's notes can't tell you, report it with `status` "question" and say in `detail` exactly \
what she needs to decide. The cross-review pauses until she answers.
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
stands. Judge fixes by the code, not by the answer. Cicely owns the project, so her decisions settle what they \
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


def gh(repository: str, *args: str, input: str | None = None) -> str:
    """Runs the GitHub CLI against the named repository, so GH_REPO and the CLI's default never redirect it."""
    executable = shutil.which('gh')
    if not executable:
        raise Refusal('The GitHub CLI (gh) is not on PATH.')
    result = run([executable, *args, '--repo', repository], input=input)
    if result.returncode != 0:
        raise Refusal(f'gh {" ".join(args[:2])} failed: {tail(result.stderr)}')
    return result.stdout.strip()


def pull_request(repository: str, number: int) -> dict:
    fields = 'number,title,body,state,isDraft,headRefOid,headRefName,baseRefName,url'
    return json.loads(gh(repository, 'pr', 'view', str(number), '--json', fields))


def post(repository: str, number: int, body: str) -> str:
    output = gh(repository, 'pr', 'comment', str(number), '--body-file', '-', input=body).splitlines()
    return output[-1] if output else None


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
    """Pulls the head's Git LFS objects, which the read-only reviewer can't, and refuses to review pointers."""
    found = run(['git', '-C', str(worktree), 'grep', '-q', '-e', 'filter=lfs', '--', ':(glob)**/.gitattributes'])
    if found.returncode == 1:
        return
    if found.returncode != 0:
        raise Refusal(f'Could not check the checkout for Git LFS: {tail(found.stderr)}')
    if run(['git', '-C', str(worktree), 'lfs', 'version']).returncode != 0:
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
        match = re.search(rf'(?m)^[ \t]*{key}[ \t]*=[ \t]*"([A-Za-z0-9._:/-]+)"[ \t]*(?:#.*)?$', top)
        if match:
            settings += ['-c', f'{key}="{match.group(1)}"']
    return settings


TOOLS = {
    'codex': 'You may run commands that only read, such as `git show`. You cannot write files, so don\'t rely on '
             'builds or tests that write.',
    'claude': 'You have only the Read, Grep and Glob tools, limited to your working directory and the folder holding '
              'the change, so you can\'t run commands or tests.',
}


def run_codex(executable: str, worktree: Path, change: Path, prompt: str, session: str | None,
              timeout: float) -> tuple[str, dict]:
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
        result = run(args, cwd=worktree, input=prompt, timeout=timeout)
        thread = None
        for line in result.stdout.splitlines():
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if isinstance(event, dict) and event.get('type') == 'thread.started':
                thread = event.get('thread_id')
        if result.returncode != 0 or not last.exists() or not thread:
            raise Refusal(f'Codex failed (exit {result.returncode}): {tail(result.stderr or result.stdout)}')
        try:
            return thread, json.loads(last.read_text(encoding='utf-8'))
        except ValueError:
            raise Refusal('Codex did not answer with JSON.')


def run_claude(executable: str, worktree: Path, change: Path, prompt: str, session: str | None,
               timeout: float) -> tuple[str, dict]:
    # Read-only: only the reading tools exist, confined to the checkout and the change. Restricted mode ignores
    # settings that could allow more, and no MCP server or connector is loaded.
    args = [executable, '-p', *(['--resume', session] if session else []),
            '--output-format', 'json', '--json-schema', json.dumps(REVIEW_SCHEMA),
            '--permission-mode', 'dontAsk', '--restricted', '--strict-mcp-config',
            '--tools', 'Read,Grep,Glob', '--add-dir', str(change)]
    # A Claude Code session's marker in the environment would make this look like a nested session.
    env = {name: value for name, value in os.environ.items() if name != 'CLAUDECODE'}
    result = run(args, cwd=worktree, input=prompt, env=env, timeout=timeout)
    try:
        answer = json.loads(result.stdout)
    except ValueError:
        answer = None
    if result.returncode != 0 or not isinstance(answer, dict) or answer.get('is_error') \
            or not isinstance(answer.get('structured_output'), dict) or not answer.get('session_id'):
        message = answer.get('result') if isinstance(answer, dict) else None
        raise Refusal(f'Claude failed (exit {result.returncode}): {message or tail(result.stderr or result.stdout)}')
    return answer['session_id'], answer['structured_output']


REVIEWERS = {'codex': run_codex, 'claude': run_claude}


def location(finding: dict) -> str:
    if not finding.get('file'):
        return 'general'
    return finding['file'] + (f':{finding["line"]}' if finding.get('line') else '')


def indented(text: str, prefix: str = '  ') -> list[str]:
    return [prefix + line if line.strip() else '' for line in text.strip().splitlines()]


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
    two at the reviewed head) or limit (rounds used up). Given the pull request's head, a cross-review done at an
    earlier head is due another review."""
    if not state or not state['rounds']:
        return 'review'
    if pending(state):
        return 'cicely'
    last = state['rounds'][-1]
    if last['answers'] is None and open_findings(last):
        return 'reply'
    if last['answers'] is None and (not head or head == last['head']):
        return 'done'
    return 'limit' if len(state['rounds']) >= state['maxRounds'] else 'review'


def open_findings(round: dict) -> list[dict]:
    return [finding for finding in round['findings'] if finding['status'] == 'open']


def questions(round: dict) -> list[dict]:
    return [finding for finding in round['findings'] if finding['status'] == 'question']


def pending(state: dict) -> list[dict]:
    """What waits for Cicely: the reviewer's questions in the last round and the findings taken to her, until she
    decides them."""
    waiting = questions(state['rounds'][-1]) if state['rounds'] else []
    return waiting + [finding for finding in state['escalated'] if not finding.get('decision')]


def waiting_for_cicely(state: dict) -> str:
    ids = ', '.join(dict.fromkeys(finding['id'] for finding in pending(state)))
    return f'Cicely has to decide {ids} first: ask her, then record her answers with `decide`.'

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
            'reply': raw.get('reply').strip() if isinstance(raw.get('reply'), str) and raw.get('reply').strip() else None,
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


def decisions_comment(state: dict, record: dict) -> str:
    lines = [f'[{AGENTS[state["author"]]}] Cicely\'s decisions on the cross-review, after round {record["round"]}', '']
    for decision in record['decisions']:
        lines.append(f'- **{decision["id"]}** · {decision["title"]}')
        lines += indented(decision['decision'], '  > ')
    return '\n'.join(lines) + '\n'


def answers_comment(state: dict, round: dict) -> str:
    answers = round['answers']
    lines = [f'[{AGENTS[state["author"]]}] Answers to round {round["round"]} of the cross-review, '
             f'at {answers["head"][:7]}', '']
    titles = {finding['id']: finding['title'] for finding in round['findings']}
    for reply in answers['replies']:
        note = reply['note'].strip().splitlines()
        lines.append(f'- **{reply["id"]}** · {ACTIONS[reply["action"]]} · {titles[reply["id"]]} — {note[0]}')
        lines += indented('\n'.join(note[1:]))
    return '\n'.join(lines) + '\n'


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
                 'rounds': [], 'escalated': []}
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
    resumed = None
    if not state['rounds']:
        session, output = REVIEWERS[reviewer](executable, worktree, change, first_prompt(context), None, timeout)
    else:
        try:
            session, output = REVIEWERS[reviewer](executable, worktree, change, later_prompt(context, state, False),
                                                  state['session'], timeout)
            resumed = True
        except TimedOut:
            raise
        except Refusal as lost:
            # A session that can't be resumed is started again with the history in the prompt.
            try:
                session, output = REVIEWERS[reviewer](executable, worktree, change,
                                                      later_prompt(context, state, True), None, timeout)
            except Refusal as failed:
                raise Refusal(f'{failed} Resuming the earlier session failed first: {lost}')
            resumed = False
    next_number = max([number_of(identifier) for identifier in all_ids(state)] + [0]) + 1
    summary, findings, unlisted = normalize(output, expected, next_number, not state['rounds'])
    round = {'round': context['round'], 'head': head, 'base': base, 'mergeBase': merge_base, 'reviewedAt': now(),
             'resumed': resumed, 'summary': summary, 'findings': findings, 'unlisted': unlisted,
             'commentUrl': None, 'answers': None}
    state['session'] = session
    state['rounds'].append(round)
    post_and_save(path, state, round, repository, arguments.pull_request, review_comment(state, round))
    # The head may have moved while the reviewer read; then a clean review isn't the end.
    try:
        current = pull_request(repository, arguments.pull_request)['headRefOid']
    except Refusal:
        current = None
    return {'pullRequest': arguments.pull_request, 'round': round['round'], 'author': state['author'],
            'reviewer': reviewer, 'head': head, 'session': session, 'resumed': resumed,
            'commentUrl': round['commentUrl'], 'summary': summary, 'open': open_findings(round),
            'questions': questions(round),
            'resolved': [finding['id'] for finding in findings if finding['status'] == 'resolved'],
            'unlisted': unlisted, 'turn': turn(state, current), 'maxRounds': state['maxRounds']}


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
    replies = [{'id': reply['id'], 'action': reply['action'], 'note': reply['note'].strip()} for reply in replies]
    last['answers'] = {'head': pr['headRefOid'], 'answeredAt': now(), 'replies': replies, 'commentUrl': None}
    findings = {finding['id']: finding for finding in last['findings']}
    for reply in replies:
        if reply['action'] == 'escalated':
            state['escalated'].append(dict(findings[reply['id']], note=reply['note'], round=last['round'],
                                           decision=None))
    post_and_save(path, state, last['answers'], repository, arguments.pull_request, answers_comment(state, last))
    return {'pullRequest': arguments.pull_request, 'round': last['round'], 'head': pr['headRefOid'],
            'commentUrl': last['answers']['commentUrl'], 'replies': replies,
            'pending': [finding['id'] for finding in pending(state)], 'turn': turn(state, pr['headRefOid'])}


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
    waiting = {finding['id']: finding for finding in pending(state)}
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
    record = {'round': last['round'], 'decidedAt': now(), 'commentUrl': None,
              'decisions': [{'id': decision['id'], 'title': waiting[decision['id']]['title'],
                             'decision': decision['decision'].strip()} for decision in decisions]}
    for decision in record['decisions']:
        finding = waiting[decision['id']]
        finding['decision'] = decision['decision']
        # A question she has answered comes back to the author as an open finding carrying her decision.
        if finding['status'] == 'question':
            finding['status'] = 'open'
    last['findings'].sort(key=order)
    state.setdefault('decisions', []).append(record)
    post_and_save(path, state, record, repository, arguments.pull_request, decisions_comment(state, record))
    return {'pullRequest': arguments.pull_request, 'round': last['round'], 'commentUrl': record['commentUrl'],
            'decisions': record['decisions'], 'open': open_findings(last), 'turn': turn(state, pr['headRefOid'])}


def command_status(arguments: argparse.Namespace) -> dict:
    repo = Path(arguments.repository).resolve()
    repository = github_repository(repo, arguments.remote)
    path = state_path(repo, repository, arguments.pull_request)
    state = load_state(path)
    if state is None:
        return {'pullRequest': arguments.pull_request, 'rounds': 0, 'turn': 'review'}
    last = state['rounds'][-1] if state['rounds'] else None
    return {'pullRequest': arguments.pull_request, 'author': state['author'], 'reviewer': state['reviewer'],
            'rounds': len(state['rounds']), 'maxRounds': state['maxRounds'], 'turn': turn(state),
            'head': last['head'] if last else None, 'open': open_findings(last) if last else [],
            'pending': pending(state), 'escalated': state['escalated'], 'decisions': state.get('decisions', []),
            'comments': [url for round in state['rounds']
                         for url in (round['commentUrl'], (round['answers'] or {}).get('commentUrl')) if url]
                        + [record['commentUrl'] for record in state.get('decisions', []) if record['commentUrl']],
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
            command.add_argument('--replies', required=True, help='JSON array of {"id", "action", "note"}')
        if name == 'decide':
            command.add_argument('--decisions', required=True, help='JSON array of {"id", "decision"}, in her words')
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

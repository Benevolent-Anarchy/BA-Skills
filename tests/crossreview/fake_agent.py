"""Stands in for gh, codex, claude and git-lfs in the cross-review tests.

The first argument names the tool being faked. Every call is logged to calls.jsonl in the directory
BA_CROSSREVIEW_FAKE names, with its arguments, working directory and standard input. pr.json is what
`gh pr view` prints, and comments.json holds the comments `gh pr comment` posts and `gh api` edits. Each
reviewer call takes the next entry of reviews.json and streams events as the real tool does: one step of
work, then, after the entry's `sleep`, its answer and token usage. A Codex focused check, run with write
access, starts its session's rollout file under CODEX_HOME, as Codex does, unless the entry has `noRollout`;
logs each of the entry's `tokens` there as a running total; and leaves the entry's `leaves` files behind.
Claude reports each message's `streamed` usage with every event of that message, as Claude does. Git LFS
counts as installed only when lfs-installed exists, and lfs-files.txt is what `git lfs ls-files` prints.
"""
import json
import os
import sys
import time
from pathlib import Path

fixture = Path(os.environ['BA_CROSSREVIEW_FAKE'])
tool, args = sys.argv[1], sys.argv[2:]
stdin = sys.stdin.read() if not sys.stdin.isatty() else ''
with open(fixture / 'calls.jsonl', 'a', encoding='utf-8') as log:
    log.write(json.dumps({'tool': tool, 'args': args, 'cwd': os.getcwd(), 'stdin': stdin,
                          'claudecode': os.environ.get('CLAUDECODE'), 'tmpdir': os.environ.get('TMPDIR')}) + '\n')


def value(flag):
    return args[args.index(flag) + 1]


def next_review():
    path = fixture / 'reviews.json'
    reviews = json.loads(path.read_text(encoding='utf-8'))
    if not reviews:
        sys.exit('fixture: no review queued')
    path.write_text(json.dumps(reviews[1:]), encoding='utf-8')
    return reviews[0]


if tool == 'gh':
    if args[:2] == ['pr', 'view']:
        if value('--repo') != 'fixture/repo':
            sys.exit('fixture: repository not explicit')
        print((fixture / 'pr.json').read_text(encoding='utf-8'))
    elif args[:2] == ['pr', 'comment']:
        if (fixture / 'comment-fails').exists():
            sys.exit('fixture: commenting refused')
        path = fixture / 'comments.json'
        comments = json.loads(path.read_text(encoding='utf-8')) if path.exists() else []
        comments.append({'pullRequest': args[2], 'repo': value('--repo'), 'body': stdin})
        path.write_text(json.dumps(comments), encoding='utf-8')
        print(f'https://github.com/fixture/repo/pull/{args[2]}#issuecomment-{len(comments)}')
    elif args[:3] == ['api', '--method', 'PATCH'] and args[4:] == ['--input', '-']:
        if (fixture / 'comment-fails').exists():
            sys.exit('fixture: commenting refused')
        prefix = 'repos/fixture/repo/issues/comments/'
        if not args[3].startswith(prefix):
            sys.exit(f'fixture: unexpected comment path {args[3]}')
        path = fixture / 'comments.json'
        comments = json.loads(path.read_text(encoding='utf-8'))
        number = int(args[3][len(prefix):])
        if number > len(comments) or comments[number - 1].get('deleted'):
            sys.exit('gh: Not Found (HTTP 404)')
        comments[number - 1]['body'] = json.loads(stdin)['body']
        comments[number - 1]['edits'] = comments[number - 1].get('edits', 0) + 1
        path.write_text(json.dumps(comments), encoding='utf-8')
    else:
        sys.exit(f'fixture: unexpected gh arguments {args!r}')
    sys.exit(0)

if tool == 'git-lfs':
    if not (fixture / 'lfs-installed').exists():
        sys.exit('git: \'lfs\' is not a git command.')
    if args[:1] == ['ls-files']:
        path = fixture / 'lfs-files.txt'
        print(path.read_text(encoding='utf-8') if path.exists() else '', end='')
    sys.exit(0)

def emit(event):
    print(json.dumps(event), flush=True)


review = next_review()
if review.get('prHead'):
    # The pull request moves on while the reviewer reads.
    pr = json.loads((fixture / 'pr.json').read_text(encoding='utf-8'))
    (fixture / 'pr.json').write_text(json.dumps(dict(pr, headRefOid=review['prHead'])), encoding='utf-8')
resuming = (tool == 'codex' and args[1:2] == ['resume']) or (tool == 'claude' and '--resume' in args)
if review.get('exit') or (resuming and review.get('resumeFails')):
    print(review.get('stderr', 'fixture: reviewer failed'), file=sys.stderr)
    sys.exit(review.get('exit') or 1)
usage = review.get('usage', {'input': 1200000, 'cached': 900000, 'output': 30000})
if tool == 'codex':
    session = args[2] if resuming else review.get('session', 'codex-thread-1')
    emit({'type': 'thread.started', 'thread_id': session})
    if 'sandbox_mode="workspace-write"' in args and not review.get('noRollout'):
        rollout = Path(os.environ['CODEX_HOME'], 'sessions/2026/11/01', f'rollout-2026-11-01T09-00-00-{session}.jsonl')
        rollout.parent.mkdir(parents=True, exist_ok=True)
        with open(rollout, 'a', encoding='utf-8') as stream:
            stream.write(json.dumps({'type': 'session_meta', 'payload': {'id': session}}) + '\n')
        for total in review.get('tokens', []):
            with open(rollout, 'a', encoding='utf-8') as stream:
                stream.write(json.dumps({'type': 'event_msg', 'payload': {'type': 'token_count', 'info': {
                    'total_token_usage': {'input_tokens': total, 'cached_input_tokens': total // 2,
                                          'output_tokens': 0}}}}) + '\n')
            emit({'type': 'item.started', 'item': {'type': 'command_execution',
                                                   'command': "/bin/bash -lc 'python3 -m unittest'"}})
    if 'sandbox_mode="workspace-write"' in args:
        for name in review.get('leaves', []):
            for folder in (os.getcwd(), os.environ['TMPDIR']):
                Path(folder, name).write_text('Left by the tests.\n', encoding='utf-8')
    emit({'type': 'item.started', 'item': {'type': 'command_execution', 'command': "/bin/bash -lc 'git status --short'"}})
    time.sleep(review.get('sleep', 0))
    Path(value('-o')).write_text(json.dumps(review['output']), encoding='utf-8')
    emit({'type': 'item.completed', 'item': {'type': 'agent_message', 'text': json.dumps(review['output'])}})
    emit({'type': 'turn.completed', 'usage': {'input_tokens': usage['input'], 'cached_input_tokens': usage['cached'],
                                              'output_tokens': usage['output']}})
elif tool == 'claude':
    session = value('--resume') if resuming else review.get('session', 'claude-session-1')
    emit({'type': 'system', 'subtype': 'init', 'session_id': session})
    streamed = review.get('streamed', {'input_tokens': 10, 'output_tokens': 5})
    emit({'type': 'assistant', 'message': {'id': 'message-1', 'usage': streamed, 'content': [
        {'type': 'tool_use', 'name': 'Read', 'input': {'file_path': os.path.join(os.getcwd(), 'widget.py')}}]}})
    emit({'type': 'assistant', 'message': {'id': 'message-1', 'usage': streamed, 'content': [
        {'type': 'text', 'text': 'Reading on.'}]}})
    time.sleep(review.get('sleep', 0))
    emit({'type': 'result', 'subtype': 'success', 'is_error': False, 'session_id': session,
          'result': '', 'structured_output': review['output'], 'total_cost_usd': 1.25,
          'usage': {'input_tokens': usage['input'] - usage['cached'], 'cache_creation_input_tokens': 0,
                    'cache_read_input_tokens': usage['cached'], 'output_tokens': usage['output']}})
else:
    sys.exit(f'fixture: unknown tool {tool}')

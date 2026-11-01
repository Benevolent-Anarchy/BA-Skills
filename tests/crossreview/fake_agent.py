"""Stands in for gh, codex, claude and git-lfs in the cross-review tests.

The first argument names the tool being faked. Every call is logged to calls.jsonl in the directory
BA_CROSSREVIEW_FAKE names, with its arguments, working directory and standard input. pr.json is what
`gh pr view` prints; each reviewer call takes the next entry of reviews.json. lfs-files.txt is what
`git lfs ls-files` prints.
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
                          'claudecode': os.environ.get('CLAUDECODE')}) + '\n')


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
    else:
        sys.exit(f'fixture: unexpected gh arguments {args!r}')
    sys.exit(0)

if tool == 'git-lfs':
    if args[:1] == ['ls-files']:
        path = fixture / 'lfs-files.txt'
        print(path.read_text(encoding='utf-8') if path.exists() else '', end='')
    sys.exit(0)

review = next_review()
if review.get('prHead'):
    # The pull request moves on while the reviewer reads.
    pr = json.loads((fixture / 'pr.json').read_text(encoding='utf-8'))
    (fixture / 'pr.json').write_text(json.dumps(dict(pr, headRefOid=review['prHead'])), encoding='utf-8')
time.sleep(review.get('sleep', 0))
resuming = (tool == 'codex' and args[1:2] == ['resume']) or (tool == 'claude' and '--resume' in args)
if review.get('exit') or (resuming and review.get('resumeFails')):
    print(review.get('stderr', 'fixture: reviewer failed'), file=sys.stderr)
    sys.exit(review.get('exit') or 1)
if tool == 'codex':
    session = args[2] if resuming else review.get('session', 'codex-thread-1')
    Path(value('-o')).write_text(json.dumps(review['output']), encoding='utf-8')
    print(json.dumps({'type': 'thread.started', 'thread_id': session}))
    print(json.dumps({'type': 'turn.completed'}))
elif tool == 'claude':
    session = value('--resume') if resuming else review.get('session', 'claude-session-1')
    print(json.dumps({'type': 'result', 'subtype': 'success', 'is_error': False, 'session_id': session,
                      'result': json.dumps(review['output']), 'structured_output': review['output']}))
else:
    sys.exit(f'fixture: unknown tool {tool}')

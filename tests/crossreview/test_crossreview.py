"""Behaviour tests for the cross-review script.

Each test builds a local origin and clone whose configured remote names a GitHub repository, rewritten to
the local origin for fetches. Fake gh, codex and claude commands stand in for GitHub and the reviewers,
so no test touches the network or a real agent.
"""
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'skills/ba-crossreview/scripts/crossreview.py'
FAKE = Path(__file__).resolve().parent / 'fake_agent.py'


def finding(title, severity='major', file='widget.py', line=2, id=None, status='open', reply=None, detail='It breaks.'):
    return {'id': id, 'status': status, 'severity': severity, 'file': file, 'line': line, 'title': title,
            'detail': detail, 'reply': reply}


def review(*findings, summary='Reviewed.', **extra):
    return dict({'output': {'summary': summary, 'findings': list(findings)}}, **extra)


class CrossReview(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='ba crossreview ü '))
        self.addCleanup(self.remove)
        self.origin = self.root / 'origin.git'
        self.repo = self.root / 'clone [literal]'
        self.fixture = self.root / 'fixture'
        self.temp = self.root / 'temp'
        bin = self.root / 'bin'
        for path in (self.repo, self.fixture, self.temp, bin):
            path.mkdir()
        for tool in ('gh', 'codex', 'claude'):
            if os.name == 'nt':
                (bin / f'{tool}.cmd').write_text(f'@"{sys.executable}" "{FAKE}" {tool} %*\r\n', encoding='utf-8')
            else:
                wrapper = bin / tool
                wrapper.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{FAKE}" {tool} "$@"\n', encoding='utf-8')
                wrapper.chmod(0o755)
        self.env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull, GH_REPO='wrong/repository',
                        PYTHONDONTWRITEBYTECODE='1', BA_CROSSREVIEW_FAKE=str(self.fixture), CLAUDECODE='1',
                        TMPDIR=str(self.temp), TEMP=str(self.temp), TMP=str(self.temp),
                        PATH=str(bin) + os.pathsep + os.environ.get('PATH', ''))
        subprocess.run(['git', 'init', '-q', '--bare', '-b', 'main', str(self.origin)], env=self.env, check=True)
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'core.autocrlf', 'false')
        (self.repo / 'widget.py').write_text('def add(a, b):\n    return a - b\n', encoding='utf-8')
        self.git('add', '-A')
        self.git('commit', '-qm', 'Base')
        self.base = self.git('rev-parse', 'HEAD')
        self.git('remote', 'add', 'origin', str(self.origin))
        self.git('push', '-q', 'origin', 'main')
        self.git('checkout', '-q', '-b', 'feature')
        (self.repo / 'widget.py').write_text('def add(a, b):\n    return a - b\n\n\ndef widget():\n    return 1\n',
                                             encoding='utf-8')
        self.head = self.commit('Add the widget')
        self.git('config', 'remote.origin.url', 'https://github.com/fixture/repo.git')
        self.git('config', f'url.{self.origin}.insteadOf', 'https://github.com/fixture/repo.git')
        self.pr = {'number': 7, 'title': 'Add the widget', 'body': 'Adds a widget.\n\nCloses #3', 'state': 'OPEN',
                   'isDraft': True, 'headRefOid': self.head, 'headRefName': 'feature', 'baseRefName': 'main',
                   'url': 'https://github.com/fixture/repo/pull/7'}
        self.write_pr()
        self.queue()

    def remove(self):
        def writable(function, path, _):
            os.chmod(path, stat.S_IWRITE)
            function(path)
        # Python 3.12 renamed the error hook; 3.10 and 3.11 only know the old name.
        shutil.rmtree(self.root, **({'onexc': writable} if sys.version_info >= (3, 12) else {'onerror': writable}))

    def git(self, *args, cwd=None):
        result = subprocess.run(['git', '-C', str(cwd or self.repo), *args], env=self.env, capture_output=True,
                                text=True, encoding='utf-8')
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def commit(self, message):
        """Commits the clone's changes on feature and pushes them as the pull request's head."""
        self.git('commit', '-qam', message)
        head = self.git('rev-parse', 'HEAD')
        self.git('push', '-q', '-f', str(self.origin), f'{head}:refs/heads/feature', f'{head}:refs/pull/7/head')
        return head

    def push_fix(self, text='def add(a, b):\n    return a + b\n'):
        (self.repo / 'widget.py').write_text(text, encoding='utf-8')
        self.pr['headRefOid'] = self.commit('Fix it')
        self.write_pr()
        return self.pr['headRefOid']

    def write_pr(self):
        (self.fixture / 'pr.json').write_text(json.dumps(self.pr), encoding='utf-8')

    def queue(self, *reviews):
        (self.fixture / 'reviews.json').write_text(json.dumps(list(reviews)), encoding='utf-8')

    def calls(self, tool=None):
        path = self.fixture / 'calls.jsonl'
        calls = [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines()] if path.exists() else []
        return [call for call in calls if tool in (None, call['tool'])]

    def comments(self):
        path = self.fixture / 'comments.json'
        return json.loads(path.read_text(encoding='utf-8')) if path.exists() else []

    def script(self, command, *args, ok=True):
        result = subprocess.run([sys.executable, '-B', str(SCRIPT), command, '--repository', str(self.repo),
                                 '--pull-request', '7', *args], env=self.env, capture_output=True, text=True,
                                encoding='utf-8')
        output = json.loads(result.stdout)
        if ok:
            self.assertEqual(result.returncode, 0, output)
            self.assertNotIn('error', output)
        else:
            self.assertEqual(result.returncode, 1, output)
            self.assertIn('error', output)
        return output

    def review(self, author='claude', *args, ok=True):
        return self.script('review', '--author', author, *args, ok=ok)

    def reply(self, *replies, ok=True):
        path = self.root / 'replies.json'
        path.write_text(json.dumps([{'id': id, 'action': action, 'note': note} for id, action, note in replies]),
                        encoding='utf-8')
        return self.script('reply', '--replies', str(path), ok=ok)

    def option(self, args, flag):
        return args[args.index(flag) + 1]

    def test_codex_reviews_claudes_pull_request_read_only_at_the_pushed_head(self):
        self.queue(review(finding('No test for widget', 'minor', file=None, line=None, id='X-9'),
                          finding('Subtracts instead of adding', 'blocker', detail='add(2, 3) is -1.\nIt should be 5.'),
                          summary='Two problems.'))
        result = self.review('claude')
        self.assertEqual((result['reviewer'], result['round'], result['turn'], result['head']),
                         ('codex', 1, 'reply', self.head))
        self.assertEqual([(item['id'], item['severity']) for item in result['open']], [('F1', 'blocker'), ('F2', 'minor')])
        call, = self.calls('codex')
        self.assertEqual(call['args'][0], 'exec')
        self.assertNotIn('resume', call['args'])
        self.assertIn('sandbox_mode="read-only"', call['args'])
        self.assertIn('--output-schema', call['args'])
        self.assertIn('--json', call['args'])
        worktree = Path(call['cwd'])
        self.assertFalse(worktree.samefile(self.repo))
        self.assertTrue(str(worktree.resolve()).startswith(str(self.temp.resolve())))
        self.assertEqual(self.git('rev-parse', 'HEAD', cwd=worktree), self.head)
        for text in ('You are Codex', 'pull request #7', 'fixture/repo', '"Add the widget"', 'which Claude wrote',
                     f'git diff {self.base}...{self.head}', 'Closes #3', 'AGENTS.md'):
            self.assertIn(text, call['stdin'])
        comment, = self.comments()
        self.assertEqual(comment['repo'], 'fixture/repo')
        body = comment['body']
        self.assertTrue(body.startswith(f'[Codex] Cross-review of #7, round 1, at {self.head[:7]}\n\nTwo problems.'))
        self.assertIn('- **F1** · blocker · `widget.py:2` · Subtracts instead of adding\n  add(2, 3) is -1.\n  It should be 5.',
                      body)
        self.assertIn('- **F2** · minor · `general` · No test for widget', body)
        self.assertEqual(result['commentUrl'], 'https://github.com/fixture/repo/pull/7#issuecomment-1')

    def test_claude_reviews_codexs_pull_request_with_only_reading_tools(self):
        self.queue(review(finding('Subtracts instead of adding')))
        result = self.review('codex')
        self.assertEqual(result['reviewer'], 'claude')
        call, = self.calls('claude')
        args = call['args']
        self.assertEqual(args[0], '-p')
        self.assertNotIn('--resume', args)
        self.assertEqual(self.option(args, '--permission-mode'), 'dontAsk')
        self.assertEqual(self.option(args, '--tools'), 'Read,Grep,Glob,Bash')
        self.assertEqual(self.option(args, '--output-format'), 'json')
        self.assertEqual(json.loads(self.option(args, '--json-schema'))['required'], ['summary', 'findings'])
        allowed = args[args.index('--allowedTools') + 1:args.index('--disallowedTools')]
        self.assertTrue(allowed and all(tool.startswith('Bash(git ') for tool in allowed))
        self.assertIn('Bash(git push:*)', args[args.index('--disallowedTools') + 1:])
        self.assertIsNone(call['claudecode'])
        self.assertIn('You are Claude', call['stdin'])
        self.assertIn('which Codex wrote', call['stdin'])
        self.assertTrue(self.comments()[0]['body'].startswith('[Claude] Cross-review of #7, round 1'))

    def test_answers_must_cover_exactly_the_open_findings(self):
        self.queue(review(finding('One'), finding('Two', 'minor')))
        self.review()
        cases = [([('F1', 'declined', 'No.')], 'Unanswered: F2'),
                 ([('F1', 'declined', 'No.'), ('F2', 'declined', 'No.'), ('F3', 'declined', 'No.')], 'F3'),
                 ([('F1', 'declined', 'No.'), ('F1', 'declined', 'No.'), ('F2', 'declined', 'No.')], 'repeated: F1'),
                 ([('F1', 'ignored', 'No.'), ('F2', 'declined', 'No.')], 'fixed, declined or escalated'),
                 ([('F1', 'declined', ' '), ('F2', 'declined', 'No.')], 'needs a note')]
        for replies, message in cases:
            self.assertIn(message, self.reply(*replies, ok=False)['error'])
        self.assertEqual(len(self.comments()), 1)
        self.assertEqual(self.script('status')['turn'], 'reply')

    def test_a_fix_must_be_pushed_before_it_is_answered(self):
        self.queue(review(finding('Subtracts instead of adding')))
        self.review()
        self.assertIn('push the fixes first', self.reply(('F1', 'fixed', 'Adds now.'), ok=False)['error'])
        head = self.push_fix()
        result = self.reply(('F1', 'fixed', 'Adds now.\nSee the new test.'))
        self.assertEqual((result['turn'], result['head']), ('review', head))
        body = self.comments()[1]['body']
        self.assertTrue(body.startswith(f'[Claude] Answers to round 1 of the cross-review, at {head[:7]}'))
        self.assertIn('- **F1** · fixed · Subtracts instead of adding — Adds now.\n  See the new test.', body)

    def test_the_next_round_resumes_the_reviewer_in_the_same_checkout_with_the_answers(self):
        self.queue(review(finding('Subtracts instead of adding', 'blocker'), finding('No test', 'minor')))
        first = self.review()
        head = self.push_fix()
        self.reply(('F1', 'fixed', 'Adds now.'), ('F2', 'declined', 'test_widget covers it.'))
        self.queue(review(finding('Subtracts instead of adding', 'blocker', id='F1', status='resolved', reply='Fixed.'),
                          finding('No test', 'minor', id='F2', reply="test_widget doesn't call add."),
                          finding('The fix broke negatives', 'major')))
        result = self.review()
        self.assertEqual((result['round'], result['resumed'], result['session'], result['turn']),
                         (2, True, 'codex-thread-1', 'reply'))
        self.assertEqual([(item['id'], item['new']) for item in result['open']], [('F3', True), ('F2', False)])
        self.assertEqual(result['resolved'], ['F1'])
        first_call, call = self.calls('codex')
        self.assertEqual(call['args'][1:3], ['resume', 'codex-thread-1'])
        self.assertIn('sandbox_mode="read-only"', call['args'])
        self.assertEqual(Path(call['cwd']), Path(first_call['cwd']))
        self.assertEqual(self.git('rev-parse', 'HEAD', cwd=Path(call['cwd'])), head)
        for text in ('round 2', f'from {self.head} to {head}', 'F1 (blocker, widget.py:2)', 'Claude fixed it: Adds now.',
                     'Claude declined it: test_widget covers it.'):
            self.assertIn(text, call['stdin'])
        self.assertNotIn('You are Codex', call['stdin'])
        body = self.comments()[2]['body']
        self.assertIn('- **F3** · major · `widget.py:2` · The fix broke negatives *(new)*', body)
        self.assertIn("  > test_widget doesn't call add.", body)
        self.assertIn("doesn't call add.\n\n**Resolved**\n- **F1** · Subtracts instead of adding\n  > Fixed.", body)
        self.assertEqual(first['session'], 'codex-thread-1')

    def test_the_claude_reviewer_resumes_its_own_session(self):
        self.queue(review(finding('One')))
        self.review('codex')
        self.reply(('F1', 'declined', 'Not a bug.'))
        self.queue(review(finding('One', id='F1', status='resolved')))
        result = self.review('codex')
        self.assertEqual((result['resumed'], result['turn']), (True, 'done'))
        self.assertEqual(self.option(self.calls('claude')[1]['args'], '--resume'), 'claude-session-1')
        self.assertTrue(self.comments()[2]['body'].endswith('**Resolved**\n- **F1** · One\n\nNothing is open.\n'))

    def test_a_session_that_cannot_be_resumed_starts_again_with_the_history(self):
        self.queue(review(finding('One')))
        self.review()
        self.reply(('F1', 'declined', 'Not a bug.'))
        self.queue({'resumeFails': True, 'stderr': 'no such thread'},
                   review(finding('One', id='F1', status='resolved'), session='codex-thread-2'))
        result = self.review()
        self.assertEqual((result['resumed'], result['session']), (False, 'codex-thread-2'))
        resumed, fresh = self.calls('codex')[1:]
        self.assertEqual(resumed['args'][1], 'resume')
        self.assertNotIn('resume', fresh['args'])
        for text in ('You are Codex', 'can no longer be resumed', 'Claude declined it: Not a bug.'):
            self.assertIn(text, fresh['stdin'])
        self.assertEqual(self.script('status')['turn'], 'done')

    def test_the_turns_are_kept_in_order(self):
        self.assertIn('turn to review', self.reply(('F1', 'declined', 'No.'), ok=False)['error'])
        self.queue(review(finding('One')))
        self.review()
        self.assertIn('answer them with `reply` first', self.review(ok=False)['error'])
        self.assertEqual(len(self.calls('codex')), 1)

    def test_a_clean_review_ends_it_and_finish_removes_the_checkout(self):
        self.queue(review(summary='The change holds up.'))
        result = self.review()
        self.assertEqual((result['open'], result['turn']), ([], 'done'))
        self.assertIn('The change holds up.\n\nNothing is open.', self.comments()[0]['body'])
        self.assertIn('done', self.review(ok=False)['error'])
        worktree = Path(self.calls('codex')[0]['cwd'])
        finished = self.script('finish')
        self.assertTrue(finished['removed'])
        self.assertFalse(worktree.exists())
        self.assertNotIn(worktree.name, self.git('worktree', 'list'))
        self.assertEqual(self.script('status')['turn'], 'done')

    def test_escalated_findings_go_to_cicely_and_leave_the_loop(self):
        self.queue(review(finding('Should this be a plugin?'), finding('One', 'minor')))
        self.review()
        result = self.reply(('F1', 'escalated', 'Cicely decides the architecture.'), ('F2', 'declined', 'Not a bug.'))
        self.assertEqual((result['escalated'], result['turn']), (['F1'], 'review'))
        self.queue(review(finding('Should this be a plugin?', id='F1'), finding('One', 'minor', id='F2', status='resolved')))
        result = self.review()
        self.assertEqual((result['open'], result['resolved'], result['escalated'], result['turn']),
                         ([], ['F2'], ['F1'], 'done'))
        prompt = self.calls('codex')[1]['stdin']
        self.assertIn('taken these to Cicely, so leave them out:\n- F1: Should this be a plugin?', prompt)
        self.assertNotIn('Claude escalated it', prompt)
        status = self.script('status')
        self.assertEqual(status['escalated'][0]['note'], 'Cicely decides the architecture.')

    def test_escalating_everything_ends_the_loop(self):
        self.queue(review(finding('Should this be a plugin?')))
        self.review()
        self.assertEqual(self.reply(('F1', 'escalated', 'For Cicely.'))['turn'], 'done')
        self.assertIn('for Cicely', self.comments()[1]['body'])

    def test_findings_the_reviewer_leaves_out_stay_open(self):
        self.queue(review(finding('One'), finding('Two')))
        self.review()
        self.push_fix()
        self.reply(('F1', 'fixed', 'Done.'), ('F2', 'fixed', 'Done.'))
        self.queue(review(finding('One', id='F1', status='resolved')))
        result = self.review()
        self.assertEqual(result['unlisted'], ['F2'])
        self.assertEqual([item['id'] for item in result['open']], ['F2'])
        self.assertIn("didn't re-list", result['open'][0]['reply'])

    def test_reviews_stop_at_the_round_limit_unless_it_is_raised(self):
        self.queue(review(finding('One')))
        self.review('claude', '--max-rounds', '1')
        self.assertEqual(self.reply(('F1', 'declined', 'Not a bug.'))['turn'], 'limit')
        self.assertIn('All 1 rounds are used', self.review(ok=False)['error'])
        self.queue(review(finding('One', id='F1', status='resolved')))
        self.assertEqual(self.review('claude', '--max-rounds', '2')['round'], 2)

    def test_a_head_that_moved_is_refused(self):
        self.pr['headRefOid'] = self.base
        self.write_pr()
        self.assertIn('head moved', self.review(ok=False)['error'])
        self.assertEqual((self.calls('codex'), self.comments()), ([], []))

    def test_a_closed_pull_request_is_refused(self):
        self.pr['state'] = 'MERGED'
        self.write_pr()
        self.assertIn('is merged, not open', self.review(ok=False)['error'])

    def test_a_failed_review_posts_and_records_nothing(self):
        self.queue({'exit': 3, 'stderr': 'model overloaded'})
        error = self.review(ok=False)['error']
        self.assertIn('Codex failed (exit 3)', error)
        self.assertIn('model overloaded', error)
        self.assertEqual(self.comments(), [])
        self.assertEqual(self.script('status')['rounds'], 0)
        self.queue(review(finding('One')))
        self.assertEqual(self.review()['round'], 1)

    def test_a_review_that_cannot_be_posted_is_not_recorded(self):
        (self.fixture / 'comment-fails').write_text('', encoding='utf-8')
        self.queue(review(finding('One')))
        self.assertIn('commenting refused', self.review(ok=False)['error'])
        self.assertEqual(self.script('status')['rounds'], 0)

    def test_a_reviewer_that_runs_too_long_is_stopped(self):
        self.queue(review(finding('One'), sleep=60))
        started = time.monotonic()
        error = self.review('claude', '--timeout-minutes', '0.02', ok=False)['error']
        self.assertIn('did not finish within 0.02 minutes', error)
        self.assertLess(time.monotonic() - started, 30)
        self.assertEqual(self.comments(), [])

    def test_only_github_remotes_are_accepted_and_their_urls_never_echoed(self):
        self.git('config', 'remote.origin.url', 'https://token@gitlab.example/fixture/repo.git')
        error = self.review(ok=False)['error']
        self.assertIn('not a github.com repository', error)
        self.assertNotIn('token', error)

    def test_the_author_stays_the_same_agent(self):
        self.queue(review(finding('One')))
        self.review('claude')
        self.assertIn('Claude as the author', self.review('codex', ok=False)['error'])


if __name__ == '__main__':
    unittest.main()

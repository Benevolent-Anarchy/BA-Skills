"""Behaviour tests for the cross-review script.

Each test builds a local origin and clone whose configured remote names a GitHub repository, rewritten to
the local origin for fetches. Fake gh, codex and claude commands stand in for GitHub and the reviewers,
so no test touches the network or a real agent.
"""
import fcntl
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


def finding(title, severity='major', file='widget.py', line=2, id=None, status='open', reply=None, detail='It breaks.',
            **extra):
    return dict({'id': id, 'status': status, 'severity': severity, 'file': file, 'line': line, 'title': title,
                 'detail': detail, 'stakes': None, 'options': None, 'recommendation': None, 'reply': reply}, **extra)


def question(title, detail='Only Cicely knows who calls it.'):
    return finding(title, status='question', detail=detail, stakes='Callers outside the project break if it changes.',
                   options=[{'choice': 'Keep it public', 'implies': 'Its signature is frozen.'},
                            {'choice': 'Make it private', 'implies': 'Outside callers must move.'}],
                   recommendation='Keep it public: callers exist.')


def escalation(id, note):
    return {'id': id, 'action': 'escalated', 'note': note, 'stakes': 'A plugin is hard to undo once published.',
            'options': [{'choice': 'Module', 'implies': 'Ships now; a plugin can come later.'},
                        {'choice': 'Plugin', 'implies': 'A week of packaging first.'}],
            'recommendation': 'Module, for now.'}


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
        self.codex_home = self.root / 'codex home'
        bin = self.root / 'bin'
        for path in (self.repo, self.fixture, self.temp, self.codex_home, bin):
            path.mkdir()
        self.bin = bin
        # git-lfs is faked too, so no test reaches a real one; it counts as installed only where a test says so.
        for tool in ('gh', 'codex', 'claude', 'git-lfs'):
            self.fake(tool)
        self.env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull, GH_REPO='wrong/repository',
                        PYTHONDONTWRITEBYTECODE='1', BA_CROSSREVIEW_FAKE=str(self.fixture), CLAUDECODE='1',
                        TMPDIR=str(self.temp), TEMP=str(self.temp), TMP=str(self.temp), CODEX_HOME=str(self.codex_home),
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

    def fake(self, tool):
        wrapper = self.bin / tool
        wrapper.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{FAKE}" {tool} "$@"\n', encoding='utf-8')
        wrapper.chmod(0o755)

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

    def posts(self):
        """The reviews, answers and decisions, without the status comment."""
        return [comment for comment in self.comments() if 'Cross-review status for #7' not in comment['body'][:60]]

    def status_comment(self):
        status, = [comment for comment in self.comments()
                   if 'Cross-review status for #7' in comment['body'][:60] and not comment.get('deleted')]
        return status

    def wait_for(self, check, seconds=20):
        deadline = time.monotonic() + seconds
        while not check():
            self.assertLess(time.monotonic(), deadline, 'timed out waiting')
            time.sleep(0.1)

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
        """Answers with (id, action, note) tuples, or dicts such as `escalation` makes."""
        path = self.root / 'replies.json'
        path.write_text(json.dumps([reply if isinstance(reply, dict) else dict(zip(('id', 'action', 'note'), reply))
                                    for reply in replies]), encoding='utf-8')
        return self.script('reply', '--replies', str(path), ok=ok)

    def decide(self, *decisions, ok=True):
        """Records (id, decision) or (id, decision, choice) tuples."""
        path = self.root / 'decisions.json'
        path.write_text(json.dumps([dict(zip(('id', 'decision', 'choice'), decision)) for decision in decisions]),
                        encoding='utf-8')
        return self.script('decide', '--decisions', str(path), ok=ok)

    def option(self, args, flag):
        return args[args.index(flag) + 1]

    def ledger(self):
        return self.repo / '.git/ba-crossreview'

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
        self.assertIn('--ignore-user-config', call['args'])
        self.assertIn('--ignore-rules', call['args'])
        self.assertFalse([arg for arg in call['args'] if arg.startswith('model')])
        self.assertIn('--output-schema', call['args'])
        self.assertIn('--json', call['args'])
        worktree = Path(call['cwd'])
        self.assertFalse(worktree.samefile(self.repo))
        self.assertTrue(str(worktree.resolve()).startswith(str(self.temp.resolve())))
        self.assertEqual(self.git('rev-parse', 'HEAD', cwd=worktree), self.head)
        change = worktree.with_name(worktree.name + '.change')
        self.assertIn('+def widget():', (change / 'change.diff').read_text(encoding='utf-8'))
        self.assertIn('Add the widget', (change / 'commits.txt').read_text(encoding='utf-8'))
        for text in ('You are Codex', 'pull request #7', 'fixture/repo', '"Add the widget"', 'which Claude wrote',
                     f'git diff {self.base}...{self.head}', str(change / 'change.diff'), str(change / 'commits.txt'),
                     'Closes #3', 'AGENTS.md', 'commands that only read', 'status` "question"'):
            self.assertIn(text, call['stdin'])
        comment, = self.posts()
        self.assertEqual(comment['repo'], 'fixture/repo')
        body = comment['body']
        self.assertTrue(body.startswith(f'[Codex] Cross-review of #7, round 1, at {self.head[:7]}\n\nTwo problems.'))
        self.assertIn('- **F1** · blocker · `widget.py:2` · Subtracts instead of adding\n  add(2, 3) is -1.\n  It should be 5.',
                      body)
        self.assertIn('- **F2** · minor · `general` · No test for widget', body)
        self.assertEqual(result['commentUrl'], 'https://github.com/fixture/repo/pull/7#issuecomment-2')

    def test_claude_reviews_codexs_pull_request_with_only_reading_tools(self):
        self.queue(review(finding('Subtracts instead of adding')))
        result = self.review('codex')
        self.assertEqual(result['reviewer'], 'claude')
        call, = self.calls('claude')
        args = call['args']
        self.assertEqual(args[0], '-p')
        self.assertNotIn('--resume', args)
        self.assertEqual(self.option(args, '--permission-mode'), 'dontAsk')
        self.assertEqual(self.option(args, '--tools'), 'Read,Grep,Glob')
        self.assertIn('--restricted', args)
        self.assertIn('--strict-mcp-config', args)
        self.assertFalse([arg for arg in args if 'Bash' in arg or arg.startswith('--allowed')])
        self.assertEqual(self.option(args, '--output-format'), 'stream-json')
        self.assertIn('--verbose', args)
        self.assertEqual(json.loads(self.option(args, '--json-schema'))['required'], ['summary', 'findings'])
        change = Path(self.option(args, '--add-dir'))
        self.assertEqual(change.name, Path(call['cwd']).name + '.change')
        self.assertIn('+def widget():', (change / 'change.diff').read_text(encoding='utf-8'))
        self.assertIsNone(call['claudecode'])
        for text in ('You are Claude', 'which Codex wrote', str(change / 'change.diff'), 'only the Read, Grep and Glob'):
            self.assertIn(text, call['stdin'])
        self.assertTrue(self.posts()[0]['body'].startswith('[Claude] Cross-review of #7, round 1'))

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
        self.assertEqual(len(self.posts()), 1)
        self.assertEqual(self.script('status')['turn'], 'reply')

    def test_a_fix_must_be_pushed_before_it_is_answered(self):
        self.queue(review(finding('Subtracts instead of adding')))
        self.review()
        self.assertIn('push the fixes first', self.reply(('F1', 'fixed', 'Adds now.'), ok=False)['error'])
        head = self.push_fix()
        result = self.reply(('F1', 'fixed', 'Adds now.\nSee the new test.'))
        self.assertEqual((result['turn'], result['head']), ('review', head))
        body = self.posts()[1]['body']
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
        change = Path(call['cwd']).with_name(Path(call['cwd']).name + '.change')
        self.assertIn('+    return a + b', (change / 'since.diff').read_text(encoding='utf-8'))
        self.assertIn('Fix it', (change / 'since.txt').read_text(encoding='utf-8'))
        for text in ('round 2', f'from {self.head} to {head}', 'F1 (blocker, widget.py:2)', 'Claude fixed it: Adds now.',
                     'Claude declined it: test_widget covers it.', str(change / 'since.diff')):
            self.assertIn(text, call['stdin'])
        self.assertNotIn('You are Codex', call['stdin'])
        body = self.posts()[2]['body']
        self.assertIn('- **F3** · major · `widget.py:2` · The fix broke negatives *(new)*', body)
        self.assertIn("  > test_widget doesn't call add.", body)
        self.assertIn("doesn't call add.\n\n**Resolved**\n- **F1** · Subtracts instead of adding\n  It breaks.\n  > Fixed.",
                      body)
        self.assertEqual(first['session'], 'codex-thread-1')

    def test_the_claude_reviewer_resumes_its_own_session(self):
        self.queue(review(finding('One')))
        self.review('codex')
        self.reply(('F1', 'declined', 'Not a bug.'))
        self.queue(review(finding('One', id='F1', status='resolved')))
        result = self.review('codex')
        self.assertEqual((result['resumed'], result['turn']), (True, 'done'))
        self.assertEqual(self.option(self.calls('claude')[1]['args'], '--resume'), 'claude-session-1')
        self.assertTrue(self.posts()[2]['body'].endswith('**Resolved**\n- **F1** · One\n  It breaks.\n\nNothing is open.\n'))

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
        self.assertIn('The change holds up.\n\nNothing is open.', self.posts()[0]['body'])
        self.assertIn('done', self.review(ok=False)['error'])
        worktree = Path(self.calls('codex')[0]['cwd'])
        finished = self.script('finish')
        self.assertTrue(finished['removed'])
        self.assertFalse(worktree.exists())
        self.assertFalse(worktree.with_name(worktree.name + '.change').exists())
        self.assertNotIn(worktree.name, self.git('worktree', 'list'))
        self.assertEqual(self.script('status')['turn'], 'done')

    def test_an_escalated_finding_pauses_for_cicely_and_her_decision_goes_to_the_reviewer(self):
        self.queue(review(finding('Should this be a plugin?'), finding('One', 'minor')))
        self.review()
        self.assertIn('Escalation F1 needs `stakes`',
                      self.reply(('F1', 'escalated', 'For Cicely.'), ('F2', 'declined', 'No.'), ok=False)['error'])
        result = self.reply(escalation('F1', 'Cicely decides the architecture.'), ('F2', 'declined', 'Not a bug.'))
        self.assertEqual((result['pending'], result['turn']), (['F1'], 'cicely'))
        answers = self.posts()[1]['body']
        self.assertIn('for Cicely', answers)
        self.assertIn('**Why it matters:** A plugin is hard to undo once published.', answers)
        self.assertIn('1. **Module:** Ships now; a plugin can come later.', answers)
        briefing = result['briefing']
        for text in ('Cross-review of #7: paused for your decision', '#### F1 · Should this be a plugin?',
                     'Codex raised this major finding at `widget.py:2` in round 1, and Claude took it to you.',
                     "**Claude's question:** Cicely decides the architecture.", '2. **Plugin:** A week of packaging first.',
                     '**Claude recommends:** Module, for now.', 'under `[Cee, via the skill]`'):
            self.assertIn(text, briefing)
        self.assertIn(briefing, self.status_comment()['body'])
        self.assertIn('Cicely has to decide F1 first', self.review(ok=False)['error'])
        self.assertEqual(len(self.calls('codex')), 1)
        self.assertIn('Undecided: F1', self.decide(ok=False)['error'])
        self.assertIn('Not waiting or repeated: F2', self.decide(('F1', 'Leave it.'), ('F2', 'No.'), ok=False)['error'])
        self.assertIn("needs Cicely's answer", self.decide(('F1', ' '), ok=False)['error'])
        result = self.decide(('F1', 'Keep it a module for now.\nI will plan plugins later.'))
        self.assertEqual(result['turn'], 'review')
        record = self.posts()[2]['body']
        self.assertTrue(record.startswith('[Cee, via the skill] Decisions on the cross-review of #7, after round 1\n\n'
                                          'Claude paused the cross-review to ask her.'))
        self.assertIn("**Claude's question:** Cicely decides the architecture.", record)
        self.assertIn('1. **Module:** Ships now', record)
        self.assertTrue(record.endswith('**Her answer:**\n> Keep it a module for now.\n> I will plan plugins later.\n'))
        self.assertIn('Codex reviews round 2 next', self.status_comment()['body'])
        self.queue(review(finding('Should this be a plugin?', id='F1', status='resolved'),
                          finding('One', 'minor', id='F2', status='resolved')))
        result = self.review()
        self.assertEqual((result['open'], result['resolved'], result['turn']), ([], ['F1', 'F2'], 'done'))
        prompt = self.calls('codex')[1]['stdin']
        for text in ('Claude took it to Cicely: Cicely decides the architecture.',
                     'Cicely decided: Keep it a module for now.', 'Claude declined it: Not a bug.', 'her decisions settle'):
            self.assertIn(text, prompt)
        status = self.script('status')
        self.assertEqual((status['pending'], status['escalated'][0]['note']), ([], 'Cicely decides the architecture.'))
        self.assertEqual(status['decisions'][0]['decisions'][0]['id'], 'F1')
        self.assertEqual(len(status['comments']), 4)

    def test_escalating_everything_still_pauses_for_cicely(self):
        self.queue(review(finding('Should this be a plugin?')))
        self.review()
        self.assertEqual(self.reply(escalation('F1', 'For Cicely.'))['turn'], 'cicely')
        self.assertEqual(self.script('status')['turn'], 'cicely')
        self.assertEqual(self.decide(('F1', 'Leave it.'))['turn'], 'review')

    def test_a_question_from_the_reviewer_pauses_for_cicely_before_the_author_answers(self):
        self.queue(review(finding('One', 'minor'), question('Is the widget meant to be public?')))
        result = self.review()
        self.assertEqual(result['turn'], 'cicely')
        self.assertEqual([(item['id'], item['status']) for item in result['questions']], [('F1', 'question')])
        self.assertEqual([item['id'] for item in result['open']], ['F2'])
        self.assertIn('**For Cicely to decide**\n- **F1** · `widget.py:2` · Is the widget meant to be public?\n'
                      '  Only Cicely knows who calls it.\n\n  **Why it matters:** Callers outside the project break',
                      self.posts()[0]['body'])
        self.assertIn('  1. **Keep it public:** Its signature is frozen.', self.posts()[0]['body'])
        for text in ('Codex asks you this about `widget.py:2`, in round 1.', '**Why it matters:** Callers outside',
                     '2. **Make it private:** Outside callers must move.', '**Codex recommends:** Keep it public',
                     '- Asked of you: F1', '- Open, for Claude to answer: F2'):
            self.assertIn(text, result['briefing'])
        self.assertIn('Cicely has to decide F1 first', self.reply(('F2', 'declined', 'No.'), ok=False)['error'])
        result = self.decide(('F1', 'Yes, keep it public.'))
        self.assertIn('Codex asks you this about `widget.py:2`', self.posts()[1]['body'])
        self.assertEqual(result['turn'], 'reply')
        self.assertEqual([(item['id'], item.get('decision')) for item in result['open']],
                         [('F1', 'Yes, keep it public.'), ('F2', None)])
        self.assertIn('Unanswered: F1', self.reply(('F2', 'declined', 'No.'), ok=False)['error'])
        self.reply(('F1', 'declined', 'Cicely wants it public, so nothing changes.'), ('F2', 'declined', 'No.'))
        self.queue(review(finding('Is the widget meant to be public?', id='F1', status='resolved'),
                          finding('One', 'minor', id='F2', status='resolved')))
        self.assertEqual(self.review()['turn'], 'done')
        prompt = self.calls('codex')[1]['stdin']
        self.assertIn('Cicely decided: Yes, keep it public.\n  Claude declined it: Cicely wants it public', prompt)

    def test_decide_is_refused_when_nothing_waits_for_cicely(self):
        self.queue(review(finding('One')))
        self.review()
        self.assertIn('Nothing is waiting for Cicely', self.decide(('F1', 'Fine.'), ok=False)['error'])

    def test_answers_to_only_minor_findings_ask_cicely_before_another_round(self):
        self.queue(review(finding('No test', 'minor'), finding('Odd name', 'nit')))
        self.review()
        self.push_fix()
        result = self.reply(('F1', 'fixed', 'Added one.'), ('F2', 'declined', "The name is the project's."))
        self.assertEqual((result['turn'], result['pending'], result['changedLines']), ('cicely', ['next-round'], 6))
        self.assertIn('these answers change 6 lines, so the cross-review pauses for Cicely', self.posts()[1]['body'])
        for text in ('#### Another round after round 1?', 'F1 (minor, fixed), F2 (nit, declined)',
                     "Claude's answers changed 6 lines", 'changed fewer than 200 lines',
                     'round 1 took 0 min and about 1.2M tokens (900k cached).',
                     '1. **Another round** (round 2 of 3): Codex checks the answers to F1, F2 and the 6 changed lines',
                     "2. **Stop here:** The cross-review ends at", "Codex won't check the fixes to F1.",
                     'The declines of F2 stand.'):
            self.assertIn(text, result['briefing'])
        self.assertIn('Cicely has to decide next-round first', self.review(ok=False)['error'])
        self.assertIn('needs `choice`', self.decide(('next-round', 'Enough.'), ok=False)['error'])
        self.assertIn('needs `choice`', self.decide(('next-round', 'Enough.', 'maybe'), ok=False)['error'])
        result = self.decide(('next-round', "That's enough, stop here.", 'stop'))
        self.assertEqual(result['turn'], 'stopped')
        record = self.posts()[2]['body']
        self.assertIn('#### Another round after round 1?', record)
        self.assertIn("**Her answer:**\n> That's enough, stop here.\n\n**So:** the cross-review stops here.", record)
        self.assertIn("Codex didn't check Claude's last answers: F1 (fixed), F2 (declined)", result['briefing'])
        self.assertIn('stopped by you after round 1', self.status_comment()['body'])
        self.assertIn('Cicely stopped the cross-review after round 1', self.review(ok=False)['error'])
        self.assertEqual((len(self.calls('codex')), self.script('status')['turn']), (1, 'stopped'))
        self.push_fix('def add(a, b):\n    return b + a\n')
        self.queue(review(summary='Fine.'))
        self.assertEqual(self.review()['round'], 2)

    def test_cicely_can_have_another_round_after_minor_findings(self):
        self.queue(review(finding('No test', 'minor')))
        self.review()
        self.reply(('F1', 'declined', 'test_widget covers it.'))
        result = self.decide(('next-round', 'Do one more.', 'review'))
        self.assertEqual(result['turn'], 'review')
        self.assertIn('**So:** another round.', self.posts()[2]['body'])
        self.queue(review(finding('No test', 'minor', id='F1', status='resolved')))
        self.assertEqual(self.review()['turn'], 'done')
        prompt = self.calls('codex')[1]['stdin']
        self.assertIn('Claude declined it: test_widget covers it.', prompt)
        self.assertIn('settled unless the reason is wrong on the facts', prompt)

    def test_large_answers_go_straight_to_another_round(self):
        self.queue(review(finding('No test', 'minor')))
        self.review()
        self.push_fix('def add(a, b):\n    return a + b\n' + ''.join(f'\n\ndef helper{n}():\n    return {n}\n'
                                                                  for n in range(60)))
        result = self.reply(('F1', 'fixed', 'Added tests, and much more.'))
        self.assertEqual((result['turn'], result['pending']), ('review', []))
        self.assertGreaterEqual(result['changedLines'], 200)

    def test_the_status_comment_and_status_show_the_reviewer_at_work(self):
        self.queue(review(finding('One'), sleep=3))
        process = subprocess.Popen([sys.executable, '-B', str(SCRIPT), 'review', '--repository', str(self.repo),
                                    '--pull-request', '7', '--author', 'codex'], env=self.env, stdout=subprocess.PIPE,
                                   text=True, encoding='utf-8')
        try:
            self.wait_for(lambda: (self.script('status').get('running') or {}).get('latest'))
            status = self.script('status')
            self.assertEqual((status['running']['round'], status['running']['head'], status['running']['latest']),
                             (1, self.head, 'read `widget.py`'))
            self.assertIn('### Cross-review of #7: Claude is reviewing round 1', status['briefing'])
            self.assertIn('**Now:** Claude has been reviewing', status['briefing'])
            self.wait_for(lambda: 'Latest: read `widget.py`.' in self.status_comment()['body'])
            self.assertTrue(self.status_comment()['body'].startswith('[Codex] Cross-review status for #7\n'))
        finally:
            output, _ = process.communicate(timeout=60)
        result = json.loads(output)
        self.assertEqual(result['usage'], {'input': 1200000, 'cached': 900000, 'output': 30000, 'cost': 1.25})
        self.assertEqual(result['statusComment'], 'https://github.com/fixture/repo/pull/7#issuecomment-1')
        self.assertIsNone(self.script('status')['running'])
        body = self.status_comment()['body']
        for text in ('waiting for Codex to answer round 1', '**Next:** Codex answers F1.',
                     'about 1.2M tokens (900k cached, $1.25)', '- Open, for Codex to answer: F1'):
            self.assertIn(text, body)
        self.assertEqual(len(self.comments()), 2)

    def test_a_deleted_status_comment_is_posted_again(self):
        self.queue(review(finding('One')))
        self.review()
        comments = self.comments()
        comments[0]['deleted'] = True
        (self.fixture / 'comments.json').write_text(json.dumps(comments), encoding='utf-8')
        self.reply(('F1', 'declined', 'Not a bug.'))
        self.assertIn('Codex reviews round 2 next', self.status_comment()['body'])
        self.assertEqual(self.script('status')['statusComment'], 'https://github.com/fixture/repo/pull/7#issuecomment-4')

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
        self.queue(review(finding('One', 'minor', detail='It breaks on Sundays.')))
        self.review('claude', '--max-rounds', '1')
        result = self.reply(('F1', 'declined', 'Not a bug.'))
        self.assertEqual(result['turn'], 'limit')
        for text in ('stopped at the limit of 1 rounds', '### All 1 rounds are used',
                     "Codex hasn't checked Claude's answers to round 1:", '- **F1** · minor · One',
                     '  - Codex: It breaks on Sundays.', '  - Claude declined it: Not a bug.',
                     '1. **One more round** (`--max-rounds 2`)', '2. **Stop here:**'):
            self.assertIn(text, result['briefing'])
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
        self.assertEqual(self.posts(), [])
        self.assertIn('**Round 1 failed** at ', self.status_comment()['body'])
        self.assertIn('model overloaded', self.status_comment()['body'])
        self.assertEqual(self.script('status')['rounds'], 0)
        self.queue(review(finding('One')))
        self.assertEqual(self.review()['round'], 1)
        self.assertNotIn('failed', self.status_comment()['body'])

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
        self.assertEqual(self.posts(), [])

    def test_only_github_remotes_are_accepted_and_their_urls_never_echoed(self):
        self.git('config', 'remote.origin.url', 'https://token@gitlab.example/fixture/repo.git')
        error = self.review(ok=False)['error']
        self.assertIn('not a github.com repository', error)
        self.assertNotIn('token', error)

    def test_the_author_stays_the_same_agent(self):
        self.queue(review(finding('One')))
        self.review('claude')
        self.assertIn('Claude as the author', self.review('codex', ok=False)['error'])

    def test_new_commits_after_a_clean_review_are_reviewed_as_another_round(self):
        self.queue(review(summary='Fine.'))
        self.assertEqual(self.review()['turn'], 'done')
        self.assertIn('the cross-review is done', self.review(ok=False)['error'])
        head = self.push_fix()
        self.assertEqual(self.script('status')['head'], self.head)
        self.queue(review(summary='Still fine.'))
        result = self.review()
        self.assertEqual((result['round'], result['head'], result['turn']), (2, head, 'done'))
        prompt = self.calls('codex')[1]['stdin']
        self.assertIn('(None: nothing was open after your last review.)', prompt)
        self.assertIn(f'from {self.head} to {head}', prompt)

    def test_a_head_that_moves_while_the_reviewer_reads_is_due_another_review(self):
        self.queue(review(summary='Fine.', prHead='b' * 40))
        self.assertEqual(self.review()['turn'], 'review')

    def test_a_second_command_is_refused_while_one_runs(self):
        self.ledger().mkdir(parents=True)
        with open(self.ledger() / 'fixture-repo-7.lock', 'a+b') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.queue(review(finding('One')))
            self.assertIn('Another cross-review command is running', self.review(ok=False)['error'])
            self.assertIn('Another cross-review command is running', self.script('finish', ok=False)['error'])
        self.assertEqual((self.calls('codex'), self.comments()), ([], []))
        self.assertEqual(self.review()['round'], 1)

    @unittest.skipIf(os.geteuid() == 0, 'root can write to a read-only folder')
    def test_a_record_that_cannot_be_written_stops_the_command_before_it_posts(self):
        self.queue(review(finding('One')))
        self.review()
        self.ledger().chmod(0o555)
        try:
            self.assertIn('Could not write the record', self.reply(('F1', 'declined', 'No.'), ok=False)['error'])
        finally:
            self.ledger().chmod(0o755)
        self.assertEqual(len(self.posts()), 1)
        self.assertEqual(self.script('status')['turn'], 'reply')

    def test_git_lfs_objects_are_pulled_before_the_reviewer_reads(self):
        (self.fixture / 'lfs-installed').write_text('', encoding='utf-8')
        (self.repo / '.gitattributes').write_text('*.bin filter=lfs diff=lfs merge=lfs -text\n', encoding='utf-8')
        (self.repo / 'asset.bin').write_text('version https://git-lfs.github.com/spec/v1\n', encoding='utf-8')
        self.git('add', '-A')
        self.pr['headRefOid'] = self.commit('Add an asset')
        self.write_pr()
        (self.fixture / 'lfs-files.txt').write_text('0123456789 - asset.bin\n', encoding='utf-8')
        self.queue(review(finding('One')))
        self.assertIn('1 files as pointers, such as asset.bin', self.review(ok=False)['error'])
        self.assertEqual((self.calls('codex'), self.comments()), ([], []))
        (self.fixture / 'lfs-files.txt').write_text('0123456789 * asset.bin\n', encoding='utf-8')
        self.review()
        pull = [call for call in self.calls('git-lfs') if call['args'][:1] == ['pull']][-1]
        self.assertEqual(pull['args'], ['pull', 'origin'])
        self.assertEqual(Path(pull['cwd']), Path(self.calls('codex')[0]['cwd']))

    def test_lfs_files_are_found_without_tracked_attributes(self):
        (self.fixture / 'lfs-installed').write_text('', encoding='utf-8')
        (self.fixture / 'lfs-files.txt').write_text('0123456789 * asset.bin\n', encoding='utf-8')
        self.queue(review(finding('One')))
        self.review()
        self.assertIn(['pull', 'origin'], [call['args'] for call in self.calls('git-lfs')])

    def test_lfs_named_in_info_attributes_needs_git_lfs(self):
        (self.repo / '.git/info').mkdir(exist_ok=True)
        (self.repo / '.git/info/attributes').write_text('*.bin filter=lfs -text\n', encoding='utf-8')
        self.queue(review(finding('One')))
        self.assertIn('Git LFS is not installed', self.review(ok=False)['error'])
        (self.fixture / 'lfs-installed').write_text('', encoding='utf-8')
        self.review()
        self.assertIn(['pull', 'origin'], [call['args'] for call in self.calls('git-lfs')])

    def test_a_project_without_git_lfs_is_never_pulled(self):
        (self.fixture / 'lfs-installed').write_text('', encoding='utf-8')
        self.queue(review(finding('One')))
        self.review()
        self.assertEqual([call['args'][0] for call in self.calls('git-lfs')], ['version', 'ls-files'])

    def test_codex_keeps_the_model_and_effort_its_configuration_names(self):
        for config in ('model = "gpt-test"\nmodel_reasoning_effort = "xhigh"  # deep\n\n[profiles.fast]\nmodel = "other"\n',
                       "model = 'gpt-test'\nmodel_reasoning_effort = 'xhigh'\n[profiles.fast]\nmodel = 'other'\n"):
            with self.subTest(config=config):
                (self.codex_home / 'config.toml').write_text(config, encoding='utf-8')
                self.queue(review(finding('One')))
                self.review()
                args = self.calls('codex')[-1]['args']
                self.assertIn('model="gpt-test"', args)
                self.assertIn('model_reasoning_effort="xhigh"', args)
                self.assertNotIn('model="other"', args)
                self.script('finish')
                (self.repo / '.git/ba-crossreview/fixture-repo-7.json').unlink()

    def test_github_ssh_over_443_is_accepted(self):
        url = 'ssh://git@ssh.github.com:443/fixture/repo.git'
        self.git('config', 'remote.origin.url', url)
        self.git('config', f'url.{self.origin}.insteadOf', url)
        self.queue(review(finding('One')))
        self.review()
        self.assertEqual(self.comments()[0]['repo'], 'fixture/repo')


if __name__ == '__main__':
    unittest.main()

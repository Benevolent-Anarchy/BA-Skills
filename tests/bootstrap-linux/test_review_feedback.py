"""Regressions from the cloud review of PR #62; services stop at fixture boundaries."""
import contextlib
import io
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch

import test_workflows as workflows
b = workflows.b


class CloudReview(unittest.TestCase):
    setUp = workflows.Workflows.setUp

    def cli(self, *arguments):
        output = io.StringIO()
        with patch.object(b, 'Bootstrap', return_value=self.engine), contextlib.redirect_stdout(output):
            code = b.main(list(arguments))
        return code, json.loads(output.getvalue())

    def test_app_managed_plugin_versions_are_retained_without_downloads(self):
        project = Path(self.id['projectPath'])
        b.write_manifest(project, b.foundation(self.id, self.preset))
        self.engine.git(project, 'init', '--initial-branch=main')
        ids = b.read_json(b.ASSETS/'obsidian/plugins.json')
        for version in ('0.6.0-beta.2', '1.2.3.4'):
            with self.subTest(version=version):
                for plugin in ids:
                    active = project/'docs/.obsidian/plugins'/plugin
                    active.mkdir(parents=True, exist_ok=True)
                    b.atomic_json(active/'manifest.json', dict(id=plugin, version=version, minAppVersion='1.0.0'))
                    (active/'main.js').write_text('app-managed bytes')
                with patch.object(self.engine, 'obsidian_request', side_effect=AssertionError('must retain installed plugins')):
                    result = self.engine.install_obsidian(self.id, app_version='1.5.0', app_check=lambda *_: {'verified': True})
                self.assertTrue(result['installedVerified'], result)
                self.assertEqual([p['version'] for p in result['plugins']], [version]*len(ids))
                for plugin in ids:
                    self.assertEqual((project/'docs/.obsidian/plugins'/plugin/'main.js').read_text(), 'app-managed bytes')

    def test_case_variants_share_journal_and_lock_and_cannot_restart(self):
        with patch.object(self.engine, 'prepare', side_effect=RuntimeError('preparation interrupted')):
            self.engine.create(self.id, self.preset)
        path = self.engine.journal_path(self.id)
        before = path.read_bytes()
        for title, owner in (('new project', 'cicely-f'), ('New Project', 'CICELY-F')):
            with self.subTest(title=title, owner=owner):
                other = b.identity(title, self.id['description'], str(self.root), owner)
                self.assertEqual(self.engine.journal_path(other), path)
                self.assertEqual(self.engine.load(other)['invocationId'], self.engine.load(self.id)['invocationId'])
                self.assertEqual(self.engine.plan(other, self.preset)['journalPath'], str(path))
                if title != self.id['title']:
                    self.assertEqual(self.engine.plan(other, self.preset)['status'], 'blocked')
                with b.lock(path), self.assertRaisesRegex(ValueError, 'locked'):
                    with b.lock(self.engine.journal_path(other)):
                        self.fail('case-variant invocation acquired the lock')
                self.assertEqual(path.read_bytes(), before)

    def test_case_variants_find_existing_case_sensitive_journal(self):
        journal = self.engine.new_journal(self.id, self.preset)
        historical = self.engine.root/(b.sha(self.id['fullName'])+'.json')
        b.atomic_json(historical, journal)
        other = b.identity('new project', self.id['description'], str(self.root), 'CICELY-F')
        self.assertEqual(self.engine.journal_path(other), historical)
        self.assertEqual(self.engine.load(other)['invocationId'], journal['invocationId'])
        self.engine.save(journal)
        self.assertEqual(list(self.engine.root.glob('*.json')), [historical])

    def test_local_setup_uses_remote_identity_and_retains_display_title(self):
        project = Path(self.id['projectPath'])
        b.write_manifest(project, b.foundation(self.id, self.preset))
        self.engine.git(project, 'init', '--initial-branch=main')
        self.engine.git(project, 'remote', 'add', 'origin', 'https://github.com/'+self.id['fullName']+'.git')
        self.fixture.repos[self.id['fullName']] = dict(id=2, full_name=self.id['fullName'], private=True)
        for title in ('Foo: a small game', 'Café', 'Foo.', 'My\\_Game'):
            with self.subTest(title=title):
                (project/'README.md').write_text('# '+title+'\n')
                actual = self.engine.local_identity(project/'docs')
                self.assertEqual(actual['title'], title.replace('\\_', '_'))
                for key in ('owner', 'repository', 'fullName', 'projectPath', 'vaultPath'):
                    self.assertEqual(actual[key], self.id[key])

    def test_create_cli_resumes_legacy_foundation_journal(self):
        manifest = b.foundation(self.id, self.preset, legacy=True)
        journal = self.engine.new_journal(self.id, self.preset)
        journal.update(schemaVersion=1, inputHash=b.input_hash(self.id), manifest=b.records(manifest), templateVersion=b.manifest_hash(manifest))
        for key in ('presetSelection', 'recipeVersion', 'resolution', 'preparation', 'verification'):
            journal.pop(key)
        self.engine.save(journal)
        with patch.object(self.engine, 'install_obsidian', return_value=dict(installedVerified=True, enabledVerified=True, pending=[], plugins=[])):
            code, report = self.cli('--mode', 'create', '--name', self.id['title'], '--description', self.id['description'], '--owner', self.id['owner'], '--parent', self.id['parent'])
        self.assertEqual(code, 0, report)
        self.assertEqual(report['status'], 'complete', report)
        self.assertEqual(len(self.fixture.repos), 2)

    def test_interactive_retry_restores_stored_selection_without_preset_prompts(self):
        for name, renderer in (('foundation', None), ('tauri', None), ('godot', 'mobile')):
            with self.subTest(preset=name):
                preset = b.selection(self.id, name, renderer=renderer)
                self.engine.save(self.engine.new_journal(self.id, preset))
                with patch('builtins.input', side_effect=AssertionError('stored options must not be prompted')), patch.object(self.engine, 'prereqs', return_value={'passed': True, 'checks': []}):
                    code, report = self.cli('--mode', 'plan', '--interactive', '--name', self.id['title'], '--description', self.id['description'], '--owner', self.id['owner'], '--parent', self.id['parent'])
                self.assertEqual(code, 0, report)
                self.assertEqual(report['status'], 'ready', report)
                self.assertEqual(self.engine.load(self.id)['presetSelection'], preset)

    def test_empty_xdg_paths_use_home_defaults_independent_of_cwd(self):
        with patch.dict(os.environ, {'XDG_STATE_HOME': '', 'XDG_CONFIG_HOME': ''}):
            os.environ.pop('BA_BOOTSTRAP_STATE_ROOT', None)
            with patch.object(Path, 'home', return_value=self.root):
                self.assertEqual(b.Bootstrap().root, self.root/'.local/state/BA-Skills/ba-bootstrap/state')
                self.assertEqual(b.obsidian_settings(), self.root/'.config/obsidian/obsidian.json')


if __name__ == '__main__':
    unittest.main()

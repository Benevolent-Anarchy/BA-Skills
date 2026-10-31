"""Linux bootstrap contract: real files/Git, with network/app effects replaced at boundaries."""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'skills/ba-bootstrap/scripts/bootstrap.sh'
RUNTIME = SCRIPT.with_name('bootstrap_linux.py')

class Entrypoints(unittest.TestCase):
    def test_native_cli_exists_and_reports_missing_input_as_json(self):
        self.assertTrue(SCRIPT.exists(), 'native bootstrap entry point is missing')
        result = subprocess.run([str(SCRIPT)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)['status'], 'missing-input')
    def test_help_and_invalid_option(self):
        self.assertTrue(SCRIPT.exists(), 'native bootstrap entry point is missing')
        self.assertEqual(subprocess.run([str(SCRIPT), '--help'], capture_output=True).returncode, 0)
        self.assertNotEqual(subprocess.run([str(SCRIPT), '--renderer', 'nonsense'], capture_output=True).returncode, 0)

class RuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not RUNTIME.exists():
            raise AssertionError('native bootstrap runtime is missing')
        spec = importlib.util.spec_from_file_location('bootstrap_linux', RUNTIME)
        cls.b = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.b)
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='BA bootstrap ü space ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.identity = self.b.identity('Foo _ Bar', 'Useful {{PROJECT_TITLE}}', str(self.root), 'cicely-f')
        self.selection = self.b.selection(self.identity, 'foundation')
        self.engine = self.b.Bootstrap(self.root / 'state', request=lambda *args: (404, None))
    def test_identity_preserves_case_and_rejects_reserved_names(self):
        self.assertEqual(self.identity['repository'], 'Foo-_-Bar')
        for name in ['../bad', 'CON', '.git', 'end.', 'a' * 90]:
            with self.assertRaises(ValueError): self.b.identity(name, 'x', str(self.root), 'cicely-f')
    def test_selection_validates_options_and_identifiers(self):
        self.assertEqual(self.b.selection(self.identity, 'godot')['renderer'], 'compatibility')
        self.assertEqual(self.b.selection(self.identity, 'tauri')['appIdentifier'], 'com.cicely-f.foo---bar')
        with self.assertRaises(ValueError): self.b.selection(self.identity, 'foundation', renderer='mobile')
        with self.assertRaises(ValueError): self.b.selection(self.identity, 'tauri', app_identifier='1.invalid')
    def test_empty_explicit_engine_options_are_rejected(self):
        with self.assertRaises(ValueError): self.b.selection(self.identity,'godot',renderer='')
        with self.assertRaises(ValueError): self.b.selection(self.identity,'tauri',app_identifier='')
    def test_manifest_preserves_tokens_and_gate_runs_without_powershell(self):
        manifest = self.b.foundation(self.identity, self.selection)
        self.b.write_manifest(self.root / 'project', manifest)
        readme = (self.root / 'project/README.md').read_text()
        self.assertIn('Useful {{PROJECT_TITLE}}', readme)
        gate = self.root / 'project/tools/verify.sh'
        result = subprocess.run([str(gate)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
    def test_generated_gate_is_offline_without_system_site_packages(self):
        project=self.root/'offline generated project'
        self.b.write_manifest(project,self.b.foundation(self.identity,self.selection))
        result=subprocess.run([os.sys.executable,'-I','-S',str(project/'tools/verify_linux.py'),'--json'],capture_output=True,text=True,cwd=self.root)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertTrue(json.loads(result.stdout)['Passed'])
        self.assertFalse(list(project.rglob('__pycache__')))
    def test_manifest_conflicts_are_atomic_and_symlinks_refused(self):
        project = self.root / 'project'; project.mkdir()
        (project / 'z').write_text('existing')
        manifest = [self.b.entry('a', b'new'), self.b.entry('z', b'changed')]
        with self.assertRaises(ValueError): self.b.write_manifest(project, manifest)
        self.assertFalse((project / 'a').exists())
        (project / 'link').symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ValueError): self.b.write_manifest(project, [self.b.entry('link/x', b'x')])
    def test_frozen_snapshot_detects_changed_bytes_and_missing_receipt(self):
        journal = self.engine.new_journal(self.identity, self.selection)
        source = self.root / 'source'
        self.b.write_manifest(source, self.b.foundation(self.identity, self.selection))
        self.engine.freeze(journal, source, self.b.source_manifest(source))
        frozen, manifest = self.engine.snapshot(journal)
        self.assertEqual(journal['preparation']['phase'], 'frozen')
        (frozen / 'README.md').write_text('changed')
        with self.assertRaises(ValueError): self.engine.snapshot(journal)
    def test_discard_only_before_any_repository_attempt(self):
        journal = self.engine.new_journal(self.identity, self.selection)
        self.engine.save(journal)
        journal['phases']['privateRepository'] = 'creating'; self.engine.save(journal)
        with self.assertRaises(ValueError): self.engine.discard(journal)
        journal['phases'].clear(); self.engine.save(journal)
        self.assertEqual(self.engine.discard(journal)['status'], 'discarded')
        self.assertFalse(self.engine.journal_path(self.identity).exists())
    def test_bad_journal_is_preserved(self):
        path = self.engine.journal_path(self.identity); path.parent.mkdir(parents=True)
        path.write_text('{invalid')
        with self.assertRaises(ValueError): self.engine.load(self.identity)
        self.assertEqual(path.read_text(), '{invalid')
    def test_preparation_failure_never_creates_repositories(self):
        calls = []
        def request(method, endpoint, body=None):
            calls.append(method)
            if endpoint == '/user': return 200, {'login':'cicely-f'}
            if endpoint == '/users/cicely-f': return 200, {'type':'User'}
            return 404, None
        engine = self.b.Bootstrap(self.root / 'state', request=request)
        with patch.object(engine, 'prepare', side_effect=RuntimeError('preparation failed')):
            report = engine.create(self.identity, self.selection)
        self.assertEqual(report['status'], 'partial')
        self.assertNotIn('POST', calls)
    def test_lost_creation_response_quarantines_identity_on_resume(self):
        def request(method, endpoint, body=None):
            if endpoint == '/user': return 200, {'login':'cicely-f'}
            if endpoint == '/users/cicely-f': return 200, {'type':'User'}
            if method == 'POST': return 0, None
            return 404, None
        engine = self.b.Bootstrap(self.root / 'state', request=request)
        report = engine.create(self.identity, self.selection)
        self.assertEqual(report['status'], 'identity-unconfirmed', report)
        journal = engine.load(self.identity)
        self.assertEqual(journal['phases']['privateRepository'], 'creating')
        with patch.object(engine, 'request', wraps=request) as spy:
            report = engine.create(self.identity, self.selection)
        self.assertEqual(report['status'], 'identity-unconfirmed')
        self.assertFalse(any(call.args[0] == 'POST' for call in spy.call_args_list))
    def test_archive_refuses_traversal(self):
        import zipfile
        archive = self.root / 'archive.zip'
        with zipfile.ZipFile(archive, 'w') as z:
            z.writestr('repo/../escape', 'bad')
        with self.assertRaises(ValueError): self.b.expand_archive(archive, self.root / 'out', [])
        self.assertFalse((self.root / 'escape').exists())
    def test_dependencies_choose_latest_stable_and_validate_integrity(self):
        def metadata(url):
            if 'crates.io' in url: return {'versions':[{'num':'3.2.0','yanked':False},{'num':'4.0.0-beta','yanked':False}]}
            return {'versions':{'3.0.0':{'version':'3.0.0','dist':{'tarball':'https://registry.npmjs.org/create-tauri-app/-/create-tauri-app-3.0.0.tgz','integrity':'sha512-'+base64.b64encode(bytes(64)).decode()}}}}
        result = self.b.resolve_dependencies(self.b.selection(self.identity, 'tauri'), metadata)
        self.assertEqual(result['selections']['tauri'], '3.2.0')
        self.assertEqual(result['selections']['generator'], '3.0.0')
    def test_plugin_release_skips_packaging_mismatch_and_verifies_digest(self):
        registry = [{'id':'thing','repo':'owner/thing'}]
        def release(tag): return {'tag_name':tag,'draft':False,'prerelease':False,'assets':[{'name':n,'browser_download_url':f'https://github.com/owner/thing/releases/download/{tag}/{n}'} for n in ['manifest.json','main.js']]}
        def request(method, endpoint, body=None):
            if endpoint.endswith('/latest'): return 200, release('2.0.0')
            if 'releases?' in endpoint: return 200, [release('1.0.0')]
            return 200, {'id':'thing','version':'1.0.0','minAppVersion':'1.0.0'}
        result = self.b.plugin_release('thing', registry, request)
        self.assertEqual(result['version'], '1.0.0')
        self.assertEqual(len(result['skipped']), 1)
    def test_cli_resume_restores_stored_parent_and_rejects_override(self):
        journal = self.engine.new_journal(self.identity, self.selection); self.engine.save(journal)
        env = {**os.environ, 'BA_BOOTSTRAP_STATE_ROOT':str(self.root / 'state')}
        result = subprocess.run([str(SCRIPT),'--mode','discard','--name',self.identity['title'],'--owner','cicely-f','--parent',str(self.root / 'wrong')], env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('parent', json.loads(result.stdout)['conflicts'][0].lower())

if __name__ == '__main__': unittest.main()

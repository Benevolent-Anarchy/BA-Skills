"""Cross-engine journals and the documented Python 3.9 compatibility floor."""
import copy
import datetime as dt
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

import original_protocol
import test_release as release_fixtures

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'skills/ba-release/scripts/release_native.py'


def load_native():
    spec = importlib.util.spec_from_file_location('ba_release_compat', HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CompatibilityReviewTests(unittest.TestCase):
    def fixture(self):
        fixture = release_fixtures.ReleaseTests(methodName='runTest')
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        return fixture

    def test_source_reservation_writes_settings_on_python39(self):
        fixture = self.fixture()
        module = load_native()
        settings = module.configuration(fixture.repo)
        planned = module.plan(fixture.repo, ['itch-linux'], fixture.state)
        result = module.reserve_source(settings, planned, fixture.state / 'reservation', 'patch')
        self.assertEqual(result['status'], 'source-update-required')
        content = (fixture.repo / 'project.godot').read_bytes()
        self.assertIn(b'config/version="1.2.4"', content)
        self.assertNotIn(b'\r\n', content)

    def test_powershell_roundtrip_observation_timestamps_on_python39(self):
        module = load_native()
        expected = dt.datetime(2026, 1, 1, 0, 0, 0, 123456, dt.timezone.utc)
        for value in ['2026-01-01T00:00:00.1234567Z',
                      '2026-01-01T01:00:00.1234567+01:00']:
            with self.subTest(value=value):
                self.assertEqual(module.observation({'observedAt': value}), expected)
        self.assertEqual(module.observation({'observedAt': '2026-01-01T00:00:00.1Z'}),
                         dt.datetime(2026, 1, 1, 0, 0, 0, 100000, dt.timezone.utc))
        with self.assertRaises(module.ReleaseError):
            module.observation({'observedAt': '2026-01-01T00:00:00.invalidZ'})

    def test_powershell_sent_timestamp_allows_later_abandonment(self):
        fixture = self.fixture()
        fixture.original_protocol_config(steam=True)
        module = load_native()
        planned = original_protocol.plan_fixture(fixture.repo, ['steam'], with_steam=True)
        path, state = original_protocol.journal_fixture(fixture.state, planned, {
            'steam': {'status': 'awaiting-store-action', 'attempts': 1,
                      'remote': {'phase': 'uploaded', 'buildId': '99'}}})
        ledger = module.ledger_directory(planned, fixture.state)
        ledger.mkdir(parents=True, exist_ok=True)
        sent = {'steam:42:default': [{
            'sourceCommit': planned['head'], 'version': planned['version'],
            'planId': planned['planId'], 'statePath': str(path), 'destination': 'steam',
            'sentAt': '2026-01-01T00:00:00.1234567Z'}]}
        module.write_json(ledger / 'sent.json', sent)
        receipt = {'destination': 'steam', 'planId': planned['planId'],
                   'observedAt': '2026-01-01T00:00:01Z', 'live': False,
                   'evidenceUrl': 'https://partner.steamgames.com/apps/builds/42',
                   'appId': 42, 'buildId': '99', 'branch': 'default'}
        receipt_path = fixture.base / 'abandon.json'
        module.write_json(receipt_path, receipt)
        self.assertEqual(module.confirm(path, receipt_path, abandon=True, authorized=True)['status'],
                         'abandoned')
        saved = module.read_json(ledger / 'sent.json')['steam:42:default'][0]
        self.assertEqual(saved['sentAt'], '2026-01-01T00:00:00.1234567Z')
        self.assertIn('abandoned', saved)
        self.assertEqual(module.read_json(path / 'state.json')['approval'], state['approval'])


class ArtifactOrderingReviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='BA artifact order ')
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.directory = self.path / 'builds' / '1'
        self.directory.mkdir(parents=True)
        self.module = load_native()
        # Culture-aware Sort-Object can interleave lowercase and accented names
        # ahead of uppercase names; Python's default path ordering is ordinal.
        files = []
        for name, content in [('a.txt', b'lower'), ('\u00e4.txt', b'accent'), ('Z.txt', b'upper')]:
            payload = self.directory / name
            payload.write_bytes(content)
            files.append({'path': 'builds/1/' + name, 'size': len(content),
                          'sha256': original_protocol.sha(content)})
        self.state = {'status': 'prepared', 'plan': {'requiredExports': [{'name': 'Linux'}]},
                      'artifacts': [{'preset': 'Linux', 'directory': 'builds/1', 'files': files,
                                     'sourceCommit': 'a' * 40}]}
        self.state['approval'] = {
            'artifactsSha256': original_protocol.sha(original_protocol.pipeline_text(self.state['artifacts']))}

    def test_culture_sorted_journal_keeps_approved_order_and_hash(self):
        before = copy.deepcopy(self.state)
        self.module.assert_artifacts(self.path, self.state)
        self.assertEqual(self.state, before)
        self.assertEqual([record['path'] for record in self.state['artifacts'][0]['files']],
                         ['builds/1/a.txt', 'builds/1/\u00e4.txt', 'builds/1/Z.txt'])

    def test_order_independence_still_rejects_file_changes(self):
        for mutation in ['content', 'added', 'missing', 'size', 'hash']:
            with self.subTest(mutation=mutation):
                state = copy.deepcopy(self.state)
                if mutation == 'content':
                    (self.directory / 'a.txt').write_bytes(b'other')
                elif mutation == 'added':
                    (self.directory / 'extra.txt').write_bytes(b'extra')
                elif mutation == 'missing':
                    (self.directory / 'a.txt').unlink()
                elif mutation == 'size':
                    state['artifacts'][0]['files'][0]['size'] = 100
                else:
                    state['artifacts'][0]['files'][0]['sha256'] = '0' * 64
                with self.assertRaisesRegex(self.module.ReleaseError, 'artifact'):
                    self.module.assert_artifacts(self.path, state)
                (self.directory / 'a.txt').write_bytes(b'lower')
                (self.directory / 'extra.txt').unlink(missing_ok=True)

    def test_order_independence_rejects_duplicate_saved_paths(self):
        self.state['artifacts'][0]['files'].append(copy.deepcopy(self.state['artifacts'][0]['files'][0]))
        with self.assertRaisesRegex(self.module.ReleaseError, 'artifact'):
            self.module.assert_artifacts(self.path, self.state)

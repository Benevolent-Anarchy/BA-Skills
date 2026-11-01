"""Regression coverage for public text and short-lived token boundaries."""
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import traceback
import unittest
from unittest.mock import patch

HELPER = Path(__file__).resolve().parents[2] / 'skills/ba-release/scripts/release_native.py'


class SecurityReviewTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('security_review', HELPER)
        self.m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.m)
        self.temp = tempfile.TemporaryDirectory(prefix='release security ')
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.account = 'fixture@example.invalid'
        self.service = 'tester@project.iam.gserviceaccount.com'

    def gcloud(self, warning_at=None, token='fixture-user-token'):
        executable = self.path / 'gcloud'
        executable.write_text(
            '#!/usr/bin/env python3\nimport json,sys\n'
            'command=sys.argv[2]\n'
            f'if command == {warning_at!r}: print("fixture CLI notice",file=sys.stderr)\n'
            f'print(json.dumps([{{"account":{self.account!r},"status":"ACTIVE"}}]) '
            f'if command == "list" else {token!r})\n'
        )
        executable.chmod(0o755)
        return str(executable)

    def mint(self, request, user_token):
        self.assertEqual(user_token, 'fixture-user-token')
        return {
            'accessToken': 'fixture-minted-token',
            'expireTime': (dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=59)).isoformat(),
        }

    def auth(self, action, executable, transport=None):
        return self.m.with_google_play_token(
            self.account, self.service, self.path, action, executable, transport or self.mint
        )

    def test_public_text_rejects_basic_authorization_and_quoted_credential_keys(self):
        for value in ['Authorization: Basic Zml4dHVyZQ==', "'token': 'fixture-value'", '"password" = fixture-value']:
            with self.subTest(value=value), self.assertRaises(self.m.ReleaseError):
                self.m.credential_free(value)

    def test_public_text_accepts_ordinary_hyphenated_words(self):
        for value in ['desk-developmenttooling', 'task-implementation', 'kiosk-configuration']:
            with self.subTest(value=value):
                self.m.credential_free(value)

    def test_gcloud_stderr_notices_do_not_contaminate_json_or_access_token(self):
        for command in ['list', 'print-access-token']:
            with self.subTest(command=command):
                result = self.auth(
                    lambda: os.environ['BA_GOOGLE_PLAY_ACCESS_TOKEN'], self.gcloud(command)
                )
                self.assertEqual(result, 'fixture-minted-token')

    def test_multiline_user_token_is_rejected_before_transport(self):
        def transport(*args):
            self.fail('Malformed token reached transport')
        with self.assertRaisesRegex(self.m.ReleaseError, 'token acquisition failed'):
            self.auth(lambda: None, self.gcloud(token='fixture-user-token\nnotice'), transport)

    def test_malformed_minted_token_is_rejected_before_action(self):
        def transport(request, token):
            result = self.mint(request, token)
            result['accessToken'] += '\r\nnotice'
            return result
        with self.assertRaisesRegex(self.m.ReleaseError, 'usable short-lived token'):
            self.auth(lambda: self.fail('Malformed token reached action'), self.gcloud(), transport)

    def test_api_value_error_does_not_expose_token_in_traceback(self):
        request = {'method': 'GET', 'uri': 'https://androidpublisher.googleapis.com/fixture'}
        with patch.object(self.m.urllib.request, 'urlopen', side_effect=ValueError('private-header-fixture')):
            try:
                self.m.api_request(request, 'fixture-user-token')
            except self.m.ApiError:
                self.assertNotIn('private-header-fixture', traceback.format_exc())
            else:
                self.fail('API error was not sanitized')

    def test_auth_transport_value_error_does_not_expose_token_in_traceback(self):
        def transport(*args):
            raise ValueError('private-header-fixture')
        with patch.dict(os.environ, {'BA_GOOGLE_PLAY_ACCESS_TOKEN': 'prior'}):
            try:
                self.auth(lambda: self.fail('Failed transport reached action'), self.gcloud(), transport)
            except self.m.ReleaseError:
                self.assertNotIn('private-header-fixture', traceback.format_exc())
            else:
                self.fail('Auth error was not sanitized')
            self.assertEqual(os.environ['BA_GOOGLE_PLAY_ACCESS_TOKEN'], 'prior')

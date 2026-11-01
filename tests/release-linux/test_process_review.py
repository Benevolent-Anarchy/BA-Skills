"""Cancellation regressions; every external action stays inside local fixtures."""
import contextlib
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import unittest
from unittest.mock import patch

from process_fixture import process_stopped
import test_release

SCRIPTS = Path(__file__).resolve().parents[2] / 'skills/ba-release/scripts'
HELPER = Path(os.environ.get('BA_RELEASE_PROCESS_HELPER', SCRIPTS / 'release_native.py'))
AUTH_HELPER = Path(os.environ.get('BA_RELEASE_AUTH_HELPER', SCRIPTS / 'google_play_auth_native.py'))


class UnreapedUpload:
    # Simulate a process stuck in the kernel even after KILL. Real local
    # processes cannot provide this failure deterministically.
    pid = 1073741824
    stdin = stdout = stderr = None

    def __init__(self, interruption=None):
        self.interruption = interruption

    def communicate(self, *args, **kwargs):
        if self.interruption is not None:
            error, self.interruption = self.interruption, None
            raise error
        raise subprocess.TimeoutExpired('fixture upload', kwargs.get('timeout'))

    def poll(self):
        return None

    def kill(self):
        pass

    def wait(self, *args, **kwargs):
        raise subprocess.TimeoutExpired('fixture upload', kwargs.get('timeout'))


class ProcessReviewTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('process_review_native', HELPER)
        self.m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.m)

    def release_fixture(self):
        fixture = test_release.ReleaseTests('test_plan_is_read_only_and_contains_full_source_evidence')
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        fixture.prepare('itch-linux,notes')
        return fixture

    def test_default_external_action_can_finish_without_a_deadline(self):
        # Compress a ten-minute deadline to 60 ms while retaining a real child.
        # A default timeout would kill legitimate long exports or uploads.
        real_popen = subprocess.Popen

        def accelerated_deadline(*args, **kwargs):
            process = real_popen(*args, **kwargs)
            communicate = process.communicate

            def scaled_communicate(input=None, timeout=None):
                return communicate(input, None if timeout is None else timeout / 10000)

            process.communicate = scaled_communicate
            return process

        with patch.object(self.m.subprocess, 'Popen', accelerated_deadline):
            try:
                result = self.m.run(sys.executable, ['-c', 'import time;time.sleep(.12);print("finished")'])
            except self.m.InterruptedOperation:
                self.fail('Default deadline interrupted an action that was still progressing')
        self.assertEqual(result, (0, 'finished\n'))

    def test_bounded_cleanup_failure_keeps_publication_uncertain_and_blocks_retry(self):
        fixture = self.release_fixture()
        status = fixture.cli('status', '--state-path', fixture.path)
        real_popen = subprocess.Popen

        def spawn(command, *args, **kwargs):
            if Path(command[0]).name == 'butler':
                return UnreapedUpload()
            return real_popen(command, *args, **kwargs)

        with patch.dict(os.environ, fixture.env), patch.object(self.m.subprocess, 'Popen', spawn):
            result = self.m.publish(fixture.path, status['planId'], status['notesSha256'])
            self.assertEqual(result['status'], 'needs-reconciliation')
            self.assertEqual(fixture.journal()['destinations']['itch-linux']['status'], 'uncertain')
            self.m.publish(fixture.path)
        self.assertEqual(fixture.journal()['destinations']['itch-linux']['attempts'], 1)

    def test_bounded_cleanup_failure_preserves_cancellation_to_stop_workflow(self):
        process = UnreapedUpload(self.m.Cancellation('Fixture signal cancellation'))
        with patch.object(self.m.subprocess, 'Popen', return_value=process):
            with self.assertRaises(self.m.ReleaseError) as raised:
                self.m.run(sys.executable)
        self.assertIsInstance(raised.exception, self.m.Cancellation)

    def test_cancelled_auth_wrapper_allows_native_upload_cleanup_and_journal(self):
        fixture = self.release_fixture()
        status = fixture.cli('status', '--state-path', fixture.path)
        upload_pid = fixture.base / 'upload.pid'
        native_pid = fixture.base / 'native.pid'
        fixture.env['FIXTURE_UPLOAD_PID'] = str(upload_pid)
        fixture.fake('butler', 'import os,pathlib,signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\npathlib.Path(os.environ["FIXTURE_UPLOAD_PID"]).write_text(str(os.getpid()))\nwhile True:time.sleep(.1)\n')
        native_driver = fixture.base / 'native-driver.py'
        native_driver.write_text(
            'import importlib.util,pathlib,os,sys,time\n'
            'spec=importlib.util.spec_from_file_location("release_native",' + repr(str(HELPER)) + ')\n'
            'm=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)\n'
            'pathlib.Path(' + repr(str(native_pid)) + ').write_text(str(os.getpid()))\n'
            'terminate=m.terminate_process_group\n'
            # Account for scheduling/journal latency between two nested owners
            # whose identical grace periods would otherwise race unpredictably.
            'def delayed_cleanup(*args,**kwargs):\n time.sleep(.25)\n return terminate(*args,**kwargs)\n'
            'm.terminate_process_group=delayed_cleanup\n'
            'm.install_cancellation_handlers();sys.exit(m.main())\n'
        )
        command = [sys.executable, str(native_driver), '--mode', 'publish', '--state-path', str(fixture.path),
                   '--approved-plan-id', status['planId'], '--approved-notes-sha256', status['notesSha256']]
        wrapper_driver = fixture.base / 'wrapper-driver.py'
        wrapper_driver.write_text(
            'import importlib.util,sys\n'
            'spec=importlib.util.spec_from_file_location("release_native",' + repr(str(HELPER)) + ')\n'
            'm=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);sys.modules["release_native"]=m\n'
            'spec=importlib.util.spec_from_file_location("auth_wrapper",' + repr(str(AUTH_HELPER)) + ')\n'
            'auth=importlib.util.module_from_spec(spec);spec.loader.exec_module(auth)\n'
            # Token acquisition is unrelated to process ownership; invoke the
            # real wrapper action without credentials or a network request.
            'auth.with_google_play_token=lambda account,service,config,action,gcloud:action()\n'
            'sys.argv=["auth","--account","fixture@example.invalid","--service-account","fixture@project.iam.gserviceaccount.com","--gcloud-config-directory","/unused","--",*' + repr(command) + ']\n'
            'm.install_cancellation_handlers();sys.exit(auth.main())\n'
        )
        process = subprocess.Popen([sys.executable, str(wrapper_driver)], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, env=fixture.env, start_new_session=True)
        try:
            deadline = time.monotonic() + 5
            while not upload_pid.exists() and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertTrue(upload_pid.exists(), 'Fixture upload did not start')
            process.send_signal(signal.SIGTERM)
            process.communicate(timeout=8)
            self.assertNotEqual(process.returncode, 0)
            self.assertEqual(fixture.journal()['destinations']['itch-linux']['status'], 'uncertain')
            self.assertEqual(fixture.journal()['status'], 'needs-reconciliation')
            self.assertTrue(process_stopped(int(upload_pid.read_text())), 'Wrapper cancellation orphaned its upload')
            self.assertNotIn('github-put', fixture.calls())
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=1)
            for pidfile in [native_pid, upload_pid]:
                if pidfile.exists():
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(int(pidfile.read_text()), signal.SIGKILL)


if __name__ == '__main__':
    unittest.main()

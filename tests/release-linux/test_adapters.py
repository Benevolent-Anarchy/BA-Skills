"""Exercise store adapters and recovery using in-memory API transcripts only."""
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from process_fixture import process_stopped
from unittest.mock import patch

HELPER=Path(__file__).resolve().parents[2]/'skills/ba-release/scripts/release_native.py'

class AdapterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec=importlib.util.spec_from_file_location('native_adapter',HELPER);cls.m=importlib.util.module_from_spec(spec);spec.loader.exec_module(cls.m)
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='release adapter ü ');self.addCleanup(self.temp.cleanup);self.path=Path(self.temp.name)
        (self.path/'bundle.aab').write_bytes(b'fixed bundle');(self.path/'notes.google-play.txt').write_text('Approved changes')
        self.bundle={'path':'bundle.aab','sha256':self.m.digest(b'fixed bundle'),'size':12};self.artifacts=[{'preset':'AAB','directory':'.','files':[self.bundle]}]
        self.destination={'id':'google-play','type':'google-play','preset':'AAB','packageName':'com.fixture.game','versionCode':7,'track':'production','language':'en-US','releaseStatus':'completed','userFraction':None,'retainVersionCodes':['6']}
        self.plan={'version':'1.2.3'};self.record={'status':'pending','remote':{}};self.calls=[];self.saves=[]
    def save(self):self.saves.append(json.loads(json.dumps(self.record)))
    def transport(self,request):
        self.calls.append(request);uri=request['uri'];method=request['method']
        if method=='POST' and uri.endswith('/edits'):return {'id':'edit_1'}
        if method=='GET' and uri.endswith('/bundles'):return {'bundles':[]}
        if method=='POST' and '/bundles?' in uri:return {'versionCode':7,'sha256':self.bundle['sha256']}
        if method=='GET' and '/tracks/' in uri:return {'track':'production','releases':[]}
        return {}
    def publish(self,transport=None,replace=False):return self.m.publish_play(self.plan,self.destination,self.artifacts,self.path,self.record,self.save,transport or self.transport,replace)
    def test_play_commits_exact_bundle_and_track_and_remains_submitted(self):
        self.assertEqual(self.publish(),'submitted');self.assertEqual(self.record['remote']['phase'],'edit-committed')
        body=next(r['body'] for r in self.calls if r['method']=='PUT');release=body['releases'][0]
        self.assertEqual(release['versionCodes'],['6','7']);self.assertEqual(release['releaseNotes'][0]['text'],'Approved changes')
        self.assertTrue(any(s['remote']['phase']=='committing' for s in self.saves))
    def test_play_reuses_saved_edit_and_existing_matching_bundle(self):
        self.record['remote']['editId']='existing'
        def transport(request):
            if request['method']=='GET' and request['uri'].endswith('/bundles'):
                self.calls.append(request);return {'bundles':[{'versionCode':'7','sha256':self.bundle['sha256']}]}
            return self.transport(request)
        self.publish(transport);self.assertFalse(any(r['method']=='POST' and (r['uri'].endswith('/edits') or '/bundles?' in r['uri']) for r in self.calls))
    def test_play_rejects_existing_code_with_different_bundle_before_track_write(self):
        def transport(request):
            if request['uri'].endswith('/bundles'):return {'bundles':[{'versionCode':7,'sha256':'different'}]}
            return self.transport(request)
        with self.assertRaisesRegex(self.m.ReleaseError,'different bundle'):self.publish(transport)
        self.assertFalse(any(r['method']=='PUT' for r in self.calls))
    def test_play_lost_commit_response_retains_committing_phase(self):
        def transport(request):
            if ':commit?' in request['uri']:raise self.m.ApiError(500)
            return self.transport(request)
        with self.assertRaises(self.m.ApiError):self.publish(transport)
        self.assertEqual(self.record['remote']['phase'],'committing')
    def test_play_missing_edit_requires_separate_authorization(self):
        self.record['remote']={'editId':'expired','phase':'track-updated'}
        def transport(request):
            if request['uri'].endswith('/edits/expired'):raise self.m.ApiError(404)
            return self.transport(request)
        with self.assertRaises(self.m.ApiError):self.publish(transport)
        self.assertFalse(any(r['uri'].endswith('/edits') for r in self.calls))
        self.publish(transport,True);self.assertEqual(self.record['remote']['previousEdits'][0]['id'],'expired')
    def test_play_non_404_error_never_replaces_edit(self):
        self.record['remote']={'editId':'expired','phase':'track-updated'}
        def transport(request):raise self.m.ApiError(403)
        with self.assertRaises(self.m.ApiError):self.publish(transport,True)
        self.assertEqual(self.record['remote']['editId'],'expired')
    def test_play_matches_already_deployed_track_without_resubmission(self):
        release={'name':'1.2.3','versionCodes':['7','6'],'status':'completed','releaseNotes':[{'language':'en-US','text':'Approved changes'}]}
        def transport(request):
            if request['uri'].endswith('/bundles'):return {'bundles':[{'versionCode':7,'sha256':self.bundle['sha256']}]}
            if '/tracks/' in request['uri']:return {'releases':[release]}
            return self.transport(request)
        self.assertEqual(self.publish(transport),'submitted');self.assertEqual(self.record['remote']['phase'],'existing-track-matched');self.assertFalse(any(':commit' in r['uri'] for r in self.calls))
    def test_play_deployed_match_cleanup_failure_does_not_resubmit_on_retry(self):
        self.record['remote']={'phase':'existing-track-matched','bundleSha256':self.bundle['sha256'],'versionCode':7}
        self.assertEqual(self.publish(),'submitted');self.assertFalse(self.calls);self.assertEqual(self.record['remote']['cleanupStatus'],'pending')
    def test_play_draft_remains_console_action(self):self.destination['releaseStatus']='draft';self.assertEqual(self.publish(),'awaiting-store-action')
    def test_play_wrong_uploaded_hash_stops_before_track(self):
        def transport(request):
            if '/bundles?' in request['uri']:return {'versionCode':7,'sha256':'wrong'}
            return self.transport(request)
        with self.assertRaisesRegex(self.m.ReleaseError,'differs'):self.publish(transport)
        self.assertFalse(any('/tracks/' in r['uri'] for r in self.calls))
    def test_play_rejects_more_than_500_utf16_characters(self):
        (self.path/'notes.google-play.txt').write_text('😀'*251)
        with self.assertRaisesRegex(self.m.ReleaseError,'500'):self.publish()
        self.assertFalse(self.calls)
    def test_fixed_host_api_refuses_arbitrary_token_destination(self):
        with self.assertRaisesRegex(self.m.ReleaseError,'host'):self.m.api_request({'method':'GET','uri':'https://attacker.invalid/'},'fixture')
    def test_process_timeout_kills_descendants(self):
        script=self.path/'slow';script.write_text('#!/bin/sh\nsleep 10 &\nwait\n');script.chmod(0o755)
        with self.assertRaisesRegex(self.m.ReleaseError,'timed out'):self.m.run(str(script),timeout=0.05)
    def test_steam_zero_exit_without_proof_is_uncertain(self):
        script=self.path/'steamcmd';script.write_text('#!/bin/sh\necho no-proof\n');script.chmod(0o755)
        dest={'id':'steam','type':'steam','appId':42,'branch':'default','depots':[{'id':43,'preset':'Linux','exclude':[]}]};artifacts=[{'preset':'Linux','directory':'.'}]
        with patch.dict(os.environ,{'BA_STEAM_USERNAME':'fixture'}):
            with self.assertRaisesRegex(self.m.ReleaseError,'verifiable'):self.m.publish_steam(self.plan,dest,artifacts,self.path,self.record,self.save,str(script))
        self.assertTrue(self.record['remote']['ambiguous'])
    def test_steam_records_build_id_and_never_claims_live(self):
        script=self.path/'steamcmd';script.write_text('#!/bin/sh\necho "Successfully finished AppID 42 build (BuildID 99)"\n');script.chmod(0o755)
        dest={'id':'steam','type':'steam','appId':42,'branch':'default','depots':[{'id':43,'preset':'Linux','exclude':['private?.txt']}]};artifacts=[{'preset':'Linux','directory':'.'}]
        with patch.dict(os.environ,{'BA_STEAM_USERNAME':'fixture'}):self.assertEqual(self.m.publish_steam(self.plan,dest,artifacts,self.path,self.record,self.save,str(script)),'awaiting-store-action')
        self.assertEqual(self.record['remote']['buildId'],'99');self.assertNotIn('live',self.record['remote']);app=next(self.path.glob('steam/steam/*/app_42.vdf'));self.assertIn('"SetLive" ""',app.read_text())
    def test_auth_rejects_account_mismatch_without_token_acquisition(self):
        config=self.path/'credentials';config.mkdir();gcloud=self.path/'gcloud';gcloud.write_text('#!/bin/sh\necho \'[{"account":"other@example.invalid","status":"ACTIVE"}]\'\n');gcloud.chmod(0o755)
        with self.assertRaisesRegex(self.m.ReleaseError,'match'):self.m.with_google_play_token('fixture@example.invalid','tester@project.iam.gserviceaccount.com',config,lambda:None,str(gcloud))
    def test_auth_limits_token_lifetime_and_restores_environment_on_failure(self):
        config=self.path/'credentials';config.mkdir();gcloud=self.path/'gcloud';gcloud.write_text('#!/bin/sh\nif [ "$2" = list ]; then echo \'[{"account":"fixture@example.invalid","status":"ACTIVE"}]\'; else echo fixture-user-token; fi\n');gcloud.chmod(0o755)
        def transport(request,user_token):
            self.assertEqual(user_token,'fixture-user-token');return {'accessToken':'fixture-minted-token','expireTime':(dt.datetime.now(dt.timezone.utc)+dt.timedelta(minutes=59)).isoformat()}
        def action():self.assertEqual(os.environ['BA_GOOGLE_PLAY_ACCESS_TOKEN'],'fixture-minted-token');raise ValueError('action failed')
        with patch.dict(os.environ,{'BA_GOOGLE_PLAY_ACCESS_TOKEN':'prior','CLOUDSDK_CONFIG':'prior-config'}):
            with self.assertRaisesRegex(ValueError,'action failed'):self.m.with_google_play_token('fixture@example.invalid','tester@project.iam.gserviceaccount.com',config,action,str(gcloud),transport)
            self.assertEqual(os.environ['BA_GOOGLE_PLAY_ACCESS_TOKEN'],'prior');self.assertEqual(os.environ['CLOUDSDK_CONFIG'],'prior-config')
    def test_auth_refuses_credentials_inside_git_checkout(self):
        import subprocess
        subprocess.run(['git','init','-q',str(self.path)],check=True)
        with self.assertRaisesRegex(self.m.ReleaseError,'outside'):self.m.with_google_play_token('fixture@example.invalid','tester@project.iam.gserviceaccount.com',self.path,lambda:None)


    def test_original_powershell_pipeline_json_cardinality_and_escape_vectors(self):
        # Explicit protocol outputs: no input => no JSON text, one object =>
        # object rather than array, multiple objects => array, property order kept.
        vectors=[([],''),([{'preset':'Linux','directory':'builds/1'}],'{"preset":"Linux","directory":"builds/1"}'),([{'b':2,'a':1},{'x':'ü\n'}],'[{"b":2,"a":1},{"x":"ü\\n"}]')]
        for value,expected in vectors:self.assertEqual(self.m.pipeline_json(value),expected)
        self.assertEqual(self.m.compact({'x':'\x85\u2028\u2029'}),'{"x":"\\u0085\\u2028\\u2029"}')


    def test_timeout_sends_term_before_kill_so_nested_orchestrator_can_cleanup(self):
        import signal,sys,time
        child_pid=self.path/'child.pid';cleaned=self.path/'cleaned';script=self.path/'nested.py'
        script.write_text('import os,signal,subprocess,time,pathlib\nchild=subprocess.Popen(["sleep","10"],start_new_session=True)\npathlib.Path('+repr(str(child_pid))+').write_text(str(child.pid))\ndef terminate(sig,frame):\n os.killpg(child.pid,signal.SIGTERM)\n child.wait(timeout=1)\n pathlib.Path('+repr(str(cleaned))+').write_text("term-cleanup")\n raise SystemExit(0)\nsignal.signal(signal.SIGTERM,terminate)\nwhile True:time.sleep(.01)\n')
        try:
            with self.assertRaisesRegex(self.m.ReleaseError,'timed out'):self.m.run(sys.executable,[str(script)],timeout=.15)
            self.assertTrue(cleaned.is_file(),'SIGKILL prevented the nested orchestrator from cleaning its owned child group')
            pid=int(child_pid.read_text());self.assertFalse((Path('/proc')/str(pid)).exists())
        finally:
            if child_pid.exists():
                try:os.killpg(int(child_pid.read_text()),signal.SIGKILL)
                except ProcessLookupError:pass
    def test_timeout_cleans_child_group_after_direct_launcher_already_exited(self):
        import signal,time
        pidfile=self.path/'descendant.pid';script=self.path/'launcher';script.write_text('#!/bin/sh\nsleep 10 &\necho $! > "'+str(pidfile)+'"\nexit 0\n');script.chmod(0o755)
        start=time.monotonic()
        try:
            with self.assertRaisesRegex(self.m.ReleaseError,'timed out'):self.m.run(str(script),timeout=.05)
            self.assertLess(time.monotonic()-start,1);pid=int(pidfile.read_text());stat=Path('/proc')/str(pid)/'stat';self.assertTrue(process_stopped(pid))
        finally:
            if pidfile.exists():
                try:os.kill(int(pidfile.read_text()),signal.SIGKILL)
                except ProcessLookupError:pass


    def test_original_ordered_source_tag_identity_matches_fixed_hash_vector(self):
        expected=(Path(__file__).parent/'fixtures/powershell-identity.json').read_text();identity=json.loads(expected)
        self.assertEqual(self.m.compact(identity),expected)
        self.assertEqual(self.m.digest(self.m.compact(identity)),'4f45cb0fcd9fd08ca81932ec0c4ffbee1c8b66340d81c5893760358e784f02f0')

if __name__=='__main__':unittest.main()

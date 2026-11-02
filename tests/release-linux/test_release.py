"""Native release behavioral tests. All stores, engines and credentials are local fixtures."""
import base64
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from process_fixture import process_stopped
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'skills/ba-release/scripts/release.sh'
HELPER = ROOT / 'skills/ba-release/scripts/release_native.py'
IGNORE = ['steam_api*.dll','libsteam_api.so','libgodotsteam.*','steam_appid.txt']

class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='BA release ü ')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / 'game space'; self.repo.mkdir()
        self.state = self.base / 'state'; self.bin = self.base / 'bin'; self.bin.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin)+os.pathsep+os.environ['PATH'], BA_TEST_LOG=str(self.base/'calls'))
        self.git('init', '-q'); self.git('config','user.email','fixture@example.invalid'); self.git('config','user.name','Fixture')
        self.git('remote','add','origin','https://github.com/fixture/game.git')
        # Exercise exact config bytes even when host-wide attributes normalize text.
        self.write('.gitattributes', 'release.json -text\n')
        self.write('project.godot','[application]\nconfig/name="Fixture"\nconfig/version="1.2.3"\nconfig/features=PackedStringArray("4.7")\n')
        self.write('export_presets.cfg','[preset.0]\nname="Linux"\nplatform="Linux"\nexport_path="build/game.x86_64"\n[preset.0.options]\nbinary_format/architecture="x86_64"\n')
        self.write('tools/verify.sh','#!/bin/sh\nprintf "gate\\n" >> "$BA_TEST_LOG"\n', True)
        self.write('tools/standalone.sh','#!/bin/sh\ntest -f "$1/game.x86_64" && test ! -e "$1/steam_appid.txt"\n',True)
        self.config={'schemaVersion':1,'project':'.','previousRelease':'base','exports':{'linux':'Linux'},'verification':{'gate':{'script':'tools/verify.sh','arguments':[]},'standalone':{'exports':['linux'],'script':'tools/standalone.sh','arguments':['{artifact}']}},'distributions':{'itch':{'game':'fixture/game','ignore':IGNORE,'channels':{'linux':'linux'}},'notes':True},'sourceTag':False}
        self.save_config(); self.commit('base'); self.git('tag','base'); self.write('feature.txt','new behavior'); self.commit('feature')
        self.fake('godot', '''import pathlib,sys,os
if '--version' in sys.argv: print('4.7.2.stable.fixture'); sys.exit(0)
p=pathlib.Path(sys.argv[-1]); p.write_bytes(b'exported executable'); (p.parent/'steam_appid.txt').write_text('42')
with open(os.environ['BA_TEST_LOG'],'a') as f: f.write('export\\n')
''')
        self.fake('butler', '''import pathlib,sys,fnmatch,os
with open(os.environ['BA_TEST_LOG'],'a') as f: f.write(('dry' if '--dry-run' in sys.argv else 'push')+'\\n')
if '--dry-run' in sys.argv:
 p=pathlib.Path(sys.argv[2]); pats=[sys.argv[i+1] for i,a in enumerate(sys.argv) if a=='--ignore']
 for q in sorted(p.rglob('*')) if p.is_dir() else [p]:
  if q.is_file() and not any(fnmatch.fnmatchcase(q.name,x) for x in pats): print(q.relative_to(p) if p.is_dir() else q.name)
''')
        self.fake('gh', '''import os,sys,json,base64,pathlib
args=sys.argv[1:]; path=next((x for x in args if x.startswith('repos/')),'')
root=pathlib.Path(os.environ['BA_TEST_LOG']+'.github'); root.mkdir(exist_ok=True)
f=root/path.replace('/','_')
if '--method' in args:
 body=json.loads(pathlib.Path(args[args.index('--input')+1]).read_text()); f.write_text(json.dumps({'encoding':'base64','content':body['content'],'sha':'fixture-sha'})); print('{}')
 with open(os.environ['BA_TEST_LOG'],'a') as log: log.write('github-put\\n')
elif '/contents/' not in path: print(json.dumps({'private':False,'permissions':{'push':True}}))
elif f.exists(): print(f.read_text())
else: print('HTTP 404 Not Found'); sys.exit(1)
''')
    def write(self,path,text,executable=False):
        p=self.repo/path; p.parent.mkdir(parents=True,exist_ok=True);p.write_text(text)
        if executable:p.chmod(0o755)
        return p
    def fake(self,name,code):
        p=self.bin/name;p.write_text('#!/usr/bin/env python3\n'+code);p.chmod(0o755);return p
    def git(self,*args):
        return subprocess.check_output(['git','-C',str(self.repo),*args],stderr=subprocess.STDOUT,text=True).strip()
    def commit(self,msg):self.git('add','.');self.git('commit','-qm',msg)
    def save_config(self):self.write('release.json',json.dumps(self.config,indent=2)+'\n')
    def cli(self,mode,*args,ok=True):
        opts=['--repository',str(self.repo),'--state-root',str(self.state)] if mode in ('setup','validate','plan','doctor','prepare') else []
        result=subprocess.run([str(SCRIPT),'--mode',mode,*opts,*map(str,args)],capture_output=True,text=True,env=self.env)
        try: data=json.loads(result.stdout)
        except Exception:self.fail('Expected structured output: '+result.stdout+result.stderr)
        if ok:self.assertEqual(result.returncode,0,data)
        else:self.assertNotEqual(result.returncode,0,data)
        return data
    def prepare(self,selection='itch-linux'):
        r=self.cli('prepare','--destination',selection); self.path=Path(r['statePath']);return r
    def journal(self):return json.loads((self.path/'state.json').read_text())
    def save_journal(self,s):(self.path/'state.json').write_text(json.dumps(s))
    def approve(self,**kwargs):
        s=self.cli('status','--state-path',self.path)
        return self.cli('publish','--state-path',self.path,'--approved-plan-id',s['planId'],'--approved-notes-sha256',s['notesSha256'],**kwargs)
    def calls(self):return (self.base/'calls').read_text().splitlines() if (self.base/'calls').exists() else []
    def load_module(self):
        spec=importlib.util.spec_from_file_location('ba_release_native',HELPER); module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
    def test_plan_is_read_only_and_contains_full_source_evidence(self):
        before=self.git('status','--porcelain');r=self.cli('plan','--destination','itch-linux,notes')
        self.assertTrue(r['ready']);self.assertEqual(r['head'],self.git('rev-parse','HEAD'));self.assertEqual(len(r['changes']),1)
        self.assertEqual(self.git('status','--porcelain'),before);self.assertFalse(self.state.exists());self.assertFalse(self.calls())
    def test_plan_requires_explicit_selection(self):self.assertFalse(self.cli('plan',ok=False)['ready'])
    def test_dirty_source_blocks_prepare_but_plan_reports_it(self):
        self.write('feature.txt','dirty');self.assertFalse(self.cli('plan','--destination','itch-linux',ok=False)['ready'])
        self.assertIn('uncommitted',self.cli('prepare','--destination','itch-linux',ok=False)['error']);self.assertFalse(self.calls())
    def test_duplicate_json_keys_rejected(self):
        self.write('release.json','{"schemaVersion":1,"schemaVersion":1}')
        self.assertIn('Duplicate',self.cli('validate',ok=False)['error'])
    def test_path_escape_and_symlink_escape_rejected(self):
        self.config['verification']['gate']['script']='../escape.sh';self.save_config();self.assertIn('inside',self.cli('validate',ok=False)['error'])
        outside=self.base/'escape.sh';outside.write_text('#!/bin/sh\n');(self.repo/'escape.sh').symlink_to(outside)
        self.config['verification']['gate']['script']='escape.sh';self.save_config();self.assertIn('inside',self.cli('validate',ok=False)['error'])
    def test_prepare_exports_once_and_standalone_withholds_steam(self):
        a=self.prepare();b=self.prepare();self.assertEqual(a['statePath'],b['statePath']);self.assertEqual(self.calls().count('export'),1)
        s=self.journal();self.assertEqual(s['verification'],'succeeded');self.assertEqual(s['checks']['itch-linux']['standalone'],'succeeded')
        self.assertTrue((self.path/s['artifacts'][0]['directory']/'steam_appid.txt').exists())
    def test_failed_gate_never_exports(self):
        self.write('tools/verify.sh','#!/bin/sh\nexit 7\n',True);self.commit('gate failure')
        self.assertIn('verification',self.cli('prepare','--destination','itch-linux',ok=False)['error']);self.assertNotIn('export',self.calls())
    def test_failed_export_can_retry_without_rerunning_gate(self):
        self.fake('godot','import sys;sys.exit(7)\n');a=self.cli('prepare','--destination','itch-linux',ok=False);self.path=Path(a['statePath'])
        self.fake('godot',"import pathlib,sys;p=pathlib.Path(sys.argv[-1]);p.write_text('retry')\n")
        self.prepare();self.assertEqual(self.calls().count('gate'),1)
    def test_empty_butler_preview_fails_preparation(self):
        self.fake('butler','');r=self.cli('prepare','--destination','itch-linux',ok=False);self.assertEqual(r['status'],'preparation-failed')
    def test_state_root_must_stay_outside_source(self):
        r=self.cli('prepare','--destination','itch-linux','--state-root',self.repo/'state',ok=False);self.assertIn('outside',r['error'])
    def test_version_reservation_requires_commit_and_never_bumps_twice(self):
        r=self.cli('prepare','--destination','itch-linux','--version-change','patch',ok=False);self.assertEqual(r['status'],'source-update-required')
        self.assertIn('1.2.4',(self.repo/'project.godot').read_text());self.cli('prepare','--destination','itch-linux',ok=False)
        self.assertIn('1.2.4',(self.repo/'project.godot').read_text());self.commit('reserve source');self.prepare();self.assertEqual(self.journal()['plan']['version'],'1.2.4')
    def test_publication_requires_exact_approval(self):
        self.prepare();self.assertIn('approval',self.cli('publish','--state-path',self.path,ok=False)['error'].lower());self.assertNotIn('push',self.calls())
    def test_changed_artifact_blocks_publish(self):
        self.prepare();s=self.journal();(self.path/s['artifacts'][0]['files'][0]['path']).write_text('tampered')
        self.assertIn('artifact',self.cli('publish','--state-path',self.path,ok=False)['error'].lower());self.assertNotIn('push',self.calls())
    def test_changed_plan_target_blocks_publish(self):
        self.prepare();s=self.journal();s['plan']['destinations'][0]['target']='attacker/game:linux';self.save_journal(s)
        self.assertIn('plan',self.cli('publish','--state-path',self.path,ok=False)['error'].lower());self.assertNotIn('push',self.calls())
    def test_publish_is_idempotent_and_writes_public_notes_only_after_live(self):
        self.prepare('itch-linux,notes');self.assertEqual(self.approve()['status'],'published');self.assertEqual(self.approve()['status'],'published')
        self.assertEqual(self.calls().count('push'),1);self.assertEqual(self.calls().count('github-put'),2)
    def test_notes_only_wait_for_live_evidence(self):
        self.prepare('notes');self.assertEqual(self.approve(ok=False)['status'],'awaiting-release');self.assertNotIn('github-put',self.calls())
    def test_hold_skips_all_store_work_and_requires_explicit_unhold(self):
        self.prepare();identity=self.journal()['plan']['planId'];self.cli('hold','--state-path',self.path,'--destination','itch-linux','--hold-reason','Release later')
        self.assertEqual(self.approve(ok=False)['status'],'on-hold');self.assertNotIn('push',self.calls());self.assertEqual(identity,self.journal()['plan']['planId'])
        self.cli('unhold','--state-path',self.path,'--destination','itch-linux');self.assertEqual(self.approve()['status'],'published')
    def test_hold_rejects_private_reason_and_remote_progress(self):
        self.prepare();self.cli('hold','--state-path',self.path,'--destination','itch-linux','--hold-reason','Bearer secret',ok=False)
        s=self.journal();s['destinations']['itch-linux']['remote']['phase']='pushing';self.save_journal(s)
        self.cli('hold','--state-path',self.path,'--destination','itch-linux','--hold-reason','Later',ok=False)
    def test_interrupted_publication_is_uncertain_until_authorized(self):
        self.prepare();s=self.cli('status','--state-path',self.path);state=self.journal();state['destinations']['itch-linux']['status']='in-progress';self.save_journal(state)
        r=self.approve(ok=False);self.assertEqual(r['status'],'needs-reconciliation');self.assertNotIn('push',self.calls())
        self.cli('publish','--state-path',self.path,'--retry-uncertain');self.assertEqual(self.calls().count('push'),1)
    def test_extend_reuses_exports_and_requires_new_approval(self):
        self.prepare();self.approve();self.cli('extend','--state-path',self.path,'--destination','notes')
        self.assertEqual(self.calls().count('export'),1);self.assertIsNone(self.journal()['approval']);self.assertEqual(self.approve()['status'],'published')
    def test_source_change_after_prepare_blocks_publish(self):
        self.prepare();self.write('feature.txt','later');self.commit('later')
        self.assertIn('changed',self.cli('publish','--state-path',self.path,ok=False)['error']);self.assertNotIn('push',self.calls())
    def test_doctor_checks_selected_tools_without_build_or_network(self):
        templates=self.base/'templates/4.7.2.stable';templates.mkdir(parents=True);(templates/'linux_release.x86_64').touch()
        r=self.cli('doctor','--destination','itch-linux','--template-root',templates.parent);self.assertTrue(r['ready']);self.assertFalse(r['remoteAccessVerified']);self.assertFalse(self.calls())
    def test_setup_uses_hash_and_does_not_overwrite_changed_config(self):
        r=self.cli('setup');answers=self.base/'answers.json';answers.write_text(json.dumps({'sourceTag':True}))
        self.cli('setup','--answers-path',answers,'--expected-config-sha256','wrong',ok=False)
        self.assertFalse(json.loads((self.repo/'release.json').read_text())['sourceTag'])
        self.cli('setup','--answers-path',answers,'--expected-config-sha256',r['configSha256']);self.assertTrue(json.loads((self.repo/'release.json').read_text())['sourceTag'])

    def test_prepare_without_a_selection_writes_nothing_and_never_prompts(self):
        before=self.git('status','--porcelain')
        for extra in ([],['--interactive']):
            result=subprocess.run([str(SCRIPT),'--mode','prepare','--repository',str(self.repo),'--state-root',str(self.state),*extra],capture_output=True,text=True,env=self.env,stdin=subprocess.DEVNULL)
            self.assertEqual(result.returncode,2,result.stdout+result.stderr)
            data=json.loads(result.stdout)
            self.assertEqual(data['status'],'selection-required');self.assertTrue(data['selection']['required']);self.assertTrue(data['selection']['choices'])
        self.assertEqual(self.git('status','--porcelain'),before);self.assertFalse(self.state.exists() and any(self.state.iterdir()))

    def test_setup_reenables_notes_when_selected_in_stores(self):
        self.config['distributions']['notes'] = False
        self.save_config()
        self.commit('disable public notes')
        report = self.cli('setup', '--destination', 'notes')
        answers = self.base / 'enable-notes.json'
        answers.write_text(json.dumps({'stores': ['itch', 'notes']}))
        result = self.cli('setup', '--destination', 'notes', '--answers-path', answers,
                          '--expected-config-sha256', report['configSha256'])
        self.assertIs(result['report']['configuration']['distributions']['notes'], True)
        self.assertEqual(result['report']['configuration']['distributions']['itch'], self.config['distributions']['itch'])
        self.commit('enable public notes')
        planned = self.cli('plan', '--destination', 'notes')
        self.assertTrue(next(d for d in planned['destinations'] if d['id'] == 'notes')['selected'])

    def test_setup_python_hooks_run_without_shebang_or_execute_permission(self):
        self.git('rm', 'tools/verify.sh', 'tools/standalone.sh')
        self.write('tools/verify.py', 'import os\nwith open(os.environ["BA_TEST_LOG"], "a") as stream: stream.write("python-gate\\n")\n')
        self.write('tools/standalone.py', 'import pathlib,sys\nassert (pathlib.Path(sys.argv[1])/"game.x86_64").is_file()\n')
        self.config['verification'] = {'gate': {'script': 'tools/verify.py', 'arguments': []},
                                       'standalone': {'exports': ['linux'], 'script': 'tools/standalone.py', 'arguments': ['{artifact}']}}
        self.save_config()
        self.commit('Python verification hooks')
        self.assertEqual(self.cli('setup')['configuration']['verification']['gate']['script'], 'tools/verify.py')
        self.prepare()
        self.assertIn('python-gate', self.calls())


    def add_android(self, policy='existing'):
        self.write('export_presets.cfg',(self.repo/'export_presets.cfg').read_text()+'[preset.1]\nname="AAB"\nplatform="Android"\nexport_path="build/game.aab"\n[preset.1.options]\ngradle_build/use_gradle_build=true\ngradle_build/export_format=1\nversion/code=7\nversion/name="1.2.3"\npackage/unique_name="com.fixture.game"\npackage/signed=true\n')
        self.config['exports']['aab']='AAB';self.config['distributions']['google-play']={'export':'aab','track':'production','releaseStatus':'completed','userFraction':None,'language':'en-US','retainVersionCodes':[]};self.config['androidVersionCodePolicy']=policy;self.save_config();self.commit('configure Android')
    def test_configuration_hash_pins_exact_bytes_including_line_endings(self):
        self.prepare();data=(self.repo/'release.json').read_bytes();(self.repo/'release.json').write_bytes(data.replace(b'\n',b'\r\n'))
        self.git('add','release.json');self.git('commit','-qm','config newline only')
        self.assertIn('changed',self.cli('publish','--state-path',self.path,ok=False)['error'])
        self.assertNotEqual(self.journal()['plan']['configSha256'],self.cli('plan','--destination','itch-linux')['configSha256'])
    def test_powershell_hook_is_refused_even_with_a_shell_sibling(self):
        self.write('tools/verify.ps1','# Windows gate\n');self.config['verification']['gate']['script']='tools/verify.ps1';self.save_config();self.commit('PowerShell hook')
        error=self.cli('validate',ok=False)['error'];self.assertIn('tools/verify.ps1',error);self.assertIn('.sh',error);self.assertFalse(self.calls())
    def test_shell_hook_receives_its_configured_arguments_unchanged(self):
        self.config['verification']['standalone']['arguments']=['--artifact-directory','{artifact}','-Platform','{platform}']
        self.write('tools/standalone.sh','#!/bin/sh\ntest "$1" = --artifact-directory && test "$3" = -Platform && test -f "$2/game.x86_64"\n',True);self.save_config();self.commit('shell hook arguments')
        self.prepare();self.assertEqual(self.journal()['checks']['itch-linux']['standalone'],'succeeded')
    def test_android_counter_reserved_once_and_does_not_touch_other_preset(self):
        self.add_android('increment-selected');r=self.cli('prepare','--destination','google-play',ok=False);self.assertEqual(r['status'],'source-update-required')
        self.assertIn('version/code=8',(self.repo/'export_presets.cfg').read_text());self.cli('prepare','--destination','google-play',ok=False);self.assertNotIn('version/code=9',(self.repo/'export_presets.cfg').read_text())
        self.commit('reserve Android code');self.prepare('google-play');self.assertEqual(self.journal()['plan']['destinations'][-1]['versionCode'],8)
    def test_play_hold_requires_fresh_track_review_to_unhold(self):
        self.add_android();self.prepare('google-play');self.cli('hold','--state-path',self.path,'--destination','google-play','--hold-reason','Await review')
        self.cli('unhold','--state-path',self.path,'--destination','google-play',ok=False);self.cli('unhold','--state-path',self.path,'--destination','google-play','--play-track-reviewed')
        self.assertIn('playTrackReviewedAt',self.journal()['destinations']['google-play']['hold'])
    def test_extend_android_retains_original_artifact_source_and_notes(self):
        self.add_android('increment-selected');self.prepare();self.approve();original=self.journal()['artifacts'][0]['sourceCommit'];notes=(self.path/'notes.md').read_bytes()
        r=self.cli('extend','--state-path',self.path,'--destination','google-play',ok=False);self.assertEqual(r['status'],'source-update-required');self.commit('reserve added Android code')
        self.cli('extend','--state-path',self.path,'--destination','google-play');s=self.journal();self.assertEqual(s['artifacts'][0]['sourceCommit'],original);self.assertEqual((self.path/'notes.md').read_bytes(),notes);self.assertEqual(self.calls().count('export'),2)
    def test_older_build_cannot_overwrite_newer_sent_channel(self):
        self.prepare();m=self.load_module();s=self.journal();directory=m.ledger_directory(s['plan'],self.state);directory.mkdir(parents=True)
        old=s['plan']['head'];self.write('feature.txt','new');self.commit('newer');new=self.git('rev-parse','HEAD');self.git('checkout','--detach',old)
        (directory/'sent.json').write_text(json.dumps({'itch:fixture/game:linux':[{'sourceCommit':new,'version':'1.2.4','statePath':str(self.base/'other'),'destination':'itch-linux'}]}))
        self.assertEqual(self.approve(ok=False)['status'],'publication-failed');self.assertNotIn('push',self.calls());self.assertIn('not sent',self.journal()['destinations']['itch-linux']['error'])
    def test_corrupt_ledger_blocks_planning_without_store_calls(self):
        m=self.load_module();s=self.cli('plan','--destination','itch-linux');directory=m.ledger_directory(s,self.state);directory.mkdir(parents=True);(directory/'live.json').write_text('{bad')
        self.assertIn('repair',self.cli('plan','--destination','itch-linux',ok=False)['error']);self.assertFalse(self.calls())
    def test_steam_submission_confirm_receipt_requires_unchanged_approval_and_build_proof(self):
        self.config['distributions']['steam']={'appId':42,'branch':'default','depots':{'43':'linux'}};self.save_config();self.commit('Steam config');self.prepare('steam')
        self.fake('steamcmd','print("Successfully finished AppID 42 build (BuildID 99)")\n');self.env['BA_STEAM_USERNAME']='fixture';self.assertEqual(self.approve(ok=False)['status'],'needs-store-action');status=self.cli('status','--state-path',self.path)
        receipt={'destination':'steam','planId':status['planId'],'notesSha256':status['notesSha256'],'observedAt':'2026-01-01T00:00:00Z','live':True,'appId':42,'buildId':'wrong','branch':'default','announcementUrl':'https://store.steampowered.com/news/app/42/view/123'};file=self.base/'receipt.json';file.write_text(json.dumps(receipt));self.cli('confirm','--state-path',self.path,'--receipt-path',file,ok=False)
        receipt['buildId']='99';file.write_text(json.dumps(receipt));self.assertEqual(self.cli('confirm','--state-path',self.path,'--receipt-path',file)['status'],'published');self.cli('confirm','--state-path',self.path,'--receipt-path',file)
    def test_abandon_requires_authorization_and_marks_only_own_sent_entry(self):
        self.config['distributions']['steam']={'appId':42,'branch':'default','depots':{'43':'linux'}};self.save_config();self.commit('Steam config');self.prepare('steam');self.fake('steamcmd','print("Successfully finished AppID 42 build (BuildID 99)")\n');self.env['BA_STEAM_USERNAME']='fixture';self.approve(ok=False)
        receipt={'destination':'steam','planId':self.journal()['plan']['planId'],'observedAt':'2099-01-01T00:00:00Z','live':False,'evidenceUrl':'https://partner.steamgames.com/apps/builds/42','appId':42,'buildId':'99','branch':'default'};file=self.base/'abandon.json';file.write_text(json.dumps(receipt));self.cli('abandon','--state-path',self.path,'--receipt-path',file,ok=False)
        import datetime;receipt['observedAt']=datetime.datetime.now(datetime.timezone.utc).isoformat();file.write_text(json.dumps(receipt));self.cli('abandon','--state-path',self.path,'--receipt-path',file,ok=False)
        self.assertEqual(self.cli('abandon','--state-path',self.path,'--receipt-path',file,'--abandon-authorized')['status'],'abandoned')
    def test_source_tag_pushes_only_annotated_approved_tag_to_local_fixture(self):
        remote=self.base/'remote.git';subprocess.run(['git','init','--bare','-q',str(remote)],check=True)
        self.config['sourceTag']=True;self.save_config();self.commit('enable tags');self.git('push',str(remote),'HEAD:refs/heads/main');self.git('config','url.'+str(remote)+'.pushInsteadOf','https://github.com/fixture/game.git')
        self.prepare();self.assertEqual(self.approve()['status'],'published');head=self.journal()['plan']['head'];remote_head=subprocess.check_output(['git','--git-dir',str(remote),'rev-parse','v1.2.3^{commit}'],text=True).strip();self.assertEqual(remote_head,head);self.assertEqual(self.git('cat-file','-t','v1.2.3'),'tag')
    def test_source_tag_conflict_stops_before_store_write(self):
        remote=self.base/'remote.git';subprocess.run(['git','init','--bare','-q',str(remote)],check=True)
        self.config['sourceTag']=True;self.save_config();self.commit('enable tags');self.git('push',str(remote),'HEAD:refs/heads/main');self.git('config','url.'+str(remote)+'.pushInsteadOf','https://github.com/fixture/game.git');self.git('tag','v1.2.3','base');self.git('push',str(remote),'refs/tags/v1.2.3')
        self.prepare();self.assertEqual(self.approve(ok=False)['status'],'publication-failed');self.assertNotIn('push',self.calls())
    def test_config_migration_only_adds_store_after_explicit_acknowledgment(self):
        self.prepare();notes=(self.path/'notes.md').read_bytes();self.config['distributions']['steam']={'appId':42,'branch':'default','depots':{'43':'linux'}};self.save_config();self.commit('add Steam only')
        self.cli('extend','--state-path',self.path,'--destination','steam',ok=False);self.cli('extend','--state-path',self.path,'--destination','steam','--migrate-configuration');s=self.journal();self.assertIsNone(s['approval']);self.assertEqual(self.calls().count('export'),1);self.assertEqual(notes,(self.path/'notes.md').read_bytes());self.assertIn('configurationMigration',s['history'][0])
    def test_config_migration_refuses_existing_destination_change(self):
        self.prepare();self.config['distributions']['steam']={'appId':42,'branch':'default','depots':{'43':'linux'}};self.config['distributions']['itch']['game']='other/game';self.save_config();self.commit('unsafe migration')
        self.assertIn('existing destinations',self.cli('extend','--state-path',self.path,'--destination','steam','--migrate-configuration',ok=False)['error'])


    def test_setup_proposes_shell_hooks_beside_powershell_ones(self):
        (self.repo/'release.json').unlink();self.write('tools/verify.ps1','# fixture Windows gate\n');self.write('tools/standalone.ps1','# fixture Windows standalone\n');self.commit('unset config')
        r=self.cli('setup');self.assertEqual(r['configuration']['verification']['gate']['script'],'tools/verify.sh');self.assertEqual(r['configuration']['verification']['standalone']['script'],'tools/standalone.sh')
    def test_migration_then_android_counter_reservation_can_resume_after_commit(self):
        self.add_android('increment-selected');del self.config['exports']['aab'];del self.config['distributions']['google-play'];self.save_config();self.commit('unconfigure Play before release');self.prepare();self.approve()
        self.config['exports']['aab']='AAB';self.config['distributions']['google-play']={'export':'aab','track':'production','releaseStatus':'completed','userFraction':None,'language':'en-US','retainVersionCodes':[]};self.save_config();self.commit('add reviewed Play config only')
        r=self.cli('extend','--state-path',self.path,'--destination','google-play','--migrate-configuration',ok=False);self.assertEqual(r['status'],'source-update-required');self.commit('reserve Android counter');self.cli('extend','--state-path',self.path,'--destination','google-play');self.assertEqual(self.calls().count('export'),2)
    def test_submitted_play_baseline_advances_without_claiming_live(self):
        self.add_android();self.config['distributions']['google-play']['baselineAdvancesOn']='submitted';self.save_config();self.commit('submitted baseline');planned=self.cli('plan','--destination','google-play');m=self.load_module();directory=m.ledger_directory(planned,self.state);directory.mkdir(parents=True);source=self.git('rev-parse','HEAD')
        (directory/'sent.json').write_text(json.dumps({'play:com.fixture.game:production':[{'sourceCommit':source,'version':'1.2.2','submittedAt':'2026-01-01T00:00:00Z'}]}))
        fresh=self.cli('plan','--destination','google-play');self.assertEqual(fresh['baselines']['google-play'],source);self.assertEqual(fresh['previousCommit'],self.git('rev-parse','base'))
    def test_held_notes_preflight_still_blocks_store_writes_when_visibility_private(self):
        self.prepare('itch-linux,notes');self.cli('hold','--state-path',self.path,'--destination','notes','--hold-reason','Publish later');self.fake('gh','import json;print(json.dumps({"private":True,"permissions":{"push":True}}))\n')
        self.assertEqual(self.approve(ok=False)['status'],'publication-failed');self.assertNotIn('push',self.calls());self.assertEqual(self.journal()['destinations']['notes']['status'],'held')
    def test_lock_conflict_refuses_mutation(self):
        import fcntl
        self.prepare()
        with (self.path/'.lock').open('a+b') as stream:
            fcntl.flock(stream,fcntl.LOCK_EX|fcntl.LOCK_NB);self.assertIn('locked',self.cli('hold','--state-path',self.path,'--destination','itch-linux','--hold-reason','later',ok=False)['error'])
    def test_migration_rejects_source_edits_beyond_release_config(self):
        self.prepare();self.config['distributions']['steam']={'appId':42,'branch':'default','depots':{'43':'linux'}};self.save_config();self.write('feature.txt','later source');self.commit('config and source')
        self.assertIn('beyond release.json',self.cli('extend','--state-path',self.path,'--destination','steam','--migrate-configuration',ok=False)['error'])


    def test_timed_out_upload_is_uncertain_and_requires_authorized_retry(self):
        self.prepare();status=self.cli('status','--state-path',self.path);self.fake('butler','import time;time.sleep(10)\n');m=self.load_module();real_run=m.run
        def bounded(executable,args=(),cwd=None,env=None,timeout=600):
            return real_run(executable,args,cwd,env,0.05 if Path(executable).name=='butler' else timeout)
        with patch.dict(os.environ,self.env),patch.object(m,'run',bounded):result=m.publish(self.path,status['planId'],status['notesSha256'])
        self.assertEqual(result['status'],'needs-reconciliation');self.assertEqual(self.journal()['destinations']['itch-linux']['status'],'uncertain')
        before=self.journal()['destinations']['itch-linux']['attempts'];self.cli('publish','--state-path',self.path,ok=False);self.assertEqual(self.journal()['destinations']['itch-linux']['attempts'],before)


    def test_duplicate_resolved_itch_channels_rejected_before_any_export_or_upload(self):
        self.write('export_presets.cfg',(self.repo/'export_presets.cfg').read_text()+'[preset.2]\nname="Alternate"\nplatform="Linux"\nexport_path="build/alternate.x86_64"\n[preset.2.options]\n')
        self.config['exports']['alternate']='Alternate';self.config['distributions']['itch']['channels']['alternate']={'export':'alternate','channel':'linux'};self.save_config();self.commit('colliding remote payloads')
        self.assertIn('distinct',self.cli('validate',ok=False)['error']);self.cli('prepare','--destination','itch-linux',ok=False);self.assertFalse(self.calls())
    def test_patch_preparation_uses_current_live_version_boundary(self):
        self.config['previousRelease']=None;self.save_config();self.commit('use ledger baseline');m=self.load_module();settings=m.configuration(self.repo);directory=m.ledger_directory(settings,self.state);directory.mkdir(parents=True);head=self.git('rev-parse','HEAD')
        (directory/'live.json').write_text(json.dumps({'itch:fixture/game:linux':{'sourceCommit':head,'version':'1.2.3'}}))
        preview=self.cli('plan','--destination','itch-linux','--version-change','patch',ok=False);self.assertTrue(preview['configurationReady']);self.assertEqual(preview['previousCommit'],head)
        result=self.cli('prepare','--destination','itch-linux','--version-change','patch',ok=False);self.assertEqual(result['status'],'source-update-required');self.assertIn('1.2.4',(self.repo/'project.godot').read_text())
    def test_new_release_patch_reservation_uses_current_live_version_boundary(self):
        self.prepare();self.approve();self.config['previousRelease']=None;self.save_config();self.commit('use confirmed live baseline')
        result=self.cli('prepare','--destination','itch-linux','--version-change','patch','--new-release',ok=False);self.assertEqual(result['status'],'source-update-required')
    def test_setup_add_play_retains_discovered_alias_and_existing_store_settings(self):
        self.add_android();del self.config['exports']['aab'];del self.config['distributions']['google-play'];self.save_config();self.commit('existing unconfigured AAB');report=self.cli('setup');answers=self.base/'add-play.json';answers.write_text(json.dumps({'stores':['itch','notes','google-play']}))
        result=self.cli('setup','--answers-path',answers,'--expected-config-sha256',report['configSha256']);updated=result['report']['configuration'];self.assertEqual(updated['exports']['aab'],'AAB');self.assertEqual(updated['distributions']['google-play']['export'],'aab');self.assertEqual(updated['distributions']['itch'],self.config['distributions']['itch']);self.assertEqual(updated['verification'],self.config['verification'])
    def test_setup_add_itch_discovers_existing_apk_alias(self):
        self.write('export_presets.cfg',(self.repo/'export_presets.cfg').read_text()+'[preset.1]\nname="APK"\nplatform="Android"\nexport_path="build/game.apk"\n[preset.1.options]\ngradle_build/use_gradle_build=false\ngradle_build/export_format=0\nversion/code=7\nversion/name="1.2.3"\npackage/unique_name="com.fixture.game"\npackage/signed=true\n');del self.config['distributions']['itch'];self.save_config();self.commit('unconfigured itch APK');report=self.cli('setup');answers=self.base/'add-itch.json';answers.write_text(json.dumps({'stores':['notes','itch']}))
        result=self.cli('setup','--answers-path',answers,'--expected-config-sha256',report['configSha256']);updated=result['report']['configuration'];self.assertEqual(updated['exports']['apk'],'APK');self.assertEqual(updated['distributions']['itch']['channels']['android'],'apk')
    def test_committed_android_reservation_revert_is_rejected_without_source_write(self):
        self.add_android('increment-selected');original=self.git('rev-parse','HEAD');m=self.load_module();directory=self.state/'reservation';settings=m.configuration(self.repo);planned=m.plan(self.repo,['google-play'],self.state)
        result=m.reserve_source(settings,planned,directory);self.assertEqual(result['status'],'source-update-required');self.commit('reserve counter');settings=m.configuration(self.repo);planned=m.plan(self.repo,['google-play'],self.state);self.assertEqual(m.reserve_source(settings,planned,directory)['status'],'source-committed')
        self.git('restore','--source',original,'--','export_presets.cfg');self.commit('explicitly revert counter');before=(self.repo/'export_presets.cfg').read_bytes();settings=m.configuration(self.repo);planned=m.plan(self.repo,['google-play'],self.state)
        with self.assertRaisesRegex(m.ReleaseError,'reverted'):m.reserve_source(settings,planned,directory)
        self.assertEqual((self.repo/'export_presets.cfg').read_bytes(),before);self.assertEqual(self.git('status','--porcelain'),'')


    def original_protocol_config(self,play=False,steam=False,display=None):
        if play:self.add_android()
        if steam:self.config['distributions']['steam']={'appId':42,'branch':'default','depots':{'43':'linux'}}
        if display:self.config['distributions']['itch']['displayNameTemplate']='{title} {version} ({os})'
        self.save_config();self.git('add','.');self.git('commit','-q','--allow-empty','-m','original protocol configuration')
    def test_original_protocol_matches_exact_plan_identity_actions_and_order(self):
        from original_protocol import plan_fixture,json_text
        self.original_protocol_config(play=True,steam=True,display=True);expected=plan_fixture(self.repo,['google-play','itch-linux','steam'],True,True,'Fixture 1.2.3 (Linux)');actual=self.cli('plan','--destination','steam,itch-linux,google-play')
        self.assertEqual(actual,expected)
        self.assertEqual(list(actual),list(expected));self.assertEqual(actual['planId'],expected['planId'])
    def test_original_protocol_single_artifact_approval_survives_status_hold_and_publish(self):
        from original_protocol import plan_fixture,journal_fixture
        self.original_protocol_config();planned=plan_fixture(self.repo,['itch-linux']);self.path,state=journal_fixture(self.state,planned);original_approval=state['approval'].copy();status=self.cli('status','--state-path',self.path);self.assertEqual(status['notesSha256'],original_approval['notesSha256'])
        self.cli('hold','--state-path',self.path,'--destination','itch-linux','--hold-reason','Original hold');self.assertEqual(self.cli('publish','--state-path',self.path,ok=False)['status'],'on-hold');self.assertEqual(self.journal()['approval'],original_approval);self.assertNotIn('push',self.calls())
        self.cli('unhold','--state-path',self.path,'--destination','itch-linux');self.assertEqual(self.cli('publish','--state-path',self.path)['status'],'published');self.assertEqual(self.journal()['approval'],original_approval);self.assertEqual(self.calls().count('push'),1)
    def test_original_protocol_empty_artifact_approval_remains_awaiting_release(self):
        from original_protocol import plan_fixture,journal_fixture
        self.original_protocol_config();self.path,state=journal_fixture(self.state,plan_fixture(self.repo,['notes']));self.assertEqual(self.cli('publish','--state-path',self.path,ok=False)['status'],'awaiting-release');self.assertEqual(self.journal()['approval'],state['approval']);self.assertFalse(self.calls())
    def test_original_protocol_legacy_android_derived_flag_completion_preserves_approval_and_uncertainty(self):
        from original_protocol import plan_fixture,journal_fixture
        self.original_protocol_config(play=True);planned=plan_fixture(self.repo,['google-play'],True);self.path,state=journal_fixture(self.state,planned,{'google-play':{'status':'uncertain','attempts':2,'remote':{'editId':'original-edit','phase':'committing','versionCode':7}}})
        for collection in ['exports','requiredExports']:
            for preset in state['plan'][collection]:preset.pop('useGradle',None)
        self.save_journal(state);before=copy.deepcopy(state);self.assertEqual(self.cli('publish','--state-path',self.path,ok=False)['status'],'needs-reconciliation');after=self.journal();self.assertTrue(after['plan']['requiredExports'][0]['useGradle']);self.assertEqual(after['approval'],before['approval']);self.assertEqual(after['destinations'],before['destinations']);self.assertEqual(after['artifacts'],before['artifacts']);self.assertFalse(self.calls())
    def test_original_protocol_legacy_completion_never_hides_changed_approved_field(self):
        from original_protocol import plan_fixture,journal_fixture
        self.original_protocol_config(play=True);self.path,state=journal_fixture(self.state,plan_fixture(self.repo,['google-play'],True))
        for collection in ['exports','requiredExports']:
            for preset in state['plan'][collection]:preset.pop('useGradle',None)
        state['plan']['destinations'][-1]['track']='internal';self.save_journal(state);before=(self.path/'state.json').read_bytes();self.assertIn('plan',self.cli('publish','--state-path',self.path,ok=False)['error']);self.assertEqual((self.path/'state.json').read_bytes(),before)
    def test_original_protocol_steam_confirmation_preserves_original_approval(self):
        from original_protocol import plan_fixture,journal_fixture
        self.original_protocol_config(steam=True);self.path,state=journal_fixture(self.state,plan_fixture(self.repo,['steam'],with_steam=True),{'steam':{'status':'awaiting-store-action','attempts':1,'remote':{'phase':'build-uploaded','buildId':'99'}}});status=self.cli('status','--state-path',self.path)
        receipt={'destination':'steam','planId':state['plan']['planId'],'notesSha256':status['notesSha256'],'observedAt':'2026-01-01T00:00:00Z','live':True,'appId':42,'buildId':'99','branch':'default','announcementUrl':'https://store.steampowered.com/news/app/42/view/123'};file=self.base/'original-receipt.json';file.write_text(json.dumps(receipt));self.assertEqual(self.cli('confirm','--state-path',self.path,'--receipt-path',file)['status'],'published');self.assertEqual(self.journal()['approval'],state['approval']);self.assertFalse(self.calls())
    def test_original_windows_checkout_pin_read_and_hold_do_not_rewrite_path(self):
        from original_protocol import plan_fixture,journal_fixture
        self.original_protocol_config();pin='C:\\Users\\Fixture\\Game';self.path,state=journal_fixture(self.state,plan_fixture(self.repo,['itch-linux'],repository_pin=pin));status=self.cli('status','--state-path',self.path);self.assertEqual(status['plan']['repository'],pin)
        self.cli('hold','--state-path',self.path,'--destination','itch-linux','--hold-reason','Preserve original source');self.assertEqual(self.journal()['plan'],state['plan']);self.assertEqual(self.journal()['approval'],state['approval']);self.cli('publish','--state-path',self.path,ok=False);self.assertEqual(self.journal()['plan']['repository'],pin);self.assertFalse(self.calls())


    def test_signal_cancellation_of_native_release_cleans_its_owned_export_process_group(self):
        import signal,time
        pidfile=self.base/'export.pid';self.env['FIXTURE_CHILD_PID']=str(pidfile);self.fake('godot','import os,time,pathlib\npathlib.Path(os.environ["FIXTURE_CHILD_PID"]).write_text(str(os.getpid()))\nwhile True:time.sleep(.1)\n')
        process=subprocess.Popen([str(SCRIPT),'--mode','prepare','--repository',str(self.repo),'--state-root',str(self.state),'--destination','itch-linux'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=self.env,start_new_session=True)
        try:
            deadline=time.monotonic()+3
            while not pidfile.exists() and time.monotonic()<deadline:time.sleep(.01)
            self.assertTrue(pidfile.exists(),'Fixture export did not start');process.send_signal(signal.SIGTERM);output,errors=process.communicate(timeout=3);self.assertNotEqual(process.returncode,0)
            pid=int(pidfile.read_text());stat=Path('/proc')/str(pid)/'stat';self.assertTrue(process_stopped(pid),'Cancelled native release orphaned its export process')
        finally:
            if process.poll() is None:os.killpg(process.pid,signal.SIGKILL);process.communicate(timeout=1)
            if pidfile.exists():
                try:os.killpg(int(pidfile.read_text()),signal.SIGKILL)
                except ProcessLookupError:pass


    def test_original_protocol_multiple_artifact_approval_preserves_hold_and_order(self):
        from original_protocol import plan_fixture,journal_fixture
        self.original_protocol_config(play=True);self.path,state=journal_fixture(self.state,plan_fixture(self.repo,['itch-linux','google-play'],True))
        self.cli('hold','--state-path',self.path,'--destination','itch-linux,google-play','--hold-reason','Original release delayed');result=self.cli('publish','--state-path',self.path,ok=False);self.assertEqual(result['status'],'on-hold');self.assertEqual(self.journal()['approval'],state['approval']);self.assertEqual(self.journal()['artifacts'],state['artifacts']);self.assertFalse(self.calls())
    def test_original_protocol_uncertain_retry_requires_authorization_and_never_reapproves(self):
        from original_protocol import plan_fixture,journal_fixture
        self.original_protocol_config();self.path,state=journal_fixture(self.state,plan_fixture(self.repo,['itch-linux']),{'itch-linux':{'status':'uncertain','attempts':1,'remote':{'phase':'pushing'}}});self.assertEqual(self.cli('publish','--state-path',self.path,ok=False)['status'],'needs-reconciliation');self.assertFalse(self.calls())
        self.assertEqual(self.cli('publish','--state-path',self.path,'--retry-uncertain')['status'],'published');self.assertEqual(self.calls().count('push'),1);self.assertEqual(self.journal()['approval'],state['approval']);self.cli('publish','--state-path',self.path);self.assertEqual(self.calls().count('push'),1)
    def test_native_legacy_derived_flag_completion_keeps_existing_approval(self):
        self.add_android();self.prepare('google-play');self.cli('hold','--state-path',self.path,'--destination','google-play','--hold-reason','Do not contact Play');self.approve(ok=False);state=self.journal();approval=copy.deepcopy(state['approval'])
        for collection in ['exports','requiredExports']:
            for preset in state['plan'][collection]:preset.pop('useGradle',None)
        self.save_journal(state);self.assertEqual(self.cli('publish','--state-path',self.path,ok=False)['status'],'on-hold');self.assertEqual(self.journal()['approval'],approval);self.assertTrue(self.journal()['plan']['requiredExports'][0]['useGradle'])
    def test_original_legacy_completion_does_not_save_when_artifacts_changed(self):
        from original_protocol import plan_fixture,journal_fixture
        self.original_protocol_config(play=True);self.path,state=journal_fixture(self.state,plan_fixture(self.repo,['google-play'],True))
        for collection in ['exports','requiredExports']:
            for preset in state['plan'][collection]:preset.pop('useGradle',None)
        self.save_journal(state);before=(self.path/'state.json').read_bytes();(self.path/state['artifacts'][0]['files'][0]['path']).write_text('tampered')
        self.assertIn('artifact',self.cli('publish','--state-path',self.path,ok=False)['error']);self.assertEqual((self.path/'state.json').read_bytes(),before)
    def test_signal_cancelled_upload_records_uncertain_before_exiting_and_skips_later_writes(self):
        import signal,time
        self.prepare('itch-linux,notes');status=self.cli('status','--state-path',self.path);pidfile=self.base/'upload.pid';self.env['FIXTURE_CHILD_PID']=str(pidfile);self.fake('butler','import os,time,pathlib\npathlib.Path(os.environ["FIXTURE_CHILD_PID"]).write_text(str(os.getpid()))\nwhile True:time.sleep(.1)\n')
        process=subprocess.Popen([str(SCRIPT),'--mode','publish','--state-path',str(self.path),'--approved-plan-id',status['planId'],'--approved-notes-sha256',status['notesSha256']],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=self.env,start_new_session=True)
        try:
            deadline=time.monotonic()+3
            while not pidfile.exists() and time.monotonic()<deadline:time.sleep(.01)
            self.assertTrue(pidfile.exists());process.send_signal(signal.SIGTERM);process.communicate(timeout=3);self.assertNotEqual(process.returncode,0);self.assertEqual(self.journal()['destinations']['itch-linux']['status'],'uncertain');self.assertEqual(self.journal()['status'],'needs-reconciliation');self.assertNotIn('github-put',self.calls());pid=int(pidfile.read_text());stat=Path('/proc')/str(pid)/'stat';self.assertTrue(process_stopped(pid))
        finally:
            if process.poll() is None:os.killpg(process.pid,signal.SIGKILL);process.communicate(timeout=1)
            if pidfile.exists():
                try:os.killpg(int(pidfile.read_text()),signal.SIGKILL)
                except ProcessLookupError:pass


    def test_original_protocol_preparation_resume_preserves_exports_approval_and_legacy_derived_completion(self):
        from original_protocol import plan_fixture,journal_fixture
        self.original_protocol_config(play=True);self.path,state=journal_fixture(self.state,plan_fixture(self.repo,['google-play'],True))
        for collection in ['exports','requiredExports']:
            for preset in state['plan'][collection]:preset.pop('useGradle',None)
        self.save_journal(state);result=self.cli('prepare','--destination','google-play');self.assertEqual(result['status'],'prepared');self.assertEqual(self.journal()['approval'],state['approval']);self.assertEqual(self.journal()['artifacts'],state['artifacts']);self.assertFalse(self.calls())


    def test_original_legacy_flag_completion_handles_one_collection_without_hiding_other_metadata(self):
        from original_protocol import plan_fixture,journal_fixture
        self.original_protocol_config(play=True);self.path,state=journal_fixture(self.state,plan_fixture(self.repo,['google-play'],True));state['plan']['exports'][-1].pop('useGradle');state['destinations']['google-play'].update(status='held',hold={'reason':'Do not publish','heldAt':'2026-01-01T00:00:00Z'});self.save_journal(state)
        self.assertEqual(self.cli('publish','--state-path',self.path,ok=False)['status'],'on-hold');after=self.journal();self.assertTrue(after['plan']['exports'][-1]['useGradle']);self.assertTrue(after['plan']['requiredExports'][0]['useGradle']);self.assertEqual(after['approval'],state['approval'])
    def test_original_windows_pin_can_confirm_observed_steam_result_without_rebasing_source(self):
        from original_protocol import plan_fixture,journal_fixture
        self.original_protocol_config(steam=True);pin='C:\\Users\\Fixture\\Original Game';planned=plan_fixture(self.repo,['steam'],with_steam=True,repository_pin=pin);self.path,state=journal_fixture(self.state,planned,{'steam':{'status':'awaiting-store-action','attempts':1,'remote':{'phase':'build-uploaded','buildId':'99'}}})
        receipt={'destination':'steam','planId':planned['planId'],'notesSha256':state['approval']['notesSha256'],'observedAt':'2026-01-01T00:00:00Z','live':True,'appId':42,'buildId':'99','branch':'default','announcementUrl':'https://store.steampowered.com/news/app/42/view/123'};file=self.base/'original-windows-receipt.json';file.write_text(json.dumps(receipt));self.assertEqual(self.cli('confirm','--state-path',self.path,'--receipt-path',file)['status'],'published');self.assertEqual(self.journal()['plan'],planned);self.assertEqual(self.journal()['approval'],state['approval']);self.assertFalse(self.calls())

if __name__=='__main__':unittest.main()

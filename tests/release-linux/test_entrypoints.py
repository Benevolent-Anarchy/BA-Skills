import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from process_fixture import process_stopped
ROOT=Path(__file__).resolve().parents[2]
SCRIPTS=ROOT/'skills/ba-release/scripts'
class EntryPointTests(unittest.TestCase):
    def test_discovery_uses_bounded_protocol_inventories_without_prompts(self):
        with tempfile.TemporaryDirectory(prefix='BA discovery space ') as temporary:
            directory=Path(temporary);binary=directory/'bin';binary.mkdir()
            codex=binary/'codex';codex.write_text('''#!/usr/bin/env python3
import sys,json
for line in sys.stdin:
 m=json.loads(line)
 if m.get('method')=='initialize':print(json.dumps({'id':1,'result':{}}),flush=True)
 if m.get('method')=='skills/list':print(json.dumps({'id':2,'result':{'data':[{'skills':[{'name':'ba-release','enabled':True,'path':'fixture/SKILL.md','scope':'user'}]}]}}),flush=True)
''');codex.chmod(0o755)
            claude=binary/'claude';claude.write_text('''#!/usr/bin/env python3
import sys,json
m=json.loads(sys.stdin.readline());assert m['request']['subtype']=='initialize'
print(json.dumps({'type':'control_response','response':{'request_id':'ba-release-discovery','subtype':'success','response':{'commands':[{'name':'ba-release','description':'Fixture'}]}}}),flush=True)
for line in sys.stdin:pass
''');claude.chmod(0o755)
            env=dict(os.environ,PATH=str(binary)+os.pathsep+os.environ['PATH']);result=subprocess.run([str(SCRIPTS/'verify-discovery.sh'),'--directory',directory,'--timeout-seconds','2'],capture_output=True,text=True,env=env)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr);data=json.loads(result.stdout);self.assertEqual(len(data['results']),2);self.assertFalse(data['errors'])
    def test_discovery_timeout_is_failure_and_does_not_leave_child(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory=Path(temporary);binary=directory/'bin';binary.mkdir()
            for name in ['codex','claude']:
                p=binary/name;p.write_text('#!/bin/sh\nsleep 10\n');p.chmod(0o755)
            env=dict(os.environ,PATH=str(binary)+os.pathsep+os.environ['PATH']);result=subprocess.run([str(SCRIPTS/'verify-discovery.sh'),'--directory',directory,'--timeout-seconds','0.05'],capture_output=True,text=True,env=env,timeout=3)
            self.assertNotEqual(result.returncode,0);self.assertEqual(len(json.loads(result.stdout)['errors']),2)
    def test_release_installer_registers_both_native_agent_targets(self):
        with tempfile.TemporaryDirectory(prefix='release install ü ') as temporary:
            result=subprocess.run([str(SCRIPTS/'install.sh'),'--home',temporary],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            for agent in ['.agents','.claude']:self.assertEqual((Path(temporary)/agent/'skills/ba-release').resolve(),(ROOT/'skills/ba-release').resolve())
    def test_auth_cli_rejects_missing_explicit_action(self):
        result=subprocess.run([str(SCRIPTS/'google-play-auth.sh'),'--account','fixture@example.invalid','--service-account','tester@project.iam.gserviceaccount.com','--gcloud-config-directory','/missing'],capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)

    def test_discovery_kills_descendants_after_launcher_exit_without_unbounded_drain(self):
        import time
        with tempfile.TemporaryDirectory() as temporary:
            directory=Path(temporary);binary=directory/'bin';binary.mkdir();pids=[]
            for name in ['codex','claude']:
                pidfile=directory/(name+'.pid');p=binary/name;p.write_text('#!/bin/sh\nsleep 10 &\necho $! > "'+str(pidfile)+'"\nexit 0\n');p.chmod(0o755)
            env=dict(os.environ,PATH=str(binary)+os.pathsep+os.environ['PATH']);start=time.monotonic()
            process=subprocess.Popen([str(SCRIPTS/'verify-discovery.sh'),'--directory',directory,'--timeout-seconds','0.05'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env,start_new_session=True)
            try:
                try:output,errors=process.communicate(timeout=1)
                except subprocess.TimeoutExpired:self.fail('Discovery lost its deadline after the launcher exited with inherited stdout held open.')
                self.assertLess(time.monotonic()-start,1);self.assertNotEqual(process.returncode,0);self.assertEqual(len(json.loads(output)['errors']),2)
                for pidfile in directory.glob('*.pid'):
                    pid=int(pidfile.read_text());stat=Path('/proc')/str(pid)/'stat';self.assertTrue(process_stopped(pid),'Discovery descendant survived cleanup')
            finally:
                if process.poll() is None:process.kill();process.communicate(timeout=1)
                for pidfile in directory.glob('*.pid'):
                    try:os.kill(int(pidfile.read_text()),9)
                    except ProcessLookupError:pass

if __name__=='__main__':unittest.main()

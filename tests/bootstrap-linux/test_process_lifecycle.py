"""Real process-group cancellation probes, without SDKs, services or user state."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
ROOT=Path(__file__).resolve().parents[2]
BOOTSTRAP=ROOT/'skills/ba-bootstrap/scripts/bootstrap_linux.py'
GATE=ROOT/'skills/ba-bootstrap/assets/project/tools/verify_linux.py'

def alive(pid):
    try: return Path(f'/proc/{pid}/stat').read_text().split(') ',1)[1][0]!='Z'
    except FileNotFoundError: return False

class ProcessLifecycle(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='process lifecycle ü '); self.addCleanup(self.tmp.cleanup); self.root=Path(self.tmp.name); self.groups=[]; self.drivers=[]
    def tearDown(self):
        for group in self.groups:
            try: os.killpg(group,signal.SIGKILL)
            except ProcessLookupError: pass
        for driver in self.drivers:
            if driver.poll() is None: driver.kill()
            driver.communicate()
    def fixture(self,mode):
        script=self.root/'native fixture.sh'; script.write_text('#!/usr/bin/env bash\n'+("trap '' TERM\n" if mode=='ignore-term' else '')+('trap \'echo graceful > "$1/graceful"; exit 0\' TERM\n' if mode=='graceful' else '')+'sleep 60 &\nprintf "%s %s\\n" "$$" "$!" > "$1/pids"\n'+('exit 0\n' if mode=='leader-exit' else 'wait\n')); return script
    def driver(self,module,script,timeout=30,nested=False):
        driver=self.root/('driver-'+str(len(self.drivers))+'.py')
        module=GATE if module=='gate' else BOOTSTRAP
        args=['bash',str(script),str(self.root)]
        if nested:
            middle=self.root/'nested gate.py'; middle.write_text(self.driver_source(GATE,args,30)); args=[sys.executable,str(middle)]
        driver.write_text(self.driver_source(module,args,timeout)); child=subprocess.Popen([sys.executable,str(driver)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True); self.drivers.append(child)
        deadline=time.monotonic()+4
        while not (self.root/'pids').exists() and child.poll() is None and time.monotonic()<deadline: time.sleep(.01)
        self.assertTrue((self.root/'pids').exists(),'native subprocess did not start')
        pids=[int(p) for p in (self.root/'pids').read_text().split()]; self.groups.append(pids[0]); return child,pids
    def driver_source(self,module,args,timeout):
        return '\n'.join(['import importlib.util,json,sys',f'spec=importlib.util.spec_from_file_location("probe",{str(module)!r})','module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)',f'args={args!r}', 'try:',f'    module.process(args,{str(self.root)!r},timeout={timeout})' if module==GATE else f'    module.command(args,cwd={str(self.root)!r},timeout={timeout})','except Exception as exc:', '    print(json.dumps({"error":str(exc)})); sys.exit(1)'])+'\n'
    def assert_stopped(self,pids):
        deadline=time.monotonic()+2
        while any(alive(pid) for pid in pids) and time.monotonic()<deadline: time.sleep(.01)
        self.assertFalse([pid for pid in pids if alive(pid)],'owned subprocesses survived cancellation')
    def test_sigterm_cleans_native_children_for_bootstrap_and_generated_gate(self):
        for module in ('bootstrap','gate'):
            with self.subTest(module=module):
                (self.root/'pids').unlink(missing_ok=True)
                child,pids=self.driver(module,self.fixture('waiting')); child.send_signal(signal.SIGTERM); output,_=child.communicate(timeout=6)
                self.assertNotEqual(child.returncode,0,output); self.assert_stopped(pids)
    def test_sigterm_cleans_group_after_leader_has_exited_and_descendant_holds_stdout(self):
        child,pids=self.driver('gate',self.fixture('leader-exit')); time.sleep(.1); child.send_signal(signal.SIGTERM); output,_=child.communicate(timeout=6)
        self.assertNotEqual(child.returncode,0,output); self.assert_stopped(pids)
    def test_timeout_allows_native_term_cleanup_before_forced_kill(self):
        child,pids=self.driver('bootstrap',self.fixture('graceful'),timeout=.2); output,_=child.communicate(timeout=6)
        self.assertNotEqual(child.returncode,0,output); self.assertIn('timed out',output); self.assertTrue((self.root/'graceful').exists(),'native TERM cleanup did not run'); self.assert_stopped(pids)
    def test_outer_bootstrap_cancellation_propagates_through_nested_native_gate(self):
        child,pids=self.driver('bootstrap',self.fixture('waiting'),nested=True); child.send_signal(signal.SIGTERM); output,_=child.communicate(timeout=7)
        self.assertNotEqual(child.returncode,0,output); self.assert_stopped(pids)
    def test_timeout_forces_ignoring_nested_native_children_to_exit(self):
        child,pids=self.driver('bootstrap',self.fixture('ignore-term'),timeout=.2,nested=True)
        output,_=child.communicate(timeout=6)
        self.assertNotEqual(child.returncode,0,output); self.assertIn('timed out',output); self.assert_stopped(pids)
    def test_sigint_cleans_native_children(self):
        child,pids=self.driver('gate',self.fixture('waiting')); child.send_signal(signal.SIGINT)
        output,_=child.communicate(timeout=6); self.assertNotEqual(child.returncode,0,output); self.assert_stopped(pids)
if __name__=='__main__': unittest.main()

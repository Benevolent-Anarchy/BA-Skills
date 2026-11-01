import importlib.util
import json
import sys
from pathlib import Path
import tempfile
import unittest
sys.dont_write_bytecode=True
ROOT = Path(__file__).resolve().parents[2]
GATE = ROOT/'skills/ba-bootstrap/assets/project/tools/verify_linux.py'
class GateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not GATE.exists(): raise AssertionError('native generated project gate missing')
        spec=importlib.util.spec_from_file_location('verify_linux',GATE); cls.g=importlib.util.module_from_spec(spec); spec.loader.exec_module(cls.g)
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='gate space ü '); self.addCleanup(self.tmp.cleanup); self.root=Path(self.tmp.name)
    def test_junit_requires_executed_cases_and_correct_counts(self):
        p=self.root/'x.xml'
        for text in ['<testsuites tests="0" failures="0" errors="0"/>','<testsuites tests="1" failures="0" errors="0"><testsuite><testcase><skipped/></testcase></testsuite></testsuites>','<testsuites tests="2" failures="0" errors="0"><testsuite><testcase/></testsuite></testsuites>']:
            p.write_text(text)
            with self.assertRaises(ValueError): self.g.junit(p)
        p.write_text('<testsuites tests="1" failures="0" errors="0"><testsuite><testcase/></testsuite></testsuites>'); self.assertEqual(self.g.junit(p),1)
    def test_gut_rejects_missing_assertions_and_orphans(self):
        p=self.root/'totals.json'
        p.write_text(json.dumps(dict(hookComplete=True,failed=False,scripts=1,tests=1,asserts=0,seconds=0)))
        with self.assertRaises(ValueError): self.g.gut_totals(p,1)
        p.write_text(json.dumps(dict(hookComplete=True,failed=True,scripts=1,tests=1,asserts=1,seconds=0)))
        with self.assertRaises(ValueError): self.g.gut_totals(p,1)
    def test_tauri_release_requires_direct_dependency_and_stable_family(self):
        data={'resolve':{'root':'app','nodes':[{'id':'app','deps':[{'name':'tauri','pkg':'tauri'}]}]},'packages':[{'id':'tauri','name':'tauri','version':'2.5.0'}]}
        self.g.tauri_release(data,'2.4.0')
        with self.assertRaises(ValueError): self.g.tauri_release(data,'2.4.0',True)
        with self.assertRaises(ValueError): self.g.tauri_release(data,'3.0.0')
    def test_documentation_finds_broken_links_without_reading_code_examples(self):
        (self.root/'docs').mkdir()
        for name in ['DESIGN','DECISIONS','JUDGEMENTS']:
            (self.root/f'docs/{name.lower()}').mkdir(); (self.root/f'docs/{name}.md').write_text('# '+name+'\n\n## Index\n')
        (self.root/'README.md').write_text('# Title\n\n`[ignored](no.md)`\n\n[bad](missing.md)\n')
        result=self.g.documentation(self.root)
        self.assertFalse(result['Passed']); self.assertEqual(len(result['Diagnostics']),1,result)
    def test_process_failure_is_never_passed(self):
        with self.assertRaises(RuntimeError): self.g.process(['bash','-c','exit 9'],self.root)
    def test_process_timeout_is_failure(self):
        with self.assertRaises(RuntimeError): self.g.process(['bash','-c','sleep 2'],self.root,timeout=.05)
class NativeGateStages(unittest.TestCase):
    setUpClass=GateTests.__dict__['setUpClass']
    setUp=GateTests.setUp
    def test_tauri_complete_dispatch_checks_junit_and_application_binary(self):
        import hashlib
        config={'schemaVersion':1,'preset':'tauri','requiredChecks':['documentation','typescript','frontend-tests','frontend-build','rust-format','rust-lint','rust-tests','tauri-build'],'tauri':{'selectedRelease':'2.5.0','crateName':'test-app'}}
        files={'tools/verify.json':json.dumps(config),'package.json':json.dumps({'name':'test-app','version':'1.0.0','devDependencies':{}}),'package-lock.json':json.dumps({'lockfileVersion':3,'packages':{'':{'name':'test-app','version':'1.0.0','devDependencies':{}}}}),'src-tauri/Cargo.toml':'[package]\nname = "test-app"','src-tauri/Cargo.lock':'version = 4'}
        for name,text in files.items():
            path=self.root/name; path.parent.mkdir(parents=True,exist_ok=True); path.write_text(text)
        (self.root/'node_modules').mkdir(); (self.root/'docs').mkdir()
        for name in ('design','decisions','judgements'):
            (self.root/'docs'/name).mkdir(); (self.root/'docs'/(name.upper()+'.md')).write_text('# Index\n\n## Index\n')
        calls=[]; output={'empty':False,'binary':True}
        def runner(args,cwd,env=None):
            calls.append(args)
            if args[:2]==['cargo','metadata']: return json.dumps({'resolve':{'root':'app','nodes':[{'id':'app','deps':[{'name':'tauri','pkg':'tauri'}]}]},'packages':[{'id':'tauri','name':'tauri','version':'2.5.0'}]})
            if (env or {}).get('BA_TAURI_STAGE')=='frontend-tests': Path(env['BA_TAURI_RESULTS']).write_text('<testsuites tests="0" failures="0" errors="0"/>' if output['empty'] else '<testsuites tests="1" failures="0" errors="0"><testsuite><testcase/></testsuite></testsuites>')
            if (env or {}).get('BA_TAURI_STAGE')=='tauri-build' and output['binary']:
                binary=self.root/'src-tauri/target/release/test-app'; binary.parent.mkdir(parents=True,exist_ok=True); binary.write_bytes(b'fixture app binary')
            return ''
        result=self.g.verify(self.root,True,runner); self.assertTrue(result['Passed'],result)
        self.assertEqual([s['Name'] for s in result['Stages']],config['requiredChecks'])
        output['empty']=True; result=self.g.verify(self.root,True,runner); self.assertFalse(result['Passed']); self.assertTrue(any(s['Name']=='frontend-tests' and not s['Passed'] for s in result['Stages']))
        output.update(empty=False,binary=False); (self.root/'src-tauri/target/release/test-app').unlink(); result=self.g.verify(self.root,True,runner); self.assertFalse(result['Passed']); self.assertTrue(any('application binary' in d for d in result['Diagnostics']))

if __name__=='__main__': unittest.main()

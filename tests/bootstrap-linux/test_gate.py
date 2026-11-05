import importlib.util
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest
from unittest import mock
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
        self.assertEqual([s['Name'] for s in result['Stages']],['documentation','git-lfs-pointers',*config['requiredChecks'][1:]])
        self.assertEqual(result['Stages'][1]['NotChecked'],'this is not a Git checkout')
        output['empty']=True; result=self.g.verify(self.root,True,runner); self.assertFalse(result['Passed']); self.assertTrue(any(s['Name']=='frontend-tests' and not s['Passed'] for s in result['Stages']))
        output.update(empty=False,binary=False); (self.root/'src-tauri/target/release/test-app').unlink(); result=self.g.verify(self.root,True,runner); self.assertFalse(result['Passed']); self.assertTrue(any('application binary' in d for d in result['Diagnostics']))

LFS_FILTER=[('filter.lfs.clean','git-lfs clean -- %f'),('filter.lfs.smudge','git-lfs smudge -- %f'),('filter.lfs.process','git-lfs filter-process'),('filter.lfs.required','true')]
LFS_RULE='*.png filter=lfs diff=lfs merge=lfs -text\n'
PLAIN=Path('assets/plaster wall/base colour.png')
NEEDS_GIT_LFS=unittest.skipUnless(shutil.which('git-lfs'),'git-lfs is not installed, so the fixture cannot make pointers')
class GitLfsPointers(unittest.TestCase):
    """The gate checks LFS pointers at HEAD only in a Git checkout of the project that has a committed filter=lfs rule."""
    setUpClass=GateTests.__dict__['setUpClass']
    def setUp(self):
        GateTests.setUp(self)
        environment={'GIT_CONFIG_GLOBAL':os.devnull,'GIT_CONFIG_NOSYSTEM':'1','GIT_ATTR_NOSYSTEM':'1','XDG_CONFIG_HOME':str(self.root/'no config'),'GIT_AUTHOR_NAME':'Gate','GIT_AUTHOR_EMAIL':'gate@example.invalid','GIT_COMMITTER_NAME':'Gate','GIT_COMMITTER_EMAIL':'gate@example.invalid'}
        patcher=mock.patch.dict(os.environ,environment); patcher.start(); self.addCleanup(patcher.stop)
        self.project=self.root/'project ü'; self.project.mkdir()
    def git(self,*args,at=None):
        return subprocess.run(['git','-C',str(at or self.project),*args],check=True,capture_output=True,text=True).stdout
    def blob(self,path):
        return subprocess.run(['git','-C',str(self.project),'cat-file','blob','HEAD:'+Path(path).as_posix()],check=True,capture_output=True).stdout
    def write(self,path,data):
        path=self.project/path; path.parent.mkdir(parents=True,exist_ok=True)
        path.write_bytes(data) if isinstance(data,bytes) else path.write_text(data)
    def checkout(self,lfs=True):
        self.git('init','-q','--initial-branch=main')
        for key,value in LFS_FILTER if lfs else []: self.git('config',key,value)
    def commit(self,message,*paths):
        self.git('add','-A','--',*paths); self.git('commit','-q','-m',message)
    def only(self,*commands):
        # PATH and Git's exec path hold only the named commands, so a missing git-lfs or Git is missing for real.
        tools=Path(tempfile.mkdtemp(dir=self.root,prefix='only '))
        for name in commands: (tools/name).symlink_to(shutil.which(name))
        return mock.patch.dict(os.environ,{'PATH':str(tools),'GIT_EXEC_PATH':str(tools)})
    def plain_file_under_rule(self,attributes='.gitattributes',rule=LFS_RULE,data=b'\x89PNG plain texture'):
        # A plain file committed before its rule, as a commit made without Git LFS stores it.
        # Only the rule is staged after it: staging the texture again would store a pointer.
        self.checkout(); self.write(PLAIN,data); self.commit('Add a texture')
        self.write(attributes,rule); self.commit('Send textures through Git LFS',attributes)
        self.assertEqual(self.blob(PLAIN),data)
    def fails_naming(self,*paths):
        with self.assertRaises(ValueError) as caught: self.g.lfs_pointers(self.project)
        message=str(caught.exception)
        self.assertIn('committed at HEAD as plain files rather than LFS pointers',message)
        for path in paths: self.assertIn('\n'+Path(path).as_posix()+'\n',message)
        self.assertIn('git add --renormalize',message)
        return message

    def test_project_that_is_not_its_own_git_checkout_is_not_checked(self):
        self.assertEqual(self.g.lfs_pointers(self.project),'this is not a Git checkout')
        # A copy inside another checkout, such as the selftest's, is still not one.
        self.git('init','-q',at=self.root); self.write('.gitattributes',LFS_RULE); self.write(PLAIN,b'plain')
        self.git('add','-A',at=self.root); self.git('commit','-q','-m','Outer',at=self.root)
        self.assertEqual(self.g.lfs_pointers(self.project),'this is not a Git checkout')
    def test_checkout_with_no_commit_yet_is_not_checked(self):
        # Bootstrap runs the gate again on a staging copy it has initialised but not committed.
        self.checkout(); self.write('.gitattributes',LFS_RULE)
        self.assertEqual(self.g.lfs_pointers(self.project),'there is no commit yet')
    def test_checkout_without_a_committed_lfs_rule_is_not_checked(self):
        self.checkout(lfs=False)
        self.write('.gitattributes','* text=auto eol=lf\n*.png binary\n# *.png filter=lfs diff=lfs merge=lfs -text\n  # *.jpg filter=lfs\nfilter=lfs\n')
        self.write(PLAIN,b'plain'); self.commit('Add a texture')
        # A rule not yet committed is not checked: only commits are.
        self.write('assets/.gitattributes',LFS_RULE)
        with self.only('git'):
            self.assertEqual(self.g.lfs_pointers(self.project),'no committed .gitattributes sends files through Git LFS')
    @NEEDS_GIT_LFS
    def test_plain_file_git_lfs_should_hold_fails_naming_it(self):
        cases={'top-level rule':('.gitattributes',LFS_RULE,b'\x89PNG plain texture'),
               # git lfs fsck --pointers (git-lfs 3.8.1) misses this one: the rule's folder holds the file only in a subfolder.
               'rule in a parent folder':('assets/.gitattributes',LFS_RULE,b'\x89PNG plain texture'),
               'macro':('.gitattributes','[attr]texture filter=lfs diff=lfs merge=lfs -text\n*.png texture\n',b'\x89PNG plain texture'),
               'quoted pattern':('.gitattributes','"assets/plaster wall/*.png" filter=lfs diff=lfs merge=lfs -text\n',b'\x89PNG plain texture'),
               'file too large to be a pointer':('.gitattributes',LFS_RULE,b'\x89PNG'+bytes(4096)),
               'pointer cut short':('.gitattributes',LFS_RULE,b'version https://git-lfs.github.com/spec/v1\noid sha256:'+b'0'*64+b'\n'),
               'pointer with more after it':('.gitattributes',LFS_RULE,b'version https://git-lfs.github.com/spec/v1\noid sha256:'+b'0'*64+b'\nsize 12\nmore\n')}
        for case,(attributes,rule,data) in cases.items():
            with self.subTest(case):
                shutil.rmtree(self.project); self.project.mkdir()
                self.plain_file_under_rule(attributes,rule,data); self.fails_naming(PLAIN)
    @NEEDS_GIT_LFS
    def test_files_committed_as_pointers_pass(self):
        self.checkout(); self.write('.gitattributes',LFS_RULE); self.write(PLAIN,b'\x89PNG texture')
        # An empty file stays empty, and Git runs no filter on a symbolic link.
        self.write('assets/empty.png',b''); (self.project/'assets/link.png').symlink_to('plaster wall/base colour.png')
        self.commit('Add textures through Git LFS')
        self.assertTrue(self.blob(PLAIN).startswith(b'version https://git-lfs.github.com/spec/v1\n'))
        self.assertEqual(self.blob('assets/empty.png'),b'')
        self.assertIsNone(self.g.lfs_pointers(self.project))
        # Renormalizing in a new commit is the remedy the failure names.
        shutil.rmtree(self.project); self.project.mkdir(); self.plain_file_under_rule()
        self.git('add','--renormalize','.'); self.git('commit','-q','-m','Store the texture as a pointer')
        self.assertIsNone(self.g.lfs_pointers(self.project))
    @NEEDS_GIT_LFS
    def test_names_every_plain_file_and_needs_no_git_lfs(self):
        self.checkout(); self.write('assets/a.png',b'plain a'); self.write('assets/sub/b.png',b'plain b'); self.write('kept.png',b'plain, but no rule sends it')
        self.commit('Add textures'); self.write('assets/.gitattributes',LFS_RULE); self.commit('Send textures through Git LFS','assets/.gitattributes')
        self.write('assets/c.png',b'\x89PNG texture'); self.commit('Add a texture through Git LFS','assets/c.png')
        with self.only('git'):
            message=self.fails_naming('assets/a.png','assets/sub/b.png')
            self.assertIn('2 file(s)',message); self.assertNotIn('kept.png',message); self.assertNotIn('assets/c.png',message)
        # The rules at HEAD decide, not the working tree's.
        self.write('assets/.gitattributes','')
        with self.only('git'): self.fails_naming('assets/a.png','assets/sub/b.png')
        with self.subTest('Git missing'), self.only():
            with self.assertRaisesRegex(ValueError,'Git is not installed'): self.g.lfs_pointers(self.project)
    @NEEDS_GIT_LFS
    def test_global_attributes_do_not_count_but_the_checkouts_own_do(self):
        self.checkout(); self.write('.gitattributes',LFS_RULE); self.write(PLAIN,b'\x89PNG texture'); self.write('notes.txt',b'plain notes')
        self.commit('Add a texture through Git LFS, and notes')
        # A user's global attributes file is not the project's, so it does not count.
        config=self.root/'config'; (config/'git').mkdir(parents=True); (config/'git/attributes').write_text('*.txt filter=lfs diff=lfs merge=lfs -text\n')
        with mock.patch.dict(os.environ,{'XDG_CONFIG_HOME':str(config)}):
            self.assertIsNone(self.g.lfs_pointers(self.project))
        # The checkout's own .git/info/attributes does, as Git applies it on commit there.
        (self.project/'.git/info').mkdir(exist_ok=True); (self.project/'.git/info/attributes').write_text('*.txt filter=lfs diff=lfs merge=lfs -text\n')
        self.fails_naming('notes.txt')
    def test_checkout_git_cannot_read_fails(self):
        self.write('.git','gitdir: '+str(self.root/'missing')+'\n')
        with self.assertRaisesRegex(ValueError,'Git cannot read the checkout'): self.g.lfs_pointers(self.project)
    @NEEDS_GIT_LFS
    def test_gate_reports_whether_it_checked(self):
        tools=self.project/'tools'; tools.mkdir()
        for name in ('verify_linux.py','process_linux.py'): shutil.copy2(GATE.parent/name,tools/name)
        shutil.copytree(GATE.parent/'_vendor',tools/'_vendor',ignore=shutil.ignore_patterns('__pycache__'))
        self.write('tools/verify.json',json.dumps({'schemaVersion':1,'preset':'foundation','requiredChecks':['documentation']}))
        for name in ('design','decisions','judgements'):
            (self.project/'docs'/name).mkdir(parents=True); self.write('docs/'+name.upper()+'.md','# Index\n\n## Index\n')
        def gate():
            return subprocess.run([sys.executable,'-B',str(tools/'verify_linux.py')],capture_output=True,text=True)
        ran=gate(); self.assertEqual(ran.returncode,0,ran.stdout+ran.stderr)
        self.assertIn('git-lfs-pointers: not checked, as this is not a Git checkout\n',ran.stdout)
        self.plain_file_under_rule()
        ran=gate(); self.assertEqual(ran.returncode,1,ran.stdout+ran.stderr)
        self.assertIn('git-lfs-pointers: FAILED\n',ran.stdout); self.assertIn(PLAIN.as_posix(),ran.stdout)
        result=self.g.verify(self.project)
        self.assertFalse(result['Passed']); self.assertEqual([s['Name'] for s in result['Stages']],['documentation','git-lfs-pointers'])
        self.assertTrue(result['Stages'][0]['Passed'],result)
        self.git('add','--renormalize','.'); self.git('commit','-q','-m','Store the texture as a pointer')
        ran=gate(); self.assertEqual(ran.returncode,0,ran.stdout+ran.stderr)
        self.assertIn('git-lfs-pointers: passed\n',ran.stdout)

if __name__=='__main__': unittest.main()

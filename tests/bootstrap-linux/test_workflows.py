"""End-to-end state effects with real Git and external services replaced at their boundaries."""
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('bootstrap_workflows',ROOT/'skills/ba-bootstrap/scripts/bootstrap_linux.py'); b=importlib.util.module_from_spec(spec); spec.loader.exec_module(b)

class Fixture:
    def __init__(self,id): self.id=id; self.repos={}; self.labels={}; self.heads={}; self.readme=None; self.calls=[]; self.fail_creation=None
    def request(self,method,endpoint,body=None):
        self.calls.append((method,endpoint,body))
        if endpoint=='/user': return 200,{'login':self.id['owner']}
        if endpoint=='/users/'+self.id['owner']: return 200,{'type':'User'}
        if method=='POST' and endpoint=='/user/repos':
            if self.fail_creation: return self.fail_creation,{'message':'Denied'}
            repo=dict(id=len(self.repos)+100,full_name=self.id['owner']+'/'+body['name'],private=body['private'],has_issues=body['has_issues'],default_branch='main',permissions={'push':True},archived=False,has_pull_requests=True,has_wiki=True,has_projects=True,has_discussions=True,allow_auto_merge=True)
            self.repos[repo['full_name']]=repo; return 201,dict(repo)
        for name,repo in self.repos.items():
            prefix='/repos/'+name
            if endpoint==prefix:
                if method=='PATCH': repo.update(body)
                return 200,dict(repo)
            if endpoint==prefix+'/git/ref/heads/main':
                return (200,{'object':{'sha':self.heads[name]}}) if name in self.heads else (409,{'message':'Git Repository is empty.'})
            if endpoint.startswith(prefix+'/git/trees/'):
                paths=['README.md'] if name.endswith('-release-notes') else b.source_paths(self.id['projectPath'])
                return 200,{'truncated':False,'tree':[{'path':p,'type':'blob'} for p in paths]}
            if endpoint==prefix+'/contents/README.md':
                if method=='PUT': self.readme=body['content']; self.heads[name]='b'*40
                return (200,{'encoding':'base64','content':self.readme}) if self.readme else (404,None)
            if endpoint.startswith(prefix+'/labels'):
                if method in ('POST','PATCH'): self.labels[body['name']]=dict(body); return 201,body
                return 200,list(self.labels.values())
            if endpoint==prefix+'/actions/permissions': return 200,{'enabled':False}
            if endpoint==prefix+'/pages': return 404,None
        return 404,None
    def runner(self,args,**kwargs):
        if args[0]=='git' and 'push' in args:
            root=Path(args[args.index('-C')+1]); self.heads[self.id['fullName']]=b.command(['git','-C',root,'rev-parse','HEAD']).stdout.strip(); return subprocess.CompletedProcess(args,0,'fixture push\n')
        env={**kwargs.pop('env',{}),'GIT_AUTHOR_NAME':'Fixture','GIT_AUTHOR_EMAIL':'fixture@example.invalid','GIT_COMMITTER_NAME':'Fixture','GIT_COMMITTER_EMAIL':'fixture@example.invalid'}
        return b.command(args,env=env,**kwargs)

class Workflows(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='workflow ü spaces '); self.addCleanup(self.tmp.cleanup); self.root=Path(self.tmp.name)
        self.id=b.identity('New Project','Useful project',str(self.root),'cicely-f'); self.preset=b.selection(self.id,'foundation'); self.fixture=Fixture(self.id)
        self.engine=b.Bootstrap(self.root/'state',request=self.fixture.request,runner=self.fixture.runner)
    def test_create_publishes_exact_initial_commit_and_recovery_is_idempotent(self):
        obs=dict(installedVerified=True,enabledVerified=True,pending=[],plugins=[])
        with patch.object(self.engine,'install_obsidian',return_value=obs): result=self.engine.create(self.id,self.preset)
        self.assertEqual(result['status'],'complete',result)
        project=Path(self.id['projectPath']); journal=self.engine.load(self.id)
        self.assertEqual(b.command(['git','-C',project,'status','--porcelain']).stdout,'')
        self.assertEqual(b.command(['git','-C',project,'rev-list','--count','HEAD']).stdout.strip(),'1')
        self.assertEqual(len(self.fixture.repos),2)
        self.assertEqual(len(self.fixture.labels),len(b.read_json(b.ASSETS/'labels.json')))
        self.assertFalse(self.engine.preparation_source(journal).exists())
        self.engine.snapshot(journal)
        posts=sum(m=='POST' for m,_,_ in self.fixture.calls)
        result=self.engine.create(self.id,self.preset)
        self.assertEqual(result['status'],'complete',result)
        self.assertEqual(sum(m=='POST' for m,_,_ in self.fixture.calls),posts)
    def test_matching_legacy_foundation_journal_resumes_natively(self):
        manifest=b.foundation(self.id,self.preset,legacy=True)
        journal=self.engine.new_journal(self.id,self.preset)
        journal.update(schemaVersion=1,inputHash=b.input_hash(self.id),manifest=b.records(manifest),templateVersion=b.manifest_hash(manifest))
        for key in ('presetSelection','recipeVersion','resolution','preparation','verification'): journal.pop(key)
        self.engine.save(journal)
        with patch.object(self.engine,'install_obsidian',return_value=dict(installedVerified=True,enabledVerified=True,pending=[],plugins=[])):
            result=self.engine.create(self.id,self.preset)
        self.assertEqual(result['status'],'complete',result)
        self.assertEqual(len(self.fixture.repos),2)
    def test_definite_client_rejection_can_retry_but_cannot_discard(self):
        self.fixture.fail_creation=403; result=self.engine.create(self.id,self.preset)
        self.assertEqual(result['status'],'blocked',result)
        journal=self.engine.load(self.id); self.assertEqual(journal['phases']['privateRepository'],'failed')
        with self.assertRaises(ValueError): self.engine.discard(journal)
        self.fixture.fail_creation=None
        with patch.object(self.engine,'install_obsidian',return_value=dict(installedVerified=True,enabledVerified=False,pending=['open app'],plugins=[])):
            result=self.engine.create(self.id,self.preset)
        self.assertEqual(result['status'],'partial',result)
        self.assertEqual(len(self.fixture.repos),2)
        self.assertNotIn('complete',self.engine.load(self.id)['phases'])
    def test_local_setup_resolves_nested_directory_and_refuses_companion(self):
        project=Path(self.id['projectPath']); b.write_manifest(project,b.foundation(self.id,self.preset)); self.engine.git(project,'init','--initial-branch=main'); self.engine.git(project,'remote','add','origin','https://github.com/'+self.id['fullName']+'.git')
        self.fixture.repos[self.id['fullName']]={'id':2,'full_name':self.id['fullName'],'private':True}
        actual=self.engine.local_identity(project/'docs')
        self.assertEqual(actual['projectPath'],str(project))
        self.engine.git(project,'remote','set-url','origin','https://github.com/cicely-f/Thing-release-notes.git')
        with self.assertRaises(ValueError): self.engine.local_identity(project)
    def test_obisidian_installs_curated_files_and_preserves_preferences(self):
        project=Path(self.id['projectPath']); b.write_manifest(project,b.foundation(self.id,self.preset)); self.engine.git(project,'init','--initial-branch=main')
        ids=b.read_json(b.ASSETS/'obsidian/plugins.json'); registry=[{'id':p,'repo':'fixture/'+p} for p in ids]
        def manifest(plugin): return {'id':plugin,'version':'1.0.0','minAppVersion':'1.0.0'}
        def request(method,url,body=None):
            if url==b.REGISTRY: return 200,registry
            if url.endswith('/latest'):
                plugin=url.split('/')[3]; tag='1.0.0'; base='https://github.com/fixture/'+plugin+'/releases/download/'+tag+'/'
                assets=[{'name':name,'browser_download_url':base+name,'digest':'sha256:'+b.sha(json.dumps(manifest(plugin)).encode() if name=='manifest.json' else b'console.log("fixture")')} for name in ('manifest.json','main.js')]
                return 200,{'tag_name':tag,'draft':False,'prerelease':False,'assets':assets}
            plugin=url.split('/')[4]; return 200,manifest(plugin)
        def fetch(url,path):
            plugin=url.split('/')[4]; Path(path).write_bytes(json.dumps(manifest(plugin)).encode() if url.endswith('manifest.json') else b'console.log("fixture")')
        self.engine.fetch=fetch
        with patch.object(self.engine,'obsidian_request',side_effect=request):
            result=self.engine.install_obsidian(self.id,app_version='1.5.0',app_check=lambda *_:{'verified':False,'pending':'app pending'})
        self.assertTrue(result['installedVerified'],result); self.assertFalse(result['enabledVerified'])
        local=project/'docs/.obsidian'; self.assertEqual(b.read_json(local/'community-plugins.json'),ids)
        preference=local/'plugins/dataview/data.json'; preference.write_text('{"custom":true}')
        self.engine.fetch=lambda *_:self.fail('ordinary setup must reuse installed plugins')
        result=self.engine.install_obsidian(self.id,app_version='1.5.0',app_check=lambda *_:{'verified':True})
        self.assertTrue(result['enabledVerified'],result); self.assertEqual(b.read_json(preference),{'custom':True})
        self.assertTrue(all(p['digestVerification']=='verified' for p in result['plugins']))

class PluginRecovery(unittest.TestCase):
    setUp=Workflows.setUp
    # This class reuses the isolated checkout fixture, and adds transaction interruption coverage.
    def test_interrupted_promotion_rolls_back_and_replays_pinned_release(self):
        project=Path(self.id['projectPath']); b.write_manifest(project,b.foundation(self.id,self.preset)); self.engine.git(project,'init','--initial-branch=main')
        ids=b.read_json(b.ASSETS/'obsidian/plugins.json'); registry=[{'id':p,'repo':'fixture/'+p} for p in ids]; selected={'version':'1.0.0'}; requests=[]
        def contents(plugin,version,name): return json.dumps({'id':plugin,'version':version,'minAppVersion':'1.0.0'}).encode() if name=='manifest.json' else ('fixture '+version).encode()
        def request(method,url,body=None):
            requests.append(url)
            if url==b.REGISTRY: return 200,registry
            if url.endswith('/latest'):
                plugin=url.split('/')[3]; version=selected['version']; base='https://github.com/fixture/'+plugin+'/releases/download/'+version+'/'
                return 200,{'tag_name':version,'draft':False,'prerelease':False,'assets':[{'name':name,'browser_download_url':base+name,'digest':'sha256:'+b.sha(contents(plugin,version,name))} for name in ('manifest.json','main.js')]}
            pieces=url.split('/'); return 200,json.loads(contents(pieces[4],pieces[-2],'manifest.json'))
        def fetch(url,path):
            pieces=url.split('/'); Path(path).write_bytes(contents(pieces[4],pieces[-2],pieces[-1]))
        self.engine.fetch=fetch; app=lambda *_:{'verified':True}
        with patch.object(self.engine,'obsidian_request',side_effect=request):
            result=self.engine.install_obsidian(self.id,app_version='1.5.0',app_check=app); self.assertTrue(result['installedVerified'],result)
            selected['version']='2.0.0'; rename=b.os.rename; interrupted={'done':False}
            def fail_once(source,target):
                if '/stage/'+ids[1] in str(source) and not interrupted['done']:
                    interrupted['done']=True; raise OSError('fixture interrupted promotion')
                return rename(source,target)
            with patch.object(b.os,'rename',side_effect=fail_once): result=self.engine.install_obsidian(self.id,refresh=True,app_version='1.5.0',app_check=app)
            self.assertFalse(result['installedVerified']); self.assertTrue(any('interrupted promotion' in p for p in result['pending']))
            for plugin in ids: self.assertEqual(b.read_json(project/'docs/.obsidian/plugins'/plugin/'manifest.json')['version'],'1.0.0')
            selected['version']='3.0.0'; requests.clear(); result=self.engine.install_obsidian(self.id,app_version='1.5.0',app_check=app)
        self.assertTrue(result['installedVerified'],result); self.assertTrue(result['enabledVerified'])
        self.assertFalse(requests,'recovery must use pinned release URLs rather than selecting newer releases')
        for plugin in ids: self.assertEqual(b.read_json(project/'docs/.obsidian/plugins'/plugin/'manifest.json')['version'],'2.0.0')
    def test_bootstrap_process_timeout_is_controlled_failure(self):
        with self.assertRaises(RuntimeError): b.command(['bash','-c','sleep 2'],timeout=.05)

class ReviewRegressions(unittest.TestCase):
    setUp=Workflows.setUp
    def test_completed_refresh_is_blocked_without_remote_or_vault_mutations(self):
        with patch.object(self.engine,'install_obsidian',return_value=dict(installedVerified=True,enabledVerified=True,pending=[],plugins=[])):
            result=self.engine.create(self.id,self.preset)
        self.assertEqual(result['status'],'complete',result)
        path=self.engine.journal_path(self.id); before=path.read_bytes(); self.fixture.calls.clear()
        with patch.object(self.engine,'install_obsidian',side_effect=AssertionError('completed refresh must use local-setup')):
            result=self.engine.create(self.id,self.preset,refresh=True)
        self.assertEqual(result['status'],'blocked',result)
        self.assertTrue(any('local-setup' in text and '--refresh-plugins' in text for text in result['pending']),result)
        self.assertEqual([method for method,_,_ in self.fixture.calls if method!='GET'],[])
        self.assertEqual(path.read_bytes(),before)
    def test_case_only_parent_retry_cannot_rebind_partial_invocation(self):
        original=b.identity('New Project','Useful project',str(self.root/'Projects'),'cicely-f')
        other=b.identity('New Project','Useful project',str(self.root/'projects'),'cicely-f')
        self.fixture.id=original
        with patch.object(self.engine,'prepare',side_effect=RuntimeError('fixture preparation failure')):
            result=self.engine.create(original,self.preset)
        self.assertEqual(result['status'],'partial',result)
        path=self.engine.journal_path(original); before=path.read_bytes(); self.fixture.calls.clear()
        with patch.object(self.engine,'install_obsidian',return_value=dict(installedVerified=True,enabledVerified=True,pending=[],plugins=[])):
            result=self.engine.create(other,self.preset)
        self.assertEqual(result['status'],'blocked',result)
        self.assertNotEqual(b.input_hash(original,self.preset),b.input_hash(other,self.preset))
        self.assertEqual(path.read_bytes(),before)
        self.assertFalse(Path(original['projectPath']).exists()); self.assertFalse(Path(other['projectPath']).exists())
        self.assertEqual([method for method,_,_ in self.fixture.calls if method!='GET'],[])
    def test_cli_resume_rejects_case_only_explicit_parent_before_any_service_call(self):
        import os
        original=b.identity('New Project','Useful project',str(self.root/'Projects'),'cicely-f')
        journal=self.engine.new_journal(original,self.preset); self.engine.save(journal); path=self.engine.journal_path(original); before=path.read_bytes()
        result=subprocess.run([str(ROOT/'skills/ba-bootstrap/scripts/bootstrap.sh'),'--mode','resume','--name','New Project','--owner','cicely-f','--parent',str(self.root/'projects'),'--state-root',str(self.engine.root)],capture_output=True,text=True,env={**os.environ,'PATH':'/usr/bin:/bin'})
        self.assertNotEqual(result.returncode,0); report=json.loads(result.stdout); self.assertEqual(report['status'],'blocked'); self.assertIn('parent',report['conflicts'][0])
        self.assertEqual(path.read_bytes(),before); self.assertFalse(Path(self.root/'projects/New-Project').exists())

    def test_unmarked_casefolded_journal_is_readable_but_cannot_move_checkout(self):
        original=b.identity('New Project','Useful project',str(self.root/'Projects'),'cicely-f')
        other=b.identity('New Project','Useful project',str(self.root/'projects'),'cicely-f')
        journal=self.engine.new_journal(original,self.preset); journal.pop('inputHashFormat',None)
        # Literal historical format: its stored absolute project path was case folded.
        values=[original['title'],original['description'],'cicely-f','New-Project',original['projectPath'].lower(),'bootstrap-state-v2','foundation',1,None,None,None,None]
        journal['inputHash']=hashlib.sha256(json.dumps(values,ensure_ascii=False,separators=(',',':')).encode()).hexdigest()
        self.engine.save(journal); path=self.engine.journal_path(original); before=path.read_bytes()
        loaded=self.engine.load(original); self.assertEqual(loaded['inputHash'],journal['inputHash'])
        result=self.engine.create(other,self.preset)
        self.assertEqual(result['status'],'blocked',result); self.assertEqual(path.read_bytes(),before)
        self.assertFalse(Path(other['projectPath']).exists())
        self.assertEqual(self.engine.plan(original,self.preset)['status'],'ready')

if __name__=='__main__': unittest.main()

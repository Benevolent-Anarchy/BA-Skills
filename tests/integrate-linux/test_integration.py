"""Behavior tests: every Git write is confined to temporary local repositories."""
import json, os, pathlib, re, shutil, subprocess, tempfile, unittest
ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / 'skills/ba-integrate/scripts'

class Integration(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='ba integrate ü ')
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        self.repo = self.root / 'working tree [literal]'
        self.repo.mkdir()
        self.env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GH_REPO='wrong/repository')
        transport=self.root/'transport-bin';transport.mkdir()
        shutil.copy(ROOT/'tests/integrate-linux/git_transport.py',transport/'git');(transport/'git').chmod(0o755)
        self.env.update(FIXTURE_REAL_GIT=shutil.which('git'),PATH=str(transport)+os.pathsep+self.env['PATH'])
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        (self.repo / 'file [one].txt').write_text('base\n')
        self.git('add', '.'); self.git('commit', '-qm', 'base')
        self.base = self.git('rev-parse', 'HEAD')
        self.gh = self.root / 'fake gh'
        self.data = self.root / 'gh.json'; self.data.write_text('{}')
        self.env['FIXTURE_DATA'] = str(self.data)
        self.gh.write_text('''#!/usr/bin/env python3
import json, os, sys
p=os.environ['FIXTURE_DATA']; d=json.load(open(p)); a=sys.argv[1:]
if d.get('fail'): print('fixture failure',file=sys.stderr);sys.exit(23)
if d.get('warning'):print('fixture warning',file=sys.stderr)
if a[:2] in (['pr','view'],['pr','edit']):
 if '--repo' not in a or a[a.index('--repo')+1]!='test/repo':raise SystemExit('repository not explicit')
 # Like Ubuntu's gh 2.46, which lacks this pr view field.
 if '--json' in a and 'closingIssuesReferences' in a[a.index('--json')+1]:raise SystemExit('Unknown JSON field: "closingIssuesReferences"')
if a[:2]==['api','graphql'] and d.get('graphql_pages'):
 pages=d['graphql_pages'];o=pages.pop(0);d['graphql_pages']=pages;json.dump(d,open(p,'w'));print(json.dumps(o));sys.exit()
if a[:2]==['api','graphql']:
 q=next(x[6:] for x in a if x.startswith('query='))
 if 'ClosingIssues' in q:
  k='closingIssuesReferences'; c=d.get('closing',[])
  o={'data':{'repository':{'pullRequest':{k:{'nodes':c,'totalCount':len(c),'pageInfo':{'hasNextPage':False}}}}}}
 elif 'PullRequestCommits' in q:
  c=d.get('commits',[]); o={'data':{'repository':{'pullRequest':{'headRefOid':d.get('head','a'*40),'mergeCommit':d.get('merge'),'commits':{'nodes':[{'commit':x} for x in c],'totalCount':d.get('commitTotal',len(c)),'pageInfo':{'hasNextPage':False}}}}}}
 elif 'LandedCommit' in q:
  oid=next(x[4:] for x in a if x.startswith('oid='));o={'data':{'repository':{'object':d['objects'][oid]}}}
 else: o={'data':{'repository':{'pullRequests':{'nodes':d.get('targeting',[]),'pageInfo':{'hasNextPage':d.get('more',False),'endCursor':d.get('cursor')}}}}}
elif a[:2]==['pr','edit']:
 n=int(a[2])
 if d.get('fail_edit')==n:raise SystemExit('edit refused')
 d['targeting']=[x for x in d.get('targeting',[]) if x['number']!=n];json.dump(d,open(p,'w'));print('{}');sys.exit()
elif a[:2]==['pr','view']:
 views=d.get('views',[])
 if views: o=views.pop(0);d['views']=views;json.dump(d,open(p,'w'))
 else:o=d.get('pr',{'number':1,'url':'https://github.com/test/repo/pull/1','state':'OPEN','baseRefName':'main'})
elif a[:2]==['repo','view']:o={'nameWithOwner':'test/repo','defaultBranchRef':{'name':'main'}}
elif a[:2]==['issue','view']:o=d.get('issue',{'state':'CLOSED','closedAt':'2020-01-01T00:00:00Z'})
elif a[:2]==['api','--method']:
 print(d.get('rendered',''));sys.exit()
elif a[0]=='api' and '/compare/' in a[1]:o={'status':d.get('compare','ahead')}
elif a[0]=='api' and '/timeline?' in a[1]:o=d.get('timeline',[])
else:raise SystemExit('unexpected gh arguments '+repr(a))
print(json.dumps(o))
''')
        self.gh.chmod(0o755)
    def git(self,*args,ok=True):
        p=subprocess.run(['git','-C',str(self.repo),*args],env=self.env,text=True,capture_output=True)
        if ok and p.returncode: self.fail(p.stderr)
        return p.stdout.strip() if ok else p
    def call(self,name,ok=True,**kwargs):
        args=['bash',str(SCRIPTS/(name+'.sh'))]
        if name in ('update','land'):kwargs.setdefault('worktree',str(self.repo))
        else:kwargs.setdefault('repository',str(self.repo))
        if name!='update' and name!='survey':kwargs.setdefault('github_cli',str(self.gh))
        for k,v in kwargs.items():
            args.append('--'+k.replace('_','-'))
            if v is not True: args.append(str(v))
        p=subprocess.run(args,env=self.env,text=True,capture_output=True)
        try:d=json.loads(p.stdout)
        except ValueError:self.fail(f'Expected JSON: {p.returncode} {p.stdout} {p.stderr}')
        self.assertEqual(p.returncode,0 if ok else 1,(d,p.stderr))
        self.assertEqual('error' in d,not ok,d)
        return d
    def state(self,**data): self.data.write_text(json.dumps(data))
    def github(self):self.git('remote','add','origin','https://github.com/test/repo.git')
    def branch(self,name,content):
        self.git('checkout','-qb',name,self.base)
        (self.repo / 'file [one].txt').write_text(content+'\n')
        self.git('commit','-qam',name)
        return self.git('rev-parse','HEAD')
    def local_remote(self):
        remote=self.root/'bare remote';subprocess.run(['git','init','--bare','-q',str(remote)],check=True)
        self.github();self.env['FIXTURE_REMOTE']=str(remote)
        self.git('push','-q','origin','main','feature')
        return remote
    def test_empty_survey_and_no_ready(self):
        path=self.root/'pull requests.json';path.write_text('[]')
        d=self.call('survey',base='main',pull_requests_json=path);self.assertEqual(d['order'],[])
        path.write_text(json.dumps([{'number':1,'isDraft':True,'headRefOid':self.base,'headRefName':'draft','baseRefName':'main'}]))
        d=self.call('survey',base='main',pull_requests_json=path);self.assertEqual(d['skipped'],[{'number':1,'reason':'draft'}])
    def test_survey_dependency_conflict_and_unready_history(self):
        a=self.branch('a','a');b=self.branch('b','b');self.git('checkout','-qb','stack','a')
        (self.repo/'second').write_text('stack');self.git('add','.');self.git('commit','-qm','stack');c=self.git('rev-parse','HEAD')
        prs=[dict(number=n,title=str(n),url='url',isDraft=d,isCrossRepository=False,headRefName=h,headRefOid=s,baseRefName=t) for n,h,s,t,d in [(1,'a',a,'main',False),(2,'b',b,'main',False),(3,'stack',c,'a',False),(4,'draft',a,'main',True)]]
        p=self.root/'prs.json';p.write_text(json.dumps(prs));d=self.call('survey',base='main',pull_requests_json=p)
        self.assertLess(d['order'].index(1),d['order'].index(3));self.assertEqual(d['conflicts'][0]['files'],['file [one].txt'])
        self.assertEqual(next(p for p in d['pullRequests'] if p['number']==3)['includesUnready'][0]['number'],4)
    def test_update_replays_conflict_and_preserves_dirty_tree(self):
        h=self.branch('feature','feature');b=self.branch('newbase','newbase')
        self.git('merge','--no-ff','--no-commit',h,ok=False)
        (self.repo/'file [one].txt').write_text('resolved\n');self.git('add','.');self.git('commit','-qm','resolved');r=self.git('rev-parse','HEAD')
        d=self.call('update',head=h,base=b,rehearsed=r);self.assertTrue(d['matches']);self.assertEqual(d['replayed'],['file [one].txt'])
        (self.repo/'file [one].txt').write_text('user work\n')
        d=self.call('update',head=h,base=b,rehearsed=r,ok=False);self.assertIn('uncommitted',d['error']);self.assertEqual((self.repo/'file [one].txt').read_text(),'user work\n')
    def test_update_mismatch_and_bad_source(self):
        h=self.branch('feature','feature')
        d=self.call('update',head=h,base=self.base,rehearsed=self.base,ok=False);self.assertFalse(d['matches'])
        self.call('update',head='missing',base=self.base,rehearsed=h,ok=False)
    def test_retarget_approved_set_and_subprocess_failure(self):
        self.github();self.state(targeting=[dict(number=2,title='two',url='url',isDraft=True)])
        d=self.call('retarget',branch='feature',base_branch='main',approved='none',ok=False);self.assertEqual(d['unexpected'],[2])
        self.assertEqual(json.loads(self.data.read_text())['targeting'][0]['number'],2)
        d=self.call('retarget',branch='feature',base_branch='main',approved='2');self.assertEqual(d['retargeted'],[2]);self.assertEqual(d['remaining'],[])
        self.state(fail=True);self.call('retarget',branch='feature',base_branch='main',list=True,ok=False)
    def test_retarget_accepts_pull_requests_github_already_moved(self):
        self.github();self.state(targeting=[],pr=dict(state='OPEN',baseRefName='main'))
        d=self.call('retarget',branch='feature',base_branch='main',approved='2');self.assertEqual(d['alreadyRetargeted'],[2]);self.assertEqual(d['retargeted'],[]);self.assertEqual(d['remaining'],[])
        self.state(targeting=[],pr=dict(state='CLOSED',baseRefName='main'))
        d=self.call('retarget',branch='feature',base_branch='main',approved='2',ok=False);self.assertEqual(d['missing'],[2])
        self.state(targeting=[],pr=dict(state='OPEN',baseRefName='elsewhere'))
        d=self.call('retarget',branch='feature',base_branch='main',approved='2',ok=False);self.assertEqual(d['missing'],[2])
        self.state(targeting=[dict(number=3,title='three',url='url',isDraft=False)],pr=dict(state='OPEN',baseRefName='main'))
        d=self.call('retarget',branch='feature',base_branch='main',approved='2',ok=False);self.assertEqual((d['unexpected'],d['missing']),([3],[2]))
        self.assertEqual([p['number'] for p in json.loads(self.data.read_text())['targeting']],[3])
    def test_retarget_incomplete_page_refused(self):
        self.github();self.state(more=True);self.call('retarget',branch='feature',base_branch='main',approved='none',ok=False)
    def test_repository_identity_refuses_multi_push_and_rewrite(self):
        self.github();self.git('config','--add','remote.origin.pushurl','https://github.com/test/repo.git');self.git('config','--add','remote.origin.pushurl','https://github.com/other/repo.git')
        self.call('retarget',branch='feature',base_branch='main',list=True,ok=False)
        self.git('config','--unset-all','remote.origin.pushurl');self.git('config','url.https://github.com/other/repo.git.insteadOf','https://github.com/test/repo.git')
        self.call('retarget',branch='feature',base_branch='main',list=True,ok=False)
    def test_repository_identity_refuses_off_github_rewrites(self):
        self.github()
        for kind in ['insteadOf','pushInsteadOf']:
            for destination in ['https://secret@example.invalid/test/repo.git','git@example.invalid:test/repo.git',str(self.root/'local remote'),'ssh://git@ssh.github.com.evil:443/test/repo.git','ssh://git@ssh.github.com:444/test/repo.git']:
                with self.subTest(kind=kind,destination=destination):
                    key='url.'+destination+'.'+kind
                    self.git('config',key,'https://github.com/test/repo.git')
                    try:
                        d=self.call('retarget',branch='feature',base_branch='main',list=True,ok=False)
                        self.assertIn('github.com',d['error'])
                        self.assertNotIn('secret',d['error'])
                    finally:self.git('config','--unset-all',key)
    def test_repository_identity_accepts_same_github_repository_rewrite(self):
        self.github()
        self.git('config','url.git@github.com:Test/Repo.git.pushInsteadOf','https://github.com/test/repo.git')
        d=self.call('retarget',branch='feature',base_branch='main',list=True)
        self.assertEqual(d['repository'],'test/repo')
    def test_repository_identity_accepts_github_ssh_over_443(self):
        self.github()
        self.git('remote','set-url','origin','ssh://git@ssh.github.com:443/test/repo.git')
        self.assertEqual(self.call('retarget',branch='feature',base_branch='main',list=True)['repository'],'test/repo')
        self.git('remote','set-url','origin','https://github.com/test/repo.git')
        for kind in ['insteadOf','pushInsteadOf']:
            with self.subTest(kind=kind):
                key='url.ssh://git@ssh.github.com:443/.'+kind
                self.git('config',key,'https://github.com/')
                try:self.assertEqual(self.call('retarget',branch='feature',base_branch='main',list=True)['repository'],'test/repo')
                finally:self.git('config','--unset-all',key)
    def test_off_github_rewrite_cannot_land(self):
        head=self.branch('feature','feature');remote=self.local_remote()
        decoy=self.root/'decoy remote';subprocess.run(['git','init','--bare','-q',str(decoy)],check=True)
        self.git('push','-q',str(decoy),'main','feature')
        self.git('config','url.'+str(decoy)+'.pushInsteadOf','https://github.com/test/repo.git')
        self.state(pr=dict(state='OPEN',isDraft=False,headRefName='feature',headRefOid=head,baseRefName='main'))
        try:
            d=self.call('land',pull_request=1,branch='feature',approved_head=head,updated=head,base_branch='main',expected_base=self.base,rehearsed=head,message='fixture',timeout_seconds=0,poll_seconds=0,ok=False)
            self.assertIn('github.com',d['error']);self.assertFalse(d['branchPushed']);self.assertFalse(d['landed'])
        finally:
            for destination in [remote,decoy]:
                self.assertEqual(self.git('ls-remote',str(destination),'refs/heads/main').split()[0],self.base)
                self.assertEqual(self.git('ls-remote',str(destination),'refs/heads/feature').split()[0],head)
    def test_off_github_rewrite_cannot_delete(self):
        head=self.branch('feature','feature');self.git('branch','-f','main',head);remote=self.local_remote()
        decoy=self.root/'decoy remote';subprocess.run(['git','init','--bare','-q',str(decoy)],check=True)
        self.git('push','-q',str(decoy),'main','feature')
        self.git('config','url.'+str(decoy)+'.pushInsteadOf','https://github.com/test/repo.git')
        try:
            d=self.call('delete-branch',branch='feature',merged_tip=head,base_branch='main',ok=False)
            self.assertIn('github.com',d['error'])
        finally:
            for destination in [remote,decoy]:
                self.assertEqual(self.git('ls-remote',str(destination),'refs/heads/main').split()[0],head)
                refs=self.git('ls-remote',str(destination),'refs/heads/feature')
                self.assertEqual(refs.split()[0] if refs else None,head)
    def test_land_validation_then_local_landing_and_resume(self):
        h=self.branch('feature','feature');self.local_remote()
        common=dict(pull_request=1,branch='feature',approved_head=h,updated=h,base_branch='main',expected_base=self.base,rehearsed=h,message='Merge fixture',timeout_seconds=0,poll_seconds=0)
        self.state(pr=dict(state='OPEN',isDraft=True,headRefName='feature',headRefOid=h,baseRefName='main'))
        self.call('land',ok=False,**common);self.assertEqual(self.git('ls-remote','origin','refs/heads/main').split()[0],self.base)
        view=dict(state='OPEN',isDraft=False,headRefName='feature',headRefOid=h,baseRefName='main')
        self.state(views=[view,view],pr=dict(state='MERGED'))
        d=self.call('land',**common);self.assertTrue(d['merged']);self.assertTrue(d['landed'])
        d=self.call('land',**common);self.assertTrue(d['resumed'])
    def test_land_reports_closing_issues_without_the_pr_view_field(self):
        h=self.branch('feature','feature');self.local_remote();url='https://github.com/other/repo/issues/9'
        view=dict(state='OPEN',isDraft=False,headRefName='feature',headRefOid=h,baseRefName='main')
        self.state(views=[view,view],pr=dict(state='MERGED'),closing=[dict(url=url,number=9,repository={'nameWithOwner':'other/repo'})])
        d=self.call('land',pull_request=1,branch='feature',approved_head=h,updated=h,base_branch='main',expected_base=self.base,rehearsed=h,message='fixture',timeout_seconds=0,poll_seconds=0)
        self.assertTrue(d['merged']);self.assertEqual(d['closingIssues'],[dict(url=url,repository='other/repo',number=9)])
    def test_land_source_mismatch_never_pushes(self):
        h=self.branch('feature','feature');self.local_remote()
        d=self.call('land',pull_request=1,branch='feature',approved_head=h,updated=self.base,base_branch='main',expected_base=self.base,rehearsed=h,message='bad',timeout_seconds=0,ok=False)
        self.assertFalse(d['branchPushed']);self.assertEqual(self.git('ls-remote','origin','refs/heads/feature').split()[0],h)
    def test_delete_protects_dependents_then_deletes_and_absent(self):
        h=self.branch('feature','feature');self.git('branch','-f','main',h);self.local_remote()
        self.state(targeting=[dict(number=2,url='url',title='two',isDraft=True)])
        self.call('delete-branch',branch='feature',merged_tip=h,base_branch='main',ok=False)
        self.state();d=self.call('delete-branch',branch='feature',merged_tip=h,base_branch='main');self.assertEqual(d['outcome'],'deleted')
        d=self.call('delete-branch',branch='feature',merged_tip=h,base_branch='main');self.assertEqual(d['outcome'],'absent')
    def test_check_issues_empty_and_incomplete_commits(self):
        self.github();self.state();d=self.call('check-issues',pull_request=1);self.assertEqual(d['issues'],[]);self.assertTrue(d['allClosed'])
        self.state(commitTotal=1);self.call('check-issues',pull_request=1,ok=False)
    def test_check_issues_rendered_commit_and_reopened(self):
        self.github();url='https://github.com/test/repo/issues/9';oid='a'*40
        self.state(pr=dict(state='MERGED',mergedAt='2020-01-01T00:00:00Z',baseRefName='main',url='url'),head=oid,merge={'oid':oid,'message':'Fix #9','parents':{'totalCount':1}},commits=[{'oid':oid,'message':'Fix #9'}],rendered='Fix <a data-hovercard-type="issue" data-url="'+url+'">#9</a>',issue={'state':'OPEN','closedAt':None},timeline=[{'event':'reopened','created_at':'2020-01-02T00:00:00Z','actor':{'login':'person'}}])
        d=self.call('check-issues',pull_request=1);self.assertFalse(d['allClosed']);self.assertEqual(d['landing'],'fast-forward');self.assertIn('person',d['issues'][0]['findings'][0])
    def test_installer_preflight_and_links(self):
        home=self.root/'home';home.mkdir();target=home/'.claude/skills/ba-integrate';target.mkdir(parents=True);(target/'mine').write_text('keep')
        cmd=['bash',str(ROOT/'install.sh'),'--home',str(home)]
        p=subprocess.run(cmd,capture_output=True,text=True);self.assertNotEqual(p.returncode,0);self.assertTrue((target/'mine').exists());self.assertFalse((home/'.agents/skills/ba-bootstrap').exists())
        (target/'mine').unlink();target.rmdir();p=subprocess.run(cmd,capture_output=True,text=True);self.assertEqual(p.returncode,0,p.stderr)
        self.assertEqual((home/'.agents/skills/ba-integrate').resolve(),(ROOT/'skills/ba-integrate').resolve())
        self.assertEqual((home/'.claude/skills/ba-crossreview').resolve(),(ROOT/'skills/ba-crossreview').resolve())
        p=subprocess.run(cmd+['--check-only'],capture_output=True,text=True);self.assertEqual(p.returncode,0,p.stderr)

    def test_survey_live_paginates_reviews_and_reports_all(self):
        self.github()
        p=dict(number=7,title='seven',url='url',isDraft=False,isCrossRepository=False,headRefName='main',headRefOid=self.base,baseRefName='main',reviewDecision='APPROVED',mergeable='MERGEABLE',reviewThreads=dict(nodes=[{'isResolved':False}],pageInfo=dict(hasNextPage=True,endCursor='review-next')))
        self.state(graphql_pages=[{'data':{'repository':{'pullRequests':{'nodes':[p],'pageInfo':{'hasNextPage':True,'endCursor':'next'}}}}},{'data':{'repository':{'pullRequests':{'nodes':[],'pageInfo':{'hasNextPage':False}}}}},{'data':{'repository':{'pullRequest':{'reviewThreads':{'nodes':[{'isResolved':False},{'isResolved':True}],'pageInfo':{'hasNextPage':False}}}}}}])
        # The test-only transport routes fetches locally, including unavailable PR refs.
        remote=self.root/'bare';subprocess.run(['git','init','--bare','-q',str(remote)],check=True)
        self.env['FIXTURE_REMOTE']=str(remote);self.git('push','-q','origin','main')
        d=self.call('survey',base='main',github_cli=self.gh)
        self.assertEqual(d['order'],[7]);self.assertEqual(d['pullRequests'][0]['unresolvedReviewThreads'],2)
    def test_land_commit_failure_aborts_own_merge(self):
        h=self.branch('feature','feature');self.local_remote()
        hook=self.repo/'.git/hooks/pre-commit';hook.write_text('#!/bin/sh\nexit 41\n');hook.chmod(0o755)
        view=dict(state='OPEN',isDraft=False,headRefName='feature',headRefOid=h,baseRefName='main');self.state(pr=view)
        d=self.call('land',pull_request=1,branch='feature',approved_head=h,updated=h,base_branch='main',expected_base=self.base,rehearsed=h,message='bad hook',timeout_seconds=0,ok=False)
        self.assertFalse(d['landed']);self.assertFalse((self.repo/'.git/MERGE_HEAD').exists());self.assertEqual(self.git('ls-remote','origin','refs/heads/main').split()[0],self.base)
    def test_land_wait_failure_is_resumable_without_second_merge(self):
        h=self.branch('feature','feature');self.local_remote()
        view=dict(state='OPEN',isDraft=False,headRefName='feature',headRefOid=h,baseRefName='main');self.state(pr=view)
        args=dict(pull_request=1,branch='feature',approved_head=h,updated=h,base_branch='main',expected_base=self.base,rehearsed=h,message='fixture',timeout_seconds=0,poll_seconds=0)
        d=self.call('land',ok=False,**args);self.assertTrue(d['landed']);merge=d['mergeCommit'];self.assertFalse(d['merged'])
        self.state(pr=dict(state='MERGED'));d=self.call('land',**args);self.assertEqual(d['mergeCommit'],merge)
    def test_delete_moved_branch_is_preserved(self):
        h=self.branch('feature','feature');self.git('branch','-f','main',h);self.local_remote()
        (self.repo/'later').write_text('new work');self.git('add','.');self.git('commit','-qm','later');new=self.git('rev-parse','HEAD');self.git('push','-q','origin','feature')
        d=self.call('delete-branch',branch='feature',merged_tip=h,base_branch='main');self.assertEqual(d['outcome'],'moved');self.assertEqual(d['current'],new)
    def test_issue_squash_excludes_original_messages(self):
        self.github();h='a'*40;s='b'*40;parent='c'*40
        def obj(oid,message,parents,introduced):return dict(oid=oid,message=message,parents=dict(totalCount=len(parents),nodes=[{'oid':x} for x in parents]),associatedPullRequests=dict(totalCount=1 if introduced else 0,nodes=[{'number':1,'repository':{'nameWithOwner':'test/repo'}}] if introduced else []))
        self.state(pr=dict(state='MERGED',mergedAt='2020-01-01T00:00:00Z',baseRefName='main',url='url'),head=h,merge={'oid':s,'message':'Squash','parents':{'totalCount':1}},commits=[{'oid':h,'message':'Fix #10'}],compare='diverged',objects={s:obj(s,'Squash',[parent],True),parent:obj(parent,'old',[],False)},rendered='Fix <a data-hovercard-type="issue" data-url="https://github.com/test/repo/issues/10">#10</a>')
        d=self.call('check-issues',pull_request=1);self.assertEqual(d['landing'],'squash');self.assertEqual(d['issues'],[])
    def test_issue_merged_without_sources_is_not_empty_success(self):
        self.github();self.state(pr=dict(state='MERGED',mergedAt='2020-01-01T00:00:00Z',baseRefName='main',url='url'))
        self.call('check-issues',pull_request=1,ok=False)
    def test_issue_landed_commit_identity_ignores_repository_case(self):
        self.github();head='a'*40;one='b'*40;two='c'*40;parent='d'*40
        def obj(oid,parents,introduced):
            return dict(oid=oid,message='landed',parents=dict(totalCount=len(parents),nodes=[{'oid':x} for x in parents]),associatedPullRequests=dict(totalCount=int(introduced),nodes=[{'number':1,'repository':{'nameWithOwner':'Test/Repo'}}] if introduced else []))
        for landing,merge,listed,objects in [
            ('squash',one,[head],{one:obj(one,[parent],True),parent:obj(parent,[],False)}),
            ('rebase',two,[head,'e'*40],{two:obj(two,[one],True),one:obj(one,[parent],True),parent:obj(parent,[],False)}),
        ]:
            with self.subTest(landing=landing):
                self.state(pr=dict(state='MERGED',mergedAt='2020-01-01T00:00:00Z',baseRefName='main',url='url'),head=head,merge={'oid':merge,'message':'landed','parents':{'totalCount':1}},commits=[{'oid':x,'message':'original'} for x in listed],compare='diverged',objects=objects)
                d=self.call('check-issues',pull_request=1)
                self.assertEqual(d['landing'],landing)
    def test_issue_repository_case_does_not_hide_unexplained_open_issue(self):
        self.github();head='a'*40;merge='b'*40
        for repository,cross_repository in [('Test/Repo',False),('other/repo',True)]:
            with self.subTest(repository=repository):
                self.state(pr=dict(state='MERGED',mergedAt='2020-01-01T00:00:00Z',baseRefName='main',url='url'),head=head,merge={'oid':merge,'message':'Merge','parents':{'totalCount':2}},commits=[{'oid':head,'message':'work'}],closing=[dict(url='https://github.com/'+repository+'/issues/9',number=9,repository={'nameWithOwner':repository})],issue={'state':'OPEN','closedAt':None})
                d=self.call('check-issues',pull_request=1)
                self.assertFalse(d['allClosed'])
                findings=d['issues'][0]['findings']
                self.assertEqual(any('It lives in' in x for x in findings),cross_repository)
                self.assertEqual(any('No cause found' in x for x in findings),not cross_repository)
    def test_installer_check_only_makes_no_directories(self):
        home=self.root/'fresh home';p=subprocess.run(['bash',str(ROOT/'install.sh'),'--home',str(home),'--check-only'],capture_output=True,text=True)
        self.assertEqual(p.returncode,0,p.stderr);self.assertFalse(home.exists())
    def test_aggregate_gate_does_not_hide_a_failure(self):
        root=self.root/'gate fixture';(root/'tools').mkdir(parents=True);shutil.copy(ROOT/'tools/verify.sh',root/'tools/verify.sh')
        for suite,code in [('bootstrap-linux',0),('integrate-linux',17),('release-linux',0),('crossreview',0)]:
            path=root/'tests'/suite;path.mkdir(parents=True);(path/'run-tests.sh').write_text('#!/bin/sh\necho '+suite+'\nexit '+str(code)+'\n')
        p=subprocess.run(['bash',str(root/'tools/verify.sh')],capture_output=True,text=True);self.assertEqual(p.returncode,1);self.assertIn('release',p.stdout);self.assertIn('crossreview',p.stdout);self.assertNotIn('Verification passed',p.stdout)
    def test_aggregate_gate_ignores_cdpath_for_relative_invocation(self):
        root=self.root/'gate fixture';decoy=self.root/'decoy'
        (root/'tools').mkdir(parents=True);(decoy/'tools').mkdir(parents=True)
        shutil.copy(ROOT/'tools/verify.sh',root/'tools/verify.sh')
        for directory,code in [(root,0),(decoy,77)]:
            for suite in ['bootstrap-linux','integrate-linux','release-linux','crossreview']:
                path=directory/'tests'/suite;path.mkdir(parents=True)
                (path/'run-tests.sh').write_text('#!/bin/sh\necho '+suite+'-fixture\nexit '+str(code)+'\n')
        for cdpath in ['.:',str(decoy)+':.']:
            with self.subTest(cdpath=cdpath):
                p=subprocess.run(['bash','tools/verify.sh'],cwd=root,env=dict(self.env,CDPATH=cdpath),capture_output=True,text=True)
                self.assertEqual(p.returncode,0,(p.stdout,p.stderr))
                for suite in ['bootstrap-linux','integrate-linux','release-linux','crossreview']:self.assertIn(suite+'-fixture',p.stdout)
    def test_direct_release_runner_does_not_run_cdpath_decoy_suite(self):
        root=self.root/'suite fixture';decoy=self.root/'decoy'
        for directory,body in [(root,"self.fail('intended suite executed')"),(decoy,'pass')]:
            suite=directory/'tests/release-linux';suite.mkdir(parents=True)
            (suite/'test_identity.py').write_text('import unittest\nclass Identity(unittest.TestCase):\n def test_identity(self): '+body+'\n')
        shutil.copy(ROOT/'tests/release-linux/run-tests.sh',root/'tests/release-linux/run-tests.sh')
        p=subprocess.run(['bash','tests/release-linux/run-tests.sh'],cwd=root,env=dict(self.env,CDPATH=str(decoy)+':.'),capture_output=True,text=True)
        self.assertNotEqual(p.returncode,0,(p.stdout,p.stderr))
        self.assertIn('intended suite executed',p.stderr)
    def test_documented_landing_message_preserves_literal_titles(self):
        skill=(ROOT/'skills/ba-integrate/SKILL.md').read_text()
        template=next(block for block in re.findall(r'```bash\n(.*?)```',skill,re.S) if 'bash scripts/land.sh' in block)
        scripts=self.root/'scripts';scripts.mkdir()
        (scripts/'land.sh').write_text('python3 -c \'import json,sys; print(json.dumps(sys.argv[1:]))\' "$@"\n')
        gh=self.root/'gh';gh.write_text('#!/usr/bin/env python3\nimport os,sys\nassert sys.argv[1:]==["pr","view","1","--repo","test/repo","--json","title","--jq",".title"]\nprint(os.environ["FIXTURE_TITLE"])\n');gh.chmod(0o755)
        for title in ["Keep Cicely's notes","Don't drop Cicely's notes",r'Parse C:\temp paths',"x'; touch injected; echo '",'$(touch injected) `touch injected` "quoted"']:
            with self.subTest(title=title):
                (self.root/'injected').unlink(missing_ok=True)
                command=template
                for key,value in {'<n>':'1','<owner>':'test','<repo>':'repo','<branch>':'feature','<title>':title,'<rehearsal>':'worktree',"<update's commit>":'updated','<base>':'main','<approved head>':'head','<expected base>':'base','<step commit>':'rehearsed'}.items():command=command.replace(key,value)
                p=subprocess.run(['bash','-c',command],cwd=self.root,env=dict(self.env,PATH=str(self.root)+os.pathsep+self.env['PATH'],FIXTURE_TITLE=title),capture_output=True,text=True)
                self.assertFalse((self.root/'injected').exists(),'title executed as shell code')
                self.assertEqual(p.returncode,0,p.stderr)
                args=json.loads(p.stdout)
                self.assertEqual(args[args.index('--message')+1],'Merge pull request #1 from test/feature\n\n'+title)

    def test_partial_graphql_page_is_never_empty_success(self):
        self.github();self.state(graphql_pages=[{'data':{'repository':{'pullRequests':{'nodes':[],'pageInfo':{}}}}}])
        self.call('retarget',branch='feature',base_branch='main',approved='none',ok=False)
    def test_update_does_not_abandon_existing_merge(self):
        h=self.branch('feature','feature');b=self.branch('newbase','base update');self.git('merge','--no-ff','--no-commit',h,ok=False)
        (self.repo/'file [one].txt').write_text('user resolution');self.git('add','.')
        self.call('update',head=h,base=b,rehearsed=h,ok=False)
        self.assertTrue((self.repo/'.git/MERGE_HEAD').exists());self.assertEqual((self.repo/'file [one].txt').read_text(),'user resolution')
    def test_update_replays_kept_file_and_deleted_file(self):
        h=self.branch('feature','feature');self.git('checkout','-qb','deletedbase',self.base);self.git('rm','--','file [one].txt');self.git('commit','-qm','delete');b=self.git('rev-parse','HEAD')
        self.git('merge','--no-ff','--no-commit',h,ok=False);self.git('rm','--force','--','file [one].txt');self.git('commit','-qm','resolve deletion');deleted=self.git('rev-parse','HEAD')
        d=self.call('update',head=h,base=b,rehearsed=deleted);self.assertTrue(d['matches']);self.assertFalse((self.repo/'file [one].txt').exists())
        self.git('checkout','--detach',b);self.git('merge','--no-ff','--no-commit',h,ok=False);self.git('checkout',h,'--','file [one].txt');self.git('commit','-qm','resolve keep');kept=self.git('rev-parse','HEAD')
        d=self.call('update',head=h,base=b,rehearsed=kept);self.assertTrue(d['matches']);self.assertEqual((self.repo/'file [one].txt').read_text(),'feature\n')
    def test_land_base_moved_and_retargeted_pr_refuse(self):
        h=self.branch('feature','feature');self.local_remote();args=dict(pull_request=1,branch='feature',approved_head=h,updated=h,base_branch='main',expected_base=self.base,rehearsed=h,message='fixture',timeout_seconds=0)
        self.state(pr=dict(state='OPEN',isDraft=False,headRefName='feature',headRefOid=h,baseRefName='elsewhere'));self.call('land',ok=False,**args)
        self.git('push','-q','origin','feature:main');self.call('land',ok=False,**args)
    def test_non_github_remote_and_credentials_are_safe(self):
        self.git('remote','add','origin','https://secret-token@example.invalid/test/repo.git')
        d=self.call('retarget',branch='feature',base_branch='main',list=True,ok=False);self.assertNotIn('secret-token',json.dumps(d));self.assertIn('***@',d['error'])
        self.git('remote','set-url','origin','https://secret-token@github.com/test/repo.git');self.state(warning=True)
        d=self.call('retarget',branch='feature',base_branch='main',approved='none');self.assertNotIn('secret-token',json.dumps(d));self.assertEqual(d['remaining'],[])
    def test_delete_unmerged_branch_and_service_failure_preserve_tip(self):
        h=self.branch('feature','feature');self.local_remote();self.call('delete-branch',branch='feature',merged_tip=h,base_branch='main',ok=False)
        self.git('push','-q','origin','feature:main');self.state(fail=True);self.call('delete-branch',branch='feature',merged_tip=h,base_branch='main',ok=False);self.assertEqual(self.git('ls-remote','origin','refs/heads/feature').split()[0],h)

    def prepared_landing(self):
        h=self.branch('feature','feature');self.git('checkout','main')
        (self.repo/'base new file').write_text('base work');self.git('add','.');self.git('commit','-qm','new base');b=self.git('rev-parse','HEAD')
        self.git('checkout','-qb','updated','feature');self.git('merge','--no-ff','-m','update','main');u=self.git('rev-parse','HEAD');remote=self.local_remote()
        self.state(pr=dict(state='OPEN',isDraft=False,headRefName='feature',headRefOid=u,baseRefName='main'))
        return h,b,u,remote,dict(pull_request=1,branch='feature',approved_head=h,updated=u,base_branch='main',expected_base=b,rehearsed=u,message='fixture',timeout_seconds=0,poll_seconds=0)
    def test_base_moved_back_after_check_is_not_restored(self):
        h,b,u,remote,args=self.prepared_landing()
        hook=self.repo/'.git/hooks/pre-commit';hook.write_text('#!/usr/bin/env python3\nimport subprocess\nsubprocess.run('+repr(['git','--git-dir',str(remote),'update-ref','refs/heads/main',self.base])+',check=True)\n');hook.chmod(0o755)
        d=self.call('land',ok=False,**args);self.assertTrue(d['branchPushed']);self.assertFalse(d['landed']);self.assertEqual(self.git('ls-remote','origin','refs/heads/main').split()[0],self.base);self.assertEqual(self.git('ls-remote','origin','refs/heads/feature').split()[0],u)
    def test_branch_vanished_after_check_is_not_recreated(self):
        h,b,u,remote,args=self.prepared_landing()
        hook=self.repo/'.git/hooks/pre-commit';hook.write_text('#!/usr/bin/env python3\nimport subprocess\nsubprocess.run('+repr(['git','--git-dir',str(remote),'update-ref','-d','refs/heads/feature'])+',check=True)\n');hook.chmod(0o755)
        d=self.call('land',ok=False,**args);self.assertFalse(d['branchPushed']);self.assertFalse(d['landed']);self.assertEqual(self.git('ls-remote','origin','refs/heads/feature'),'');self.assertEqual(self.git('ls-remote','origin','refs/heads/main').split()[0],b)
    def test_partial_retarget_failure_reports_completed_edits(self):
        self.github();self.state(targeting=[dict(number=n,title=str(n),url='url',isDraft=False) for n in [1,2]],fail_edit=2)
        d=self.call('retarget',branch='feature',base_branch='main',approved='1,2',ok=False);self.assertEqual(d['retargeted'],[1]);self.assertEqual([p['number'] for p in json.loads(self.data.read_text())['targeting']],[2])
    def test_issue_rebase_audits_copies_not_original_commits(self):
        self.github();h='a'*40;one='b'*40;two='c'*40;parent='d'*40;url='https://github.com/test/repo/issues/9'
        def obj(oid,message,parents,introduced):return dict(oid=oid,message=message,parents=dict(totalCount=len(parents),nodes=[{'oid':x} for x in parents]),associatedPullRequests=dict(totalCount=1 if introduced else 0,nodes=[{'number':1,'repository':{'nameWithOwner':'test/repo'}}] if introduced else []))
        self.state(pr=dict(state='MERGED',mergedAt='2020-01-01T00:00:00Z',baseRefName='other',url='url'),head=h,merge={'oid':two,'message':'last copy','parents':{'totalCount':1}},commits=[{'oid':h,'message':'original'},{'oid':'e'*40,'message':'original'}],compare='diverged',objects={two:obj(two,'last copy',[one],True),one:obj(one,'Fix #9',[parent],True),parent:obj(parent,'old',[],False)},rendered='Fix <a data-hovercard-type="issue" data-url="'+url+'">#9</a>',issue={'state':'OPEN','closedAt':None})
        d=self.call('check-issues',pull_request=1);self.assertEqual(d['landing'],'rebase');self.assertEqual(d['issues'][0]['commits'],['bbbbbbbb']);self.assertIn('other',d['issues'][0]['findings'][0])

    def test_invalid_cli_is_structured_failure(self):
        for name in ['survey','update','land','retarget','delete-branch','check-issues']:
            p=subprocess.run(['bash',str(SCRIPTS/(name+'.sh')),'--unknown'],capture_output=True,text=True)
            self.assertEqual(p.returncode,1,(name,p.stdout,p.stderr));self.assertIn('error',json.loads(p.stdout))

if __name__=='__main__' :unittest.main()

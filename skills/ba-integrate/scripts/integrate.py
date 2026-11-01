#!/usr/bin/env python3
"""Native Linux integration operations. All external commands use argument arrays."""
import argparse
import datetime as dt
import html
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time


def redact(text):
    return re.sub(r'([A-Za-z][A-Za-z0-9+.-]*://)[^\s/]+@', r'\1***@', str(text))


def run(args, cwd, allowed=(0,)):
    p = subprocess.run(args, cwd=cwd, text=True, encoding='utf-8', errors='replace', capture_output=True)
    if p.returncode not in allowed:
        raise RuntimeError(f'{args[0]} {" ".join(args[1:])} failed ({p.returncode}): {p.stdout} {p.stderr}')
    return p


class Repo:
    def __init__(self, path):
        self.path = str(pathlib.Path(path).resolve(strict=True))
        self.git('rev-parse', '--git-dir')
    def git(self, *args, allowed=(0,)):
        return run(['git', '--literal-pathspecs', '-c', 'core.quotePath=false', '-C', self.path, *args], self.path, allowed)
    def text(self, *args):
        return self.git(*args).stdout.strip()
    def paths(self, *args):
        return [p for p in self.git(*args, '-z').stdout.split('\0') if p]
    def resolve(self, rev, what):
        p = self.git('rev-parse', '--verify', '--quiet', rev+'^{commit}', allowed=(0,1,128))
        if p.returncode or not p.stdout.strip():
            raise RuntimeError(f'{what} {rev} is not a commit in this repository.')
        return p.stdout.strip()
    def exists(self, sha):
        return self.git('cat-file','-e',sha+'^{commit}',allowed=(0,1,128)).returncode == 0
    def ancestor(self, a, b):
        return self.git('merge-base','--is-ancestor',a,b,allowed=(0,1)).returncode == 0
    def merging(self):
        return self.git('rev-parse','--quiet','--verify','MERGE_HEAD',allowed=(0,1)).returncode == 0
    def clean(self):
        return not self.git('status','--porcelain','--untracked-files=no').stdout.strip() and not self.merging()
    def tree(self, sha):
        return self.text('rev-parse',sha+'^{tree}')
    def remote(self, remote, branch):
        # Validate names before constructing refspecs or lease expressions.
        self.git('check-ref-format','refs/heads/'+branch)
        lines = self.text('ls-remote','--heads',remote,'refs/heads/'+branch).splitlines()
        return next((x.split()[0] for x in lines if x.split()[-1]=='refs/heads/'+branch),None)
    def github(self, remote='origin'):
        def config(key):
            return self.git('config','--get-all',key,allowed=(0,1)).stdout.splitlines()
        configured = config('remote.'+remote+'.pushurl') or config('remote.'+remote+'.url')
        if len(configured)!=1:
            raise RuntimeError(f'{remote} must have exactly one push destination; nothing was changed.')
        named = github_url(configured[0])
        if not named:
            raise RuntimeError(f'{remote} ({configured[0]}) is not a github.com repository; nothing was changed.')
        effective = self.text('remote','get-url','--push','--all',remote).splitlines()
        if len(effective)!=1:
            raise RuntimeError('Remote has multiple destinations after URL rewriting; nothing was changed.')
        rewritten=github_url(effective[0])
        if not rewritten:
            raise RuntimeError(f'{remote} has a push destination outside github.com after URL rewriting; nothing was changed.')
        if rewritten.lower()!=named.lower():
            raise RuntimeError(f'{remote} is configured as {named}, but a URL rewrite sends pushes to {rewritten}; nothing was changed.')
        return named


def github_url(url):
    m=re.fullmatch(r'(?:https://(?:[^@/\s]+@)?github\.com/|git@github\.com:|ssh://git@github\.com/)([\w.-]+)/([\w.-]+?)(?:\.git)?/?',url)
    return '/'.join(m.groups()) if m else None


class GitHub:
    def __init__(self, repo, command=None):
        self.repo=repo
        self.command=command or shutil.which('gh')
        if not self.command: raise RuntimeError('The GitHub CLI (gh) is not installed or not on PATH.')
    def raw(self,*args): return run([self.command,*args],self.repo.path).stdout
    def call(self,*args):
        value=json.loads(self.raw(*args))
        if isinstance(value,dict) and value.get('errors'): raise RuntimeError('GitHub GraphQL errors: '+json.dumps(value['errors']))
        return value
    def query(self,query,**variables):
        args=['api','graphql','-f','query='+query]
        for k,v in variables.items():
            if v is not None: args += ['-F' if isinstance(v,(bool,int)) else '-f',k+'='+ (str(v).lower() if isinstance(v,bool) else str(v))]
        value=self.call(*args)
        if not value.get('data'): raise RuntimeError('GitHub returned no query data.')
        return value['data']
    def connection(self,query,select,**variables):
        nodes=[];after=None;seen=set();total=None
        while True:
            page=select(self.query(query,**variables,after=after))
            if not isinstance(page,dict) or not isinstance(page.get('nodes'),list) or not isinstance(page.get('pageInfo'),dict) or not isinstance(page['pageInfo'].get('hasNextPage'),bool):
                raise RuntimeError('GitHub returned no complete connection; refusing a partial audit.')
            nodes.extend(page['nodes']);total=page.get('totalCount',total)
            if not page['pageInfo'].get('hasNextPage'):break
            after=page['pageInfo'].get('endCursor')
            if not after or after in seen: raise RuntimeError('GitHub reported more records without a new cursor; audit would be incomplete.')
            seen.add(after)
        if total is not None and len(nodes)!=total: raise RuntimeError(f'Read {len(nodes)} of {total} records; audit would be incomplete.')
        return nodes
    def targeting(self,here,branch):
        owner,name=here.split('/',1)
        query='''query($owner:String!,$name:String!,$branch:String!,$after:String){repository(owner:$owner,name:$name){pullRequests(states:OPEN,baseRefName:$branch,first:100,after:$after){pageInfo{hasNextPage endCursor} nodes{number url title isDraft}}}}'''
        return self.connection(query,lambda d:d['repository']['pullRequests'],owner=owner,name=name,branch=branch)


def update(a,r,out):
    h=r.resolve(a.head,'Head');b=r.resolve(a.base,'Base');s=r.resolve(a.rehearsed,'Rehearsed step')
    out.update(head=h,base=b,rehearsed=s)
    if not r.clean():raise RuntimeError('The integration worktree has uncommitted changes or a merge in progress; nothing was changed.')
    started=False
    try:
        r.git('checkout','--quiet','--detach',h)
        up=r.ancestor(b,h);replayed=[]
        if not up:
            started=True;r.git('merge','--no-ff','--no-commit','--no-edit',b,allowed=(0,1))
            replayed=sorted(set(r.paths('diff','--name-only','--diff-filter=U')))
            for path in replayed:
                kept=r.git('cat-file','-e',s+':'+path,allowed=(0,1,128)).returncode==0
                if kept:r.git('checkout',s,'--',path)
                else:r.git('rm','--quiet','--force','--',path)
            if r.paths('diff','--name-only','--diff-filter=U'):raise RuntimeError('Paths still unmerged after replaying the rehearsal.')
            if r.merging():r.git('commit','--quiet','-m',a.message)
        out.update(commit=r.text('rev-parse','HEAD'),tree=r.tree('HEAD'),rehearsedTree=r.tree(s),upToDate=up,replayed=replayed)
        out['matches']=out['tree']==out['rehearsedTree']
        if not out['matches']:
            out['differences']=r.paths('diff','--name-only',s,'HEAD')
            raise RuntimeError('The updated head differs from the rehearsed step in: '+', '.join(out['differences']))
    finally:
        if started and r.merging():r.git('merge','--abort')


def conflicts(r,left,right):
    p=r.git('merge-tree','--write-tree','--name-only','--no-messages','-z',left,right,allowed=(0,1))
    return sorted(set(x for x in p.stdout.split('\0')[1:] if x)) if p.returncode else []


def survey(a,r,out):
    live=not a.pull_requests_json
    if live:r.git('fetch','--quiet','--no-tags','origin')
    base=a.base
    if not base:
        base=r.git('symbolic-ref','--quiet','--short','refs/remotes/origin/HEAD',allowed=(0,1)).stdout.strip() or 'origin/main'
    branch=base.removeprefix('origin/');sha=r.resolve(base,'Base')
    if live:
        gh=GitHub(r,a.github_cli);owner,name=r.github().split('/',1)
        query='''query($owner:String!,$name:String!,$after:String){repository(owner:$owner,name:$name){pullRequests(states:OPEN,first:100,after:$after,orderBy:{field:CREATED_AT,direction:ASC}){pageInfo{hasNextPage endCursor} nodes{number title url isDraft isCrossRepository createdAt headRefName headRefOid baseRefName mergeable reviewDecision reviewThreads(first:100){pageInfo{hasNextPage endCursor} nodes{isResolved}}}}}}'''
        prs=gh.connection(query,lambda d:d['repository']['pullRequests'],owner=owner,name=name)
        for pr in prs:
            threads=pr.get('reviewThreads')
            if not isinstance(threads,dict): raise RuntimeError('GitHub returned no review threads.')
            count=sum(not t['isResolved'] for t in threads['nodes']);after=threads['pageInfo'].get('endCursor');more=threads['pageInfo'].get('hasNextPage');seen=set()
            while more and not pr['isDraft']:
                if not after or after in seen:raise RuntimeError('GitHub reported more review threads without a new cursor.')
                seen.add(after)
                tq='''query($owner:String!,$name:String!,$number:Int!,$after:String){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100,after:$after){pageInfo{hasNextPage endCursor} nodes{isResolved}}}}}'''
                threads=gh.query(tq,owner=owner,name=name,number=pr['number'],after=after)['repository']['pullRequest']['reviewThreads']
                count+=sum(not t['isResolved'] for t in threads['nodes']);more=threads['pageInfo']['hasNextPage'];after=threads['pageInfo'].get('endCursor')
            pr['unresolvedReviewThreads']=count
    else:
        prs=json.loads(pathlib.Path(a.pull_requests_json).read_text())
        if not isinstance(prs,list):raise RuntimeError('Pull requests JSON must be an array.')
    ready=[];unready=[];skipped=[]
    def skip(pr,reason):
        skipped.append(dict(number=pr['number'],reason=reason));unready.append((pr,reason))
    for pr in sorted(prs,key=lambda p:int(p['number'])):
        pr['number']=int(pr['number'])
        if pr.get('isDraft'):skip(pr,'draft')
        elif pr.get('isCrossRepository'):skip(pr,'from a fork')
        else:ready.append(pr)
    while True:
        heads={p['headRefName'] for p in ready};stranded=[p for p in ready if p['baseRefName']!=branch and p['baseRefName'] not in heads]
        if not stranded:break
        for pr in stranded:
            skip(pr,f"targets {pr['baseRefName']}, which is neither {branch} nor a ready PR's branch");ready.remove(pr)
    if live and prs:
        specs=['refs/pull/'+str(p['number'])+'/head' for p in prs]
        if r.git('fetch','--quiet','--no-tags','origin',*specs,allowed=(0,1,128)).returncode:
            for spec in specs:r.git('fetch','--quiet','--no-tags','origin',spec,allowed=(0,1,128))
    for pr in ready:
        if not r.exists(pr['headRefOid']):raise RuntimeError(f"PR #{pr['number']}'s head is not available locally; run the survey again.")
    unchecked=[p['number'] for p,_ in unready if not r.exists(p['headRefOid'])]
    pending=[(p,why) for p,why in unready if r.exists(p['headRefOid']) and not r.ancestor(p['headRefOid'],sha)]
    facts={}
    for pr in ready:
        h=pr['headRefOid'];mb=r.text('merge-base',sha,h);includes=[]
        for other,why in pending:
            if other['baseRefName']==pr['headRefName']:continue
            p=r.git('merge-base',other['headRefOid'],h,allowed=(0,1));shared=p.stdout.strip()
            if p.returncode or not shared or shared==h:continue
            n=int(r.text('rev-list','--count',sha+'..'+shared))
            if n:includes.append(dict(number=other['number'],reason=why,sharedCommits=n))
        facts[pr['number']]=dict(number=pr['number'],title=pr.get('title'),url=pr.get('url'),head=pr['headRefName'],headSha=h,baseRef=pr['baseRefName'],dependsOn=[],includesUnready=includes,commits=int(r.text('rev-list','--count',sha+'..'+h)),behindBase=int(r.text('rev-list','--count',h+'..'+sha)),files=r.paths('diff','--name-only',mb,h),conflictsWithBase=conflicts(r,sha,h),reviewDecision=pr.get('reviewDecision'),unresolvedReviewThreads=pr.get('unresolvedReviewThreads'),mergeable=pr.get('mergeable'),reason=None)
    for p in ready:
        for q in ready:
            if p['number']==q['number'] or p['headRefOid']==q['headRefOid']:continue
            if q['baseRefName']==p['headRefName'] or (facts[p['number']]['commits'] and r.ancestor(p['headRefOid'],q['headRefOid'])):facts[q['number']]['dependsOn'].append(p['number'])
    pairs=[];partners={n:[] for n in facts}
    for i,p in enumerate(ready):
        for q in ready[i+1:]:
            x,y=p['number'],q['number']
            if x in facts[y]['dependsOn'] or y in facts[x]['dependsOn']:continue
            files=conflicts(r,p['headRefOid'],q['headRefOid'])
            if files:pairs.append(dict(between=[x,y],files=files));partners[x].append(y);partners[y].append(x)
    order=[];remaining=set(facts)
    while remaining:
        available=[n for n in remaining if set(facts[n]['dependsOn']).issubset(order)]
        if not available:raise RuntimeError('Pull requests build on each other in a cycle.')
        n=min(available,key=lambda n:(len(partners[n]),n));f=facts[n];why=[]
        if f['dependsOn']:why.append('after '+', '.join('#'+str(x) for x in f['dependsOn'])+', which it builds on')
        why.append('conflicts with '+(', '.join('#'+str(x) for x in sorted(partners[n])) if partners[n] else 'no other ready PR'))
        if f['conflictsWithBase']:why.append(f"conflicts with {branch} in {len(f['conflictsWithBase'])} file(s)")
        if not f['commits']:why.append(f'has no commits that {branch} lacks')
        if f['includesUnready']:why.append('contains the unmerged work of '+', '.join('#'+str(p['number'])+' ('+p['reason']+')' for p in f['includesUnready']))
        f['reason']='; '.join(why);order.append(n);remaining.remove(n)
    out.update(repository=r.path,base=dict(ref=base,branch=branch,sha=sha),order=order,pullRequests=[facts[n] for n in order],conflicts=pairs,skipped=skipped,uncheckedSkipped=unchecked)


def retarget(a,r,out):
    gh=GitHub(r,a.github_cli);here=r.github(a.remote)
    out.update(branch=a.branch,base=a.base_branch,repository=here,targeting=gh.targeting(here,a.branch))
    if a.list:return
    if not a.approved:raise RuntimeError('Retargeting needs --approved numbers or none. Nothing was retargeted.')
    approved=set() if a.approved=='none' else {int(x) for x in re.split(r'[,\s]+',a.approved) if x}
    found={p['number'] for p in out['targeting']}
    if found!=approved:
        out.update(unexpected=sorted(found-approved),missing=sorted(approved-found));raise RuntimeError('The pull requests targeting this branch differ from the plan. Nothing was retargeted.')
    out['retargeted']=[]
    for p in out['targeting']:
        gh.raw('pr','edit',str(p['number']),'--repo',here,'--base',a.base_branch);out['retargeted'].append(p['number'])
    out['remaining']=gh.targeting(here,a.branch)
    if out['remaining']:raise RuntimeError('Pull requests still target the branch after retargeting.')


def delete_branch(a,r,out):
    gh=GitHub(r,a.github_cli);here=r.github(a.remote);out.update(branch=a.branch,deleted=False,repository=here)
    tip=r.resolve(a.merged_tip,'Merged tip')
    r.git('fetch','--quiet','--no-tags',a.remote,'refs/heads/'+a.base_branch);base=r.resolve('FETCH_HEAD',a.base_branch)
    if not r.ancestor(tip,base):raise RuntimeError(f'{tip} is not in {a.base_branch}, so {a.branch} has not merged. Nothing was deleted.')
    current=r.remote(a.remote,a.branch)
    if current==tip:
        dependents=gh.targeting(here,a.branch)
        if dependents:out['dependents']=[dict(number=p['number'],url=p['url']) for p in dependents];raise RuntimeError('Open pull requests still target this branch; retarget them first. Nothing was deleted.')
        p=r.git('push','--quiet','--force-with-lease=refs/heads/'+a.branch+':'+tip,a.remote,':refs/heads/'+a.branch,allowed=(0,1,128))
        if not p.returncode:out.update(deleted=True,outcome='deleted');return
        current=r.remote(a.remote,a.branch)
        if current==tip:raise RuntimeError('Deleting the branch failed though it still points at the merged tip. '+p.stdout+p.stderr)
    out['outcome']='moved' if current else 'absent'
    if current:out['current']=current


def land(a,r,out):
    out.update(pullRequest=a.pull_request,branchPushed=False,landed=False,merged=False)
    gh=GitHub(r,a.github_cli);here=r.github(a.remote)
    approved=r.resolve(a.approved_head,'Approved head');updated=r.resolve(a.updated,'Updated head');expected=r.resolve(a.expected_base,'Expected base');rehearsed=r.resolve(a.rehearsed,'Rehearsed step');tree=r.tree(rehearsed)
    out['branchTip']=updated
    if not r.ancestor(approved,updated):raise RuntimeError('The updated head does not contain the approved head. Nothing was pushed.')
    if not r.ancestor(expected,updated):raise RuntimeError('The updated head does not contain the expected base. Nothing was pushed.')
    if r.tree(updated)!=tree:raise RuntimeError('The updated head differs from the rehearsed step. Nothing was pushed.')
    def view():return gh.call('pr','view',str(a.pull_request),'--repo',here,'--json','state,isDraft,headRefOid,headRefName,baseRefName,closingIssuesReferences')
    def ready(heads,when):
        deadline=time.monotonic()+a.timeout_seconds
        while True:
            p=view()
            if p.get('state')!='OPEN' or p.get('isDraft') or p.get('headRefName')!=a.branch or p.get('baseRefName')!=a.base_branch:
                raise RuntimeError('Pull request is no longer open, ready, on the approved branch and base '+when+'.')
            if p.get('headRefOid') in heads:return
            if time.monotonic()>=deadline:raise RuntimeError('GitHub head differs from the plan '+when+'.')
            time.sleep(a.poll_seconds)
    def push(commit,branch,old):
        if not r.ancestor(old,commit):raise RuntimeError('Refusing to rewrite '+branch)
        r.git('push','--quiet','--force-with-lease=refs/heads/'+branch+':'+old,a.remote,commit+':refs/heads/'+branch)
    remote_base=r.remote(a.remote,a.base_branch);resumed=False
    if remote_base and remote_base!=expected and r.exists(remote_base):
        parents=r.text('rev-list','--parents','-n','1',remote_base).split()[1:]
        resumed=parents==[expected,updated] and r.tree(remote_base)==tree
    started=False
    try:
        if resumed:
            out.update(resumed=True,landed=True,mergeCommit=remote_base,branchPushed=r.remote(a.remote,a.branch)==updated)
        else:
            if remote_base!=expected:raise RuntimeError('Base branch has moved; nothing was pushed.')
            remote_branch=r.remote(a.remote,a.branch)
            if remote_branch not in (approved,updated):raise RuntimeError('Pull request branch has moved; nothing was pushed.')
            ready([approved,updated],'before anything was pushed')
            if not r.clean():raise RuntimeError('The integration worktree has uncommitted changes or a merge in progress. Nothing was pushed.')
            r.git('checkout','--quiet','--detach',expected);started=True
            r.git('merge','--no-ff','--no-commit',updated)
            with tempfile.NamedTemporaryFile(mode='w',encoding='utf-8') as f:
                f.write(a.message);f.flush();r.git('commit','--quiet','-F',f.name)
            merge=r.text('rev-parse','HEAD')
            if r.tree(merge)!=tree:raise RuntimeError('The merge commit differs from the rehearsed step. Nothing was pushed.')
            if remote_branch!=updated:push(updated,a.branch,remote_branch);out['branchPushed']=True
            ready([updated],'after the branch push, before landing; base unchanged')
            push(merge,a.base_branch,expected);out.update(landed=True,mergeCommit=merge)
        deadline=time.monotonic()+a.timeout_seconds;last_error=None;p=None
        while True:
            try:p=view()
            except (RuntimeError,ValueError) as e:last_error=str(e);p=None
            if p and p.get('state')=='MERGED':break
            if time.monotonic()>=deadline:break
            time.sleep(a.poll_seconds)
        out['state']=p.get('state') if p else None
        if not p or p.get('state')!='MERGED':raise RuntimeError('Landed on the base, but GitHub has not confirmed MERGED. Do not delete its branch or start the next step. Run again with the same arguments to resume waiting. '+(last_error or ''))
        out['merged']=True
        out['closingIssues']=[dict(url=x['url'],repository=x['repository']['owner']['login']+'/'+x['repository']['name'],number=x['number']) for x in p.get('closingIssuesReferences',[])]
    finally:
        if started and r.merging():r.git('merge','--abort')


def timestamp(value):
    return dt.datetime.fromisoformat(value.replace('Z','+00:00')).astimezone(dt.timezone.utc)


def check_issues(a,r,out):
    out['pullRequest']=a.pull_request
    gh=GitHub(r,a.github_cli);here=r.github(a.remote);owner,name=here.split('/',1)
    repo=gh.call('repo','view',here,'--json','nameWithOwner,defaultBranchRef');default=repo['defaultBranchRef']['name']
    pr=gh.call('pr','view',str(a.pull_request),'--repo',here,'--json','number,url,state,mergedAt,baseRefName')
    fields=dict(owner=owner,name=name,number=a.pull_request)
    cq='''query ClosingIssues($owner:String!,$name:String!,$number:Int!,$manual:Boolean!,$after:String){repository(owner:$owner,name:$name){pullRequest(number:$number){closingIssuesReferences(first:100,after:$after,userLinkedOnly:$manual){totalCount pageInfo{hasNextPage endCursor} nodes{number url repository{nameWithOwner}}}}}}'''
    closing=gh.connection(cq,lambda d:d['repository']['pullRequest']['closingIssuesReferences'],**fields,manual=False)
    manual={p['url'] for p in gh.connection(cq,lambda d:d['repository']['pullRequest']['closingIssuesReferences'],**fields,manual=True)}
    pq='''query PullRequestCommits($owner:String!,$name:String!,$number:Int!,$after:String){repository(owner:$owner,name:$name){pullRequest(number:$number){headRefOid mergeCommit{oid message parents(first:2){totalCount}} commits(first:100,after:$after){totalCount pageInfo{hasNextPage endCursor} nodes{commit{oid message}}}}}}'''
    record={}
    def commit_page(d):
        nonlocal record
        p=d['repository']['pullRequest']
        if not record:record=p
        return p['commits']
    listed=[p['commit'] for p in gh.connection(pq,commit_page,**fields)]
    merge=record.get('mergeCommit');head=record['headRefOid'];landing=None
    commits=[dict(p,landedAsMerge=bool(merge and p['oid']==merge['oid'])) for p in listed]
    if pr['state']=='MERGED':
        if not merge:raise RuntimeError('GitHub reports the pull request merged without its merge commit; audit would be incomplete.')
        if not listed:raise RuntimeError('GitHub lists no commits for a merged pull request; which messages landed is unknown.')
        if merge['oid']==head:landing='fast-forward'
        else:
            status=gh.call('api',f"repos/{here}/compare/{head}...{merge['oid']}?per_page=1").get('status')
            if status not in ('ahead','identical','behind','diverged'):raise RuntimeError('GitHub comparison does not establish which commits landed.')
            if status in ('ahead','identical'):
                landing='merge' if merge['parents']['totalCount']>=2 else 'fast-forward'
                commits.append(dict(oid=merge['oid'],message=merge['message'],landedAsMerge=True))
            else:
                query='''query LandedCommit($owner:String!,$name:String!,$oid:GitObjectID!){repository(owner:$owner,name:$name){object(oid:$oid){... on Commit{oid message parents(first:100){totalCount nodes{oid}} associatedPullRequests(first:10){totalCount nodes{number repository{nameWithOwner}}}}}}}'''
                landed={};seen=set();queue=[merge['oid']]
                while queue:
                    oid=queue.pop(0)
                    if oid in seen:continue
                    seen.add(oid)
                    c=gh.query(query,owner=owner,name=name,oid=oid)['repository']['object']
                    if not c or not c.get('oid'):raise RuntimeError('GitHub returned no landed commit; audit would be incomplete.')
                    assoc=c['associatedPullRequests'];introduced=any(p['number']==a.pull_request and p['repository']['nameWithOwner'].lower()==here.lower() for p in assoc['nodes'])
                    if len(c['parents']['nodes'])!=c['parents']['totalCount'] or (not introduced and len(assoc['nodes'])!=assoc['totalCount']):raise RuntimeError('GitHub returned a partial landed commit record; audit would be incomplete.')
                    if not introduced:
                        if oid==merge['oid']:raise RuntimeError('GitHub does not record the pull request as introducing its merge commit; which messages landed is unknown.')
                        continue
                    landed[oid]=dict(oid=c['oid'],message=c['message'],landedAsMerge=oid==merge['oid'])
                    if len(landed)>len(listed)+1:raise RuntimeError('More introduced commits than listed; which messages landed is unknown.')
                    queue.extend(p['oid'] for p in c['parents']['nodes'])
                commits=list(landed.values());landing='merge' if merge['parents']['totalCount']>=2 else ('squash' if len(commits)==1 else 'rebase')
    expected={}
    def add(url,repository,number,source):
        if url not in expected:expected[url]=dict(url=url,repository=repository,number=number,linked=False,manualLink=False,commits=[],inMergeCommit=False)
        e=expected[url]
        if source=='linked':e.update(linked=True,manualLink=url in manual)
        elif source=='merge':e['inMergeCommit']=True
        elif source not in e['commits']:e['commits'].append(source);e['commits'].sort()
    for ref in closing:add(ref['url'],ref['repository']['nameWithOwner'],ref['number'],'linked')
    keyword=r'\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b'
    for commit in commits:
        if not re.search(keyword,commit['message'],re.I):continue
        with tempfile.NamedTemporaryFile(mode='w',encoding='utf-8') as f:
            json.dump(dict(text=commit['message'],mode='gfm',context=here),f);f.flush()
            rendered=gh.raw('api','--method','POST','markdown','--input',f.name)
        for match in re.finditer(keyword+r':?\s+<a\s([^>]*)>',rendered,re.I):
            attrs=match[1]
            if not re.search(r'\bdata-hovercard-type="issue"',attrs):continue
            link=re.search(r'\bdata-url="https://github\.com/([^/\"]+/[^/\"]+)/issues/(\d+)"',attrs)
            if link:add(f'https://github.com/{link[1]}/issues/{link[2]}',html.unescape(link[1]),int(link[2]),'merge' if commit['landedAsMerge'] else commit['oid'][:8])
    merged_at=timestamp(pr['mergedAt']) if pr.get('mergedAt') else None
    ago=int((dt.datetime.now(dt.timezone.utc)-merged_at).total_seconds()) if merged_at else None
    for e in expected.values():
        e['linkedBy']='manual link' if e['manualLink'] else ('description keyword' if e['linked'] else ('commit keyword' if e['commits'] else 'merge commit keyword'))
        issue=gh.call('issue','view',e['url'],'--json','state,stateReason,closedAt');e.update(state=issue['state'],closedAt=issue.get('closedAt'),findings=[]);findings=e['findings']
        if issue['state']=='CLOSED':continue
        if pr['state']!='MERGED':findings.append(f"#{a.pull_request} has not merged; it is {pr['state']}.")
        elif pr['baseRefName']!=default:findings.append(f"#{a.pull_request} merged into {pr['baseRefName']}, not the default branch {default}, and GitHub closes issues only for pull requests merged into the default branch.")
        if e['repository'].lower()!=here.lower():findings.append(f"It lives in {e['repository']}, not {here}.")
        if pr['state']=='MERGED' and merged_at:
            events=[];page=1
            while True:
                items=gh.call('api',f"repos/{e['repository']}/issues/{e['number']}/timeline?per_page=100&page={page}")
                if not isinstance(items,list):raise RuntimeError('GitHub returned no issue timeline array.')
                events.extend(x for x in items if x.get('event') in ('closed','reopened') and timestamp(x['created_at'])>=merged_at)
                if len(items)<100:break
                page+=1
            reopened=next((x for x in reversed(events) if x['event']=='reopened'),None)
            if reopened:
                closed=next((x for x in reversed(events) if x['event']=='closed' and timestamp(x['created_at'])<=timestamp(reopened['created_at'])),None)
                prefix=f"It was closed at {closed['created_at']}, after this merge, and reopened" if closed else 'It was reopened'
                findings.append(f"{prefix} by {reopened['actor']['login']} at {reopened['created_at']}, after this merge.")
        if pr['state']=='MERGED' and ago is not None and ago<a.recent_seconds:findings.append(f'#{a.pull_request} merged only {ago} seconds ago, so GitHub may still be processing it; check again shortly.')
        if not findings:findings.append('No cause found: GitHub should have closed it. Look at the issue and the pull request by hand.')
    out.update(url=pr.get('url'),state=pr['state'],mergedAt=pr.get('mergedAt'),mergeCommit=merge['oid'] if pr['state']=='MERGED' else None,landing=landing,baseRef=pr['baseRefName'],defaultBranch=default,allClosed=all(e['state']=='CLOSED' for e in expected.values()),issues=list(expected.values()))


class JsonArgumentParser(argparse.ArgumentParser):
    def error(self,message):
        print(json.dumps({"error": message}))
        self.exit(1)


def main():
    parser=JsonArgumentParser(description=__doc__)
    subs=parser.add_subparsers(dest='command',required=True)
    specs={
        'survey':('repository',),
        'update':('worktree','head','base','rehearsed'),
        'land':('worktree','pull-request','branch','approved-head','updated','base-branch','expected-base','rehearsed','message'),
        'retarget':('repository','branch','base-branch'),
        'delete-branch':('repository','branch','merged-tip','base-branch'),
        'check-issues':('repository','pull-request')}
    for name,required in specs.items():
        p=subs.add_parser(name)
        for key in required:p.add_argument('--'+key,required=True,type=int if key=='pull-request' else str)
        if name!='update':p.add_argument('--github-cli')
        if name not in ('survey','update'):p.add_argument('--remote',default='origin')
        if name=='survey':p.add_argument('--base');p.add_argument('--pull-requests-json')
        if name=='update':p.add_argument('--message',default='Merge the integration base into this pull request')
        if name=='retarget':p.add_argument('--list',action='store_true');p.add_argument('--approved')
        if name=='check-issues':p.add_argument('--recent-seconds',type=int,default=120)
        if name=='land':p.add_argument('--timeout-seconds',type=float,default=120);p.add_argument('--poll-seconds',type=float,default=5)
    a=parser.parse_args();out={}
    try:
        for key in ('timeout_seconds','poll_seconds','recent_seconds'):
            if getattr(a,key,0)<0:raise RuntimeError('--'+key.replace('_','-')+' cannot be negative.')
        r=Repo(getattr(a,'repository',None) or a.worktree)
        globals()[a.command.replace('-','_')](a,r,out)
    except (Exception,KeyboardInterrupt) as e:
        out['error']=redact(str(e) or 'Interrupted');print(json.dumps(out,ensure_ascii=False));return 1
    print(json.dumps(out,ensure_ascii=False));return 0


if __name__=='__main__':sys.exit(main())

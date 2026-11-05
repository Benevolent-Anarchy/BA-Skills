#!/usr/bin/env python3
"""Native Linux bootstrap, preserving frozen preparation and remote identity receipts."""
import argparse
import base64
import contextlib
import datetime
import fcntl
import hashlib
import html
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile

sys.dont_write_bytecode=True

ASSETS=Path(__file__).resolve().parent.parent/'assets'
STABLE=r'(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)'
REGISTRY='https://raw.githubusercontent.com/obsidianmd/obsidian-releases/master/community-plugins.json'

def now(): return datetime.datetime.now(datetime.timezone.utc).isoformat()
def sha(data): return hashlib.sha256(data.encode() if isinstance(data,str) else data).hexdigest()
def compact(value): return json.dumps(value,ensure_ascii=False,separators=(',',':'))
def read_json(path): return json.loads(Path(path).read_text(encoding='utf-8'))
def atomic_json(path,data):
    path=Path(path); owned(path.parent,path); path.parent.mkdir(parents=True,exist_ok=True)
    fd,name=tempfile.mkstemp(prefix=path.name+'.',suffix='.tmp',dir=path.parent)
    try:
        with os.fdopen(fd,'w',encoding='utf-8',newline='\n') as stream:
            json.dump(data,stream,ensure_ascii=False,indent=2); stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
        os.replace(name,path)
    finally:
        if Path(name).exists(): Path(name).unlink()
def owned(root,path):
    root=Path(os.path.abspath(root)); path=Path(os.path.abspath(path))
    if not path.is_relative_to(root): raise ValueError('Path escapes its ownership root: '+str(path))
    cursor=path
    while cursor!=root.parent:
        if cursor.is_symlink(): raise ValueError('Linked path conflict: '+str(cursor))
        if cursor==root: break
        cursor=cursor.parent
    return path

def relative(path):
    if not isinstance(path,str) or not path or path.startswith('/') or re.search(r'[\\:\x00-\x1f<>"|?*]',path): raise ValueError('Unsafe manifest path: '+str(path))
    for part in path.split('/'):
        if part in ('','.','..','.git') or re.match(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',part,re.I) or part.endswith(('.',' ')): raise ValueError('Unsafe manifest path: '+path)
    return path

def repository_name(name):
    result=re.sub(r'\s+','-',name.strip())
    if not result or not re.fullmatch(r'[A-Za-z0-9._-]+',result) or len(result+'-release-notes')>100 or re.match(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',result,re.I) or result.endswith('.') or result.lower()=='.git': raise ValueError('Invalid or reserved project repository name')
    return result

def identity(name,description,parent,owner='Benevolent-Anarchy'):
    repo=repository_name(name)
    if not description or not description.strip(): raise ValueError('Project description is required')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]{0,38}',owner) or owner.endswith('-'): raise ValueError('Invalid GitHub owner')
    parent=Path(parent).expanduser()
    if not parent.is_absolute(): raise ValueError('Parent must be an absolute directory path')
    parent=Path(os.path.abspath(parent)); ancestor=parent
    while not ancestor.exists() and ancestor!=ancestor.parent: ancestor=ancestor.parent
    if not ancestor.is_dir(): raise ValueError('Parent is not a usable directory')
    project=parent/repo
    return dict(title=name.strip(),description=description.strip(),owner=owner,repository=repo,fullName=owner+'/'+repo,notesRepository=repo+'-release-notes',notesFullName=owner+'/'+repo+'-release-notes',parent=str(parent),projectPath=str(project),vaultPath=str(project/'docs'),defaultBranch='main')

def selection(id,preset='godot',renderer=None,app_identifier=None):
    if preset not in ('foundation','godot','tauri'): raise ValueError('Invalid preset')
    if renderer is not None and preset!='godot': raise ValueError('Renderer is a Godot-only option')
    if app_identifier is not None and preset!='tauri': raise ValueError('Application identifier is a Tauri-only option')
    result=dict(name=preset,recipeVersion=1,renderer=None,appIdentifier=None,packageName=None,crateName=None)
    if preset=='godot':
        renderer='compatibility' if renderer is None else renderer
        if renderer not in ('compatibility','mobile','forward-plus'): raise ValueError('Invalid Godot renderer')
        result['renderer']=renderer
    if preset=='tauri':
        name=re.sub(r'[^a-z0-9-]+','-',id['repository'].lower()).strip('-') or 'project'
        reserved='as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self static struct super trait true type unsafe use where while abstract become box do final macro override priv try typeof unsized virtual yield gen build deps examples incremental'.split()
        if not name[0].isalpha() or name in reserved: name='project-'+name
        prefix={'benevolent-anarchy':'org.benevolent-anarchy','cicely-f':'com.cicely-f'}.get(id['owner'].lower(),'com.'+id['owner'].lower())
        identifier=prefix+'.'+name if app_identifier is None else app_identifier
        if not re.fullmatch(r'[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z][A-Za-z0-9-]*)+',identifier): raise ValueError('Invalid application identifier')
        result.update(packageName=name,crateName=name,appIdentifier=identifier)
    return result

def entry(path,data):
    if isinstance(data,str): data=data.encode()
    return {'path':relative(path),'bytes':data,'sha256':sha(data)}
def records(manifest): return [{'path':e['path'],'sha256':e['sha256']} for e in sorted(manifest,key=lambda e:e['path'])]
def manifest_hash(manifest): return sha('\n'.join(e['path']+':'+e['sha256'] for e in sorted(manifest,key=lambda e:e['path'])))
def input_hash(id,preset=None,casefold_path=False):
    values=[id['title'],id['description'],id['owner'].lower(),id['repository'],id['projectPath'].lower() if casefold_path else id['projectPath']]
    if preset: values+=['bootstrap-state-v2',preset['name'],preset['recipeVersion'],preset['renderer'],preset['appIdentifier'],preset['packageName'],preset['crateName']]
    return sha(compact(values))

def journal_input_hash(journal,id=None,preset=None):
    # Existing journals retain their original hash and snapshot receipts; never rewrite them
    # merely to upgrade hashing. The native path equality check below is always required.
    format=journal.get('inputHashFormat')
    if format not in (None,'linux-path-v1'): raise ValueError('Unknown bootstrap input hash format')
    if id is None: id=journal['identity']
    if preset is None and journal['schemaVersion']==2: preset=journal['presetSelection']
    return input_hash(id,preset,casefold_path=format is None)

def assert_journal_identity(journal,id,preset):
    stored=journal['identity']
    if any(stored.get(key)!=id.get(key) for key in ('parent','projectPath','vaultPath')):
        raise ValueError('Journal project path conflicts with requested native path; resume using the stored identity')
    if journal['inputHash']!=journal_input_hash(journal,id,preset if journal['schemaVersion']==2 else None):
        raise ValueError('Journal input/preset conflicts with requested invocation')

def write_manifest(root,manifest):
    root=Path(root).absolute(); seen=set()
    for e in manifest:
        path=relative(e['path']); key=path.lower()
        if key in seen: raise ValueError('Duplicate or case-colliding manifest path: '+path)
        seen.add(key); target=owned(root,root/path)
        if sha(e['bytes'])!=e['sha256']: raise ValueError('Manifest hash differs from bytes: '+path)
        if target.exists() and (not target.is_file() or sha(target.read_bytes())!=e['sha256']): raise ValueError('Foundation file conflict: '+str(target))
        ancestor=target.parent
        while ancestor!=root.parent:
            if ancestor.exists() and not ancestor.is_dir(): raise ValueError('Foundation parent conflict: '+str(ancestor))
            ancestor=ancestor.parent
    for path in seen:
        if any(parent.as_posix() in seen for parent in PurePosixPath(path).parents if str(parent)!='.'): raise ValueError('Manifest parent file conflict')
    for e in manifest:
        target=root/e['path']; target.parent.mkdir(parents=True,exist_ok=True)
        if not target.exists(): target.write_bytes(e['bytes'])
        if target.suffix=='.sh': target.chmod(target.stat().st_mode|0o111)
    return manifest

def source_paths(root):
    root=Path(root); paths=[]
    for directory,dirs,files in os.walk(root,followlinks=False):
        path=Path(directory); rel=path.relative_to(root).as_posix()
        dirs[:]=[d for d in dirs if d not in ('.git','.godot','node_modules','dist','.test-results','.vite','.vitest','coverage','__pycache__') and (path/d).relative_to(root).as_posix() not in ('src-tauri/target','src-tauri/gen/schemas')]
        for name in dirs+files:
            if (path/name).is_symlink(): raise ValueError('Linked source path: '+str(path/name))
        paths.extend((path/f).relative_to(root).as_posix() for f in files if not f.endswith('.pyc'))
    return sorted(paths)
def source_manifest(root,paths=None):
    root=Path(root)
    return [entry(p,owned(root,root/relative(p)).read_bytes()) for p in (source_paths(root) if paths is None else sorted(paths))]
def assert_bytes(root,manifest):
    if manifest_hash(source_manifest(root,[e['path'] for e in manifest]))!=manifest_hash(manifest): raise ValueError('Prepared source bytes differ from retained manifest')

def foundation(id,preset,legacy=False):
    setup={'foundation':'This preset supplies documentation and the working process. Use Bash, Python 3.10+ and Git.', 'godot':'Use Godot 4.7.x. GUT 9.7.1 is vendored in `addons/gut/`. Open `project.godot` in the matching editor. Set `GODOT` to the executable path if `godot` or `godot4` is unavailable. Preserve committed UID and import sidecars; `.godot/` is an ignored cache.', 'tauri':'Use Node.js/npm and stable Rust with rustfmt and Clippy. On Linux, install the Tauri WebKitGTK 4.1, GTK 3, AppIndicator, librsvg, patchelf and C/C++ build prerequisites separately. Run `npm ci` after a fresh clone. `Cargo.lock` freezes Rust dependencies; verification uses locked commands. Run `npm run dev` for the frontend or `npm run tauri dev` for the desktop app. Compatible stable Tauri upgrades must remain at or above `tools/verify.json`’s selected release within its major; deliberate major upgrades update dependencies, locks and that baseline together.'}[preset['name']]
    gate={'foundation':'The complete initial gate validates documentation; extend this same gate when project checks are added.', 'godot':'The complete gate validates documentation, Godot import and script compilation, and GUT tests with post-run error/orphan checks. Rendered tests require a display. Run `tools/verify_selftest.sh` to exercise deliberate verifier failures.', 'tauri':'The complete gate validates documentation, TypeScript, frontend tests and build, Rust formatting, Clippy, Rust tests and a native Tauri build without installer bundling. A build does not establish an observed app launch.'}[preset['name']]
    gate+=' Once a committed `.gitattributes` sends files through Git LFS, the gate also fails when a file Git LFS should hold is committed as a plain file rather than an LFS pointer. That check reads Git\'s own rules at HEAD, needs Git 2.40 or newer, and needs no `git-lfs`.'
    if legacy:
        setup='This preset supplies documentation and the working process. It has no engine dependencies. Use PowerShell 7.2 or newer and Git.'
        gate='The complete initial gate validates documentation. Extend this same gate as project checks are added.'
    values={'PROJECT_TITLE':re.sub(r'\s+',' ',id['title']).replace('_','\\_'),'DESCRIPTION':id['description'],'ISSUES_URL':'https://github.com/'+id['fullName']+'/issues','PRESET_NAME':{'foundation':'Documentation foundation','godot':'Godot','tauri':'Tauri'}[preset['name']],'PRESET_SETUP':setup,'PRESET_GATE':gate}
    result=[]
    for file in sorted((ASSETS/'project').rglob('*')):
        if file.is_symlink(): raise ValueError('Linked project asset')
        if not file.is_file() or '__pycache__' in file.parts or file.suffix=='.pyc': continue
        path=file.relative_to(ASSETS/'project').as_posix().removesuffix('.template'); text=file.read_text(encoding='utf-8').replace('\r\n','\n')
        text=re.sub(r'\{\{('+'|'.join(values)+r')\}\}',lambda m:values[m[1]],text)
        result.append(entry(path,text))
    return result

def gate_module(root):
    spec=importlib.util.spec_from_file_location('ba_project_gate_'+uuid.uuid4().hex,Path(root)/'tools/verify_linux.py'); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module

_process_spec=importlib.util.spec_from_file_location('ba_bootstrap_process_'+uuid.uuid4().hex,ASSETS/'project/tools/process_linux.py')
_process_helper=importlib.util.module_from_spec(_process_spec); _process_spec.loader.exec_module(_process_helper)

def command(args,cwd=None,env=None,check=True,timeout=900):
    return _process_helper.run(args,cwd=cwd,env=env,check=check,timeout=timeout)

def github(method,endpoint,body=None):
    args=['gh','api',endpoint,'--method',method,'--include','--hostname','github.com','-H','Accept: application/vnd.github+json','-H','X-GitHub-Api-Version: 2026-03-10']
    with tempfile.TemporaryDirectory(prefix='ba-bootstrap-api-') as tmp:
        if body is not None:
            path=Path(tmp)/'body.json'; path.write_text(json.dumps(body),encoding='utf-8'); args+=['--input',str(path)]
        result=command(args,check=False); raw=result.stdout
    m=re.search(r'^HTTP/\S+\s+(\d{3})',raw,re.M)
    if not m: return 0,{'message':'GitHub CLI transport/authentication failed; inspect gh auth status separately'}
    split=re.split(r'\r?\n\r?\n',raw,maxsplit=1); data=None
    if len(split)>1 and split[1].strip():
        try: data=json.JSONDecoder().raw_decode(split[1].lstrip())[0]
        except ValueError: data={'message':'GitHub returned an unreadable response'}
    return int(m[1]),data

def download(url,destination):
    if not url.startswith('https://'): raise ValueError('Downloads require HTTPS')
    with urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'BA-Bootstrap (Benevolent-Anarchy/BA-Skills)'}),timeout=90) as response:
        Path(destination).write_bytes(response.read())
def metadata(url):
    if not url.startswith('https://'): raise ValueError('Metadata requires HTTPS')
    with urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'BA-Bootstrap (Benevolent-Anarchy/BA-Skills)','Accept':'application/json'}),timeout=90) as response: return json.load(response)
def stable(versions):
    found=[v for v in versions if re.fullmatch(STABLE,v)]
    if not found: raise ValueError('Upstream metadata contains no stable release')
    return max(found,key=lambda x:tuple(map(int,x.split('.'))))
def resolve_dependencies(preset,request=metadata):
    result=dict(schemaVersion=1,preset=preset['name'],selections={},artifacts=[],resolvedAt=now())
    if preset['name']=='godot':
        obj=request('https://api.github.com/repos/bitwes/Gut/git/ref/tags/v9.7.1')['object']
        if obj['type']=='tag': obj=request('https://api.github.com/repos/bitwes/Gut/git/tags/'+obj['sha'])['object']
        if obj['type']!='commit' or not re.fullmatch(r'[a-f0-9]{40}',obj['sha']): raise ValueError('GUT tag does not identify an immutable commit')
        result.update(selections={'gut':'9.7.1','godotCompatibility':'4.7.x'},artifacts=[dict(name='gut',version='9.7.1',commit=obj['sha'],uri='https://codeload.github.com/bitwes/Gut/zip/'+obj['sha'],proof='immutable-commit-no-published-digest')])
    elif preset['name']=='tauri':
        crates=request('https://crates.io/api/v1/crates/tauri'); tauri=stable(v['num'] for v in crates['versions'] if not v['yanked'])
        npm=request('https://registry.npmjs.org/create-tauri-app'); generator=stable(npm['versions']); record=npm['versions'][generator]; dist=record['dist']
        if record['version']!=generator or not re.fullmatch(r'https://registry\.npmjs\.org/create-tauri-app/-/create-tauri-app-'+STABLE+r'\.tgz',dist['tarball']) or not re.fullmatch(r'sha512-[A-Za-z0-9+/]+={0,2}',dist['integrity']) or len(base64.b64decode(dist['integrity'][7:],validate=True))!=64: raise ValueError('Official generator integrity/version metadata is inconsistent')
        result.update(selections={'tauri':tauri,'generator':generator},artifacts=[dict(name='generator',version=generator,uri=dist['tarball'],integrity=dist['integrity'],proof='published-integrity')])
    return result

def acquire(artifact,destination,fetch=download):
    destination=Path(destination); owned(destination.parent,destination); destination.parent.mkdir(parents=True,exist_ok=True)
    if not artifact['uri'].startswith('https://'): raise ValueError('Artifact requires HTTPS')
    exists=destination.exists()
    if exists and not artifact.get('sha256') and not artifact.get('integrity'): raise ValueError('Existing artifact has no retained digest; preserve unresolved acquisition')
    working=destination if exists else Path(str(destination)+'.'+uuid.uuid4().hex+'.partial')
    if not exists: fetch(artifact['uri'],working)
    data=working.read_bytes(); digest=sha(data)
    if artifact.get('sha256') and artifact['sha256']!=digest: raise ValueError('Artifact retained digest mismatch')
    if artifact.get('integrity') and 'sha512-'+base64.b64encode(hashlib.sha512(data).digest()).decode()!=artifact['integrity']: raise ValueError('Artifact published integrity mismatch')
    if not exists: os.replace(working,destination)
    return {**artifact,'sha256':digest,'bytes':len(data),'acquiredAt':now()}

def expand_archive(archive,destination,required):
    destination=Path(destination)
    if destination.exists(): raise ValueError('Archive destination already exists; preserve unresolved expansion')
    entries=[]; roots=set()
    with zipfile.ZipFile(archive) as z:
        for info in z.infolist():
            name=info.filename.rstrip('/')
            if not name: continue
            relative(name); roots.add(name.split('/')[0])
            if stat.S_ISLNK(info.external_attr>>16): raise ValueError('Archive contains linked source')
        if len(roots)!=1: raise ValueError('Source archive needs one root')
        prefix=next(iter(roots))+'/'
        for info in z.infolist():
            if info.is_dir(): continue
            if not info.filename.startswith(prefix): raise ValueError('Archive file outside source root')
            entries.append(entry(info.filename[len(prefix):],z.read(info)))
    if not set(required)<={e['path'] for e in entries}: raise ValueError('Archive missing required source')
    write_manifest(destination,entries); return destination

@contextlib.contextmanager
def lock(path):
    path=Path(path); owned(path.parent,path); path.parent.mkdir(parents=True,exist_ok=True)
    lockpath=Path(str(path)+'.lock'); owned(path.parent,lockpath)
    with lockpath.open('a+') as stream:
        try: fcntl.flock(stream,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: raise ValueError('Bootstrap journal is locked by another invocation') from None
        yield

def remove_owned(root,paths):
    root=Path(root).absolute(); targets=[]
    for path in paths:
        path=owned(root,path)
        if path==root: raise ValueError('Cleanup cannot delete ownership root')
        if path.is_dir():
            for directory,dirs,files in os.walk(path,followlinks=False):
                for name in dirs+files: owned(root,Path(directory)/name)
        targets.append(path)
    for path in sorted(set(targets),key=lambda p:len(str(p)),reverse=True):
        if path.is_dir(): shutil.rmtree(path)
        elif path.exists(): path.unlink()

class Bootstrap:
    def __init__(self,state_root=None,request=github,fetch=download,metadata_request=metadata,runner=command):
        self.root=Path(state_root or os.environ.get('BA_BOOTSTRAP_STATE_ROOT') or Path(os.environ.get('XDG_STATE_HOME') or Path.home()/'.local/state')/'BA-Skills/ba-bootstrap/state').absolute()
        self.request=request; self.fetch=fetch; self.metadata=metadata_request; self.runner=runner
    def journal_path(self,id):
        name=id['owner']+'/'+id['repository']; canonical=owned(self.root,self.root/(sha(name.lower())+'.json'))
        # Retain historical case-sensitive filenames and their locks. Every spelling
        # must find the same existing invocation, without rewriting recovery receipts.
        legacy=owned(self.root,self.root/(sha(name)+'.json'))
        matches={path for path in (canonical,legacy) if path.exists()}
        for path in self.root.glob('*.json'):
            if path in matches: continue
            try:
                stored=read_json(owned(self.root,path))['identity']
                previous=stored['owner']+'/'+stored['repository']
                if previous.lower()==name.lower() and path.stem==sha(previous): matches.add(path)
            except (OSError,ValueError,KeyError,TypeError): continue
        if len(matches)>1: raise ValueError('Multiple journals exist for this case-insensitive GitHub name; preserve them and resolve the conflict')
        return next(iter(matches),canonical)
    def api(self,method,endpoint,body=None,expected=(200,201,204)):
        code,data=self.request(method,endpoint,body)
        if code not in expected: raise RuntimeError(f'GitHub {method} {endpoint} failed (HTTP {code}): '+str((data or {}).get('message','unreadable response')))
        return code,data
    def git(self,root,*args,check=True): return self.runner(['git','-C',str(root),*args],check=check)
    def new_journal(self,id,preset):
        return dict(schemaVersion=2,inputHashFormat='linux-path-v1',invocationId=str(uuid.uuid4()),identity=id,inputHash=input_hash(id,preset),templateVersion=manifest_hash(foundation(id,preset)),manifest=records(foundation(id,preset)),repositories={},phases={},refs={},browserEvidence={},createdAt=now(),presetSelection=preset,recipeVersion=preset['recipeVersion'],resolution=None,preparation=dict(phase='not-started',snapshot=None,manifestHash=None,checkpoints={}),verification=dict(staging=None,checkout=None))
    def save(self,journal): atomic_json(self.journal_path(journal['identity']),journal)
    def load(self,id):
        path=self.journal_path(id)
        if not path.exists(): return None
        try:
            data=read_json(path)
            if data['schemaVersion'] not in (1,2) or str(uuid.UUID(data['invocationId']))!=data['invocationId']: raise ValueError()
            if not all(isinstance(data[k],dict) for k in ('identity','repositories','phases','refs','browserEvidence')): raise ValueError()
            if data['identity']['fullName'].lower()!=(id['owner']+'/'+id['repository']).lower(): raise ValueError()
            if not re.fullmatch(r'[a-f0-9]{64}',data['templateVersion']) or not isinstance(data['manifest'],list): raise ValueError()
            seen=set()
            for e in data['manifest']:
                relative(e['path'])
                if e['path'].lower() in seen or not re.fullmatch(r'[a-f0-9]{64}',e['sha256']): raise ValueError()
                seen.add(e['path'].lower())
            preset=data.get('presetSelection') if data['schemaVersion']==2 else None
            if data['inputHash']!=journal_input_hash(data): raise ValueError()
            if preset:
                p=data['preparation']; v=data['verification']
                if preset!=selection(data['identity'],preset['name'],preset['renderer'],preset['appIdentifier']) or data['recipeVersion']!=1 or p['phase'] not in ('not-started','preparing','snapshotting','frozen') or not isinstance(p['checkpoints'],dict) or not isinstance(v,dict): raise ValueError()
                if p['snapshot'] and p['snapshot']!='prepared/'+data['invocationId']+'/source': raise ValueError()
            return data
        except Exception as exc: raise ValueError("Cannot read bootstrap journal '"+str(path)+"': invalid JSON or schema. Preserve it for recovery.") from exc
    def checkpoint(self,journal,name,value): journal['preparation']['checkpoints'][name]=value; self.save(journal)
    def preparation_source(self,journal): return owned(self.root,self.root/'preparing'/journal['invocationId']/'source')
    def snapshot(self,journal):
        p=journal['preparation']; expected='prepared/'+journal['invocationId']+'/source'
        if p['snapshot']!=expected: raise ValueError('Prepared snapshot receipt missing/invalid')
        source=owned(self.root,self.root/expected); receiptpath=owned(self.root,source.parent/'receipt.json')
        if not source.is_dir() or not receiptpath.is_file(): raise ValueError('Prepared snapshot or receipt missing; preserve state for recovery')
        receipt=read_json(receiptpath)
        if receipt.get('schemaVersion')!=1 or receipt.get('invocationId')!=journal['invocationId'] or receipt.get('inputHash')!=journal['inputHash'] or receipt.get('manifestHash')!=p['manifestHash'] or manifest_hash(journal['manifest'])!=p['manifestHash'] or manifest_hash(receipt['manifest'])!=p['manifestHash']: raise ValueError('Prepared snapshot receipt differs from invocation/manifest')
        actual=[]
        for directory,dirs,files in os.walk(source,followlinks=False):
            for name in dirs+files: owned(source,Path(directory)/name)
            actual.extend((Path(directory)/f).relative_to(source).as_posix() for f in files)
        if sorted(actual)!=sorted(e['path'] for e in journal['manifest']): raise ValueError('Prepared snapshot paths missing or unexpected')
        manifest=source_manifest(source,actual)
        if manifest_hash(manifest)!=p['manifestHash']: raise ValueError('Prepared snapshot bytes/hash differ; preserve evidence')
        return source,manifest
    def freeze(self,journal,source,manifest):
        digest=manifest_hash(manifest); p=journal['preparation']
        if p['manifestHash'] and p['manifestHash']!=digest: raise ValueError('Frozen manifest differs; preserve original snapshot')
        assert_bytes(source,manifest); journal['manifest']=records(manifest); journal['templateVersion']=digest
        p.update(phase='snapshotting',snapshot='prepared/'+journal['invocationId']+'/source',manifestHash=digest); self.save(journal)
        destination=owned(self.root,self.root/p['snapshot'])
        if not destination.parent.exists():
            destination.parent.parent.mkdir(parents=True,exist_ok=True)
            temp=destination.parent.parent/('.'+journal['invocationId']+'.'+uuid.uuid4().hex+'.partial')
            write_manifest(temp/'source',manifest); atomic_json(temp/'receipt.json',dict(schemaVersion=1,invocationId=journal['invocationId'],inputHash=journal['inputHash'],manifestHash=digest,manifest=journal['manifest']))
            os.rename(temp,destination.parent)
        self.snapshot(journal); p['phase']='frozen'; self.save(journal)
    def prereqs(self,preset):
        names={'foundation':[],'godot':['godot'],'tauri':['node','npm','rustc','cargo','rustfmt','cargo-clippy','cc','pkg-config','patchelf']}[preset['name']]; checks=[]
        for name in names:
            try:
                exe=(os.environ.get('GODOT') or shutil.which('godot') or shutil.which('godot4')) if name=='godot' else shutil.which(name)
                if not exe: raise ValueError('Required executable missing: '+name)
                version=self.runner([exe,'--version'],cwd=tempfile.gettempdir()).stdout.strip()
                if name=='godot' and not re.match(r'^4\.7(?:\.\d+)?\.stable(?:\.|$)',version): raise ValueError('Recipe requires stable Godot 4.7.x: '+version)
                checks.append(dict(name=name,passed=True,version=version,executable=exe,message=''))
            except Exception as exc: checks.append(dict(name=name,passed=False,version=None,executable=None,message=str(exc)))
        if preset['name']=='tauri':
            for package in ('webkit2gtk-4.1','gtk+-3.0','ayatana-appindicator3-0.1','librsvg-2.0'):
                try:
                    version=self.runner(['pkg-config','--modversion',package]).stdout.strip(); checks.append(dict(name=package,passed=True,version=version,message=''))
                except Exception as exc: checks.append(dict(name=package,passed=False,version=None,message=str(exc)))
        return {'passed':all(c['passed'] for c in checks),'checks':checks}
    def report(self,id,journal,status,pending=None,conflicts=None):
        return dict(status=status,identity=id,preset=(journal.get('presetSelection') or selection(id,'foundation')) if journal else None,resolution=journal.get('resolution') if journal else None,preparation=journal.get('preparation') if journal else None,verification=journal.get('verification') if journal else None,prerequisites=journal.get('prerequisites') if journal else None,phases=journal.get('phases',{}) if journal else {},pending=pending or [],conflicts=conflicts or [],browserEvidence=journal.get('browserEvidence',{}) if journal else {},obsidian=journal.get('obsidian',{}) if journal else {},journalPath=str(self.journal_path(id)))
    def visibility(self,kind,repo,journal,name):
        if kind=='public' and repo['private']: raise ValueError('Release-notes repository is no longer public: '+name)
        if kind=='private' and not repo['private'] and journal['phases'].get('privateContent')!='verified': raise ValueError('Project became public before foundation publication; make it private, then resume')
    def local_state(self,id,journal,manifest,completed):
        root=Path(id['projectPath']); owned(root,root)
        if root.exists() and not root.is_dir(): raise ValueError('Project path is a file')
        if root.exists() and journal is None and any(root.iterdir()): raise ValueError('Project path already contains files without bootstrap ownership evidence')
        if not completed:
            for e in manifest:
                target=owned(root,root/e['path'])
                if target.exists() and (not target.is_file() or sha(target.read_bytes())!=e['sha256']): raise ValueError('Generated file differs: '+e['path'])
        if (root/'.git').exists():
            if not journal or 'private' not in journal['repositories']: raise ValueError('Existing Git checkout has no recorded repository identity')
            if Path(self.git(root,'rev-parse','--show-toplevel').stdout.strip())!=root: raise ValueError('Git root differs from project path')
            if self.git(root,'remote','get-url','origin').stdout.strip()!='https://github.com/'+id['fullName']+'.git': raise ValueError('Existing Git origin differs from recorded project')
            if not completed:
                if self.git(root,'branch','--show-current').stdout.strip()!='main': raise ValueError('Partial project must be on main')
                staged=self.git(root,'diff','--cached','--name-only').stdout.splitlines()
                if set(staged)-{e['path'] for e in manifest}: raise ValueError('Unexpected staged file')
                head=self.git(root,'rev-parse','--verify','HEAD',check=False)
                if head.returncode==0:
                    if journal['refs'].get('privateMain') and head.stdout.strip()!=journal['refs']['privateMain']: raise ValueError('Unexpected local commit')
                    if not journal['refs'].get('privateMain'): self.initial_commit(root,manifest,head.stdout.strip())
        elif journal and journal['phases'].get('privateContent')=='verified': raise ValueError('Recorded checkout is missing its Git repository')
    def plan(self,id,preset):
        journal=self.load(id); conflicts=[]; owner_type=None; prerequisites=None; visibility=None
        completed=bool(journal and journal['phases'].get('complete')=='verified')
        try:
            if journal: assert_journal_identity(journal,id,preset)
            if journal and journal['schemaVersion']==1:
                if preset['name']!='foundation': raise ValueError('Legacy journal records foundation; conflicting preset cannot replace it')
                if not completed and journal['templateVersion']!=manifest_hash(foundation(id,preset,legacy=True)): raise ValueError('Legacy journal template differs from this skill version; preserve journal and recover with matching recipe')
            manifest=[]
            if not completed:
                if journal and journal['schemaVersion']==1: manifest=foundation(id,preset,legacy=True)
                elif journal and journal['preparation']['phase'] in ('frozen','snapshotting'):
                    if journal['preparation']['phase']=='snapshotting' and not (self.root/journal['preparation']['snapshot']).parent.exists():
                        source=self.preparation_source(journal); manifest=source_manifest(source,[e['path'] for e in journal['manifest']]); assert_bytes(source,journal['manifest'])
                    else: _,manifest=self.snapshot(journal)
                else: manifest=foundation(id,preset)
                with tempfile.TemporaryDirectory(prefix='ba-bootstrap-plan-') as tmp:
                    write_manifest(tmp,foundation(id,preset)); docs=gate_module(tmp).documentation(tmp)
                    if not docs['Passed']: raise ValueError('Foundation documentation preflight failed: '+'; '.join(docs['Diagnostics']))
                prerequisites=self.prereqs(preset)
                if not prerequisites['passed']: raise ValueError('Missing/unsupported prerequisites: '+'; '.join(c['name']+': '+c['message'] for c in prerequisites['checks'] if not c['passed']))
            self.local_state(id,journal,manifest,completed)
            user=self.api('GET','/user')[1]; owner=self.api('GET','/users/'+id['owner'])[1]; owner_type=owner['type']
            if owner_type=='Organization':
                member=self.api('GET','/user/memberships/orgs/'+id['owner'])[1]
                if member.get('state')!='active' or member.get('role')!='admin': raise ValueError('Creation requires an active organization owner')
            elif owner_type!='User' or user['login'].lower()!=id['owner'].lower(): raise ValueError('Personal owner must be authenticated GitHub user')
        except Exception as exc: conflicts.append(str(exc))
        for kind,name in (('private',id['fullName']),('public',id['notesFullName'])):
            try:
                code,repo=self.api('GET','/repos/'+name,expected=(200,404))
                recorded=journal and journal['repositories'].get(kind)
                creating=journal and journal['phases'].get(kind+'Repository')=='creating'
                if code==200:
                    if not recorded: raise ValueError(('identity-unconfirmed: ' if creating else 'Repository name already exists: ')+name)
                    if recorded!=repo['id'] or name.lower()!=repo['full_name'].lower(): raise ValueError('Recorded repository identity differs: '+name)
                    self.visibility(kind,repo,journal,name)
                    if kind=='private': visibility='private' if repo['private'] else 'public'
                elif recorded: raise ValueError('Recorded repository missing/inaccessible: '+name)
                elif creating: raise ValueError('identity-unconfirmed: prior creation unresolved; do not retry automatically: '+name)
            except Exception as exc: conflicts.append(str(exc))
        status='identity-unconfirmed' if any(c.startswith('identity-unconfirmed:') for c in conflicts) else 'blocked' if conflicts else 'ready'
        report=self.report(id,journal,status,conflicts=conflicts); report.update(ownerType=owner_type,preset=preset,prerequisites=prerequisites,projectVisibility=visibility); return report
    def discard(self,journal):
        if journal['repositories'] or journal['refs'] or any(k in journal['phases'] for k in ('privateRepository','publicRepository')): raise ValueError('Discard refused: a repository creation attempt was recorded; preserve recovery evidence')
        id=journal['invocationId']; paths=[self.root/'preparing'/id,self.root/'prepared'/id,*((self.root/'prepared').glob('.'+id+'.*.partial') if (self.root/'prepared').exists() else [])]
        remove_owned(self.root,paths); path=self.journal_path(journal['identity']); remove_owned(self.root,[path]); return self.report(journal['identity'],journal,'discarded')
    def status(self,id):
        journal=self.load(id)
        if not journal: return self.report(id,None,'not-started')
        pending=[]; conflicts=[]; visibility=None
        try:
            for kind in ('private','public'):
                if kind not in journal['repositories']: continue
                name=id['fullName' if kind=='private' else 'notesFullName']; repo=self.api('GET','/repos/'+name)[1]
                if repo['id']!=journal['repositories'][kind] or repo['full_name'].lower()!=name.lower(): raise ValueError('Recorded repository identity differs: '+name)
                self.visibility(kind,repo,journal,name)
                if kind=='private': visibility='private' if repo['private'] else 'public'
            if journal['phases'].get('publicSettings')=='verified': self.public_settings(id,False)
            for phase in ('privateRepository','publicRepository','privateContent','publicContent','labels','publicSettings','pullRequests','obsidian'):
                if journal['phases'].get(phase)!='verified': pending.append('Unfinished bootstrap phase: '+phase)
            if journal['schemaVersion']==2:
                for phase in ('staging','checkout'):
                    receipt=journal['verification'].get(phase)
                    if not receipt or receipt.get('Passed') is not True or receipt.get('manifestHash')!=journal['preparation']['manifestHash']: pending.append('Unfinished native verification: '+phase)
            for kind in ('private','public'):
                phase=journal['phases'].get(kind+'Repository')
                if kind not in journal['repositories'] and phase=='creating': conflicts.append('identity-unconfirmed: prior '+kind+' creation unresolved; do not retry automatically')
                if kind not in journal['repositories'] and phase=='failed': conflicts.append('GitHub '+kind+' creation failed: '+compact(journal.get('creationFailures',{}).get(kind)))
        except Exception as exc: conflicts.append(str(exc))
        result=self.report(id,journal,'identity-unconfirmed' if any(c.startswith('identity-unconfirmed') for c in conflicts) else 'blocked' if conflicts else 'complete' if not pending and journal['phases'].get('complete')=='verified' else 'partial',pending,conflicts); result['projectVisibility']=visibility; return result
    def prepare(self,journal):
        id=journal['identity']; preset=journal['presetSelection']; source=self.preparation_source(journal); cp=journal['preparation']['checkpoints']
        if 'source-ready' in cp: assert_bytes(source,cp['source-ready']['manifest']); return source,source_manifest(source,[e['path'] for e in cp['source-ready']['manifest']])
        if journal['resolution'] is None: journal['resolution']=resolve_dependencies(preset,self.metadata); self.checkpoint(journal,'resolution',{'resolvedAt':now()})
        if 'foundation' not in cp:
            manifest=foundation(id,preset); write_manifest(source,manifest); self.checkpoint(journal,'foundation',{'manifest':records(manifest)})
        else:
            retained=[e for e in cp['foundation']['manifest'] if e['path'] not in ('.gitignore','tools/verify.json') or not ('overlay' in cp or 'godot-source' in cp)]
            assert_bytes(source,retained)
        if preset['name']=='godot': self.prepare_godot(journal,source)
        elif preset['name']=='tauri': self.prepare_tauri(journal,source)
        manifest=source_manifest(source); self.checkpoint(journal,'source-ready',{'manifest':records(manifest)}); return source,manifest
    def locked_install(self,root,preset):
        if preset['name']=='tauri': self.runner(['npm','ci','--no-audit','--no-fund'],cwd=root,env={'CARGO_TARGET_DIR':str(Path(root)/'src-tauri/target')})
    def gate(self,root,journal,phase):
        if journal['schemaVersion']==1:
            # v1 owns an exact documentation foundation, without v2 engine/snapshot receipts.
            result=gate_module(root).verify(root,True) if (Path(root)/'tools/verify_linux.py').is_file() else gate_module(ASSETS/'project').documentation(root)
            if result['Passed']:
                try: assert_bytes(root,journal['manifest']); self.ignore_rules(root,journal['manifest'],selection(journal['identity'],'foundation'))
                except Exception as exc: result['Passed']=False; result['Diagnostics'].append(str(exc))
            if not result['Passed']: raise RuntimeError(phase+' complete gate failed: '+'; '.join(result['Diagnostics']))
            return
        self.locked_install(root,journal['presetSelection']); result=gate_module(root).verify(root,True)
        if result['Passed']:
            try: assert_bytes(root,journal['manifest']); self.ignore_rules(root,journal['manifest'],journal['presetSelection'])
            except Exception as exc: result['Passed']=False; result['Diagnostics'].append(str(exc))
        result.update(manifestHash=journal['preparation']['manifestHash'],observedAt=now()); journal['verification'][phase]=result; self.save(journal)
        if not result['Passed']: raise RuntimeError(phase+' complete gate failed: '+'; '.join(result['Diagnostics']))
    def ignore_rules(self,root,manifest,preset):
        root=Path(root)
        if not (root/'.git').exists(): self.git(root,'init','--initial-branch=main')
        empty=root/'.git/ba-bootstrap-empty-excludes'; empty.write_text(''); prefix=['-c','core.excludesFile='+str(empty)]
        intended=self.git(root,*prefix,'check-ignore','--no-index','--',*(e['path'] for e in manifest),check=False)
        if intended.returncode!=1: raise ValueError('Ignore rules hide intended source or failed: '+intended.stdout)
        generated=['dist/exports/probe','nested/dist/exports/probe','.test-results/probe']
        if preset['name']=='godot': generated+=['.godot/cache/probe','assets/probe.translation','export_credentials.cfg','android/build/probe','.mono/probe']
        if preset['name']=='tauri': generated+=['node_modules/probe','src-tauri/target/probe','src-tauri/gen/schemas/probe','.vite/probe','coverage/probe','.env.local']
        for path in generated:
            if self.git(root,*prefix,'check-ignore','--no-index','--',path,check=False).returncode: raise ValueError('Generated output is not ignored: '+path)
        unknown=set(self.git(root,*prefix,'ls-files','--others','--exclude-standard').stdout.splitlines())-{e['path'] for e in manifest}
        if unknown: raise ValueError('Unexpected unignored source outside frozen manifest: '+', '.join(sorted(unknown)))
    def phase(self,journal,name,value='verified'): journal['phases'][name]=value; self.save(journal)
    def create(self,id,preset,refresh=False):
        journal=None
        try:
            with lock(self.journal_path(id)):
                report=self.plan(id,preset)
                if report['status']!='ready': return report
                journal=self.load(id)
                if journal and journal['phases'].get('complete')=='verified':
                    result=self.status(id)
                    if refresh:
                        result['status']='blocked'
                        result['pending'].append('Completed bootstrap preserves project development. Run local-setup --repository '+id['projectPath']+' --refresh-plugins to update this vault.')
                    return result
                if journal is None: journal=self.new_journal(id,preset)
                journal['prerequisites']=report['prerequisites']; self.save(journal)
                if journal['schemaVersion']==1: manifest=foundation(id,preset,legacy=True)
                else:
                    if journal['preparation']['phase'] in ('not-started','preparing'):
                        journal['preparation']['phase']='preparing'; self.save(journal); source,manifest=self.prepare(journal); self.freeze(journal,source,manifest)
                    elif journal['preparation']['phase']=='snapshotting':
                        source=self.preparation_source(journal); manifest=source_manifest(source,[e['path'] for e in journal['manifest']]); self.freeze(journal,source,manifest)
                    frozen,manifest=self.snapshot(journal)
                    receipt=journal['verification'].get('staging')
                    if not receipt or not receipt['Passed'] or receipt['manifestHash']!=journal['preparation']['manifestHash']:
                        source=self.preparation_source(journal); write_manifest(source,manifest); self.gate(source,journal,'staging'); self.phase(journal,'stagingVerification')
                for kind,key in (('private','repository'),('public','notesRepository')):
                    if kind in journal['repositories']: continue
                    body={'name':id[key],'private':kind=='private','has_issues':kind=='private','auto_init':False}
                    if kind=='private': body['description']=id['description']
                    else: body.update(has_projects=False,has_wiki=False)
                    self.phase(journal,kind+'Repository','creating')
                    endpoint='/orgs/'+id['owner']+'/repos' if report['ownerType']=='Organization' else '/user/repos'
                    try: code,repo=self.request('POST',endpoint,body)
                    except Exception as exc: return self.report(id,journal,'identity-unconfirmed',[str(exc)])
                    if 400<=code<500 and code!=408:
                        journal.setdefault('creationFailures',{})[kind]={'statusCode':code,'message':(repo or {}).get('message','GitHub rejected request'),'errors':(repo or {}).get('errors',[])}; self.phase(journal,kind+'Repository','failed'); return self.report(id,journal,'blocked',conflicts=[compact(journal['creationFailures'][kind])])
                    if code!=201 or not repo or not repo.get('id'): return self.report(id,journal,'identity-unconfirmed',['Repository create result lost; preserve state, never infer identity from GET'])
                    expected=id['fullName' if kind=='private' else 'notesFullName']
                    if repo['full_name'].lower()!=expected.lower() or repo['private']!=(kind=='private'): raise ValueError('Created repository has unexpected identity/visibility')
                    journal['repositories'][kind]=repo['id']; journal.get('creationFailures',{}).pop(kind,None); self.phase(journal,kind+'Repository')
                if journal['phases'].get('privateContent')!='verified': self.private_content(id,journal,manifest)
                if journal['phases'].get('publicContent')!='verified': self.public_content(id,journal)
                if journal['phases'].get('labels')!='verified': self.labels(id); self.phase(journal,'labels')
                has_pr=self.public_settings(id,True); self.phase(journal,'publicSettings')
                if has_pr: self.phase(journal,'pullRequests')
                elif 'pullRequests' not in journal['phases']: self.phase(journal,'pullRequests','needs-browser')
                if refresh or journal['phases'].get('obsidian')!='verified':
                    obs=self.install_obsidian(id,refresh); journal['obsidian']=obs; self.phase(journal,'obsidian','verified' if obs['installedVerified'] and obs['enabledVerified'] else 'needs-app' if obs['installedVerified'] else 'incomplete')
                if all(journal['phases'].get(k)=='verified' for k in ('privateRepository','publicRepository','privateContent','publicContent','labels','publicSettings','pullRequests','obsidian')) and (journal['schemaVersion']==1 or all(journal['verification'][k]['Passed'] for k in ('staging','checkout'))):
                    self.phase(journal,'complete')
                    try: remove_owned(self.root,[self.root/'preparing'/journal['invocationId']]); cleanup={'status':'removed'}
                    except Exception as exc: cleanup={'status':'deferred','reason':str(exc)}
                else: cleanup=None
                result=self.status(id); result['pending']+=journal.get('obsidian',{}).get('pending',[])
                if cleanup is not None: result['cleanup']=cleanup
                return result
        except Exception as exc: return self.report(id,journal,'partial' if journal else 'blocked',[str(exc)])
    def initial_commit(self,root,manifest,head):
        commit=self.git(root,'--no-replace-objects','cat-file','-p',head).stdout.split('\n\n',1)[0]
        if not re.match(r'^tree [a-f0-9]+',commit) or re.search(r'^parent ',commit,re.M): raise ValueError('Unrecorded HEAD must be a single root foundation commit')
        tree=self.git(root,'--no-replace-objects','ls-tree','-rz','--full-tree',head).stdout
        blobs={}
        for item in tree.split('\0'):
            if not item: continue
            m=re.fullmatch(r'100(?:644|755) blob ([a-f0-9]{40}|[a-f0-9]{64})\t(.+)',item,re.S)
            if not m: raise ValueError('Foundation tree contains unexpected entry')
            blobs[m[2]]=m[1]
        if set(blobs)!={e['path'] for e in manifest}: raise ValueError('Foundation tree paths differ')
        for e in manifest:
            if self.git(root,'hash-object','--no-filters','--',e['path']).stdout.strip()!=blobs[e['path']]: raise ValueError('Foundation blob differs: '+e['path'])
    def private_content(self,id,journal,manifest):
        root=Path(id['projectPath']); write_manifest(root,manifest)
        if not (root/'.git').exists():
            self.git(root,'init','--initial-branch=main'); self.git(root,'remote','add','origin','https://github.com/'+id['fullName']+'.git')
        self.gate(root,journal,'checkout'); self.phase(journal,'checkoutVerification')
        if 'privateMain' not in journal['refs']:
            head=self.git(root,'rev-parse','--verify','HEAD',check=False)
            if head.returncode:
                self.git(root,'add','-f','--',*(e['path'] for e in manifest)); self.git(root,'commit','-m','Initial project foundation'); head=self.git(root,'rev-parse','HEAD')
            self.initial_commit(root,manifest,head.stdout.strip()); journal['refs']['privateMain']=head.stdout.strip(); self.save(journal)
        endpoint='/repos/'+id['fullName']; code,ref=self.api('GET',endpoint+'/git/ref/heads/main',expected=(200,404,409))
        if code==409 and (not ref or ref.get('message')!='Git Repository is empty.'): raise ValueError('Unresolved GitHub conflict for initial main ref')
        if code in (404,409):
            repo=self.api('GET',endpoint)[1]
            if repo['id']!=journal['repositories']['private'] or repo['full_name'].lower()!=id['fullName'].lower(): raise ValueError('Recorded project repository identity differs')
            self.visibility('private',repo,journal,id['fullName'])
            push=self.git(root,'push','--set-upstream','origin','main',check=False)
            code,ref=self.api('GET',endpoint+'/git/ref/heads/main',expected=(200,404))
            if code!=200: raise ValueError('Initial push unresolved (exit '+str(push.returncode)+'); resume to compare remote ref')
        if ref['object']['sha']!=journal['refs']['privateMain']: raise ValueError('Remote main differs from intended initial commit; do not force-push')
        tree=self.api('GET',endpoint+'/git/trees/'+journal['refs']['privateMain']+'?recursive=1')[1]
        if tree.get('truncated') or sorted(e['path'] for e in tree['tree'] if e['type']!='tree')!=sorted(e['path'] for e in manifest): raise ValueError('Private remote tree differs from generated manifest')
        self.api('PATCH',endpoint,{'default_branch':'main'}); repo=self.api('GET',endpoint)[1]
        if repo['default_branch']!='main' or not repo['has_issues']: raise ValueError('Private main/Issues settings did not verify')
        self.phase(journal,'privateContent')
    def public_content(self,id,journal):
        title=re.sub(r'\s+',' ',id['title']).replace('_','\\_'); expected=(ASSETS/'public-README.md.template').read_text().replace('{{PROJECT_TITLE}}',title); endpoint='/repos/'+id['notesFullName']
        code,readme=self.api('GET',endpoint+'/contents/README.md',expected=(200,404))
        if code==404:
            self.request('PUT',endpoint+'/contents/README.md',{'message':'Initial public release-notes record','content':base64.b64encode(expected.encode()).decode()}); code,readme=self.api('GET',endpoint+'/contents/README.md')
        if readme['encoding']!='base64' or base64.b64decode(readme['content']).decode()!=expected: raise ValueError('Public README differs; preserve existing record')
        repo=self.api('GET',endpoint)[1]
        if repo['default_branch']!='main': self.api('POST',endpoint+'/branches/'+urllib.parse.quote(repo['default_branch'],safe='')+'/rename',{'new_name':'main'})
        ref=self.api('GET',endpoint+'/git/ref/heads/main')[1]; tree=self.api('GET',endpoint+'/git/trees/'+ref['object']['sha']+'?recursive=1')[1]
        if tree.get('truncated') or len(tree['tree'])!=1 or tree['tree'][0]['path']!='README.md' or tree['tree'][0]['type']!='blob': raise ValueError('Public repository must contain only initial README')
        journal['refs']['publicMain']=ref['object']['sha']; self.phase(journal,'publicContent')
    def labels(self,id):
        endpoint='/repos/'+id['fullName']+'/labels'
        def all_labels():
            result={}; page=1
            while True:
                batch=self.api('GET',endpoint+f'?per_page=100&page={page}')[1]
                for label in batch: result[label['name']]=label
                if len(batch)<100: return result
                page+=1
        labels=all_labels(); expected=read_json(ASSETS/'labels.json')
        for label in expected:
            current=labels.get(label['name'])
            if current and current['color'].lower()==label['color'].lower() and current['description']==label['description']: continue
            self.api('PATCH' if current else 'POST',endpoint+'/'+urllib.parse.quote(label['name'],safe='') if current else endpoint,label)
        actual=all_labels()
        for label in expected:
            if label['name'] not in actual or actual[label['name']]['color'].lower()!=label['color'].lower() or actual[label['name']]['description']!=label['description']: raise ValueError('Label readback differs: '+label['name'])
    def public_settings(self,id,write=False):
        endpoint='/repos/'+id['notesFullName']; repo=self.api('GET',endpoint)[1]
        settings=dict(has_issues=False,has_wiki=False,has_projects=False,has_discussions=False,allow_auto_merge=False)
        has_pr='has_pull_requests' in repo
        if has_pr: settings['has_pull_requests']=False
        if write:
            self.api('PATCH',endpoint,settings); self.api('PUT',endpoint+'/actions/permissions',{'enabled':False}); repo=self.api('GET',endpoint)[1]
        if any(repo.get(k) is not v for k,v in settings.items()): raise ValueError('Public repository settings did not verify')
        if repo['private'] or repo['archived'] or repo['default_branch']!='main' or not repo.get('permissions',{}).get('push'): raise ValueError('Public visibility/main/release write access is wrong')
        if self.api('GET',endpoint+'/actions/permissions')[1].get('enabled') is not False: raise ValueError('Public Actions are enabled or unknown')
        if self.api('GET',endpoint+'/pages',expected=(200,404))[0]!=404: raise ValueError('Public repository has unexpected Pages configuration')
        return has_pr
    def browser_evidence(self,id,evidence):
        if evidence.get('disabled') is not True or evidence.get('sourceUrl')!='https://github.com/'+id['notesFullName']+'/settings': raise ValueError('Expected authenticated disabled Pull requests observation for exact settings page')
        datetime.datetime.fromisoformat(evidence['observedAt'].replace('Z','+00:00'))
        with lock(self.journal_path(id)):
            journal=self.load(id); repo=self.api('GET','/repos/'+id['notesFullName'])[1]
            if not journal or evidence.get('repositoryId')!=journal['repositories'].get('public') or repo['id']!=evidence['repositoryId'] or repo['full_name'].lower()!=id['notesFullName'].lower(): raise ValueError('Browser evidence repository identity differs')
            journal['browserEvidence']['pullRequests']=evidence; self.phase(journal,'pullRequests')
        return self.status(id)
    def prepare_godot(self,journal,root):
        cp=journal['preparation']['checkpoints']; resolution=journal['resolution']; preset=journal['presetSelection']; id=journal['identity']
        if resolution['selections'].get('gut')!='9.7.1': raise ValueError('Godot recipe requires GUT 9.7.1')
        if 'godot-ready' in cp: assert_bytes(root,cp['godot-ready']['manifest']); return
        if 'godot-source' not in cp:
            if 'godot-source-started' in cp: raise ValueError('Godot source has no completion receipt; preserve unresolved preparation')
            before=source_manifest(root); dependencies=Path(str(root)+'.dependencies'); archive=dependencies/'gut.zip'; expansion=dependencies/'gut'
            if expansion.exists(): raise ValueError('GUT expansion exists without source completion receipt')
            self.checkpoint(journal,'godot-source-started',{'startedAt':now()})
            try:
                feature={'compatibility':'GL Compatibility','mobile':'Mobile','forward-plus':'Forward Plus'}[preset['renderer']]
                settings={'compatibility':'renderer/rendering_method="gl_compatibility"\nrenderer/rendering_method.mobile="gl_compatibility"','mobile':'renderer/rendering_method="mobile"','forward-plus':''}[preset['renderer']]
                for file in sorted((ASSETS/'presets/godot').rglob('*')):
                    if not file.is_file() or file.name=='gitignore.fragment': continue
                    path=file.relative_to(ASSETS/'presets/godot').as_posix(); data=file.read_bytes().replace(b'\r\n',b'\n')
                    if path.endswith('.template'):
                        path=path.removesuffix('.template'); data=data.decode().replace('{{TITLE_JSON}}',json.dumps(id['title'])).replace('{{FEATURE_JSON}}',json.dumps(feature)).replace('{{RENDERER_SETTINGS}}',settings).encode()
                    write_manifest(root,[entry(path,data)])
                artifact=dict(resolution['artifacts'][0])
                if 'gut-acquired' in cp: artifact['sha256']=cp['gut-acquired']['sha256']
                receipt=acquire(artifact,archive,self.fetch); self.checkpoint(journal,'gut-acquired',receipt)
                source=expand_archive(archive,expansion,['addons/gut/plugin.cfg','addons/gut/gut_cmdln.gd','addons/gut/LICENSE.md'])
                gut=source_manifest(source,[p for p in source_paths(source) if p.startswith('addons/gut/')]); write_manifest(root,gut)
                atomic_json(root/'tools/verify.json',dict(schemaVersion=1,preset='godot',requiredChecks=['documentation','godot-import','godot-compile','gut-headless'],godot=dict(versionFamily='4.7',renderedTests=False)))
                with (root/'.gitignore').open('a') as stream: stream.write((ASSETS/'presets/godot/gitignore.fragment').read_text())
                manifest=source_manifest(root)
            except Exception as exc:
                # Roll back only files generated by this transaction, retaining acquired artifact proof.
                if expansion.exists(): remove_owned(self.root,[expansion])
                original={e['path']:e for e in before}
                remove_owned(self.root,[root/p for p in source_paths(root) if p not in original])
                for path,e in original.items(): (root/path).write_bytes(e['bytes'])
                cp.pop('godot-source-started',None); self.checkpoint(journal,'godot-source-failed',{'failedAt':now(),'message':str(exc),'rolledBack':True}); raise
            self.checkpoint(journal,'godot-source',{'manifest':records(manifest)})
        assert_bytes(root,cp['godot-source']['manifest'])
        gate=gate_module(root); self.runner([gate.godot_executable(),'--headless','--path',str(root),'--import'],cwd=root)
        for file in gate.godot_sources(root):
            if file.suffix=='.gd' and not Path(str(file)+'.uid').is_file(): raise ValueError('Godot did not retain source UID: '+str(file))
        self.checkpoint(journal,'godot-ready',{'manifest':records(source_manifest(root))})
    def prepare_tauri(self,journal,root):
        cp=journal['preparation']['checkpoints']; res=journal['resolution']; preset=journal['presetSelection']; id=journal['identity']; env={'CARGO_TARGET_DIR':str(root/'src-tauri/target')}
        dependencies=Path(str(root)+'.dependencies'); generator=Path(str(root)+'.generator'); artifact=dict(res['artifacts'][0])
        if 'generator-acquired' in cp: artifact['sha256']=cp['generator-acquired']['sha256']
        receipt=acquire(artifact,dependencies/'create-tauri-app.tgz',self.fetch)
        if 'generator-acquired' not in cp: self.checkpoint(journal,'generator-acquired',receipt)
        prefix=['npm','exec','--yes','--package='+str(dependencies/'create-tauri-app.tgz'),'--','create-tauri-app']
        if 'generator' not in cp:
            if 'generator-started' in cp or generator.exists(): raise ValueError('Generator execution has no completion receipt; preserve unresolved preparation')
            self.checkpoint(journal,'generator-started',{'startedAt':now()})
            try:
                generator.mkdir(parents=True); help=self.runner(prefix+['--help'],cwd=generator,env=env).stdout; plain=re.sub(r'\x1b\[[0-9;]*m','',help); major=res['selections']['tauri'].split('.')[0]
                supported=re.search(r'--tauri-version\s+\[([^]]+)\]',plain)
                if not supported or major not in [v.strip() for v in supported[1].split('|')] or not all(flag in plain for flag in ('--template','vanilla-ts','--manager','--identifier','--yes')): raise ValueError('Recorded generator cannot provide selected Tauri major; update adapter, no older release substituted')
                self.runner(prefix+['.','--template','vanilla-ts','--manager','npm','--identifier',preset['appIdentifier'],'--yes','--tauri-version',major],cwd=generator,env=env)
                for path in ('package.json','tsconfig.json','vite.config.ts','index.html','src/main.ts','src/styles.css','src-tauri/Cargo.toml','src-tauri/tauri.conf.json','src-tauri/src/main.rs','src-tauri/src/lib.rs','src-tauri/build.rs','src-tauri/capabilities/default.json'):
                    if not (generator/path).is_file(): raise ValueError('Unsupported generator layout; source missing: '+path)
                generated=source_manifest(generator)
            except Exception as exc:
                remove_owned(self.root,[generator]); cp.pop('generator-started',None); self.checkpoint(journal,'generator-failed',{'failedAt':now(),'message':str(exc),'retryable':True}); raise
            self.checkpoint(journal,'generator',{'version':res['selections']['generator'],'help':help,'manifest':records(generated)})
        assert_bytes(generator,cp['generator']['manifest'])
        if 'overlay' not in cp:
            # An interrupted overlay is intentionally retained and cannot overwrite conflicting bytes.
            manifest=[e for e in source_manifest(generator) if e['path'] not in ('README.md','.gitignore') and not re.match(r'^(src/assets|public)/.*\.(svg|png)$',e['path'])]
            write_manifest(root,manifest); config=read_json(root/'src-tauri/tauri.conf.json')
            if 'frontendDist' not in config.get('build',{}) or not config.get('app',{}).get('windows'): raise ValueError('Unsupported Tauri configuration layout')
            for icon in config.get('bundle',{}).get('icon',[]):
                if not (root/'src-tauri'/icon).is_file(): raise ValueError('Required app icon missing: '+icon)
            config.update(productName=id['title'],version='0.0.1',identifier=preset['appIdentifier'])
            for window in config['app']['windows']: window['title']=id['title']
            config['build'].update(frontendDist='../dist',devUrl='http://localhost:1420',beforeDevCommand='npm run dev',beforeBuildCommand='npm run build'); atomic_json(root/'src-tauri/tauri.conf.json',config)
            toml=(root/'src-tauri/Cargo.toml').read_text(); version=re.search(r'^tauri\s*=\s*\{[^\r\n]*version\s*=\s*"[\^~= ]*(\d+)[^"]*"',toml,re.M)
            if not version or version[1]!=res['selections']['tauri'].split('.')[0]: raise ValueError('Generator Rust dependency does not match selected Tauri family')
            toml=re.sub(r'(?m)^(tauri\s*=\s*\{[^\n]*?version\s*=\s*)"[^"]*"',lambda m:m[1]+json.dumps('^'+res['selections']['tauri']),toml)
            package=re.search(r'(?ms)^\[package\]\s*\n.*?(?=^\[|\Z)',toml)
            library=re.search(r'(?ms)^\[lib\]\s*\n.*?(?=^\[|\Z)',toml)
            old_name=re.search(r'^name\s*=\s*"([A-Za-z_][A-Za-z0-9_]*)"',library[0],re.M) if library else None
            if not package or not old_name: raise ValueError('Unsupported Cargo package/library manifest layout')
            block=package[0]
            for field,value in dict(name=preset['crateName'],version='0.0.1',description=id['description'],authors=[id['owner']]).items():
                line=field+' = '+json.dumps(value,ensure_ascii=False)
                block=re.sub(r'^'+field+r'\s*=.*$',lambda m:line,block,flags=re.M) if re.search(r'^'+field+r'\s*=',block,re.M) else block.rstrip()+'\n'+line+'\n'
            new_name=preset['crateName'].replace('-','_')+'_lib'; libblock=re.sub(r'^name\s*=.*$',lambda m:'name = '+json.dumps(new_name),library[0],flags=re.M); toml=toml.replace(package[0],block).replace(library[0],libblock); (root/'src-tauri/Cargo.toml').write_text(toml)
            main=(root/'src-tauri/src/main.rs').read_text(); call=re.escape(old_name[1])+r'\s*::\s*run\s*\(\s*\)'
            if len(re.findall(call,main))!=1: raise ValueError('Unsupported Rust main entry point')
            (root/'src-tauri/src/main.rs').write_text(re.sub(call,new_name+'::run()',main))
            package=read_json(root/'package.json'); package.update(name=preset['packageName'],version='0.0.1'); package['scripts'].update(typecheck='tsc --noEmit',test='vitest --environment jsdom'); package.setdefault('devDependencies',{}).update(vitest='latest',jsdom='latest'); atomic_json(root/'package.json',package)
            for file in (ASSETS/'presets/tauri/src').iterdir():
                (root/'src'/file.name.removesuffix('.template')).write_text(file.read_text().replace('{{TITLE_JSON}}',json.dumps(id['title'])))
            (root/'index.html').write_text('<!doctype html>\n<html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>'+html.escape(id['title'])+'</title></head><body><div id="app"></div><script type="module" src="/src/main.ts"></script></body></html>\n')
            vite=(root/'vite.config.ts').read_text()
            if not re.search(r'port:\s*1420',vite) or not re.search(r'strictPort:\s*true',vite) or '**/src-tauri/**' not in vite: raise ValueError('Unsupported Vite generator layout')
            atomic_json(root/'tools/verify.json',dict(schemaVersion=1,preset='tauri',requiredChecks=['documentation','typescript','frontend-tests','frontend-build','rust-format','rust-lint','rust-tests','tauri-build'],tauri=dict(selectedRelease=res['selections']['tauri'],crateName=preset['crateName'])))
            with (root/'.gitignore').open('a') as stream: stream.write('\n'+(generator/'.gitignore').read_text()+'\n'+(ASSETS/'presets/tauri/gitignore.fragment').read_text())
            self.checkpoint(journal,'overlay',{'manifest':records(source_manifest(root))})
        assert_bytes(root,[e for e in cp['overlay']['manifest'] if e['path']!='package.json' or 'locks' not in cp])
        if 'locks' not in cp:
            if 'locks-started' in cp or (root/'package-lock.json').exists() or (root/'src-tauri/Cargo.lock').exists(): raise ValueError('Dependency preparation has no completed lock receipt; preserve unresolved locks')
            self.checkpoint(journal,'locks-started',{'startedAt':now()}); before=(root/'package.json').read_bytes()
            try:
                self.runner(['npm','install','--package-lock-only','--no-audit','--no-fund'],cwd=root,env=env); proof=read_json(root/'package-lock.json'); package=json.loads(before)
                for name in ('vitest','jsdom'):
                    version=proof['packages']['node_modules/'+name]['version']
                    if not re.fullmatch(STABLE,version): raise ValueError('npm lock does not prove stable resolved '+name)
                    package['devDependencies'][name]='^'+version
                atomic_json(root/'package.json',package); self.runner(['npm','install','--package-lock-only','--no-audit','--no-fund'],cwd=root,env=env)
                self.runner(['cargo','generate-lockfile','--manifest-path','src-tauri/Cargo.toml'],cwd=root,env=env); self.runner(['cargo','update','--manifest-path','src-tauri/Cargo.toml','-p','tauri','--precise',res['selections']['tauri']],cwd=root,env=env)
                gate=gate_module(root); gate.npm_lock(root); selected=self.runner(['cargo','metadata','--manifest-path','src-tauri/Cargo.toml','--locked','--format-version','1','--quiet'],cwd=root,env=env).stdout; gate.tauri_release(json.loads(selected),res['selections']['tauri'],True)
                retained=source_manifest(root,['package.json','package-lock.json','src-tauri/Cargo.lock'])
            except Exception as exc:
                remove_owned(root,[root/'package-lock.json',root/'src-tauri/Cargo.lock']); (root/'package.json').write_bytes(before); cp.pop('locks-started',None); self.checkpoint(journal,'locks-failed',{'failedAt':now(),'message':str(exc),'retryable':True}); raise
            self.checkpoint(journal,'locks',{'manifest':records(retained)})
        assert_bytes(root,cp['locks']['manifest']); self.locked_install(root,preset)
        metadata=json.loads(self.runner(['cargo','metadata','--manifest-path','src-tauri/Cargo.toml','--locked','--format-version','1','--quiet'],cwd=root,env=env).stdout); gate_module(root).tauri_release(metadata,res['selections']['tauri'],True)
    def local_identity(self,repository):
        root=Path(self.git(repository,'rev-parse','--show-toplevel').stdout.strip()); origin=self.git(root,'remote','get-url','origin').stdout.strip()
        match=re.fullmatch(r'(?:https://github\.com/|git@github\.com:)([^/]+)/([^/]+?)(?:\.git)?',origin)
        if not match: raise ValueError('Local setup requires canonical GitHub origin')
        owner,repo=match.groups()
        if repo.endswith('-release-notes'): raise ValueError('Local setup refuses a release-notes companion')
        remote=self.api('GET','/repos/'+owner+'/'+repo)[1]
        if remote['full_name'].lower()!=(owner+'/'+repo).lower(): raise ValueError('Local setup requires verified project repository')
        if not remote['private']:
            code,notes=self.api('GET','/repos/'+owner+'/'+repo+'-release-notes',expected=(200,404))
            if code!=200 or notes['private'] or notes['full_name'].lower()!=(owner+'/'+repo+'-release-notes').lower(): raise ValueError('Public project needs its verified public release-notes companion')
        for path in ('README.md','AGENTS.md','docs/DESIGN.md','docs/DECISIONS.md','docs/JUDGEMENTS.md','docs/NEXT.md'):
            if not owned(root,root/path).is_file(): raise ValueError('Project foundation missing '+path)
        if not ((root/'tools/verify.sh').is_file() and (root/'tools/verify_linux.py').is_file() or (root/'tools/verify.ps1').is_file() and (root/'tools/Documentation.psm1').is_file()): raise ValueError('Project foundation missing verification helpers')
        title=(root/'README.md').read_text().splitlines()[0]
        if not title.startswith('# '): raise ValueError('README needs original top-level title')
        result=identity(repo,'Local setup',str(root.parent),owner); result.update(title=title[2:].replace('\\_','_'),projectPath=str(root),vaultPath=str(root/'docs'),description='',projectVisibility='private' if remote['private'] else 'public'); return result
    def obsidian_request(self,method,url,body=None):
        if url.startswith('/'): return self.request(method,url,body)
        if method!='GET' or not url.startswith('https://'): raise ValueError('Plugin metadata requires HTTPS GET')
        try: return 200,self.metadata(url)
        except Exception: return 0,{'message':'Public plugin metadata download failed'}
    def install_obsidian(self,id,refresh=False,app_version=None,app_check=None):
        vault=Path(id['vaultPath']); local=owned(vault,vault/'.obsidian'); key=sha(id['fullName'].lower()+'|'+str(vault.absolute()).rstrip('/').lower()); path=owned(self.root,self.root/'vaults'/(key+'.json'))
        result=dict(plugins=[],configuration=False,pending=[],installedVerified=False,enabledVerified=False,journalPath=str(path)); app_version=app_version or obsidian_version()
        try:
            ignored=self.git(id['projectPath'],'check-ignore','--no-index','docs/.obsidian/plugins/probe.js',check=False)
            if ignored.returncode: raise ValueError('docs/.obsidian must be ignored by actual Git checkout')
            if self.git(id['projectPath'],'ls-files','--','docs/.obsidian').stdout.strip(): raise ValueError('docs/.obsidian contains tracked tooling files; resolve conflict first')
            with lock(path):
                journal=read_json(path) if path.exists() else dict(schemaVersion=1,identity=id,plugins={},operation=None,phases={})
                if journal.get('schemaVersion')!=1 or journal['identity']['vaultPath']!=str(vault) or journal['identity']['fullName'].lower()!=id['fullName'].lower(): raise ValueError('Vault journal belongs to another checkout')
                ids=read_json(ASSETS/'obsidian/plugins.json'); prefs=read_json(ASSETS/'obsidian/plugin-preferences.json')
                def save(): atomic_json(path,journal)
                def recover():
                    operation=journal.get('operation')
                    if not operation: return
                    stage=owned(local/'.bootstrap',operation['root'])
                    if stage==local/'.bootstrap': raise ValueError('Invalid plugin recovery root')
                    for plugin in operation['releases']:
                        if plugin not in ids: raise ValueError('Unexpected recovery plugin ID')
                        active=owned(vault,local/'plugins'/plugin); backup=owned(vault,stage/'backup'/plugin)
                        if backup.exists():
                            remove_owned(vault,[active]); active.parent.mkdir(parents=True,exist_ok=True); os.rename(backup,active)
                        elif plugin in operation['promoted'] and plugin not in operation['existed']: remove_owned(vault,[active])
                    operation['promoted']=[]; save()
                local.mkdir(parents=True,exist_ok=True)
                for name in ('app.json','appearance.json','core-plugins.json'):
                    target=owned(vault,local/name)
                    if not target.exists(): target.write_bytes((ASSETS/'obsidian'/name).read_bytes())
                community=owned(vault,local/'community-plugins.json'); existing=read_json(community) if community.exists() else []
                if not isinstance(existing,list) or any(not isinstance(item,str) for item in existing): raise ValueError('community-plugins.json must be a flat array of plugin IDs')
                enabled=list(dict.fromkeys(existing+ids))
                if enabled!=existing: atomic_json(community,enabled)
                result['configuration']=True; recover(); changes=[]; registry=None
                for plugin in ids:
                    active=owned(vault,local/'plugins'/plugin); manifestpath=owned(vault,active/'manifest.json'); valid=False
                    try:
                        manifest=read_json(manifestpath); valid=manifest['id']==plugin and isinstance(manifest['version'],str) and bool(manifest['version'].strip()) and manifest['minAppVersion'] and owned(vault,active/'main.js').stat().st_size>0
                    except (OSError,ValueError,KeyError): valid=False
                    interrupted=journal.get('operation') and plugin in journal['operation']['releases']
                    if valid and not refresh and not interrupted:
                        if app_version and version_tuple(app_version)<version_tuple(manifest['minAppVersion']): raise ValueError('Installed plugin '+plugin+' requires Obsidian '+manifest['minAppVersion'])
                        release=journal['plugins'].get(plugin)
                        if not release or release['version']!=manifest['version']: release=dict(id=plugin,version=manifest['version'],assets={name:None for name in ('manifest.json','main.js','styles.css') if (active/name).is_file()},digests={},skipped=[])
                        integrity=plugin_integrity(release,active); result['plugins'].append(dict(id=plugin,version=manifest['version'],filesVerified=True,skipped=release.get('skipped',[]),**integrity)); continue
                    if interrupted: release=journal['operation']['releases'][plugin]
                    else:
                        if registry is None:
                            code,registry=self.obsidian_request('GET',REGISTRY)
                            if code!=200: raise ValueError('Official Obsidian registry unavailable')
                        release=plugin_release(plugin,registry,self.obsidian_request)
                    if app_version and version_tuple(app_version)<version_tuple(release['minAppVersion']): raise ValueError('Plugin '+plugin+' requires Obsidian '+release['minAppVersion'])
                    changes.append((plugin,release,active))
                if changes:
                    if not journal.get('operation'): journal['operation']=dict(root=str(local/'.bootstrap'/uuid.uuid4().hex),releases={},promoted=[],existed=[])
                    operation=journal['operation']; operation['releases'].update({plugin:release for plugin,release,_ in changes}); save(); staged=[]
                    for plugin,release,active in changes:
                        stage=owned(vault,Path(operation['root'])/'stage'/plugin); remove_owned(vault,[stage]); stage.mkdir(parents=True)
                        if active.exists():
                            for directory,dirs,files in os.walk(active,followlinks=False):
                                for name in dirs+files: owned(vault,Path(directory)/name)
                            shutil.copytree(active,stage,dirs_exist_ok=True)
                        for name,url in release['assets'].items(): self.fetch(url,owned(vault,stage/name))
                        integrity=plugin_integrity(release,stage)
                        if 'styles.css' not in release['assets'] and (stage/'styles.css').exists(): (stage/'styles.css').unlink()
                        manifest=read_json(stage/'manifest.json')
                        if any(manifest[k]!=release[k] for k in ('id','version','minAppVersion')) or not (stage/'main.js').stat().st_size: raise ValueError('Downloaded plugin differs from verified release: '+plugin)
                        staged.append((plugin,release,active,stage,integrity))
                    try:
                        for plugin,release,active,stage,integrity in staged:
                            backup=owned(vault,Path(operation['root'])/'backup'/plugin); backup.parent.mkdir(parents=True,exist_ok=True); active.parent.mkdir(parents=True,exist_ok=True)
                            if active.exists():
                                operation['existed'].append(plugin); save(); os.rename(active,backup)
                            operation['promoted'].append(plugin); save(); os.rename(stage,active); journal['plugins'][plugin]=release
                            result['plugins'].append(dict(id=plugin,version=release['version'],filesVerified=True,skipped=release['skipped'],**integrity))
                    except Exception: recover(); raise
                    journal['lastBackup']=operation['root']; journal['operation']=None; save()
                for plugin in ids:
                    directory=local/'plugins'/plugin
                    for name,content in prefs.get(plugin,{}).items():
                        target=owned(vault,directory/name)
                        if not target.exists(): atomic_json(target,content)
                nickname=owned(vault,local/'plugins/vault-nickname/data-shared.json')
                if not nickname.exists(): atomic_json(nickname,{'nickname':id['title']})
                result['installedVerified']=True
                if not app_version: result['pending'].append('Obsidian app version unknown; verify minimum-app compatibility in running app, then rerun local setup')
                app=(app_check or obsidian_app_check)(id,result['plugins']); result['enabledVerified']=bool(app.get('verified') and app_version)
                if not app.get('verified'): result['pending'].append(app['pending'])
                journal['phases'].update(files='verified',app='verified' if result['enabledVerified'] else 'pending'); save()
        except Exception as exc: result['pending'].append(str(exc)); result['installedVerified']=False
        return result

def version_tuple(value):
    if not re.fullmatch(r'\d+(?:\.\d+){1,3}',value): raise ValueError('Invalid version: '+value)
    return tuple(map(int,value.split('.')))
def plugin_release(plugin,registry,request):
    entries=[item for item in registry if item['id']==plugin]
    if len(entries)!=1 or not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+',entries[0]['repo']): raise ValueError('Plugin has no unique canonical registry repository: '+plugin)
    repo=entries[0]['repo']; skipped=[]; code,latest=request('GET','/repos/'+repo+'/releases/latest',None)
    if code!=200: raise ValueError('Latest published plugin release unavailable: '+plugin)
    def candidate(release):
        if release.get('draft') or release.get('prerelease'): return None
        assets={}; digests={}; reason=None
        for asset in release['assets']:
            name=asset['name']
            if name not in ('manifest.json','main.js','styles.css'): continue
            if name in assets or not asset['browser_download_url'].startswith('https://github.com/'+repo+'/releases/download/'): reason='Unexpected asset identity'; break
            digest=asset.get('digest')
            if digest and not re.fullmatch(r'sha256:[a-fA-F0-9]{64}',digest): reason='Malformed/unsupported asset digest'; break
            assets[name]=asset['browser_download_url']; digests[name]=digest
        if not reason and not {'manifest.json','main.js'}<=set(assets): reason='Missing manifest.json/main.js'
        if not reason:
            code,manifest=request('GET',assets['manifest.json'],None)
            if code!=200: raise ValueError('Plugin manifest download unavailable; do not infer packaging mismatch from network failure')
            try:
                if manifest['id']!=plugin or manifest['version']!=release['tag_name'].removeprefix('v'): raise ValueError()
                version_tuple(manifest['version']); version_tuple(manifest['minAppVersion'])
            except (ValueError,KeyError,TypeError): reason='Manifest ID/version differs from release metadata'
        if reason: skipped.append({'tag':release['tag_name'],'reason':reason}); return None
        return dict(id=plugin,repository=repo,tag=release['tag_name'],version=manifest['version'],minAppVersion=manifest['minAppVersion'],assets=assets,digests=digests,skipped=list(skipped))
    selected=candidate(latest)
    if selected: return selected
    history=[]; page=1
    while True:
        code,batch=request('GET',f'/repos/{repo}/releases?per_page=100&page={page}',None)
        if code!=200: raise ValueError('Plugin release history unavailable')
        history.extend(r for r in batch if r['tag_name']!=latest['tag_name'])
        if len(batch)<100: break
        page+=1
    for release in sorted(history,key=lambda r:r.get('published_at',''),reverse=True):
        selected=candidate(release)
        if selected: return selected
    raise ValueError('Plugin has no release with consistent assets/version metadata: '+plugin)

def plugin_integrity(release,directory):
    missing=[]; directory=Path(directory)
    for name in release['assets']:
        path=owned(directory,directory/relative(name))
        if not path.is_file(): raise ValueError('Plugin asset missing: '+name)
        digest=release.get('digests',{}).get(name)
        if not digest: missing.append(name); continue
        if not re.fullmatch(r'sha256:[a-fA-F0-9]{64}',digest) or sha(path.read_bytes())!=digest[7:].lower(): raise ValueError('Plugin asset digest mismatch: '+name+'; preserve pinned bytes')
    return dict(digestVerification='verified' if not missing else 'unverified-by-digest' if len(missing)==len(release['assets']) else 'partial',assetsWithoutDigest=sorted(missing))

def obsidian_settings(): return Path(os.environ.get('XDG_CONFIG_HOME') or Path.home()/'.config')/'obsidian/obsidian.json'
def obsidian_running():
    return any(command(['pgrep','-x',name],check=False).returncode==0 for name in ('obsidian','Obsidian')) if shutil.which('pgrep') else False
def obsidian_version():
    settings=obsidian_settings()
    try:
        config=read_json(settings); exe=shutil.which('obsidian')
        if config.get('cli') and exe and obsidian_running():
            output=command([exe,'version'],timeout=15).stdout
            for line in output.splitlines():
                match=re.match(r'^\s*(?:Obsidian\s+v?)?(\d+\.\d+\.\d+(?:\.\d+)?)(?:\s|$)',line)
                if match: return match[1]
    except Exception: pass
    versions=[]
    for file in settings.parent.glob('obsidian-*.asar'):
        match=re.fullmatch(r'obsidian-(\d+\.\d+\.\d+(?:\.\d+)?)\.asar',file.name)
        if match: versions.append(match[1])
    return max(versions,key=version_tuple) if versions else None

def obsidian_app_check(id,plugins):
    pending="Open '"+id['vaultPath']+"' as an Obsidian vault, enable Community plugins and the four required plugins, then check Vault Nickname and Diagram Popup"
    try:
        settings=read_json(obsidian_settings()); exe=shutil.which('obsidian')
        if not settings.get('cli') or not exe or not obsidian_running(): return dict(verified=False,pending=pending)
        matches=[key for key,value in settings.get('vaults',{}).items() if Path(value['path']).absolute()==Path(id['vaultPath']).absolute()]
        if len(matches)!=1: return dict(verified=False,pending=pending)
        vault='vault='+matches[0]
        for plugin in plugins: command([exe,vault,'plugin:enable','id='+plugin['id'],'filter=community'],timeout=30)
        enabled=json.loads(command([exe,vault,'plugins:enabled','filter=community','versions','format=json'],timeout=30).stdout)
        if all(sum(e.get('id')==p['id'] and e.get('version')==p['version'] for e in enabled)==1 for p in plugins): return dict(verified=True,pending=None)
    except Exception: pass
    return dict(verified=False,pending=pending)

class JsonParser(argparse.ArgumentParser):
    def error(self,message):
        print(json.dumps({'status':'blocked','conflicts':[message]})); raise SystemExit(2)

def main(argv=None):
    parser=JsonParser(description='BA bootstrap for Linux; Bash + Python 3, Git and authenticated GitHub CLI')
    parser.add_argument('--mode',choices=['plan','create','status','resume','discard','local-setup'],default='plan')
    for option in ('name','description','repository','renderer','app-identifier'): parser.add_argument('--'+option)
    parser.add_argument('--parent'); parser.add_argument('--owner'); parser.add_argument('--preset',choices=['foundation','godot','tauri']); parser.add_argument('--interactive',action='store_true'); parser.add_argument('--refresh-plugins',action='store_true'); parser.add_argument('--state-root',help='Recovery state directory (default XDG_STATE_HOME/BA-Skills/ba-bootstrap/state)'); parser.add_argument('--browser-evidence',type=Path,help='Authenticated disabled Pull requests JSON evidence for the stored invocation')
    args=parser.parse_args(argv); required=['repository'] if args.mode=='local-setup' else ['name'] if args.mode in ('status','resume','discard') else ['name','description']
    if args.interactive:
        for field in required:
            if not getattr(args,field): setattr(args,field,input(field+': '))
        if args.mode in ('plan','create'):
            if args.parent is None: args.parent=input('Parent directory ['+str(Path.home()/'Dev')+']: ') or str(Path.home()/'Dev')
            if args.owner is None: args.owner=input('GitHub owner [Benevolent-Anarchy; cicely-f is also available]: ') or 'Benevolent-Anarchy'
    if args.owner is None: args.owner='Benevolent-Anarchy'
    missing=[field for field in required if not getattr(args,field) or not getattr(args,field).strip()]
    if missing: print(json.dumps({'status':'missing-input','missing':missing})); return 1
    engine=Bootstrap(args.state_root)
    try:
        if args.mode=='local-setup':
            if any(getattr(args,k) is not None for k in ('preset','renderer','app_identifier')): raise ValueError('local-setup configures Obsidian only; engine options cannot be used')
            id=engine.local_identity(args.repository); report=engine.install_obsidian(id,args.refresh_plugins); report['projectVisibility']=id['projectVisibility']; report['status']='complete' if report['installedVerified'] and report['enabledVerified'] and not report['pending'] else 'partial'
        else:
            key={'owner':args.owner,'repository':repository_name(args.name)}; journal=engine.load(key)
            if args.mode in ('status','resume','discard'):
                if not journal: raise ValueError('No bootstrap journal exists for '+args.owner+'/'+key['repository'])
                id=journal['identity']; preset=journal.get('presetSelection') or selection(id,'foundation')
                if args.description is not None and args.description!=id['description']: raise ValueError('Explicit description conflicts with stored invocation')
                if args.parent is not None and str(Path(args.parent).absolute())!=id['parent']: raise ValueError('Explicit parent conflicts with stored invocation')
            else:
                id=identity(args.name,args.description,str(Path.home()/'Dev') if args.parent is None else args.parent,args.owner)
                if args.interactive and not journal:
                    if args.preset is None: args.preset=input('Preset [godot; tauri or foundation]: ') or 'godot'
                    if args.preset=='godot' and args.renderer is None: args.renderer=input('Renderer [compatibility; forward-plus or mobile]: ') or 'compatibility'
                    if args.preset=='tauri' and args.app_identifier is None:
                        proposed=selection(id,'tauri')['appIdentifier']; args.app_identifier=input('Application identifier ['+proposed+']: ') or proposed
                preset=(journal.get('presetSelection') or selection(id,'foundation')) if journal else selection(id,args.preset or 'godot',args.renderer,args.app_identifier)
                if journal: assert_journal_identity(journal,id,preset)
            if journal:
                for key,opt in (('name',args.preset),('renderer',args.renderer),('appIdentifier',args.app_identifier)):
                    if opt is not None and opt!=preset[key]: raise ValueError('Preset option conflicts with stored '+key)
            if args.browser_evidence: engine.browser_evidence(id,read_json(args.browser_evidence))
            if args.mode=='plan': report=engine.plan(id,preset)
            elif args.mode=='status': report=engine.status(id)
            elif args.mode=='discard':
                with lock(engine.journal_path(id)): report=engine.discard(engine.load(id))
            else: report=engine.create(id,preset,args.refresh_plugins)
    except Exception as exc: report={'status':'blocked','conflicts':[str(exc)]}
    print(json.dumps(report,ensure_ascii=False,indent=2)); return 0 if report['status'] in ('ready','complete','discarded') else 1

if __name__=='__main__': sys.exit(main())

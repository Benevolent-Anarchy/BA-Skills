#!/usr/bin/env python3
"""Native BA release engine. Python 3 standard library; never executes PowerShell.

Every external operation is an argument array. Persisted journals contain only
approved public metadata, snapshots and deliberately sanitized diagnostics.
"""
import argparse
import base64
import contextlib
import copy
import datetime as dt
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import uuid
import fcntl

STEAM_IGNORE = ['steam_api*.dll', 'libsteam_api.so', 'libgodotsteam.*', 'steam_appid.txt']
STORES = ['itch', 'steam', 'google-play', 'notes']
COMPLETE = ['succeeded', 'submitted', 'awaiting-store-action']
HASH_RE = r'[0-9a-f]{40}(?:[0-9a-f]{24})?'

class ReleaseError(Exception):
    """An intentionally public diagnostic safe to return or persist."""

class InterruptedOperation(ReleaseError):
    """An external process may have changed remote state before interruption."""

class Cancellation(InterruptedOperation):
    """Cancellation must stop the workflow after saving interrupted progress."""

_CANCELLING=False

def install_cancellation_handlers():
    def cancelled(signum,frame):
        global _CANCELLING
        _CANCELLING=True
        raise Cancellation('Release operation cancelled; reconcile interrupted remote progress before retrying.')
    signal.signal(signal.SIGTERM,cancelled)
    signal.signal(signal.SIGINT,cancelled)

def terminate_process_group(process,grace=2):
    # A launcher can exit before descendants close their inherited pipes. TERM
    # the owned group even then, giving nested orchestrators time to clean their
    # own groups; bound both draining and final waiting before/after KILL.
    try:os.killpg(process.pid,signal.SIGTERM)
    except ProcessLookupError:pass
    try:process.communicate(timeout=grace)
    except subprocess.TimeoutExpired:pass
    finally:
        try:os.killpg(process.pid,signal.SIGKILL)
        except ProcessLookupError:pass
    try:process.communicate(timeout=max(.05,min(grace,.2)))
    except subprocess.TimeoutExpired:
        for stream in [process.stdin,process.stdout,process.stderr]:
            if stream:stream.close()
        if process.poll() is None:process.kill()
        try:process.wait(timeout=max(.05,min(grace,.2)))
        except subprocess.TimeoutExpired:fail('External process did not exit after bounded termination; inspect its remaining process group.')

class ApiError(ReleaseError):
    def __init__(self, status=None):
        super().__init__('Google Play API request failed; inspect account permissions, edit and store state.')
        self.status = status

def fail(message):
    raise ReleaseError(message)

def compact(value):
    # ConvertTo-Json's default Newtonsoft escaping keeps Unicode but escapes
    # JavaScript line separators. Ordered objects keep their insertion order.
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).replace('\x85','\\u0085').replace('\u2028','\\u2028').replace('\u2029','\\u2029')

def pipeline_json(values):
    # PowerShell pipelines enumerate arrays: zero records produce no text,
    # one record serializes the object, and multiple records serialize an array.
    return '' if not values else compact(values[0] if len(values)==1 else values)

def digest(value):
    return hashlib.sha256(value if isinstance(value, bytes) else value.encode('utf-8')).hexdigest()

def object_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail('Duplicate JSON property; inspect the configuration or receipt.')
        result[key] = value
    return result

def parse_json(raw):
    try:
        return json.loads(raw, object_pairs_hook=object_pairs,
                          parse_constant=lambda _: fail('Non-finite JSON numbers are unsupported.'))
    except (ValueError, TypeError):
        fail('Malformed JSON; inspect the configuration or state file.')

def text_exact(path):
    return Path(path).read_bytes().decode('utf-8-sig')

def committed_text(repo, commit, path):
    code, output=run('git',['--no-optional-locks','-C',repo,'cat-file','--filters',commit+':'+path],repo)
    if code:fail('Git read failed: committed file cannot be inspected.')
    return output

def read_json(path):
    try:
        return parse_json(Path(path).read_text(encoding='utf-8-sig'))
    except OSError:
        fail('Required JSON file cannot be read.')

def write_json(path, value):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=path.name+'.', suffix='.tmp', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)
            stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)

def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()

def fields(obj, allowed, required=(), where='configuration'):
    if not isinstance(obj, dict) or set(obj)-set(allowed) or set(required)-set(obj):
        fail('Invalid or unknown fields in '+where+'.')

def credential_free(text):
    if re.search(r'(?i)(https?://[^/\s]+@|(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9]{12,}|Bearer\s+\S+|(?<![\w./-])--?(?:password|token|api.?key|secret|identity)\b|(?<![\w./-])[\w.-]*(?:password|passwd|pwd|token|api.?key|secret|credential)[\w.-]*["\s]*[:=]\s*["\s]*\S+)', text):
        fail('Credential-like text is forbidden in public release configuration, notes and receipts.')

def safe_path(root, relative, must=False, leaf=False):
    if not isinstance(relative, str) or not relative.strip() or Path(relative).is_absolute():
        fail('Configuration paths must be relative and inside the repository.')
    root = Path(root).resolve(); path = (root/relative).resolve()
    if not path.is_relative_to(root): fail('Linked and configured paths must stay inside the repository.')
    if must and not path.exists(): fail('Configured path does not exist.')
    if leaf and not path.is_file(): fail('Configured file does not exist.')
    return path

def tool(name):
    if not name: return None
    if '/' in str(name):
        path = Path(name).absolute()
        return str(path) if path.is_file() and os.access(path, os.X_OK) else None
    return shutil.which(name)

def run(executable, args=(), cwd=None, env=None, timeout=600):
    if _CANCELLING:raise Cancellation('Release operation cancelled; no further external operations started.')
    executable = tool(executable)
    if not executable: fail('Required executable is missing or not runnable.')
    environment = os.environ.copy(); environment.update(env or {})
    try:
        process = subprocess.Popen([executable, *map(str, args)], cwd=cwd, env=environment,
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try: output, _ = process.communicate(timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt, Cancellation) as error:
            terminate_process_group(process)
            if isinstance(error,Cancellation):raise
            raise InterruptedOperation('External operation timed out or was interrupted; reconcile remote progress before retrying.')
        return process.returncode, output.decode('utf-8', errors='replace')
    except OSError:
        fail('External executable could not start; check format and execute permission.')

def git(repo, args, check=True):
    code, output = run('git', ['--no-optional-locks', '-C', repo, *args], cwd=repo,
                       env={'GIT_TERMINAL_PROMPT':'0'})
    if code and check: fail('Git operation failed: '+str(args[0])+'. Check repository or ref.')
    return output.strip() if check else (code, output.strip())

def ancestor(repo, first, second):
    return bool(first and second) and git(repo, ['merge-base','--is-ancestor',first,second],False)[0] == 0

def commit_ref(repo, ref, head=None):
    if not isinstance(ref, str) or not ref.strip() or ref.startswith('-'):
        fail('previousRelease must be null or a confirmed Git ref.')
    value = git(repo, ['rev-parse','--verify',ref+'^{commit}'])
    if head and not ancestor(repo, value, head): fail('Last live baseline must be an ancestor of the selected source.')
    return value

def source_repository(origin):
    match = re.fullmatch(r'(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?/?', origin)
    if not match: fail('A credential-free github.com origin is required to derive public release notes.')
    return match[1]

def root_state(given=None):
    return Path(given or Path(os.environ.get('XDG_STATE_HOME',str(Path.home()/'.local/state')))/'ba-release/releases').resolve()

@contextlib.contextmanager
def locked(directory):
    directory = Path(directory); directory.mkdir(parents=True, exist_ok=True)
    with (directory/'.lock').open('a+b') as stream:
        try: fcntl.flock(stream, fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: fail('Release state is locked by another process or checkout.')
        try: yield
        finally: fcntl.flock(stream, fcntl.LOCK_UN)

def godot_sections(path):
    result = {}; section = None
    try: text = Path(path).read_text(encoding='utf-8-sig')
    except OSError: fail('Required Godot project or preset file cannot be read.')
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith(';'): continue
        if line.startswith('[') and line.endswith(']'):
            section=line[1:-1]
            if section in result: fail('Duplicate Godot section.')
            result[section]={}
        elif '=' in line and section is not None:
            key, value = line.split('=',1); key=key.strip(); value=value.strip()
            if key in result[section]: fail('Duplicate Godot scalar.')
            try: value=json.loads(value)
            except ValueError: pass
            result[section][key]=value
    return result

def set_scalar(text, section, key, value):
    pattern=r'(?ms)(^\['+re.escape(section)+r'\][^\S\n]*\n)(.*?)(?=^\[|\Z)'
    found=list(re.finditer(pattern,text))
    if len(found)!=1: fail('Cannot uniquely update Godot section.')
    match=found[0]; body=match[2]
    key_pattern=r'(?m)^('+re.escape(key)+r'\s*=)[^\r\n]*'
    if len(re.findall(key_pattern,body))!=1: fail('Cannot uniquely update Godot scalar.')
    body=re.sub(key_pattern,lambda m:m[1]+compact(value),body)
    return text[:match.start(2)]+body+text[match.end(2):]

def version(current, change='current'):
    if change=='current': return current
    if not re.fullmatch(r'\d+\.\d+\.\d+',current): fail('Automatic bumps require plain major.minor.patch.')
    parts=list(map(int,current.split('.'))); index={'major':0,'minor':1,'patch':2}[change]
    parts[index]+=1
    for i in range(index+1,3): parts[i]=0
    return '.'.join(map(str,parts))

def pattern_list(value):
    if not isinstance(value,list) or any(not isinstance(x,str) or not x.strip() or re.search(r'[\\/"\r\n\[\]]|\*\*',x) for x in value):
        fail('Ignore/exclude patterns must be arrays of basename globs using * and ?. ')

def baseline(value):
    if value is not None and (not isinstance(value,str) or not value.strip() or value.startswith('-')):
        fail('previousRelease must be null or a confirmed Git ref.')

def display_name(template,title,release_version,platform):
    if not isinstance(template,str) or not template.strip() or re.search(r'[\x00-\x1f]',template) or re.search(r'[{}]',re.sub(r'\{(?:title|version|os)\}','',template)):
        fail('displayNameTemplate supports only {title}, {version} and {os}.')
    if not title: fail('Godot config/name is required for display-name templates.')
    return template.replace('{title}',title).replace('{version}',release_version).replace('{os}',{'Windows Desktop':'Windows','Linux':'Linux','Android':'Android'}[platform])

def runtime(document, incomplete=False):
    fields(document,['schemaVersion','project','previousRelease','exports','verification','distributions','androidVersionCodePolicy','sourceTag'],['schemaVersion','project','previousRelease','exports','verification','distributions'],'release.json')
    if type(document['schemaVersion']) is not int or document['schemaVersion']!=1: fail('Expected integer schemaVersion 1.')
    baseline(document['previousRelease'])
    if type(document.get('sourceTag',False)) is not bool: fail('sourceTag must be boolean.')
    aliases=document['exports']
    if not isinstance(aliases,dict) or (not aliases and not incomplete): fail('exports must map aliases to existing presets.')
    if any(not re.fullmatch(r'[a-z][a-z0-9-]*',k) or not isinstance(v,str) for k,v in aliases.items()): fail('Invalid export alias.')
    def alias(value):
        if value is None and incomplete:return None
        if not isinstance(value,str) or value not in aliases: fail('Unknown or invalid export alias.')
        return aliases[value]
    verification=document['verification'];fields(verification,['gate','standalone'],['gate'],'verification')
    fields(verification['gate'],['script','arguments'],['script'],'verification.gate')
    checks=[]; groups=verification.get('standalone',[])
    if isinstance(groups,dict):groups=[groups]
    if not isinstance(groups,list):fail('Standalone checks must be an object or array.')
    for group in groups:
        fields(group,['exports','script','arguments'],['exports','script'],'standalone')
        if not isinstance(group['exports'],list) or not group['exports']:fail('Standalone exports must be nonempty aliases.')
        for name in group['exports']:checks.append({'preset':alias(name),'script':group['script'],'arguments':group.get('arguments',[])})
    distributions=document['distributions'];fields(distributions,STORES,[],'distributions')
    destinations=[]; baselines={}
    for store, settings in distributions.items():
        if store=='notes':
            if type(settings) is not bool:fail('distributions.notes must be boolean.')
            if settings:destinations.append({'id':'notes','type':'notes'})
            continue
        if store=='itch':
            fields(settings,['game','channels','ignore','displayNameTemplate','previousRelease'],['game','channels','ignore'],'itch')
            pattern_list(settings['ignore'])
            if settings.get('game') is not None and (not isinstance(settings['game'],str) or not re.fullmatch(r'[A-Za-z0-9_-]+/[A-Za-z0-9_-]+',settings['game'])):fail('Invalid Butler owner/game.')
            if not isinstance(settings['channels'],dict) or (not settings['channels'] and not incomplete):fail('Itch channels must map identifiers to aliases.')
            for name, item in settings['channels'].items():
                if not re.fullmatch(r'[a-z][a-z0-9-]*',name):fail('Invalid itch channel identifier.')
                item={'export':item} if isinstance(item,str) else item
                fields(item,['export','channel','ignore','displayNameTemplate','previousRelease'],['export'],'itch channel')
                remote=item.get('channel',name)
                if not isinstance(remote,str) or not re.fullmatch(r'[A-Za-z0-9_.-]+',remote):fail('Invalid Butler remote channel.')
                ignored=item.get('ignore',settings['ignore']);pattern_list(ignored)
                if not all(x in ignored for x in STEAM_IGNORE):fail('Butler ignore list must include every Steam pattern.')
                dest={'id':'itch-'+name,'type':'itch','preset':alias(item['export']),'target':settings['game']+':'+remote if settings['game'] else None,'ignore':ignored}
                if 'displayNameTemplate' in item or 'displayNameTemplate' in settings:dest['displayNameTemplate']=item.get('displayNameTemplate',settings.get('displayNameTemplate'))
                destinations.append(dest); baselines[dest['id']]=item.get('previousRelease',settings.get('previousRelease',document['previousRelease']))
                if 'previousRelease' in item:baseline(item['previousRelease'])
        elif store=='steam':
            fields(settings,['appId','branch','depots','exclude','previousRelease'],['appId','branch','depots'],'steam')
            app=settings['appId'];branch=settings['branch']
            if not (incomplete and app is None) and (type(app) is not int or not 0<app<=4294967295):fail('Steam appId must be a positive integer.')
            if branch is not None and (not isinstance(branch,str) or not re.fullmatch(r'[A-Za-z0-9_-]+',branch)):fail('Invalid Steam branch.')
            if not isinstance(settings['depots'],dict):fail('Steam depots must map numeric IDs to aliases.')
            depots=[];pattern_list(settings.get('exclude',[]))
            for depot, item in settings['depots'].items():
                if not re.fullmatch(r'[1-9][0-9]*',depot) or int(depot)>4294967295:fail('Invalid Steam depot ID.')
                item={'export':item} if isinstance(item,str) else item;fields(item,['export','exclude'],['export'],'Steam depot')
                excluded=item.get('exclude',settings.get('exclude',[]));pattern_list(excluded)
                depots.append({'id':int(depot),'preset':alias(item['export']),'exclude':excluded})
            if not depots and not incomplete:fail('Steam depots must list mappings.')
            destinations.append({'id':'steam','type':'steam','appId':app,'branch':branch,'depots':depots})
            baselines['steam']=settings.get('previousRelease',document['previousRelease'])
        else:
            allowed=['export','track','releaseStatus','userFraction','language','retainVersionCodes','previousRelease','baselineAdvancesOn']
            fields(settings,allowed,['export','track','releaseStatus','language','retainVersionCodes'],'google-play')
            for key,regex in [('track',r'[A-Za-z0-9_.-]+'),('language',r'[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*')]:
                if settings[key] is not None and (not isinstance(settings[key],str) or not re.fullmatch(regex,settings[key])):fail('Invalid Google Play '+key+'.')
            status=settings['releaseStatus'];fraction=settings.get('userFraction')
            if status not in [None,'draft','completed','inProgress']:fail('Invalid Google Play releaseStatus.')
            if fraction is not None and (status!='inProgress' or type(fraction) not in (int,float) or not 0<fraction<1):fail('Invalid Google Play rollout fraction.')
            retain=settings['retainVersionCodes']
            if retain is not None and (not isinstance(retain,list) or any(not isinstance(x,str) or not re.fullmatch(r'[1-9][0-9]{0,9}',x) or int(x)>2100000000 for x in retain) or len(set(retain))!=len(retain)):fail('Invalid retainVersionCodes.')
            dest={'id':'google-play','type':'google-play','preset':alias(settings['export']),'track':settings['track'],'releaseStatus':status,'userFraction':fraction,'language':settings['language'],'retainVersionCodes':retain}
            if 'baselineAdvancesOn' in settings:
                if settings['baselineAdvancesOn'] not in ['live','submitted']:fail('baselineAdvancesOn must be live or submitted.')
                dest['baselineAdvancesOn']=settings['baselineAdvancesOn']
            destinations.append(dest);baselines[dest['id']]=settings.get('previousRelease',document['previousRelease'])
        if 'previousRelease' in settings:baseline(settings['previousRelease'])
    for value in baselines.values():baseline(value)
    policy=document.get('androidVersionCodePolicy','increment-selected')
    if policy not in ['increment-selected','existing']:fail('Invalid androidVersionCodePolicy.')
    return {'schemaVersion':1,'project':document['project'],'previousReleaseRef':document['previousRelease'],'exports':list(aliases.values()),'verification':{'script':verification['gate']['script'],'arguments':verification['gate'].get('arguments',[])},'standalone':checks,'destinations':destinations,'destinationBaselines':baselines,'androidVersionCodePolicy':policy,'sourceTag':document.get('sourceTag',False)}

def configuration(repo, document=None, incomplete=False):
    repo=Path(repo).resolve()
    if git(repo,['rev-parse','--show-toplevel'])!=str(repo):fail('Repository must name the Git root.')
    if document is None:
        try:raw=text_exact(repo/'release.json')
        except OSError:fail('Run setup to gather missing release.json settings.')
        document=parse_json(raw)
    elif isinstance(document,str):raw=document;document=parse_json(raw)
    else:raw=json.dumps(document,ensure_ascii=False,indent=2)
    credential_free(raw);config=runtime(document,incomplete)
    project=safe_path(repo,document['project'],must=True)
    project_sections=godot_sections(project/'project.godot');application=project_sections.get('application',{})
    current=application.get('config/version');title=application.get('config/name')
    if not isinstance(current,str) or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?',current):fail('Godot config/version must be a release version.')
    sections=godot_sections(project/'export_presets.cfg');presets=[]
    if len(set(config['exports']))!=len(config['exports']):fail('Duplicate export preset name.')
    for name in config['exports']:
        matches=[k for k,v in sections.items() if re.fullmatch(r'preset\.\d+',k) and v.get('name')==name]
        if len(matches)!=1:fail('Existing export preset not uniquely found: '+name)
        preset=sections[matches[0]];options=sections.get(matches[0]+'.options',{});platform=preset.get('platform');output=preset.get('export_path')
        if platform not in ['Linux','Windows Desktop','Android']:fail('Unsupported export platform.')
        if not isinstance(output,str) or not output.strip():fail('Preset has no existing export_path.')
        output=(project/output).resolve();safe_path(repo,str(output.relative_to(repo)) if output.is_relative_to(repo) else '../outside')
        record={'name':name,'platform':platform,'configuredPath':output.relative_to(repo).as_posix(),'filename':output.name}
        if platform=='Windows Desktop':
            record['versionMetadata']={k:options[k] for k in ['application/file_version','application/product_version'] if k in options}
            if any(v not in ['',current,current+'.0'] for v in record['versionMetadata'].values()):fail('Windows version metadata must follow config/version.')
        if platform=='Android':
            required=['gradle_build/use_gradle_build','gradle_build/export_format','version/code','version/name','package/unique_name','package/signed']
            if any(k not in options for k in required):fail('Missing Android options.')
            gradle=options['gradle_build/use_gradle_build'];fmt=options['gradle_build/export_format'];code=options['version/code'];package=options['package/unique_name']
            aab=gradle is True and type(fmt) is int and fmt==1 and output.suffix.lower()=='.aab'
            apk=type(gradle) is bool and (not gradle or fmt==0) and output.suffix.lower()=='.apk'
            if options['package/signed'] is not True or not (aab or apk):fail('Android requires signed APK or signed Gradle AAB.')
            if type(code) is not int or not 1<=code<=2100000000:fail('Android version/code is outside the Play range.')
            if options['version/name'] not in ['',current]:fail('Android version/name must follow config/version.')
            if not isinstance(package,str) or not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+',package):fail('Android package must be an inspected literal name.')
            record.update(packageName=package,versionCode=code,format='aab' if aab else 'apk',useGradle=gradle)
        presets.append(record)
    gate=config['verification']
    def hook(path,nullable=False):
        if path is None and (incomplete or nullable):return None
        if not isinstance(path,str):fail('Verification hook must name an inspected native script.')
        # Windows release.json remains shared: choose an existing native sibling explicitly.
        if path.endswith('.ps1'):
            native=path[:-4]+'.sh'
            if (repo/native).is_file():path=native
            else:fail('PowerShell hook has no native .sh sibling; configure a Linux hook before preparation.')
        return safe_path(repo,path,leaf=True)
    verification=hook(gate['script'])
    if not isinstance(gate['arguments'],list) or any(not isinstance(x,str) for x in gate['arguments']):fail('Verification arguments must be strings.')
    checked=set()
    for check in config['standalone']:
        if check['preset'] in checked:fail('Standalone checks require distinct export presets.')
        checked.add(check['preset']);hook(check['script'],True)
        if not isinstance(check['arguments'],list) or any(not isinstance(x,str) or re.search(r'[{}]',re.sub(r'\{(?:artifact|platform|repository|filename)\}','',x)) for x in check['arguments']):fail('Unsupported standalone substitutions.')
    by_name={p['name']:p for p in presets}
    upload_targets=set()
    for dest in config['destinations']:
        target=dest.get('target') if dest['type']=='itch' else None
        if target is not None:
            if target in upload_targets:fail('Butler target must be a distinct owner/game:channel across all configured destinations.')
            upload_targets.add(target)
        if dest['type']=='itch' and dest['preset'] in by_name:
            preset=by_name[dest['preset']]
            if preset['platform']=='Android' and preset['format']!='apk':fail('Itch requires signed APK for Android.')
            if 'displayNameTemplate' in dest:display_name(dest['displayNameTemplate'],title,current,preset['platform'])
        elif dest['type']=='steam':
            if any(by_name[d['preset']]['platform']=='Android' for d in dest['depots']):fail('Steam depots require desktop presets.')
        elif dest['type']=='google-play' and dest['preset'] in by_name:
            if by_name[dest['preset']].get('format')!='aab':fail('Google Play requires a signed AAB preset.')
    if not config['destinations'] and not incomplete:fail('Configure at least one distribution.')
    origin=git(repo,['remote','get-url','origin']);source=source_repository(origin)
    return {'repository':str(repo),'projectPath':str(project),'version':current,'title':title,'config':config,'document':document,'configHash':digest(raw),'presets':presets,'notesRepository':source+'-release-notes','verificationPath':str(verification) if verification else None,'sections':sections}

def store_key(destination):
    kind=destination['type']
    if kind=='itch':return 'itch:'+str(destination.get('target'))
    if kind=='steam':return 'steam:'+str(destination['appId'])+':'+str(destination.get('branch'))
    if kind=='google-play':return 'play:'+str(destination.get('packageName'))+':'+str(destination.get('track'))
    return None

def ledger_directory(plan_or_settings, state_root):
    source=plan_or_settings['notesRepository'].removesuffix('-release-notes')
    return root_state(state_root)/'repositories'/digest('github.com/'+source.lower())[:20]

def ledger_read(plan, state_root, name='live.json'):
    path=ledger_directory(plan,state_root)/name
    if not path.exists():return {}
    try:value=read_json(path)
    except ReleaseError:fail("Release state 'repositories/"+path.parent.name+'/'+name+"' cannot be read; repair it, then retry.")
    if not isinstance(value,dict):fail('Release ledger must be an object; repair it before continuing.')
    return value

def live_receipts(ledger):
    for key,row in ledger.items():
        if not isinstance(row,dict):fail('Damaged live ledger row; repair it before continuing.')
        yield key,row
        for item in row.get('recorded',[]):
            if not isinstance(item,dict):fail('Damaged live receipt; repair it before continuing.')
            yield key,item

def newest(repo,sources):
    result=[]
    for commit in dict.fromkeys(sources):
        if not commit:continue
        if any(ancestor(repo,commit,c) for c in result):continue
        result=[c for c in result if not ancestor(repo,c,commit)]+[commit]
    if len(result)>1:fail('Previous published release is ambiguous; explicitly reconcile the divergent live sources.')
    return result[0] if result else None

def started(record):
    return record['status'] in COMPLETE+['in-progress','uncertain','abandoned'] or bool(set(record.get('remote',{}))-{'sourceCommit','notesHashes'})

def seed_sent(plan,state_root):
    root=root_state(state_root);game=plan['notesRepository'].lower();sent={}
    if not root.exists():return sent
    for checkout in sorted(root.iterdir()):
        if not checkout.is_dir() or checkout.name=='repositories':continue
        journals=[]
        for path in sorted(checkout.glob('*/state.json')):
            try:state=read_json(path);name=state.get('plan',{}).get('notesRepository','').lower()
            except (ReleaseError,AttributeError):state=None;name=''
            journals.append((path,state,name))
        games={name for _,_,name in journals if name}
        for path,state,name in journals:
            if not name:
                if games and game not in games:continue
                fail('A release journal under the state root cannot be read; restore it before publication.')
            if name!=game:continue
            try:
                saved=state['plan'];records=state['destinations']
                if not re.fullmatch(HASH_RE,saved['head']) or not saved['version'] or not isinstance(saved['destinations'],list):raise KeyError()
                for destination in saved['destinations']:
                    if not destination['selected'] or destination['type']=='notes':continue
                    record=records[destination['id']]
                    if not started(record):continue
                    entry={'sourceCommit':record.get('remote',{}).get('sourceCommit') or saved['head'],'version':saved['version'],'planId':saved['planId'],'statePath':str(path.parent),'destination':destination['id'],'seededAt':now()}
                    if record.get('remote',{}).get('abandonment'):entry['abandoned']=record['remote']['abandonment']
                    if destination['type']=='google-play' and record['status']=='submitted':entry['submittedAt']=now()
                    sent.setdefault(store_key(destination),[]).append(entry)
            except (KeyError,TypeError,ValueError):fail('A release journal is incomplete; restore it before publication.')
    return sent

def sent_read(plan,state_root):
    if not (ledger_directory(plan,state_root)/'sent.json').exists():return seed_sent(plan,state_root)
    sent=ledger_read(plan,state_root,'sent.json')
    if any(not isinstance(v,list) or any(not isinstance(e,dict) for e in v) for v in sent.values()):fail('Damaged sent ledger; repair it before continuing.')
    return sent

def change_evidence(repo,previous,head):
    changes=[]
    for line in git(repo,['log','--no-merges','--reverse','--format=%H%x1f%s',previous+'..'+head]).splitlines():
        commit,subject=line.split('\x1f',1);changes.append({'commit':commit,'subject':subject})
    return changes,git(repo,['diff','--name-only',previous,head,'--']).splitlines()

def plan(repo,selection=(),state_root=None,change='current',snapshot=None,frozen=None,tag_commit=None,releasing_version=None):
    settings=configuration(repo);repo=settings['repository'];config=settings['config'];head=git(repo,['rev-parse','HEAD'])
    selected=sorted(set(selection));known={d['id'] for d in config['destinations']}
    if set(selected)-known:fail('Unknown destination: '+', '.join(sorted(set(selected)-known)))
    blockers=[]
    if not selected:blockers.append('Select release destinations explicitly; none are selected.')
    if git(repo,['rev-parse','--is-shallow-repository'])=='true':blockers.append('Shallow history cannot establish a complete release comparison.')
    dirty=git(repo,['status','--porcelain=v1','--untracked-files=all']);release_version=version(settings['version'],change)
    ledger=ledger_read(settings,state_root);sent=None
    if frozen is not None:
        previous=frozen
        if previous and commit_ref(repo,previous,head)!=previous:fail('Prepared previous release must be an exact commit.')
    else:
        configured=config['previousReleaseRef'];candidates=[commit_ref(repo,configured,head)] if configured else []
        candidates.extend(row['sourceCommit'] for _,row in live_receipts(ledger) if row.get('version')!=(releasing_version or release_version) and re.fullmatch(HASH_RE,str(row.get('sourceCommit',''))) and ancestor(repo,row['sourceCommit'],head))
        previous=newest(repo,candidates)
    changes=[];changed_files=[]
    if previous:changes,changed_files=change_evidence(repo,previous,head)
    else:blockers.append('previousRelease is unconfirmed; identify the previous published source commit/ref.')
    baselines={};destinations=[];presets={p['name']:p for p in settings['presets']}
    for item in config['destinations']:
        item=copy.deepcopy(item);kind=item['type'];dest={'id':item['id'],'type':kind,'selected':item['id'] in selected,'status':'planned' if item['id'] in selected else 'not-selected'}
        for key,value in item.items():
            if key not in ['id','type','displayNameTemplate']:dest[key]=value
        if kind=='notes':dest.update(repository=settings['notesRepository'],path='releases/'+release_version+'.md')
        elif kind=='itch':
            preset=presets[item['preset']]
            if 'displayNameTemplate' in item:
                dest['displayName']=display_name(item['displayNameTemplate'],settings['title'],release_version,preset['platform'])
                dest['requiredActions']=["Set the upload's display name to '"+dest['displayName']+"' on itch.io's Edit game page; this does not control the downloaded archive filename."]
            if dest['selected'] and not item['target']:blockers.append(item['id']+': Butler target is unconfirmed.')
            if dest['selected'] and preset['platform']!='Android' and len([c for c in config['standalone'] if c['preset']==item['preset'] and c['script']])!=1:
                blockers.append(item['id']+': Configure a meaningful standalone functionality check with Steam files unavailable.')
        elif kind=='steam':
            dest['requiredActions']=['Verify build activation on the selected Steam branch in Steamworks.','Publish the approved notes as a Steam announcement.']
            if dest['selected'] and not dest['branch']:blockers.append('Steam branch is unconfirmed.')
        elif kind=='google-play':
            dest.update(packageName=presets[item['preset']]['packageName'],versionCode=presets[item['preset']]['versionCode'])
            dest['requiredActions']=['Review all current Play track releases before approving retained version codes.']
            if item.get('baselineAdvancesOn')!='submitted':dest['requiredActions'].append('Verify review, managed publishing and rollout state in Play Console after submission.')
            if dest['selected']:
                for key in ['track','releaseStatus','language','retainVersionCodes']:
                    if dest[key] is None:blockers.append('Google Play '+key+' is unconfirmed.')
                if dest['releaseStatus']=='inProgress' and dest['userFraction'] is None:blockers.append('Google Play rollout fraction is unconfirmed.')
        if dest['selected'] and kind!='notes':
            key=store_key(dest);sources=[]
            if snapshot is not None and dest['id'] in snapshot:ref=snapshot[dest['id']]
            else:
                if key in ledger:sources.append(ledger[key]['sourceCommit'])
                if dest.get('baselineAdvancesOn')=='submitted':
                    if sent is None:sent=sent_read(settings,state_root)
                    sources.extend(e['sourceCommit'] for e in sent.get(key,[]) if e.get('submittedAt') and not e.get('abandoned'))
                ref=newest(repo,sources) if sources else config['destinationBaselines'].get(dest['id'],config['previousReleaseRef'])
            baseline_commit=commit_ref(repo,ref,head) if ref is not None else None;baselines[dest['id']]=baseline_commit
            dest.update(previousCommit=baseline_commit,changes=[],changedFiles=[])
            if baseline_commit:dest['changes'],dest['changedFiles']=change_evidence(repo,baseline_commit,head)
            else:dest['status']='blocked';blockers.append(dest['id']+': Confirm its last live source commit/ref.')
        destinations.append(dest)
    needed=set()
    for dest in destinations:
        if not dest['selected']:continue
        if dest['type'] in ['itch','google-play']:needed.add(dest['preset'])
        if dest['type']=='steam':needed.update(d['preset'] for d in dest['depots'])
    source_tag=None
    if config['sourceTag']:
        tagged=tag_commit or head
        if commit_ref(repo,tagged,head)!=tagged:fail('Prepared source tag must name an exact ancestor commit.')
        tag_name='v'+release_version
        if git(repo,['check-ref-format','refs/tags/'+tag_name],False)[0]:blockers.append('sourceTag is not a valid Git ref.')
        source_tag={'name':tag_name,'commit':tagged,'repository':settings['notesRepository'].removesuffix('-release-notes'),'message':(settings['title'] or 'Release')+' '+release_version}
    identity={'schemaVersion':1,'repository':repo,'head':head,'configSha256':settings['configHash'],'version':release_version,'previousCommit':previous,'selectedDestinations':selected,'baselines':baselines,'versionChange':change}
    if source_tag:identity['sourceTag']=source_tag
    draft='# '+(settings['title'] or '')+' '+release_version+'\n\n<!-- sourceCommit: '+head+'; previousCommit: '+(previous or '')+' -->\n\n'
    if previous:draft+=('\n'.join('- '+c['subject'] for c in changes)+'\n') if changes else 'No commits since the confirmed previous release.\n'
    else:draft+='Previous published release boundary is unconfirmed; release notes cannot yet be derived.\n'
    draft+='\n[Release availability](../availability/'+release_version+'.json)\n'
    configuration_ready=not blockers
    if dirty:blockers.append('The source working tree contains uncommitted files; review and commit before preparation.')
    if change!='current':blockers.append('Projected version must be reserved and committed by prepare.')
    result={'schemaVersion':1,'mode':'plan','planId':digest(compact(identity)),'repository':repo,'head':head,'version':release_version,'sourceVersion':settings['version'],'versionChange':change,'preview':change!='current','configSha256':settings['configHash'],'previousCommit':previous,'selectedDestinations':selected,'notesRepository':settings['notesRepository'],'baselines':baselines,'exports':settings['presets'],'requiredExports':[p for p in settings['presets'] if p['name'] in needed],'destinations':destinations,'changes':changes,'changedFiles':changed_files,'notesDraft':draft,'configurationReady':configuration_ready,'sourceChanges':dirty.splitlines(),'blockers':blockers,'ready':not blockers}
    if source_tag:result['sourceTag']=source_tag
    return result

def state_path(path):
    path=Path(path).resolve();state=read_json(path/'state.json')
    try:
        if path.name!=state['plan']['version'] or path.parent.name!=digest(state['plan']['repository'])[:20]:fail('State must remain inside the state root; pass the path returned by prepare.')
    except (KeyError,TypeError):fail('Malformed release journal.')
    return path,state

def lfs_preflight(repo):
    files=git(repo,['ls-files','-z']).split('\0');uses=False
    for name in files:
        if Path(name).name=='.gitattributes':
            path=safe_path(repo,name,leaf=True)
            if re.search(r'\bfilter=lfs\b',path.read_text()):uses=True
    if tool('git-lfs'):
        code,listing=git(repo,['lfs','ls-files'],False)
        if code:fail('Git LFS inventory failed; resolve it before preparation.')
        uses=uses or bool(listing)
    if uses:
        if not tool('git-lfs'):fail('Git LFS is required before preparing this checkout.')
        git(repo,['lfs','pull'])
        listing=git(repo,['lfs','ls-files'])
        if any(re.match(r'^\S+ - ',line) for line in listing.splitlines()):fail('Git LFS objects remain pointer placeholders; hydrate before preparing.')

def artifact(state_dir,directory,preset,source):
    directory=Path(directory);files=[]
    for path in sorted(directory.rglob('*')):
        if path.is_symlink():fail('Staged artifact links are unsupported.')
        if path.is_file():files.append({'path':path.relative_to(state_dir).as_posix(),'size':path.stat().st_size,'sha256':digest(path.read_bytes())})
    if not files:fail('Export produced no artifact files.')
    result={'preset':preset,'directory':directory.relative_to(state_dir).as_posix(),'files':files}
    if source:result['sourceCommit']=source
    return result

def assert_artifacts(path,state):
    required={p['name'] for p in state['plan']['requiredExports']}
    present=[a['preset'] for a in state['artifacts']]
    if len(present)!=len(set(present)):fail('Duplicate prepared artifacts.')
    if state['status'] not in ['preparing','preparation-failed'] and not required.issubset(set(present)):fail('Required prepared artifact is missing.')
    for saved in state['artifacts']:
        directory=safe_path(path,saved['directory'],must=True)
        if artifact(path,directory,saved['preset'],saved.get('sourceCommit'))!=saved:fail('Prepared artifact changed: '+saved['preset'])

def engine(executable=None):
    if executable:
        found=tool(executable)
        if not found:fail('Requested Godot executable was not found.')
        return found
    for name in ['godot_console','godot4_console','godot','godot4']:
        found=tool(name)
        if found:return found
    fail('No Godot executable found; supply --godot-executable.')

def hook_run(settings,script,args,cwd):
    if script.endswith('.ps1'):
        script=script[:-4]+'.sh'
        args=[('--'+re.sub(r'([a-z0-9])([A-Z])',r'\1-\2',a[1:]).lower()) if re.fullmatch(r'-[A-Za-z][A-Za-z0-9]*',a) else a for a in args]
    path=safe_path(settings['repository'],script,leaf=True)
    return run('bash',[path,*args],cwd) if path.suffix=='.sh' else run(str(path),args,cwd)

def counter_presets(settings,planned,only=None):
    if settings['config']['androidVersionCodePolicy']=='existing':return []
    presets={p['name']:p for p in settings['presets']}
    return sorted({d['preset'] for d in planned['destinations'] if d['selected'] and d['type'] in ['itch','google-play'] and (only is None or d['id'] in only) and presets[d['preset']]['platform']=='Android'})

def reserve_source(settings,planned,directory,change='current',new_release=False,counters=None):
    directory=Path(directory);pointer=directory/'active-source.json';counters=counter_presets(settings,planned) if counters is None else counters
    if not pointer.exists() and change=='current' and not counters:return None
    directory.mkdir(parents=True,exist_ok=True)
    with locked(directory):
        reservation=read_json(pointer) if pointer.exists() else None
        if reservation and (new_release or (reservation['status']=='committed' and settings['version']!=reservation['version'])):
            if reservation['status']!='committed' or not planned['ready']:fail('Finish the existing source reservation first.')
            reservation=None
        if reservation is None:
            if not planned['ready']:fail('Release plan is blocked: '+' '.join(planned['blockers']))
            target_version=version(settings['version'],change);project=Path(settings['projectPath']);before_project=(project/'project.godot').read_text();before_presets=(project/'export_presets.cfg').read_text();after_project=before_project;after_presets=before_presets;codes=[]
            if target_version!=settings['version']:after_project=set_scalar(before_project,'application','config/version',target_version)
            for section,values in settings['sections'].items():
                if not re.fullmatch(r'preset\.\d+',section):continue
                option_section=section+'.options';options=settings['sections'].get(option_section,{})
                for key in ['version/name','application/file_version','application/product_version']:
                    value=options.get(key)
                    if target_version!=settings['version'] and value==settings['version']:after_presets=set_scalar(after_presets,option_section,key,target_version)
                    elif target_version!=settings['version'] and key.startswith('application/') and value==settings['version']+'.0':after_presets=set_scalar(after_presets,option_section,key,target_version+'.0')
                if values.get('name') in counters:
                    code=options.get('version/code')
                    if type(code) is not int or code>=2100000000:fail('Android counter cannot be incremented beyond Play limit.')
                    after_presets=set_scalar(after_presets,option_section,'version/code',code+1);codes.append({'preset':values['name'],'before':code,'after':code+1})
            files=[]
            for path,before,after in [(project/'project.godot',before_project,after_project),(project/'export_presets.cfg',before_presets,after_presets)]:
                if before!=after:files.append({'path':path.relative_to(settings['repository']).as_posix(),'beforeSha256':digest(path.read_bytes()),'afterSha256':digest(after),'content':after})
            reserved_path=directory/target_version
            if (reserved_path/'state.json').exists():fail('This version already has a prepared release; resume or extend it.')
            reservation={'schemaVersion':1,'status':'reserved','repository':settings['repository'],'originalHead':planned['head'],'configSha256':planned['configSha256'],'version':target_version,'operation':change,'selection':planned['selectedDestinations'],'files':files,'androidCodes':codes,'statePath':str(reserved_path)}
            write_json(pointer,reservation)
        if reservation['configSha256']!=planned['configSha256'] or reservation['selection']!=planned['selectedDestinations']:fail('Source reservation selection/configuration changed; resume its original release.')
        if change!='current' and change!=reservation['operation']:fail('Source reservation has a different version operation.')
        if not ancestor(settings['repository'],reservation['originalHead'],planned['head']):fail('Source reservation no longer descends from original source.')
        for item in reservation['files']:
            path=safe_path(settings['repository'],item['path'],leaf=True);actual=digest(path.read_bytes())
            if actual not in [item['beforeSha256'],item['afterSha256']]:fail('Source settings changed outside reservation; inspect before resuming.')
            if actual==item['beforeSha256']:
                if reservation['status']=='committed':fail('Committed release settings were reverted; refusing to change source on retry. Reconcile the reserved release first.')
                path.write_text(item['content'],encoding='utf-8',newline='\n')
        if git(settings['repository'],['status','--porcelain=v1','--untracked-files=all']):
            return {'status':'source-update-required','statePath':reservation['statePath'],'version':reservation['version'],'message':'Review and commit reserved version settings locally, then resume prepare with the same selection. No export has run.'}
        for item in reservation['files']:
            committed=committed_text(settings['repository'],'HEAD',item['path'])
            if digest(committed)!=item['afterSha256'] and digest(committed.rstrip('\n'))!=item['afterSha256']:fail('Reserved source settings were not committed.')
        if configuration(settings['repository'])['version']!=reservation['version']:fail('Committed version differs from reserved release.')
        reservation.update(status='committed',sourceCommit=planned['head']);write_json(pointer,reservation)
        return {'status':'source-committed','statePath':reservation['statePath']}

def butler_input(path,preset,destination):
    # caller passes a real snapshot directory as path
    directory=Path(path)
    if preset['platform']!='Android':return directory
    apk=directory/preset['filename']
    if not apk.is_file():fail('Prepared signed APK is missing.')
    for item in directory.rglob('*'):
        if item.is_file() and item not in [apk,Path(str(apk)+'.idsig')] and not ignored(item.name,destination['ignore']):fail('Additional Android payload files need explicit distribution configuration.')
    return apk

def ignored(name,patterns):
    return any(fnmatch.fnmatchcase(name,p) for p in patterns)

def distribution_checks(settings,state,path,butler):
    for destination in state['plan']['destinations']:
        if not destination['selected'] or destination['type']!='itch':continue
        exported=next(a for a in state['artifacts'] if a['preset']==destination['preset']);directory=safe_path(path,exported['directory'],must=True)
        preset=next(p for p in state['plan']['exports'] if p['name']==destination['preset'])
        record=state['checks'].setdefault(destination['id'],{'standalone':'pending','dryRun':'pending','error':None})
        input_path=butler_input(directory,preset,destination)
        if record['standalone'] in ['succeeded','not-applicable'] and record['dryRun']=='succeeded' and record.get('input')==input_path.relative_to(path).as_posix():continue
        files=sorted(p for p in directory.rglob('*') if p.is_file());excluded=[p for p in files if ignored(p.name,destination['ignore'])];included=[p for p in files if p not in excluded]
        try:
            if preset['platform']=='Android':included=[input_path];excluded=[p for p in files if p!=input_path];record['standalone']='not-applicable'
            elif record['standalone']!='succeeded':
                check=next(c for c in settings['config']['standalone'] if c['preset']==preset['name']);hold=path/'standalone-withheld'/uuid.uuid4().hex;moves=[]
                try:
                    for file in excluded:
                        held=hold/file.relative_to(directory);held.parent.mkdir(parents=True,exist_ok=True);file.rename(held);moves.append((file,held))
                    substitutes={'artifact':str(directory),'platform':preset['platform'],'repository':settings['repository'],'filename':preset['filename']}
                    args=check['arguments']
                    for key,value in substitutes.items():args=[a.replace('{'+key+'}',value) for a in args]
                    code,_=hook_run(settings,check['script'],args,directory)
                    if code:fail('Standalone functionality check failed.')
                    record['standalone']='succeeded'
                finally:
                    collision=False
                    for original,held in moves:
                        if original.exists():collision=True;continue
                        held.rename(original)
                    if collision:fail('Standalone check recreated a withheld file; inspect withheld files before restoring or publishing.')
                assert_artifacts(path,state)
            args=['push',input_path,destination['target'],'--dry-run','--userversion',state['plan']['version']]
            for pattern in destination['ignore']:args+=['--ignore',pattern]
            code,output=run(butler,args,path)
            if code:fail('Butler dry-run failed.')
            output=re.sub(r'\x1b\[[0-9;]*[A-Za-z]','',output)
            def listed(file):return bool(re.search(r'(?m)(?:^|\s)'+re.escape(file.relative_to(directory).as_posix())+r'\s*$',output))
            if any(listed(p) for p in excluded) or any(not listed(p) for p in included):fail('Butler dry-run did not list exactly every approved artifact file.')
            record.update(dryRun='succeeded',error=None,input=input_path.relative_to(path).as_posix(),included=[p.relative_to(directory).as_posix() for p in included],excluded=[p.relative_to(directory).as_posix() for p in excluded],previewSha256=digest(output))
            (path/('selection.'+destination['id']+'.txt')).write_text(output)
        except (ReleaseError,StopIteration):
            record['error']='Standalone test or Butler file-selection check failed; inspect local configuration and withheld files.'
            write_json(path/'state.json',state);raise
        write_json(path/'state.json',state)

def new_record(selected=True):
    return {'status':'pending' if selected else 'not-selected','attempts':0,'error':None,'remote':{}}

def prepare(repo,selection,state_root=None,godot=None,change='current',new_release=False,butler='butler'):
    lfs_preflight(Path(repo).resolve());settings=configuration(repo);base=root_state(state_root);checkout=base/digest(settings['repository'])[:20];path=checkout/settings['version']
    if path.is_relative_to(Path(settings['repository'])):fail('StateRoot must be outside the source repository.')
    prior=read_json(path/'state.json') if (path/'state.json').exists() else None
    frozen={'snapshot':prior['plan']['baselines'],'frozen':prior['plan']['previousCommit'],'tag_commit':prior['plan'].get('sourceTag',{}).get('commit')} if prior and not new_release else {}
    releasing={} if frozen else {'releasing_version':version(settings['version'],change)}
    planned=plan(repo,selection,base,**frozen,**releasing)
    if not planned['configurationReady']:fail('Release plan is blocked: '+' '.join(planned['blockers']))
    source_result=reserve_source(settings,planned,checkout,change,new_release) if not prior or new_release else None
    if source_result and source_result['status']=='source-update-required':return source_result
    planned=plan(repo,selection,base,**frozen)
    if not planned['ready']:fail('Release plan is blocked: '+' '.join(planned['blockers']))
    settings=configuration(repo);path=checkout/planned['version']
    with locked(path):
        state_file=path/'state.json'
        if state_file.exists():
            state=read_json(state_file)
            if state['plan']['planId']!=planned['planId']:fail('This version already has a different release plan; resume its snapshot.')
            completed=complete_derived_metadata(state,planned)
            assert_artifacts(path,state)
            if completed:write_json(state_file,state)
            if state['status'] not in ['preparing','preparation-failed']:
                if state['status']=='prepared':
                    try:distribution_checks(settings,state,path,butler)
                    except ReleaseError:state['status']='preparation-failed';write_json(state_file,state)
                return {'status':state['status'],'statePath':str(path),'planId':planned['planId']}
        else:
            state={'schemaVersion':1,'plan':planned,'status':'preparing','verification':'pending','artifacts':[],'exports':{},'checks':{},'destinations':{d['id']:new_record(d['selected']) for d in planned['destinations']},'approval':None}
            write_json(state_file,state);(path/'notes.md').write_text(planned['notesDraft'],encoding='utf-8')
        for dest in planned['destinations']:
            if dest['selected'] and dest['type']=='google-play':
                locale=path/('notes.'+dest['id']+'.txt')
                if not locale.exists():locale.write_text('\n'.join(c['subject'] for c in dest['changes']) or 'No commits since confirmed previous release.')
        if state['verification']!='succeeded':
            code,_=hook_run(settings,settings['config']['verification']['script'],settings['config']['verification']['arguments'],settings['repository'])
            if code:
                state.update(verification='failed',status='preparation-failed');write_json(state_file,state);fail('Local verification failed; publication is unavailable.')
            state['verification']='succeeded';write_json(state_file,state)
        executable=engine(godot) if planned['requiredExports'] else None
        for index,preset in enumerate(planned['requiredExports'],1):
            if state['exports'].get(preset['name'],{}).get('status')=='succeeded':continue
            directory=path/'builds'/str(index)
            if directory.exists():directory=path/'builds'/(str(index)+'-'+uuid.uuid4().hex)
            directory.mkdir(parents=True);output=directory/preset['filename'];record={'status':'in-progress','error':None};state['exports'][preset['name']]=record;write_json(state_file,state)
            try:
                environment={}
                if preset.get('useGradle'):environment['GRADLE_OPTS']=(os.environ.get('GRADLE_OPTS','')+' -Dorg.gradle.daemon=false').strip()
                code,_=run(executable,['--headless','--path',settings['projectPath'],'--export-release',preset['name'],output],settings['repository'],environment)
                if code or not output.is_file():fail('Export failed or expected output is missing.')
                exported=artifact(path,directory,preset['name'],planned['head']);state['artifacts']=[a for a in state['artifacts'] if a['preset']!=preset['name']]+[exported];record['status']='succeeded'
            except ReleaseError as error:
                record.update(status='failed',error='Local export failed; inspect engine and preset.')
                if isinstance(error,Cancellation):
                    state['status']='preparation-failed';write_json(state_file,state);raise
            write_json(state_file,state)
        fresh=plan(repo,selection,base,snapshot=planned['baselines'],frozen=planned['previousCommit'],tag_commit=planned.get('sourceTag',{}).get('commit'))
        if fresh!=planned:state['status']='preparation-failed';write_json(state_file,state);fail('Source or configuration changed during preparation.')
        state['status']='preparation-failed' if any(r['status']!='succeeded' for r in state['exports'].values()) else 'prepared'
        if state['status']=='prepared':
            try:distribution_checks(settings,state,path,butler)
            except ReleaseError:state['status']='preparation-failed'
        assert_artifacts(path,state);write_json(state_file,state)
        return {'status':state['status'],'statePath':str(path),'planId':planned['planId']}

def notes_hash(path,planned):
    notes=text_exact(Path(path)/'notes.md')
    if not notes.strip():fail('Release notes are empty.')
    credential_free(notes);canonical=digest((Path(path)/'notes.md').read_bytes())
    play=sorted((d for d in planned['destinations'] if d['selected'] and d['type']=='google-play'),key=lambda d:d['id'])
    if not play:return canonical
    manifest=[{'path':'notes.md','sha256':canonical}]
    for dest in play:
        relative='notes.'+dest['id']+'.txt';file=Path(path)/relative;text=text_exact(file);credential_free(text)
        if not text.strip() or len(text.encode('utf-16-le'))//2>500:fail('Google Play notes must contain 1 to 500 characters.')
        manifest.append({'path':relative,'sha256':digest(file.read_bytes())})
    return digest(compact(manifest))

def submitted_notes(path,state):
    for record in state['destinations'].values():
        for relative,expected in record['remote'].get('notesHashes',{}).items():
            if digest(safe_path(path,relative,leaf=True).read_bytes())!=expected:fail('A previously submitted locale cannot change through extension.')
    if state.get('canonicalNotesSha256') and digest((path/'notes.md').read_bytes())!=state['canonicalNotesSha256']:fail('Canonical notes cannot change after publication started.')

def receipt_entries(state,path):
    return [(key,row) for key,row in live_receipts(ledger_read(state['plan'],path.parent.parent)) if row.get('version')==state['plan']['version']]

def related_states(state,path):
    result=[];seen={str(path.resolve())}
    for _,row in receipt_entries(state,path):
        other=Path(row.get('statePath','')).resolve()
        if str(other) in seen:continue
        seen.add(str(other))
        if not (other/'state.json').is_file():fail('Release state recording a live channel cannot be read; restore it before refreshing availability.')
        value=read_json(other/'state.json')
        if value['plan']['version']==state['plan']['version']:result.append(value)
    return result

def shipped(state,path):
    if any(d['selected'] and d['type']!='notes' and state['destinations'][d['id']]['remote'].get('live') is True for d in state['plan']['destinations']):return True
    if any(row.get('sourceCommit')==state['plan']['head'] for _,row in receipt_entries(state,path)):return True
    for other in related_states(state,path):
        if other['plan']['head']==state['plan']['head'] and any(d['selected'] and d['type']!='notes' and other['destinations'][d['id']]['remote'].get('live') is True for d in other['plan']['destinations']):return True
    return False

def overall(state,path=None):
    statuses=[state['destinations'][key]['status'] for key in state['plan']['selectedDestinations'] if state['destinations'][key]['status']!='abandoned']
    if not statuses:return 'abandoned'
    tag=state.get('sourceTag',{'status':'pending'}) if 'sourceTag' in state['plan'] else None
    if tag:
        if tag['status'] not in ['pending','awaiting-release']:statuses.append(tag['status'])
        elif 'held' not in statuses or (path and shipped(state,path)):statuses.append('awaiting-release')
    if any(s in statuses for s in ['uncertain','in-progress']):return 'needs-reconciliation'
    completed=any(s in COMPLETE for s in statuses)
    failed=any(r['status']=='failed' or r.get('preflightStatus')=='failed' for k,r in state['destinations'].items() if k in state['plan']['selectedDestinations'])
    if tag and (tag['status']=='failed' or tag.get('preflightStatus')=='failed'):failed=True
    if failed:return 'partial-failure' if completed else 'publication-failed'
    if 'pending' in statuses:return 'prepared'
    if all(s in COMPLETE+['awaiting-release','held'] for s in statuses):
        for status,result in [('awaiting-store-action','needs-store-action'),('submitted','submitted'),('awaiting-release','awaiting-release'),('held','on-hold')]:
            if status in statuses:return result
        return 'published'
    return 'partial-failure' if completed else 'publication-failed'

def result_state(state,path):
    result={'status':state['status'],'statePath':str(path),'version':state['plan']['version'],'destinations':state['destinations']}
    if state.get('sourceTag'):result['sourceTag']=state['sourceTag']
    return result

def hold_reason(reason):
    if not isinstance(reason,str) or not reason.strip() or len(reason)>1000 or any(unicodedata.category(c) in ['Cc','Zl','Zp'] for c in reason):fail('A single-line public hold reason of 1 to 1000 characters is required.')
    credential_free(reason)

def hold(path,selection,reason=None,release=False,play_reviewed=False):
    path,state=state_path(path)
    with locked(path):
        state=read_json(path/'state.json')
        if not selection:fail('Explicit destination IDs are required for hold/unhold.')
        if state['verification']!='succeeded' or state['status'] in ['preparing','preparation-failed']:fail('Holds require a successfully prepared release.')
        if release and reason is not None:fail('--hold-reason cannot be supplied to unhold.')
        if not release:hold_reason(reason)
        selected={d['id']:d for d in state['plan']['destinations'] if d['selected']}
        for key in selection:
            if key not in selected:fail('Hold destination must belong to selected prepared plan.')
            record=state['destinations'][key];review_existing=release and play_reviewed and selected[key]['type']=='google-play' and record['status'] in ['failed','uncertain','in-progress'] and record.get('hold',{}).get('releasedAt')
            if not review_existing and (set(record['remote'])-{'sourceCommit','notesHashes'} or record['status'] not in ['pending','held','failed','awaiting-release']):fail('Hold/unhold requires no remote progress; reconcile started or uncertain store operations.')
            if release and record['status']!='held' and not record.get('hold',{}).get('releasedAt'):fail('Unhold requires an existing destination hold.')
            if release and selected[key]['type']=='google-play' and not play_reviewed:fail('Google Play unhold requires a fresh track review; acknowledge --play-track-reviewed.')
        if play_reviewed and not any(selected[k]['type']=='google-play' for k in selection):fail('Play track review requires a selected Google Play destination.')
        for key in selection:
            record=state['destinations'][key]
            if release:
                if record['status']=='held':record['status']='pending';record['hold']['releasedAt']=now()
                if play_reviewed and selected[key]['type']=='google-play':record['hold']['playTrackReviewedAt']=now()
            elif record['status']!='held' or record.get('hold',{}).get('reason')!=reason:record['status']='held';record['hold']={'reason':reason,'heldAt':now()}
        state['status']=overall(state,path);write_json(path/'state.json',state);return result_state(state,path)

def own_entry(entry,path,destination):
    return entry.get('destination')==destination['id'] and Path(entry.get('statePath','')).resolve()==path.resolve()

def sent_add(path,state,destination,source):
    sent=sent_read(state['plan'],path.parent.parent);key=store_key(destination);entries=sent.setdefault(key,[])
    if any(own_entry(e,path,destination) for e in entries):return False
    entries.append({'sourceCommit':source,'version':state['plan']['version'],'planId':state['plan']['planId'],'statePath':str(path),'destination':destination['id'],'sentAt':now()})
    write_json(ledger_directory(state['plan'],path.parent.parent)/'sent.json',sent);return True

def sent_update(path,state,destination,remove=False):
    sent=sent_read(state['plan'],path.parent.parent);key=store_key(destination);entries=sent.get(key,[])
    if remove:sent[key]=[e for e in entries if not own_entry(e,path,destination)]
    else:
        for entry in entries:
            if own_entry(entry,path,destination):entry.setdefault('submittedAt',now())
    if not sent.get(key):sent.pop(key,None)
    write_json(ledger_directory(state['plan'],path.parent.parent)/'sent.json',sent)

def channel_conflict(path,state,destination,source):
    key=store_key(destination);ledger=ledger_read(state['plan'],path.parent.parent);sent=sent_read(state['plan'],path.parent.parent)
    entries=([ledger[key]] if key in ledger else [])+[e for e in sent.get(key,[]) if not e.get('abandoned')]
    for entry in entries:
        prior=entry.get('sourceCommit')
        if prior!=source and not (re.fullmatch(HASH_RE,str(prior)) and ancestor(state['plan']['repository'],prior,source)):
            return 'A newer or divergent release is live on or has been sent to '+key+'; this build was not sent. Explicit reconciliation or authorized abandonment from the sending state is required.'
    return None

def save_live(path,state,only=()):
    planned=state['plan'];directory=ledger_directory(planned,path.parent.parent);ledger=ledger_read(planned,path.parent.parent);refused=[]
    for dest in planned['destinations']:
        if not dest['selected'] or dest['type']=='notes' or (only and dest['id'] not in only):continue
        record=state['destinations'][dest['id']]
        if record['remote'].get('live') is not True:continue
        key=store_key(dest);source=record['remote'].get('sourceCommit') or planned['head'];row=ledger.get(key)
        if row and row['sourceCommit']!=source and not ancestor(planned['repository'],row['sourceCommit'],source):
            if not any(r.get('sourceCommit')==source and r.get('version')==planned['version'] for _,r in live_receipts({key:row})):refused.append(dest['id'])
            continue
        if row and row['sourceCommit']==source and row['version']==planned['version']:continue
        receipt={'sourceCommit':source,'version':planned['version'],'statePath':str(path),'destination':dest['id'],'observedAt':now()}
        earlier=row.get('recorded',[{k:v for k,v in row.items() if k!='recorded'}]) if row else []
        ledger[key]={**receipt,'recorded':earlier+[receipt]}
    write_json(directory/'live.json',ledger)
    if refused:fail('An older live release cannot replace newer channel baselines without reconciliation: '+', '.join(refused))

def gh_request(gh,path,cwd,body=None):
    args=['api','--hostname','github.com']
    if body is not None:
        body_path=Path(cwd)/('github-request-'+uuid.uuid4().hex+'.json');write_json(body_path,body)
        try:return run(gh,[*args,'--method','PUT',path,'--input',body_path],cwd)
        finally:body_path.unlink(missing_ok=True)
    return run(gh,[*args,path],cwd)

def content_entry(output):
    entry=parse_json(output)
    if not isinstance(entry,dict) or entry.get('encoding')!='base64' or not isinstance(entry.get('content'),str):fail('Existing public content cannot be verified.')
    try:content=base64.b64decode(re.sub(r'\s','',entry['content']),validate=True).decode('utf-8')
    except (ValueError,UnicodeDecodeError):fail('Existing public content cannot be decoded.')
    return entry,content

def notes_preflight(planned,notes,path,gh):
    if '[Release availability](../availability/'+planned['version']+'.json)' not in notes:fail('Approved notes require the predictable availability link.')
    code,output=gh_request(gh,'repos/'+planned['notesRepository'],path)
    if code:fail('Public notes repository is unavailable.')
    metadata=parse_json(output)
    if metadata.get('private') is not False or metadata.get('permissions',{}).get('push') is not True:fail('Public notes require a public repository and verified write permission.')
    code,output=gh_request(gh,'repos/'+planned['notesRepository']+'/contents/releases/'+planned['version']+'.md',path)
    if code==0:
        _,previous=content_entry(output)
        if previous!=notes:fail('Existing canonical public notes conflict with approved content.')
    elif not re.search(r'HTTP 404|Not Found',output,re.I):fail('Cannot verify existing public notes; refusing all store writes.')

def publish_notes(state,path,gh):
    planned=state['plan'];notes=text_exact(path/'notes.md');notes_preflight(planned,notes,path,gh)
    target='repos/'+planned['notesRepository']+'/contents/releases/'+planned['version']+'.md'
    code,output=gh_request(gh,target,path)
    if not code:
        if content_entry(output)[1]!=notes:fail('Existing notes differ; refusing to overwrite published content.')
        return
    if not re.search(r'HTTP 404|Not Found',output,re.I):fail('Cannot verify existing public notes.')
    code,_=gh_request(gh,target,path,{'message':'Release '+planned['version'],'content':base64.b64encode(notes.encode()).decode()})
    if code:fail('GitHub note publication failed.')

def availability(state,path,gh):
    related=related_states(state,path);planned=state['plan']
    for other in related:
        if other['plan']['head']!=planned['head'] and any(h['plan']['head']==planned['head'] for h in other.get('history',[])):fail('This release was extended in another checkout; refresh availability from its newest state.')
    related=[s for s in related if s['plan']['head']==planned['head']];destinations={}
    for dest in planned['destinations']:
        if dest['type']=='notes':continue
        record=state['destinations'][dest['id']];selected=dest['selected']
        if not record['remote'].get('live'):
            candidates=[other['destinations'][dest['id']] for other in related if any(d['id']==dest['id'] and d['selected'] for d in other['plan']['destinations'])]
            candidates.sort(key=lambda r:not r['remote'].get('live'))
            if candidates and (candidates[0]['remote'].get('live') or not selected):record=candidates[0];selected=True
        public={'type':dest['type'],'selected':selected,'status':record['status'],'live':record['remote'].get('live') is True}
        if record['status']=='held':hold_reason(record['hold']['reason']);public['holdReason']=record['hold']['reason']
        if record['remote'].get('buildId'):public['buildId']=record['remote']['buildId']
        if 'versionCode' in dest:public['versionCode']=dest['versionCode']
        destinations[dest['id']]=public
    content=json.dumps({'schemaVersion':1,'generator':'ba-release','version':planned['version'],'sourceCommit':planned['head'],'destinations':destinations},ensure_ascii=False,indent=2)+'\n'
    target='repos/'+planned['notesRepository']+'/contents/availability/'+planned['version']+'.json';code,output=gh_request(gh,target,path);sha=None
    if not code:
        entry,previous=content_entry(output)
        if not entry.get('sha'):fail('Cannot verify public availability content.')
        if previous==content:return
        old=parse_json(previous)
        if not isinstance(old,dict) or old.get('generator')!='ba-release' or old.get('version')!=planned['version']:fail('Conflicting availability file is not an owned release record.')
        sha=entry['sha']
    elif not re.search(r'HTTP 404|Not Found',output,re.I):fail('Cannot verify existing availability record.')
    body={'message':'Release '+planned['version']+' availability','content':base64.b64encode(content.encode()).decode()}
    if sha:body['sha']=sha
    code,_=gh_request(gh,target,path,body)
    if code:fail('Public availability update failed.')

def tag_push_url(planned):
    repo=planned['repository'];tag=planned['sourceTag']
    if source_repository(git(repo,['remote','get-url','origin']))!=tag['repository']:fail('Origin no longer names approved source repository.')
    code,configured=git(repo,['config','--get-all','remote.origin.pushurl'],False)
    if not code:
        for url in configured.splitlines():
            if source_repository(url)!=tag['repository']:fail('Origin push URL does not name approved repository.')
    urls=git(repo,['remote','get-url','--push','--all','origin']).splitlines()
    if len(urls)!=1:fail('Origin must push to exactly one URL for release tag.')
    return urls[0]

def tag_remote(planned,url):
    tag=planned['sourceTag'];ref='refs/tags/'+tag['name'];output=git(planned['repository'],['ls-remote','--quiet','--tags',url,ref,ref+'^{}'])
    records={line.split('\t')[1]:line.split('\t')[0] for line in output.splitlines() if '\t' in line}
    return records.get(ref+'^{}',records.get(ref))

def tag_progress(planned,remote):
    tag=planned['sourceTag'];repo=planned['repository'];ref='refs/tags/'+tag['name'];local=None
    if git(repo,['show-ref','--verify','--quiet',ref],False)[0]==0:local=git(repo,['rev-parse','--verify',ref+'^{commit}'])
    if any(value and value!=tag['commit'] for value in [remote,local]):fail('Tag '+tag['name']+' already names another commit; a tag is never moved. Reconcile it by hand.')
    return 'origin' if remote else ('local' if local else None)

def tag_preflight(planned,record):
    remote=tag_remote(planned,tag_push_url(planned))
    if record['status']=='succeeded' and remote!=planned['sourceTag']['commit']:record['status']='pending'
    if not tag_progress(planned,remote) and git(planned['repository'],['var','GIT_COMMITTER_IDENT'],False)[0]:fail('Git has no annotated tagger identity.')

def publish_tag(planned):
    tag=planned['sourceTag'];repo=planned['repository'];url=tag_push_url(planned);progress=tag_progress(planned,tag_remote(planned,url));ref='refs/tags/'+tag['name']
    if progress=='origin':return
    if not progress:git(repo,['tag','--annotate','--message',tag['message'],tag['name'],tag['commit']])
    git(repo,['push','--no-follow-tags','origin',ref+':'+ref])
    if tag_remote(planned,url)!=tag['commit']:fail('Origin does not show tag on approved source after push.')

def vdf(value):
    return '"'+str(value).replace('\\','\\\\').replace('"','\\"')+'"'

def publish_steam(planned,destination,artifacts,path,record,save,steamcmd='steamcmd'):
    remote=record['remote']
    if remote.get('phase')=='build-uploaded-with-error' and remote.get('buildId'):
        remote.update(phase='build-uploaded',ambiguous=False);save();return 'awaiting-store-action'
    username=os.environ.get('BA_STEAM_USERNAME','')
    if not re.fullmatch(r'[A-Za-z0-9_-]+',username):fail('Set BA_STEAM_USERNAME for the existing authenticated SteamCMD account.')
    executable=tool(steamcmd)
    if not executable:fail('SteamCMD executable is unavailable before upload.')
    directory=path/'steam'/destination['id']/uuid.uuid4().hex;output=directory/'output';output.mkdir(parents=True);depot_lines=[]
    for depot in destination['depots']:
        matching=[a for a in artifacts if a['preset']==depot['preset']]
        if len(matching)!=1:fail('Steam depot artifact was not uniquely prepared.')
        content_root=safe_path(path,matching[0]['directory'],must=True);depot_path=directory/('depot_'+str(depot['id'])+'.vdf')
        content='"DepotBuildConfig"\n{\n  "DepotID" '+vdf(depot['id'])+'\n  "ContentRoot" '+vdf(content_root)+'\n  "FileMapping" { "LocalPath" "*" "DepotPath" "." "Recursive" "1" }\n'
        content+=''.join('  "FileExclusion" '+vdf(p)+'\n' for p in depot['exclude'])+'}\n';depot_path.write_text(content);depot_lines.append('    '+vdf(depot['id'])+' '+vdf(depot_path))
    app_path=directory/('app_'+str(destination['appId'])+'.vdf')
    app_path.write_text('"AppBuild"\n{\n  "AppID" '+vdf(destination['appId'])+'\n  "Desc" '+vdf('Version '+planned['version'])+'\n  "BuildOutput" '+vdf(output)+'\n  "SetLive" '+vdf('' if destination['branch']=='default' else destination['branch'])+'\n  "Preview" "0"\n  "Depots"\n  {\n'+'\n'.join(depot_lines)+'\n  }\n}\n')
    remote.update(phase='uploading',ambiguous=False);save();code,proof=run(executable,['+login',username,'+run_app_build',app_path,'+quit'],path)
    log=output/('app_build_'+str(destination['appId'])+'.log')
    if log.is_file():proof+='\n'+log.read_text(errors='replace')
    match=re.search(r'Successfully finished AppID\s+'+str(destination['appId'])+r'\s+build\s+\(BuildID\s+(\d+)\)',proof)
    if not match:
        if not code:remote['ambiguous']=True
        fail('SteamCMD did not provide a verifiable build-completion record.')
    remote.update(buildId=match[1],phase='build-uploaded',appId=destination['appId'],branch=destination['branch'],portal='https://partner.steamgames.com/apps/builds/'+str(destination['appId']),requiredActions=['Verify uploaded build is live on approved branch.','Publish approved Steam announcement and verify URL.'])
    if code:remote.update(phase='build-uploaded-with-error',ambiguous=True);save();fail('SteamCMD reported completion followed by an error; reconcile saved build ID.')
    save();return 'awaiting-store-action'

def api_request(request,token=None):
    uri=request['uri']
    if not re.match(r'^https://(?:androidpublisher|iamcredentials)\.googleapis\.com/',uri):fail('API host must be the fixed Google service host.')
    token=token or os.environ.get('BA_GOOGLE_PLAY_ACCESS_TOKEN')
    if not token:fail('BA_GOOGLE_PLAY_ACCESS_TOKEN is required for selected Play publication.')
    headers={'Authorization':'Bearer '+token};data=None
    if 'file' in request:headers['Content-Type']='application/octet-stream';data=Path(request['file']).read_bytes()
    elif 'body' in request:headers['Content-Type']='application/json';data=compact(request['body']).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(uri,data=data,headers=headers,method=request['method']),timeout=600) as response:
            raw=response.read().decode();return parse_json(raw) if raw.strip() else {}
    except urllib.error.HTTPError as exc:raise ApiError(exc.code) from None
    except (urllib.error.URLError,TimeoutError,OSError):raise ApiError() from None

def track_matches(track,release,language,notes):
    releases=track.get('releases',[])
    if len(releases)!=1:return False
    observed=releases[0]
    if any(k not in observed for k in ['name','status','versionCodes','releaseNotes']):return False
    if observed['name']!=release['name'] or observed['status']!=release['status'] or sorted(set(map(str,observed['versionCodes'])))!=sorted(set(release['versionCodes'])):return False
    if release['status']=='inProgress' and observed.get('userFraction')!=release['userFraction']:return False
    locale=[n for n in observed['releaseNotes'] if n.get('language')==language]
    return len(locale)==1 and locale[0].get('text')==notes

def play_changelogs(path,state):
    notes_hash(path,state['plan']);paths=[]
    for dest in state['plan']['destinations']:
        if dest['selected'] and dest['type']=='google-play':
            file=safe_path(path,'fastlane/metadata/android/'+dest['language']+'/changelogs/'+str(dest['versionCode'])+'.txt');file.parent.mkdir(parents=True,exist_ok=True);file.write_bytes((path/('notes.'+dest['id']+'.txt')).read_bytes());paths.append(str(file))
    return paths

def publish_play(planned,destination,artifacts,path,record,save,transport=None,replace_edit=False):
    transport=transport or api_request;matches=[a for a in artifacts if a['preset']==destination['preset']]
    bundles=[f for a in matches for f in a['files'] if f['path'].lower().endswith('.aab')]
    if len(matches)!=1 or len(bundles)!=1:fail('Google Play needs exactly one prepared AAB.')
    bundle_file=bundles[0];file=safe_path(path,bundle_file['path'],leaf=True);notes=text_exact(path/('notes.'+destination['id']+'.txt'));remote=record['remote']
    if not notes.strip() or len(notes.encode('utf-16-le'))//2>500:fail('Google Play notes must contain 1 to 500 characters.')
    base='https://androidpublisher.googleapis.com/androidpublisher/v3/applications/'+urllib.parse.quote(destination['packageName'],safe='')
    outcome='awaiting-store-action' if destination['releaseStatus']=='draft' else 'submitted'
    def request(method,uri,**extras):return transport({'method':method,'uri':uri,**extras})
    if remote.get('phase')=='existing-track-matched' and remote.get('bundleSha256','').lower()==bundle_file['sha256'] and str(remote.get('versionCode'))==str(destination['versionCode']):
        remote.setdefault('cleanupStatus','pending');save();return outcome
    created=False
    def create_edit(phase):
        edit=request('POST',base+'/edits',body={})
        if not isinstance(edit.get('id'),str) or not re.fullmatch(r'[A-Za-z0-9_-]+',edit['id']):fail('Google Play returned no valid edit ID.')
        remote.update(editId=edit['id'],phase=phase);save()
    if not remote.get('editId'):create_edit('edit-created');created=True
    edit_base=base+'/edits/'+remote['editId']
    try:request('GET',edit_base)
    except ApiError as exc:
        if not replace_edit or exc.status!=404:raise
        prior={'id':remote['editId'],'phase':remote.get('phase'),'reason':'not-found'};create_edit('replacement-edit-created');created=True;remote.setdefault('previousEdits',[]).append(prior);save();edit_base=base+'/edits/'+remote['editId'];request('GET',edit_base)
    existing=request('GET',edit_base+'/bundles');same=[b for b in existing.get('bundles',[]) if str(b.get('versionCode'))==str(destination['versionCode'])]
    if same:
        if len(same)!=1 or same[0].get('sha256','').lower()!=bundle_file['sha256']:fail('Android version code already assigned to different bundle; never change during retry.')
        bundle=same[0]
    else:
        uri='https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/'+urllib.parse.quote(destination['packageName'],safe='')+'/edits/'+remote['editId']+'/bundles?uploadType=media'
        bundle=request('POST',uri,file=str(file))
        if str(bundle.get('versionCode'))!=str(destination['versionCode']) or bundle.get('sha256','').lower()!=bundle_file['sha256']:fail('Uploaded bundle code or hash differs from approved snapshot.')
    remote.update(versionCode=bundle['versionCode'],bundleSha256=bundle['sha256'].lower(),phase='bundle-uploaded');save()
    track_url=edit_base+'/tracks/'+urllib.parse.quote(destination['track'],safe='');track=request('GET',track_url)
    release={'name':planned['version'],'versionCodes':sorted(set(destination['retainVersionCodes']+[str(destination['versionCode'])])),'releaseNotes':[{'language':destination['language'],'text':notes}],'status':destination['releaseStatus']}
    if destination['releaseStatus']=='inProgress':release['userFraction']=destination['userFraction']
    if created and track_matches(track,release,destination['language'],notes):
        remote.update(phase='existing-track-matched',track=destination['track'],releaseStatus=destination['releaseStatus'],portal='https://play.google.com/console');save()
        try:request('DELETE',edit_base);remote['cleanupStatus']='succeeded'
        except ReleaseError:remote.update(cleanupStatus='failed',cleanupError='Inspection edit cleanup failed; approved deployed release remains matched and will not be resubmitted.')
        save();return outcome
    request('PUT',track_url,body={'track':destination['track'],'releases':[release]});remote['phase']='track-updated';save()
    request('POST',edit_base+':validate');remote['phase']='committing';save()
    request('POST',edit_base+':commit?changesInReviewBehavior=ERROR_IF_IN_REVIEW');remote.update(phase='edit-committed',track=destination['track'],releaseStatus=destination['releaseStatus'],portal='https://play.google.com/console');save();return outcome

def complete_derived_metadata(state,fresh):
    # Release.psm1 Update-ReleaseDerivedPlanMetadata permits exactly this one
    # historical omission. Compare every other field and preserve array order.
    if state['plan']==fresh:return False
    # Round-trip JSON to separate any in-memory aliases between exports and
    # requiredExports, just as the original sorted-JSON comparison does.
    comparison=parse_json(compact(fresh));completed=False
    for collection in ['exports','requiredExports']:
        for preset in comparison[collection]:
            saved=[p for p in state['plan'][collection] if p['name']==preset['name']]
            if len(saved)==1 and preset['platform']=='Android' and 'useGradle' in preset and 'useGradle' not in saved[0]:
                preset.pop('useGradle');completed=True
    if not completed or comparison!=state['plan']:fail('Saved release plan differs from the current inspected plan.')
    state['plan']=fresh
    return True

def publish(path,approved_plan=None,approved_notes=None,butler='butler',gh='gh',steamcmd='steamcmd',retry_uncertain=False,replace_edit=False,play_transport=None):
    path,state=state_path(path)
    with locked(path):
        state=read_json(path/'state.json');planned=state['plan']
        if state.get('schemaVersion')!=1 or state['verification']!='succeeded' or state['status'] in ['preparing','preparation-failed']:fail('Release has not been prepared successfully.')
        fresh=plan(planned['repository'],planned['selectedDestinations'],path.parent.parent,snapshot=planned['baselines'],frozen=planned['previousCommit'],tag_commit=planned.get('sourceTag',{}).get('commit'))
        if not fresh['ready'] or fresh['planId']!=planned['planId']:fail('Source or release configuration changed after preparation.')
        complete_derived_metadata(state,fresh);planned=state['plan']
        assert_artifacts(path,state);notes=text_exact(path/'notes.md');canonical_hash=digest((path/'notes.md').read_bytes());current_notes_hash=notes_hash(path,planned);submitted_notes(path,state);artifacts_hash=digest(pipeline_json(state['artifacts']))
        for dest in planned['destinations']:
            record=state['destinations'][dest['id']]
            if record['status']=='held':hold_reason(record['hold']['reason'])
            if dest['selected'] and dest['type']=='google-play' and record['status'] not in COMPLETE+['held'] and record.get('hold',{}).get('releasedAt') and not record['hold'].get('playTrackReviewedAt'):fail('Google Play unhold requires fresh track review.')
        def save():write_json(path/'state.json',state)
        if approved_plan or approved_notes:
            if approved_plan!=planned['planId'] or approved_notes!=current_notes_hash:fail('Exact plan and notes approval hashes are required.')
            if state['approval'] and state['approval']['notesSha256']!=current_notes_hash and any(started(r) for r in state['destinations'].values()):fail('Approval cannot change notes after publication started.')
            state['approval']={'planId':approved_plan,'notesSha256':approved_notes,'artifactsSha256':artifacts_hash};save()
        if state.get('approval')!={'planId':planned['planId'],'notesSha256':current_notes_hash,'artifactsSha256':artifacts_hash}:fail('Publication requires approval of exact plan, notes and artifacts.')
        for dest in planned['destinations']:
            if not dest['selected'] or dest['type']!='notes':continue
            record=state['destinations'][dest['id']]
            try:notes_preflight(planned,notes,path,gh);record['preflightStatus']='succeeded';record['error']=None
            except ReleaseError:
                if record['status']!='held':record['status']='failed'
                record.update(preflightStatus='failed',error='Public notes preflight failed; check public visibility, write access, availability link and conflicting content before any store writes.')
                state['status']=overall(state,path);save();return result_state(state,path)
        if planned.get('sourceTag'):
            record=state.setdefault('sourceTag',{'status':'pending','error':None})
            try:tag_preflight(planned,record);record.update(preflightStatus='succeeded',error=None)
            except ReleaseError:
                if record['status']!='succeeded':record['status']='failed'
                record.update(preflightStatus='failed',error='Source tag preflight failed; inspect origin, tagger identity and conflicting tag before any store write.');state['status']=overall(state,path);save();return result_state(state,path)
        directory=ledger_directory(planned,path.parent.parent)
        with locked(directory):
            if not (directory/'sent.json').exists():write_json(directory/'sent.json',seed_sent(planned,path.parent.parent))
            for destination in sorted(planned['destinations'],key=lambda d:d['type']=='notes'):
                if not destination['selected']:continue
                kind=destination['type'];record=state['destinations'][destination['id']];remote=record['remote']
                if record['status'] in ['held','abandoned']:continue
                if kind!='notes' and started(record):sent_add(path,state,destination,remote.get('sourceCommit') or planned['head'])
                if kind=='google-play' and record['status']=='submitted':sent_update(path,state,destination)
                if kind=='notes':
                    if not shipped(state,path):record.update(status='awaiting-release',error=None);save();continue
                    if record['status']=='succeeded':
                        try:availability(state,path,gh);record['error']=None
                        except ReleaseError:record['error']='Public availability refresh failed; inspect access or conflicting content.';state['status']='partial-failure';save();return result_state(state,path)
                if record['status'] in COMPLETE:continue
                if record['status']=='in-progress':record.update(status='uncertain',error='Interrupted external operation; reconcile remote result before retrying.');save()
                if record['status']=='uncertain' and not retry_uncertain:continue
                if kind!='notes':
                    preset=destination['depots'][0]['preset'] if kind=='steam' else destination['preset'];exported=next(a for a in state['artifacts'] if a['preset']==preset)
                    remote.setdefault('sourceCommit',exported.get('sourceCommit') or planned['head']);source=remote['sourceCommit'];conflict=channel_conflict(path,state,destination,source)
                    if conflict:
                        if record['status']!='uncertain':record['status']='failed'
                        record['error']=conflict;save();continue
                record.update(status='in-progress',attempts=record['attempts']+1,error=None);state['canonicalNotesSha256']=canonical_hash
                if kind=='google-play':
                    relative='notes.'+destination['id']+'.txt';remote['notesHashes']={relative:digest((path/relative).read_bytes())}
                save();sent_now=sent_add(path,state,destination,source) if kind!='notes' else False
                try:
                    outcome='succeeded'
                    if kind=='itch':
                        exported=next(a for a in state['artifacts'] if a['preset']==destination['preset']);snapshot=safe_path(path,exported['directory'],must=True);preset=next(p for p in planned['exports'] if p['name']==destination['preset']);input_path=butler_input(snapshot,preset,destination)
                        if preset['platform']=='Android' and state['checks'][destination['id']].get('input')!=input_path.relative_to(path).as_posix():fail('Resume prepare to verify signed APK input.')
                        executable=tool(butler)
                        if not executable:fail('Butler executable unavailable before upload.')
                        args=['push',input_path,destination['target'],'--userversion',planned['version']]
                        for pattern in destination['ignore']:args+=['--ignore',pattern]
                        remote['phase']='pushing';save();code,_=run(executable,args,path)
                        if code:fail('Butler upload failed; inspect remote channel before retrying.')
                        remote.update(phase='upload-complete',live=True,target=destination['target'],sourceCommit=exported['sourceCommit'])
                        if 'displayName' in destination:outcome='awaiting-store-action';remote['displayNameRequired']=destination['displayName']
                    elif kind=='steam':outcome=publish_steam(planned,destination,state['artifacts'],path,record,save,steamcmd)
                    elif kind=='google-play':play_changelogs(path,state);outcome=publish_play(planned,destination,state['artifacts'],path,record,save,play_transport,replace_edit)
                    else:availability(state,path,gh);publish_notes(state,path,gh)
                    record['status']=outcome
                except ReleaseError as error:
                    record['status']='uncertain' if isinstance(error,InterruptedOperation) or remote.get('phase')=='committing' or remote.get('ambiguous') else 'failed'
                    if isinstance(error,Cancellation):
                        record['error']='Publication cancelled during an external operation; reconcile the saved remote progress before retrying.';state['status']=overall(state,path);save();raise
                    record['error']={'itch':'Butler attempt failed; reconcile remote channel before retrying if ambiguous.','steam':'Steam attempt needs inspection; check authenticated access and saved build result.','google-play':'Play attempt needs inspection; check saved edit, bundle hash/code, track and commit state.','notes':'Public note attempt failed; inspect visibility, conflicting content and GitHub access.'}[kind]
                save()
                if sent_now and record['status']=='failed' and not started(record):sent_update(path,state,destination,remove=True)
                if kind=='google-play' and record['status']=='submitted':sent_update(path,state,destination)
                if remote.get('live') is True:save_live(path,state,[destination['id']])
            if planned.get('sourceTag') and state['sourceTag']['status']!='succeeded':
                record=state['sourceTag']
                if not shipped(state,path):record.update(status='awaiting-release',error=None)
                else:
                    try:publish_tag(planned);record.update(status='succeeded',error=None)
                    except ReleaseError:record.update(status='failed',error='Source tag failed; inspect push access and conflicting tags; rerun publication.')
                save()
            state['status']=overall(state,path);save();save_live(path,state);return result_state(state,path)

def observation(receipt):
    value=receipt.get('observedAt')
    if not isinstance(value,str) or not re.search(r'(Z|[+-]\d{2}:\d{2})$',value):fail('observedAt must have timezone and identify actual observation.')
    try:observed=dt.datetime.fromisoformat(value.replace('Z','+00:00'))
    except ValueError:fail('Invalid observedAt timestamp.')
    if observed>dt.datetime.now(dt.timezone.utc)+dt.timedelta(minutes=5):fail('observedAt cannot be in the future.')
    return observed

def confirm(path,receipt_path,abandon=False,authorized=False):
    path,state=state_path(path)
    with locked(path):
        state=read_json(path/'state.json');receipt=read_json(receipt_path);credential_free(compact(receipt));planned=state['plan'];common=['destination','planId','observedAt','live']+(['evidenceUrl'] if abandon else ['notesSha256'])
        allowed=common+['appId','buildId','branch','announcementUrl','packageName','versionCode','track','releaseStatus','userFraction','evidenceUrl','target','displayName'];fields(receipt,allowed,common,'observed store receipt')
        matching=[d for d in planned['destinations'] if d['selected'] and d['type']!='notes' and d['id']==receipt['destination']]
        if len(matching)!=1:fail('Receipt must identify one selected store destination.')
        destination=matching[0];kind=destination['type'];record=state['destinations'][destination['id']];remote=record['remote'];observed=observation(receipt)
        if not state['approval'] or receipt['planId']!=planned['planId'] or state['approval']['planId']!=planned['planId']:fail('Receipt requires the approved plan of the release that sent the build.')
        if type(receipt['live']) is not bool or receipt['live'] is abandon:fail('Store live state must have been explicitly observed.')
        if abandon:
            if not authorized:fail('Abandonment requires explicit user authorization; repeat with --abandon-authorized only after approval.')
            if record['status'] not in ['awaiting-store-action','submitted','uncertain','in-progress','failed','abandoned'] or not started(record) or remote.get('live'):fail('Abandonment requires a started store write that never went live.')
        else:
            if record['status'] not in ['submitted','awaiting-store-action','uncertain','succeeded']:fail('Receipt requires uploaded, submitted or uncertain store operation.')
            assert_artifacts(path,state);submitted_notes(path,state);note_hash=notes_hash(path,planned)
            if receipt['notesSha256']!=note_hash or note_hash!=state['approval']['notesSha256'] or digest(pipeline_json(state['artifacts']))!=state['approval']['artifactsSha256']:fail('Receipt requires unchanged approved notes and artifacts.')
        if kind=='steam':
            extra=['appId','buildId','branch']+([] if abandon else ['announcementUrl']);fields(receipt,common+extra,common+extra,'Steam receipt')
            if type(receipt['appId']) is not int or receipt['appId']!=destination['appId'] or receipt['branch']!=destination['branch'] or receipt['buildId']!=remote.get('buildId'):fail('Receipt differs from approved Steam app, branch or uploaded build.')
            if abandon:
                if receipt['evidenceUrl']!='https://partner.steamgames.com/apps/builds/'+str(destination['appId']):fail('Steam abandonment requires observed Steamworks builds page.')
            elif not isinstance(receipt['buildId'],str) or not re.fullmatch(r'[1-9][0-9]*',receipt['buildId']) or not re.fullmatch(r'https://(?:store\.steampowered\.com/news/app/'+str(destination['appId'])+r'/view/[1-9][0-9]*|steamcommunity\.com/games/'+str(destination['appId'])+r'/announcements/detail/[1-9][0-9]*)/?',str(receipt['announcementUrl'])):fail('Receipt requires recorded Steam build ID and public announcement for this app.')
        elif kind=='google-play':
            extra=['packageName','versionCode','track']+([] if abandon else ['releaseStatus','userFraction','evidenceUrl']);fields(receipt,list(set(common+extra)),list(set(common+extra)),'Play receipt')
            if type(receipt['versionCode']) is not int or any(receipt[k]!=destination[k] for k in ['packageName','versionCode','track']):fail('Receipt differs from approved Play app, bundle or track.')
            if not re.fullmatch(r'https://play\.google\.com/console(?:[/?][^\s]*)?',str(receipt['evidenceUrl'])):fail('Receipt must identify observed Play Console page.')
            if not abandon:
                bundles=[f for a in state['artifacts'] if a['preset']==destination['preset'] for f in a['files'] if f['path'].lower().endswith('.aab')]
                if len(bundles)!=1 or remote.get('bundleSha256','').lower()!=bundles[0]['sha256'] or str(remote.get('versionCode'))!=str(destination['versionCode']) or remote.get('phase') not in ['committing','edit-committed','existing-track-matched','store-verified']:fail('Play completion requires recorded matching bundle and commit/deployed-track evidence.')
                if destination['releaseStatus']=='draft' or any(receipt[k]!=destination[k] for k in ['releaseStatus','userFraction']):fail('Receipt rollout must match approved non-draft publication.')
        else:
            extra=['target']+([] if abandon else ['displayName','evidenceUrl']);fields(receipt,list(set(common+extra)),list(set(common+extra)),'itch receipt')
            owner,game=destination['target'].split(':')[0].split('/')
            if receipt['target']!=destination['target'] or receipt['evidenceUrl']!='https://'+owner+'.itch.io/'+game:fail('Receipt differs from approved itch target or page.')
            if not abandon and (not remote.get('live') or 'displayName' not in destination or receipt['displayName']!=destination['displayName']):fail('Itch confirmation requires live upload and approved display name.')
        directory=ledger_directory(planned,path.parent.parent)
        with locked(directory):
            if abandon:
                sent=sent_read(planned,path.parent.parent);key=store_key(destination);entries=sent.setdefault(key,[]);own=[e for e in entries if own_entry(e,path,destination)]
                for entry in own:
                    if entry.get('sentAt') and observed<dt.datetime.fromisoformat(entry['sentAt'].replace('Z','+00:00')):fail('observedAt precedes upload being abandoned; inspect console again.')
                if not own:
                    entry={'sourceCommit':remote.get('sourceCommit') or planned['head'],'version':planned['version'],'planId':planned['planId'],'statePath':str(path),'destination':destination['id'],'sentAt':None};own=[entry];entries.append(entry)
                if record['status']!='abandoned':remote['abandonment']={'receipt':receipt,'authorizedAt':now()};record.update(status='abandoned',error=None)
                state['status']=overall(state,path);write_json(path/'state.json',state)
                for entry in own:entry['abandoned']=remote['abandonment']
                write_json(directory/'sent.json',sent)
            else:
                if not remote.get('sourceCommit'):
                    preset=destination['depots'][0]['preset'] if kind=='steam' else destination['preset'];exported=next(a for a in state['artifacts'] if a['preset']==preset)
                    if not exported.get('sourceCommit'):fail('Artifact source provenance requires reconciliation.')
                    remote['sourceCommit']=exported['sourceCommit']
                if record['status']!='succeeded':remote.update(completion=receipt,phase='store-verified',live=True);record.update(status='succeeded',error=None)
                state['status']=overall(state,path);write_json(path/'state.json',state);save_live(path,state)
        return result_state(state,path)

def migrate_configuration(state,settings,head):
    planned=state['plan'];repo=planned['repository'];previous=planned['head']
    if head==previous or not ancestor(repo,previous,head):fail('Commit reviewed release.json additions before migration.')
    if any(p!='release.json' for p in git(repo,['diff','--name-only',previous,head,'--']).splitlines()):fail('Configuration migration cannot adopt changes beyond release.json.')
    raw=committed_text(repo,previous,'release.json');old=configuration(repo,raw)['config'];current=settings['config']
    if digest(raw)!=planned['configSha256'] and digest(raw.rstrip('\n'))!=planned['configSha256']:fail('Prepared configuration cannot be read back from source commit.')
    for key in ['schemaVersion','project','previousReleaseRef','verification','androidVersionCodePolicy','sourceTag']:
        if old[key]!=current[key]:fail('Configuration migration only adds stores; existing '+key+' changed.')
    if set(old['exports'])-set(current['exports']):fail('Migration cannot remove planned exports.')
    for check in old['standalone']:
        if check not in current['standalone']:fail('Migration cannot change existing standalone checks.')
    new_by_id={d['id']:d for d in current['destinations']}
    for dest in old['destinations']:
        if new_by_id.get(dest['id'])!=dest or old['destinationBaselines'].get(dest['id'])!=current['destinationBaselines'].get(dest['id']):fail('Migration cannot change existing destinations or baselines.')
    known={d['id'] for d in old['destinations']}
    return {'fromHead':previous,'toHead':head,'fromConfigSha256':planned['configSha256'],'toConfigSha256':settings['configHash'],'addedDestinations':[d['id'] for d in current['destinations'] if d['id'] not in known],'addedExports':[p for p in current['exports'] if p not in old['exports']],'addedStandaloneChecks':[c['preset'] for c in current['standalone'] if c not in old['standalone']]}

def extend(path,selection,godot=None,butler='butler',migrate=False):
    path,state=state_path(path)
    if not selection:fail('Select additional destinations explicitly.')
    selected=sorted(set(state['plan']['selectedDestinations']+list(selection)));added=[s for s in selected if s not in state['plan']['selectedDestinations']]
    if not added:return prepare(state['plan']['repository'],selected,path.parent.parent,godot,butler=butler)
    # Persist migration before reserving an added Android artifact. A retry after
    # its counter commit must compare against the adopted configuration source.
    initial_settings=configuration(state['plan']['repository'])
    if initial_settings['configHash']!=state['plan']['configSha256']:
        with locked(path):
            state=read_json(path/'state.json');old=state['plan'];settings=configuration(old['repository']);repo=settings['repository'];head=git(repo,['rev-parse','HEAD'])
            migration=migrate_configuration(state,settings,head)
            assert_artifacts(path,state);submitted_notes(path,state)
            frozen={'snapshot':old['baselines'],'frozen':old['previousCommit'],'tag_commit':old.get('sourceTag',{}).get('commit')}
            expanded=plan(repo,sorted(set(selected+migration['addedDestinations'])),path.parent.parent,**frozen)
            if not expanded['ready']:fail('Migration adopts every added store; complete all new settings and baselines.')
            original=state.get('history',[{'plan':old}])[0]['plan']['head']
            for key in migration['addedDestinations']:
                value=expanded['baselines'].get(key)
                if value and not ancestor(repo,value,original):fail('Migrated channel baseline must precede original source.')
            adopted=plan(repo,old['selectedDestinations'],path.parent.parent,**frozen)
            if not adopted['ready'] or adopted['head']!=head or adopted['configSha256']!=settings['configHash']:fail('Migration source changed or plan is blocked; nothing saved.')
            if not migrate:fail('Review committed configuration addition, then repeat extend with --migrate-configuration.')
            state.setdefault('history',[]).append({'plan':old,'approval':state['approval'],'configurationMigration':migration})
            state.update(plan=adopted,status='preparing',verification='pending',approval=None)
            for key in migration['addedDestinations']:state['destinations'][key]=new_record(False)
            write_json(path/'state.json',state)
        result=extend(path,selection,godot,butler)
        result['configurationMigration']=migration
        return result
    with locked(path):
        state=read_json(path/'state.json');old=state['plan'];settings=configuration(old['repository']);repo=settings['repository'];head=git(repo,['rev-parse','HEAD'])
        if settings['version']!=old['version']:fail('Extension requires same version as prepared release.')
        assert_artifacts(path,state);submitted_notes(path,state)
        frozen={'snapshot':old['baselines'],'frozen':old['previousCommit'],'tag_commit':old.get('sourceTag',{}).get('commit')}
        fresh=plan(repo,selected,path.parent.parent,**frozen)
        original=state.get('history',[{'plan':old}])[0]['plan']['head']
        for key in added:
            value=fresh['baselines'].get(key)
            if value and not ancestor(repo,value,original):fail('Added channel baseline must precede original release source.')
        if settings['configHash']!=old['configSha256']:fail('Configuration changed during extension; inspect and rerun explicit migration.')
        if head!=old['head']:
            reservation=path/'extension-source'/digest(','.join(selected))[:20]/'active-source.json'
            if not reservation.exists():fail('Source changed since preparation; extension cannot silently select another release.')
            pending=read_json(reservation);changed=git(repo,['diff','--name-only',old['head'],head,'--']).splitlines()
            if pending['originalHead']!=old['head'] or any(p not in [f['path'] for f in pending['files']] for p in changed):fail('Extension source differs beyond reserved Android settings.')
        counters=[p for p in counter_presets(settings,fresh,added) if p not in [a['preset'] for a in state['artifacts']]]
        if counters:
            source_dir=path/'extension-source'/digest(','.join(selected))[:20]
            reservation=reserve_source(settings,fresh,source_dir,counters=counters)
            if reservation and reservation['status']=='source-update-required':return reservation
            settings=configuration(repo);head=git(repo,['rev-parse','HEAD'])
        fresh=plan(repo,selected,path.parent.parent,**frozen)
        if not fresh['ready']:fail('Extension plan is blocked: '+' '.join(fresh['blockers']))
        if fresh['configSha256']!=settings['configHash'] or fresh['head']!=head:fail('Source changed during extension; nothing saved.')
        history={'plan':old,'approval':state['approval']}
        state.setdefault('history',[]).append(history);state.update(plan=fresh,status='preparing',approval=None)
        if head!=old['head']:state['verification']='pending'
        for key in added:state['destinations'][key]=new_record()
        write_json(path/'state.json',state)
    result=prepare(repo,selected,path.parent.parent,godot,butler=butler)
    return result

def setup_facts(repo,project='.'):
    repo=Path(repo).resolve()
    if git(repo,['rev-parse','--show-toplevel'])!=str(repo):fail('Repository must name Git root.')
    directory=safe_path(repo,project,must=True);godot=godot_sections(directory/'project.godot');sections=godot_sections(directory/'export_presets.cfg');presets=[]
    for section,values in sections.items():
        if not re.fullmatch(r'preset\.\d+',section):continue
        record={'name':values.get('name'),'platform':values.get('platform'),'exportPath':values.get('export_path')};options=sections.get(section+'.options',{})
        if values.get('platform')=='Android':record.update(versionCode=options.get('version/code'),packageName=options.get('package/unique_name'),signed=options.get('package/signed'),gradle=options.get('gradle_build/use_gradle_build'),format=options.get('gradle_build/export_format'))
        presets.append(record)
    return {'repository':str(repo),'project':project,'title':godot.get('application',{}).get('config/name'),'version':godot.get('application',{}).get('config/version'),'presets':presets,'origin':git(repo,['remote','get-url','origin'])}

def setup_document(facts,stores,existing_aliases=None):
    if any(s not in STORES for s in stores):fail('Unsupported setup store.')
    aliases=copy.deepcopy(existing_aliases or {});desktop=[];apks=[];aabs=[]
    for preset in facts['presets']:
        if preset['platform'] in ['Windows Desktop','Linux'] and preset['exportPath']:desktop.append(preset)
        elif preset['platform']=='Android' and preset.get('signed'):
            if str(preset['exportPath']).endswith('.apk') and (preset.get('gradle') is False or preset.get('format')==0):apks.append(preset)
            if str(preset['exportPath']).endswith('.aab') and preset.get('gradle') is True and preset.get('format')==1:aabs.append(preset)
    for preset in desktop+apks+aabs:
        if preset['name'] in aliases.values():continue
        base={'Windows Desktop':'windows','Linux':'linux'}.get(preset['platform'],'apk' if preset in apks else 'aab');alias=base;index=2
        while alias in aliases:alias=base+'-'+str(index);index+=1
        aliases[alias]=preset['name']
    distributions={}
    for store in dict.fromkeys(stores):
        if store=='itch':
            channels={}
            for channel,matching in [('windows',[p for p in desktop if p['platform']=='Windows Desktop']),('linux',[p for p in desktop if p['platform']=='Linux']),('android',apks)]:
                if len(matching)==1:channels[channel]=next(a for a,v in aliases.items() if v==matching[0]['name'])
            distributions[store]={'game':None,'previousRelease':None,'ignore':STEAM_IGNORE.copy(),'channels':channels}
        elif store=='steam':distributions[store]={'appId':None,'branch':None,'previousRelease':None,'exclude':[],'depots':{}}
        elif store=='google-play':distributions[store]={'export':next((a for a,v in aliases.items() if len(aabs)==1 and v==aabs[0]['name']),None),'previousRelease':None,'track':None,'releaseStatus':None,'userFraction':None,'language':None,'retainVersionCodes':None}
        else:distributions['notes']=True
    repo=Path(facts['repository'])
    def shared_hook(stem):
        # Prefer the shared Windows spelling when a native sibling exists, so
        # newly configured repositories remain usable by both retained engines.
        if (repo/(stem+'.ps1')).is_file() and (repo/(stem+'.sh')).is_file():return stem+'.ps1'
        return next((stem+suffix for suffix in ['.sh','.py'] if (repo/(stem+suffix)).is_file()),None)
    gate=shared_hook('tools/verify');standalone=shared_hook('tools/standalone')
    verification={'gate':{'script':gate,'arguments':[]}};desktop_aliases=[a for a,v in aliases.items() if v in [p['name'] for p in desktop]]
    if desktop_aliases:verification['standalone']={'exports':desktop_aliases,'script':standalone,'arguments':['{artifact}']}
    return {'schemaVersion':1,'project':facts['project'],'previousRelease':None,'exports':aliases,'verification':verification,'distributions':distributions,'androidVersionCodePolicy':'increment-selected','sourceTag':True}

def setup(repo,selection=(),answers_path=None,expected_hash=None,interactive=False):
    repo=Path(repo).resolve();config_file=repo/'release.json';actual=digest(config_file.read_bytes()) if config_file.is_file() else 'missing';document=read_json(config_file) if actual!='missing' else None;new=document is None
    project=document['project'] if document else '.'
    if document is None and not (repo/'project.godot').is_file():
        candidates=git(repo,['ls-files','--cached','--others','--exclude-standard','--','*project.godot']).splitlines();projects=sorted(set(str(Path(p).parent) for p in candidates if (repo/p).is_file()))
        if len(projects)==1:project=projects[0]
        elif not answers_path:return {'mode':'setup','readOnly':True,'configSha256':actual,'facts':{'projects':projects},'configuration':None,'questions':[{'key':'project','prompt':'Choose actual Godot directory; none has been guessed.','choices':projects}],'stores':{'configured':[],'choices':STORES},'selection':{'required':True,'choices':[],'selected':[]}}
        else:project=read_json(answers_path).get('project','.')
    facts=setup_facts(repo,project)
    if new:document=setup_document(facts,list(dict.fromkeys('itch' if s.startswith('itch-') else s for s in selection)) or ['itch','notes'])
    expanded=runtime(document,True);questions={}
    def question(key,prompt):questions.setdefault(key,{'key':key,'prompt':prompt})
    if new:question('stores','Which stores does this game use? List every store to retain.')
    if 'sourceTag' not in document:question('sourceTag','Should releases get annotated source tags on origin?')
    if document['previousRelease'] is None:question('previousRelease','Confirm source ref of previous published release.')
    if document['verification']['gate']['script'] is None:question('verification.gate.script','Which inspected existing native script verifies this game?')
    for destination in expanded['destinations']:
        if selection and destination['id'] not in selection:continue
        kind=destination['type']
        if kind=='notes':continue
        settings=document['distributions'][kind]
        if expanded['destinationBaselines'][destination['id']] is None:question('distributions.'+kind+'.previousRelease','Confirm last live source ref for '+destination['id']+'.')
        if kind=='itch':
            if settings['game'] is None:question('distributions.itch.game','Confirm existing Butler owner/game.');question('distributions.itch.channels','Confirm explicit Butler channel-to-export mappings.')
            checks=[c for c in expanded['standalone'] if c['preset']==destination['preset'] and c['script']]
            if not checks:question('verification.standalone','Supply inspected standalone functionality checks for each desktop export.')
        else:
            keys=['appId','branch','depots'] if kind=='steam' else ['export','track','releaseStatus','language','retainVersionCodes']+(['userFraction'] if settings.get('releaseStatus')=='inProgress' else [])
            for key in keys:
                if settings.get(key) is None or (key=='depots' and not settings[key]):question('distributions.'+kind+'.'+key,'Confirm '+kind+' '+key+' from existing project/store evidence.')
    choices=[{'id':d['id'],'type':d['type'],'preset':d.get('preset')} for d in expanded['destinations']]
    for selected in selection:
        if selected not in [c['id'] for c in choices]:
            store='itch' if selected.startswith('itch-') else selected
            if store not in STORES:fail('Unknown destination: '+selected)
            question('stores','Requested destination requires an unconfigured store. List every store to keep; omitted stores are removed.')
    report={'mode':'setup','readOnly':True,'configSha256':actual,'facts':facts,'configuration':document,'questions':list(questions.values()),'stores':{'configured':[k for k,v in document['distributions'].items() if k!='notes' or v],'choices':STORES},'selection':{'required':not bool(selection),'selected':list(selection),'choices':choices}}
    answers=None
    if interactive and not answers_path:
        answers={}
        for item in report['questions']:
            text=input(item['prompt']+' (JSON value; blank leaves unknown): ')
            if text.strip():answers[item['key']]=parse_json(text)
        expected_hash=actual
    elif answers_path:answers=read_json(answers_path)
    if answers is None:return report
    if expected_hash!=actual:fail('release.json changed or expected configuration hash missing; rerun setup before applying answers.')
    if not isinstance(answers,dict):fail('Setup answers must be a JSON object.')
    candidate=copy.deepcopy(document)
    if 'project' in answers:facts=setup_facts(repo,answers['project']);candidate['project']=answers['project']
    if 'stores' in answers:
        stores=answers['stores']
        if not isinstance(stores,list) or any(s not in STORES for s in stores):fail('stores must list supported store types.')
        stores=[s for s in candidate['distributions'] if s in stores]+[s for s in dict.fromkeys(stores) if s not in candidate['distributions']]
        proposed=setup_document(facts,stores,candidate['exports']);candidate['exports']=proposed['exports'];candidate['distributions']={s:copy.deepcopy(candidate['distributions'].get(s,proposed['distributions'][s])) for s in stores}
    for key,value in answers.items():
        if key=='stores':continue
        parts=key.split('.')
        if parts[0] not in ['project','previousRelease','exports','verification','distributions','androidVersionCodePolicy','sourceTag']:fail('Unknown setup answer.')
        cursor=candidate
        for index,part in enumerate(parts[:-1]):
            if part not in cursor:cursor[part]={}
            if isinstance(cursor[part],str) and index>0 and parts[index-1] in ['channels','depots']:cursor[part]={'export':cursor[part]}
            if not isinstance(cursor[part],dict):fail('Setup answer cannot traverse scalar.')
            cursor=cursor[part]
        cursor[parts[-1]]=value
    settings=configuration(repo,candidate,incomplete=True)
    itch=candidate['distributions'].get('itch')
    if itch and itch['game'] and (new or document['distributions'].get('itch',{}).get('game')!=itch['game']) and not any(k in answers for k in ['distributions','distributions.itch','distributions.itch.channels']):fail('Explicitly confirm Butler channel mappings before saving a new itch game.')
    for ref in [candidate['previousRelease'],*settings['config']['destinationBaselines'].values()]:
        if ref is not None:commit_ref(repo,ref,'HEAD')
    current=digest(config_file.read_bytes()) if config_file.is_file() else 'missing'
    if current!=expected_hash:fail('release.json changed during setup; refusing to overwrite conflict.')
    write_json(config_file,candidate)
    return {'written':True,'report':setup(repo,selection)}

def doctor(repo,selection,args):
    settings=configuration(repo);planned=plan(repo,selection,args.state_root);checks=[]
    def add(key,passed,message):checks.append({'id':key,'status':passed,'message':message})
    add('plan','passed' if planned['ready'] else 'blocked','Configuration and source ready.' if planned['ready'] else ' '.join(planned['blockers']))
    kinds={d['type'] for d in planned['destinations'] if d['selected']}
    for key,kind,name in [('butler','itch',args.butler_executable),('steamcmd','steam',args.steam_cmd_executable),('gh','notes',args.gh_executable)]:
        add(key,'skipped' if kind not in kinds else ('passed' if tool(name) else 'blocked'),'Destination not selected.' if kind not in kinds else ('Executable found.' if tool(name) else 'Executable missing; supply runtime path.'))
    for key,kind,var in [('steam-auth','steam','BA_STEAM_USERNAME'),('play-auth','google-play','BA_GOOGLE_PLAY_ACCESS_TOKEN')]:
        add(key,'skipped' if kind not in kinds else ('unverified' if os.environ.get(var) else 'blocked'),'Destination not selected.' if kind not in kinds else ('Runtime input exists; account access/expiry unverified.' if os.environ.get(var) else 'Provide '+var+' at runtime; no login attempted.'))
    if 'itch' in kinds:add('itch-auth','unverified','Existing Butler login and selected target access were not contacted.')
    if 'notes' in kinds:add('notes-access','unverified','Public repository visibility/write access require publication preflight; no network request made.')
    if planned.get('sourceTag'):add('source-tag','unverified' if not git(repo,['var','GIT_COMMITTER_IDENT'],False)[0] else 'blocked','Tagger identity inspected; origin tags and push permissions are not contacted.')
    engine_path=None;engine_version=None;directories=None
    if planned['requiredExports']:
        try:engine_path=engine(args.godot_executable)
        except ReleaseError:pass
        add('godot','passed' if engine_path else 'blocked','Godot executable found.' if engine_path else 'Godot executable missing.')
        if engine_path:
            try:code,text=run(engine_path,['--version'],tempfile.gettempdir(),timeout=15)
            except ReleaseError:code=1;text=''
            match=re.match(r'^(\d+\.\d+(?:\.\d+)?)\.(stable|beta\d*|rc\d*|dev\d*)(?:\.|$)',text.strip()) if not code else None
            if match:
                engine_version=match[1]+'.'+match[2];minor='.'.join(match[1].split('.')[:2]);required=re.search(r'(?m)^config/features=PackedStringArray\("(\d+\.\d+)"',(Path(settings['projectPath'])/'project.godot').read_text())
                add('godot-version','blocked' if required and required[1]!=minor else 'passed','Selected engine '+engine_version+'; complete gate determines compatibility.')
            else:add('godot-version','blocked','Godot version unreadable or bounded probe failed.')
            directory=Path(engine_path).resolve().parent
            if any((directory/p).exists() for p in ['_sc_','._sc_']):directories={'data':directory/'editor_data','settings':directory/'editor_data'}
            else:directories={'data':Path(os.environ.get('XDG_DATA_HOME',str(Path.home()/'.local/share')))/'godot','settings':Path(os.environ.get('XDG_CONFIG_HOME',str(Path.home()/'.config')))/'godot'}
        templates=Path(args.template_root) if args.template_root else (directories['data']/'export_templates' if directories else None)
        for preset in planned['requiredExports']:
            section=next(k for k,v in settings['sections'].items() if re.fullmatch(r'preset\.\d+',k) and v.get('name')==preset['name']);options=settings['sections'].get(section+'.options',{});architecture=options.get('binary_format/architecture','x86_64');custom=options.get('custom_template/release');gradle=preset.get('useGradle',False)
            if gradle:custom=options.get('gradle_build/android_source_template')
            filename='windows_release_'+architecture+'.exe' if preset['platform']=='Windows Desktop' else ('linux_release.'+architecture if preset['platform']=='Linux' else ('android_source.zip' if gradle else 'android_release.apk'))
            found=False
            if custom:
                custom=custom.removeprefix('res://');found=(Path(settings['projectPath'])/custom).is_file()
            elif templates and engine_version:found=(templates/engine_version/filename).is_file()
            add('template:'+preset['name'],'passed' if found else 'blocked','Release template exists; export remains separate verification.' if found else 'Install exact engine templates or configure inspected custom template.')
    else:add('godot','skipped','No selected exports.')
    android=[p for p in planned['requiredExports'] if p['platform']=='Android']
    if android:
        editor={};editor_path=Path(args.editor_settings_path) if args.editor_settings_path else (directories['settings']/('editor_settings-'+'.'.join(engine_version.split('.')[:2])+'.tres') if directories and engine_version else None)
        if editor_path and editor_path.is_file():editor=godot_sections(editor_path).get('resource',{})
        sdk=args.android_sdk_path or editor.get('export/android/android_sdk_path') or os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT');java=args.java_sdk_path or editor.get('export/android/java_sdk_path') or os.environ.get('JAVA_HOME')
        sdk_found=bool(sdk and (Path(sdk)/'platform-tools/adb').is_file() and (Path(sdk)/'build-tools').is_dir());java_found=bool(java and (Path(java)/'bin/java').is_file())
        add('android-sdk','passed' if sdk_found else 'blocked','SDK platform/build tools checked; full export verifies versions.')
        add('java-sdk','passed' if java_found else 'blocked','Configured JDK executable checked; Gradle/export verifies compatibility.')
        credential_path=Path(settings['projectPath'])/'.godot/export_credentials.cfg';credentials=godot_sections(credential_path) if credential_path.is_file() else {}
        for preset in android:
            section=next(k for k,v in settings['sections'].items() if re.fullmatch(r'preset\.\d+',k) and v.get('name')==preset['name'])+'.options';options=settings['sections'].get(section,{});values={}
            for key,var in [('keystore/release','GODOT_ANDROID_KEYSTORE_RELEASE_PATH'),('keystore/release_user','GODOT_ANDROID_KEYSTORE_RELEASE_USER'),('keystore/release_password','GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD')]:values[key]=os.environ.get(var) or credentials.get(section,{}).get(key) or options.get(key)
            key_path=values['keystore/release'];key_path=Path(settings['projectPath'])/key_path.removeprefix('res://') if key_path else None
            found=key_path and key_path.is_file() and values['keystore/release_user'] and values['keystore/release_password']
            add('signing:'+preset['name'],'passed' if found else 'blocked','Private signing inputs present; exported signature and key validity remain unverified.' if found else 'Supply private Godot signing inputs at runtime.')
            if preset.get('useGradle'):
                directory=Path(settings['projectPath'])/str(options.get('gradle_build/gradle_build_directory') or 'res://android').removeprefix('res://')/'build';found=any((directory/f).is_file() for f in ['build.gradle','build.gradle.kts']);add('gradle:'+preset['name'],'passed' if found else 'blocked','Selected Gradle preset requires installed project Android build template.')
    else:add('android-sdk','skipped','No selected Android export.');add('java-sdk','skipped','No selected Android export.')
    return {'ready':not any(c['status']=='blocked' for c in checks),'remoteAccessVerified':False,'readOnly':True,'repository':settings['repository'],'version':settings['version'],'selectedDestinations':planned['selectedDestinations'],'checks':checks}

def with_google_play_token(account,service_account,config_directory,action,gcloud='gcloud',transport=None):
    if not re.fullmatch(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}',account):fail('Supply explicitly authorized Google account.')
    if not re.fullmatch(r'[a-z][a-z0-9-]{4,29}@[a-z][a-z0-9-]{4,29}\.iam\.gserviceaccount\.com',service_account):fail('Supply valid authorized service account email.')
    directory=Path(config_directory).resolve()
    if not directory.is_dir():fail('Existing Google CLI credential directory required.')
    code,_=run('git',['-C',directory,'rev-parse','--git-dir'],directory,timeout=15)
    if code==0:fail('Keep Google CLI credentials outside Git checkouts.')
    prior_config=os.environ.get('CLOUDSDK_CONFIG');prior_token=os.environ.get('BA_GOOGLE_PLAY_ACCESS_TOKEN')
    try:
        os.environ['CLOUDSDK_CONFIG']=str(directory)
        code,output=run(gcloud,['auth','list','--format=json','--quiet'],directory,timeout=30)
        if code:fail('Could not verify Google CLI active account.')
        identities=parse_json(output);active=[i for i in identities if i.get('status')=='ACTIVE']
        if len(active)!=1 or active[0].get('account')!=account:fail('Google CLI active account does not match authorized account.')
        code,output=run(gcloud,['auth','print-access-token','--account='+account,'--quiet'],directory,timeout=30)
        if code or not output.strip():fail('Google CLI token acquisition failed; sign in separately in authorized profile.')
        request={'method':'POST','uri':'https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/'+service_account+':generateAccessToken','body':{'scope':['https://www.googleapis.com/auth/androidpublisher'],'lifetime':'3600s'}}
        try:mint=(transport(request,output.strip()) if transport else api_request(request,output.strip()))
        except ReleaseError:fail('Google Play token generation failed.')
        try:
            expiry=dt.datetime.fromisoformat(mint['expireTime'].replace('Z','+00:00'));remaining=(expiry-dt.datetime.now(dt.timezone.utc)).total_seconds()
            if not isinstance(mint['accessToken'],str) or not mint['accessToken'].strip() or not 120<remaining<=3900:raise ValueError()
        except (ValueError,KeyError,TypeError):fail('Google Play did not return a usable short-lived token.')
        os.environ['BA_GOOGLE_PLAY_ACCESS_TOKEN']=mint['accessToken'];output=None;mint=None
        return action()
    finally:
        for key,value in [('CLOUDSDK_CONFIG',prior_config),('BA_GOOGLE_PLAY_ACCESS_TOKEN',prior_token)]:
            if value is None:os.environ.pop(key,None)
            else:os.environ[key]=value

def parser():
    cli=argparse.ArgumentParser(description=__doc__)
    cli.add_argument('--mode',required=True,choices=['setup','validate','doctor','plan','prepare','extend','hold','unhold','publish','status','confirm','abandon','play-changelogs'])
    for key in ['repository','state-root','state-path','godot-executable','template-root','editor-settings-path','android-sdk-path','java-sdk-path','receipt-path','answers-path','expected-config-sha256','approved-plan-id','approved-notes-sha256','hold-reason']:cli.add_argument('--'+key)
    cli.add_argument('--destination',action='append',default=[])
    cli.add_argument('--butler-executable',default='butler');cli.add_argument('--gh-executable',default='gh');cli.add_argument('--steam-cmd-executable',default='steamcmd')
    cli.add_argument('--version-change',choices=['current','patch','minor','major'],default='current')
    for key in ['interactive','new-release','play-track-reviewed','retry-uncertain','replace-play-edit','migrate-configuration','abandon-authorized']:cli.add_argument('--'+key,action='store_true')
    return cli

def main(argv=None):
    args=parser().parse_args(argv);selection=sorted(set(s.strip() for group in args.destination for s in group.split(',') if s.strip()));mode=args.mode
    try:
        for name in ['godot_executable','butler_executable','gh_executable','steam_cmd_executable']:
            value=getattr(args,name)
            if value and '/' in value:setattr(args,name,str(Path(value).absolute()))
        if mode in ['setup','validate','doctor','plan','prepare'] and not args.repository:fail('--repository must name inspected Git root.')
        if mode in ['extend','hold','unhold','publish','status','confirm','abandon','play-changelogs'] and not args.state_path:fail('--state-path must name existing prepared release.')
        for option,target in [('play_track_reviewed','unhold'),('migrate_configuration','extend'),('abandon_authorized','abandon')]:
            if getattr(args,option) and mode!=target:fail('--'+option.replace('_','-')+' applies only to '+target+'.')
        if mode=='unhold' and args.hold_reason is not None:fail('--hold-reason cannot be supplied to unhold.')
        if mode in ['confirm','abandon'] and not args.receipt_path:fail('--receipt-path must name an observed result.')
        exit_code=0
        if mode=='setup':result=setup(args.repository,selection,args.answers_path,args.expected_config_sha256,args.interactive)
        elif mode=='validate':
            settings=configuration(args.repository);result={'valid':True,'version':settings['version'],'exports':settings['presets'],'notesRepository':settings['notesRepository'],'previousRelease':settings['config']['previousReleaseRef'],'destinations':settings['config']['destinations']}
        elif mode=='plan':result=plan(args.repository,selection,args.state_root,args.version_change);exit_code=0 if result['ready'] else 2
        elif mode=='doctor':result=doctor(args.repository,selection,args);exit_code=0 if result['ready'] else 2
        elif mode=='prepare':
            if not selection:result={'status':'selection-required','selection':setup(args.repository)['selection']};exit_code=2
            else:result=prepare(args.repository,selection,args.state_root,args.godot_executable,args.version_change,args.new_release,args.butler_executable);exit_code=3 if result['status'] in ['preparation-failed','source-update-required'] else 0
        elif mode=='extend':result=extend(args.state_path,selection,args.godot_executable,args.butler_executable,args.migrate_configuration);exit_code=3 if result['status'] in ['preparation-failed','source-update-required'] else 0
        elif mode in ['hold','unhold']:result=hold(args.state_path,selection,args.hold_reason,mode=='unhold',args.play_track_reviewed)
        elif mode=='publish':
            if selection or args.repository or args.state_root or args.godot_executable:fail('Publish uses only sealed state path; selection and source options cannot replace plan.')
            result=publish(args.state_path,args.approved_plan_id,args.approved_notes_sha256,args.butler_executable,args.gh_executable,args.steam_cmd_executable,args.retry_uncertain,args.replace_play_edit);exit_code=0 if result['status']=='published' else 3
        elif mode=='status':
            path,state=state_path(args.state_path);result=copy.deepcopy(state);result.update(version=state['plan']['version'],planId=state['plan']['planId'],selectedDestinations=state['plan']['selectedDestinations'],notesFiles=[str(path/'notes.md')]+[str(path/('notes.'+d['id']+'.txt')) for d in state['plan']['destinations'] if d['selected'] and d['type']=='google-play'])
            try:result.update(notesSha256=notes_hash(path,state['plan']),notesError=None)
            except (ReleaseError,OSError):result.update(notesSha256=None,notesError='Prepared notes cannot be read or validated.')
        elif mode in ['confirm','abandon']:result=confirm(args.state_path,args.receipt_path,mode=='abandon',args.abandon_authorized);exit_code=3 if mode=='confirm' and result['status']!='published' else 0
        else:
            path,state=state_path(args.state_path);result={'paths':play_changelogs(path,state)}
        print(json.dumps(result,ensure_ascii=False,indent=2));return exit_code
    except (ReleaseError,OSError,KeyError,TypeError,ValueError,StopIteration) as exc:
        message=str(exc) if isinstance(exc,ReleaseError) else 'Release input/state or required file is invalid; inspect configuration and saved journal.'
        print(compact({'error':message,'mode':mode}));return 1

if __name__=='__main__':
    install_cancellation_handlers()
    sys.exit(main())

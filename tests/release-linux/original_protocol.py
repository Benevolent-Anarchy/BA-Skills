"""Fixtures transcribed from the original PowerShell release protocol.

This builds journals WITHOUT calling the native planner, preparer or serializer.
Field insertion order follows Release.psm1 Get-ReleasePlan/Get-ReleaseArtifact;
pipeline cardinality follows `... | ConvertTo-Json -Compress` (0/1/many).
Actions are literal original strings, including punctuation. The fixture's
configuration names .sh hooks.
"""
import copy
import hashlib
import json
from pathlib import Path
import subprocess

def sha(text):return hashlib.sha256(text if isinstance(text,bytes) else text.encode()).hexdigest()
def json_text(value):
    # Newtonsoft's default JavaScript escaping includes these three separators.
    return json.dumps(value,ensure_ascii=False,separators=(',',':')).replace('\x85','\\u0085').replace('\u2028','\\u2028').replace('\u2029','\\u2029')
def pipeline_text(values):return '' if not values else json_text(values[0] if len(values)==1 else values)
def git(repo,*args):return subprocess.check_output(['git','-C',str(repo),*args],text=True).strip()

def plan_fixture(repo,selection,with_play=False,with_steam=False,display=None,repository_pin=None):
    repo=Path(repo);repository=repository_pin or str(repo);head=git(repo,'rev-parse','HEAD');previous=git(repo,'rev-parse','base');selected=sorted(selection);config_hash=sha((repo/'release.json').read_bytes())
    changes=[]
    for line in git(repo,'log','--no-merges','--reverse','--format=%H%x1f%s',previous+'..'+head).splitlines():
        commit,subject=line.split('\x1f',1);changes.append({'commit':commit,'subject':subject})
    changed=git(repo,'diff','--name-only',previous,head,'--').splitlines()
    linux={'name':'Linux','platform':'Linux','configuredPath':'build/game.x86_64','filename':'game.x86_64'}
    exports=[linux]
    if with_play:exports.append({'name':'AAB','platform':'Android','configuredPath':'build/game.aab','filename':'game.aab','packageName':'com.fixture.game','versionCode':7,'format':'aab','useGradle':True})
    destinations=[];baselines={};needed=set()
    itch={'id':'itch-linux','type':'itch','selected':'itch-linux' in selected,'status':'planned' if 'itch-linux' in selected else 'not-selected','preset':'Linux','target':'fixture/game:linux','ignore':['steam_api*.dll','libsteam_api.so','libgodotsteam.*','steam_appid.txt']}
    if display:
        itch['displayName']=display
        itch['requiredActions']=["Set the upload's display name to '"+display+"' on itch.io's Edit game page; this does not control the downloaded archive filename."]
    if itch['selected']:
        baselines['itch-linux']=previous;needed.add('Linux');itch.update(previousCommit=previous,changes=copy.deepcopy(changes),changedFiles=changed.copy())
    destinations.append(itch)
    # add_android fixture appends Play AFTER existing notes; Steam is appended in
    # the order configured by each test, as OrderedHashtable expansion does.
    notes={'id':'notes','type':'notes','selected':'notes' in selected,'status':'planned' if 'notes' in selected else 'not-selected','repository':'fixture/game-release-notes','path':'releases/1.2.3.md'};destinations.append(notes)
    if with_play:
        play={'id':'google-play','type':'google-play','selected':'google-play' in selected,'status':'planned' if 'google-play' in selected else 'not-selected','preset':'AAB','track':'production','releaseStatus':'completed','userFraction':None,'language':'en-US','retainVersionCodes':[],'packageName':'com.fixture.game','versionCode':7,'requiredActions':['Review all current Play track releases before approving retained version codes.','Verify review, managed publishing and rollout state in Play Console after submission.']}
        if play['selected']:
            baselines['google-play']=previous;needed.add('AAB');play.update(previousCommit=previous,changes=copy.deepcopy(changes),changedFiles=changed.copy())
        destinations.append(play)
    if with_steam:
        steam={'id':'steam','type':'steam','selected':'steam' in selected,'status':'planned' if 'steam' in selected else 'not-selected','appId':42,'branch':'default','depots':[{'id':43,'preset':'Linux','exclude':[]}],'requiredActions':['Verify build activation on the selected Steam branch in Steamworks.','Publish the approved notes as a Steam announcement.']}
        if steam['selected']:
            baselines['steam']=previous;needed.add('Linux');steam.update(previousCommit=previous,changes=copy.deepcopy(changes),changedFiles=changed.copy())
        destinations.append(steam)
    identity={'schemaVersion':1,'repository':repository,'head':head,'configSha256':config_hash,'version':'1.2.3','previousCommit':previous,'selectedDestinations':selected,'baselines':baselines,'versionChange':'current'}
    draft='# Fixture 1.2.3\n\n<!-- sourceCommit: '+head+'; previousCommit: '+previous+' -->\n\n'
    draft+=('\n'.join('- '+c['subject'] for c in changes)+'\n') if changes else 'No commits since the confirmed previous release.\n'
    draft+='\n[Release availability](../availability/1.2.3.json)\n'
    return {'schemaVersion':1,'mode':'plan','planId':sha(json_text(identity)),'repository':repository,'head':head,'version':'1.2.3','sourceVersion':'1.2.3','versionChange':'current','preview':False,'configSha256':config_hash,'previousCommit':previous,'selectedDestinations':selected,'notesRepository':'fixture/game-release-notes','baselines':baselines,'exports':exports,'requiredExports':[copy.deepcopy(e) for e in exports if e['name'] in needed],'destinations':destinations,'changes':changes,'changedFiles':changed,'notesDraft':draft,'configurationReady':True,'sourceChanges':[],'blockers':[],'ready':True}

def journal_fixture(root,plan,statuses=None):
    path=Path(root)/sha(plan['repository'])[:20]/plan['version'];path.mkdir(parents=True,exist_ok=True);artifacts=[];exports={};checks={}
    for index,preset in enumerate(plan['requiredExports'],1):
        directory=path/'builds'/str(index);directory.mkdir(parents=True);payload=directory/preset['filename'];payload.write_bytes(('Original approved '+preset['name']).encode());relative=payload.relative_to(path).as_posix()
        artifacts.append({'preset':preset['name'],'directory':directory.relative_to(path).as_posix(),'files':[{'path':relative,'size':payload.stat().st_size,'sha256':sha(payload.read_bytes())}],'sourceCommit':plan['head']});exports[preset['name']]={'status':'succeeded','error':None}
    (path/'notes.md').write_text(plan['notesDraft']);manifest=[{'path':'notes.md','sha256':sha((path/'notes.md').read_bytes())}]
    records={}
    for dest in plan['destinations']:
        record={'status':'pending' if dest['selected'] else 'not-selected','attempts':0,'error':None,'remote':{}}
        if statuses and dest['id'] in statuses:record.update(copy.deepcopy(statuses[dest['id']]))
        records[dest['id']]=record
        if dest['selected'] and dest['type']=='google-play':
            locale=path/('notes.'+dest['id']+'.txt');locale.write_text('Approved original Play notes');manifest.append({'path':locale.name,'sha256':sha(locale.read_bytes())})
        if dest['selected'] and dest['type']=='itch':checks[dest['id']]={'standalone':'succeeded','dryRun':'succeeded','error':None,'input':next(a['directory'] for a in artifacts if a['preset']==dest['preset'])}
    notes_hash=manifest[0]['sha256'] if len(manifest)==1 else sha(pipeline_text(manifest))
    approval={'planId':plan['planId'],'notesSha256':notes_hash,'artifactsSha256':sha(pipeline_text(artifacts))}
    state={'schemaVersion':1,'plan':plan,'status':'prepared','verification':'succeeded','artifacts':artifacts,'exports':exports,'checks':checks,'destinations':records,'approval':approval}
    (path/'state.json').write_text(json.dumps(state,ensure_ascii=False,indent=2));return path,state

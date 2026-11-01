#!/usr/bin/env python3
"""Standalone Linux project gate. Python standard library only; no installed skill needed."""
import argparse
import importlib.util
import datetime
import json
import html
import os
from pathlib import Path
import re
import signal
import shutil
import subprocess
import sys
import unicodedata
import uuid
import xml.etree.ElementTree as ET

# A complete CommonMark block parser distinguishes list content from code indentation.
# Sources, licenses and checksums travel with the generated project for offline use.
sys.dont_write_bytecode=True
sys.path.insert(0,str(Path(__file__).resolve().parent/'_vendor'))
from markdown_it import MarkdownIt
from markdown_it.rules_inline import autolink, backtick, html_inline, image, link
MARKDOWN=MarkdownIt('commonmark')

def located_inline(rule,kind):
    """Keep source positions while leaving CommonMark link recognition to the parser."""
    def parse(state,silent):
        start=state.pos; count=len(state.tokens)
        matched=rule(state,silent)
        if matched and not silent:
            token=next((token for token in state.tokens[count:] if token.type==kind),None)
            if token is not None: token.meta['source_span']=(start,state.pos)
        return matched
    return parse

for name,rule,kind in (('link',link,'link_open'),('image',image,'image'),('autolink',autolink,'link_open'),('html_inline',html_inline,'html_inline'),('backticks',backtick,'code_inline')):
    MARKDOWN.inline.ruler.at(name,located_inline(rule,kind))

def rendered_text(children):
    return ''.join(rendered_text(child.children or []) if child.type=='image' else
                   child.content if child.type in ('text','code_inline') else
                   ' ' if child.type in ('softbreak','hardbreak') else '' for child in children)

def inline_nodes(children,origin=0):
    """Walk image alt inlines as well, retaining their origin in the paragraph."""
    for index,child in enumerate(children):
        yield child,children,index,origin
        if child.type=='image':
            yield from inline_nodes(child.children or [],origin+child.meta['source_span'][0]+2)

def inline_links(children):
    for child,siblings,index,origin in inline_nodes(children):
        if child.type not in ('link_open','image'): continue
        start,end=child.meta['source_span']
        if child.type=='image': label=rendered_text(child.children or [])
        else:
            close=next(i for i in range(index+1,len(siblings)) if siblings[i].type=='link_close')
            label=rendered_text(siblings[index+1:close])
        yield child,label,origin+start,origin+end

REQUIRED = {'foundation':['documentation'], 'godot':['documentation','godot-import','godot-compile','gut-headless'], 'tauri':['documentation','typescript','frontend-tests','frontend-build','rust-format','rust-lint','rust-tests','tauri-build']}

_process_spec=importlib.util.spec_from_file_location('ba_gate_process_'+uuid.uuid4().hex,Path(__file__).resolve().parent/'process_linux.py')
_process_helper=importlib.util.module_from_spec(_process_spec); _process_spec.loader.exec_module(_process_helper)
run_process=_process_helper.run

def process(args,cwd,env=None,timeout=900):
    return run_process(args,cwd=cwd,env=env,timeout=timeout).stdout

def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))

def safe(root, path):
    root, path = Path(root).absolute(), Path(path).absolute()
    if not path.is_relative_to(root): raise ValueError('Target leaves the repository')
    cursor = path
    while cursor != root:
        if cursor.is_symlink(): raise ValueError('Target traverses a symbolic link')
        cursor = cursor.parent
    if root.is_symlink(): raise ValueError('Repository root is a symbolic link')
    return path

def inline_text(value):
    value=re.sub(r'!?\[([^]]*)\]\([^)]*\)',r'\1',value)
    value=re.sub(r'(`+)(.*?)\1',lambda m:m[2].replace('\n',' '),value)
    value=re.sub(r'(?<!\\)(\*\*|__|\*|_)(.+?)\1',lambda m:m[2],value)
    value=re.sub(r'\\([!"#$%&\'()*+,\-./:;<=>?@\[\]\\^_`{|}~])',r'\1',value)
    return html.unescape(value)

def anchor(title):
    title=inline_text(title)
    return ''.join(c for c in title.strip().lower() if unicodedata.category(c)[0] in 'LNM' or c in ' _-').replace(' ','-')

def escaped(text,at):
    back=at-1
    while back>=0 and text[back]=='\\': back-=1
    return (at-back-1)%2==1

def source_lines(text):
    starts=[0]
    for match in re.finditer('\n',text): starts.append(match.end())
    if starts[-1]!=len(text): starts.append(len(text))
    return starts

def block_spans(text,tree,kinds):
    starts=source_lines(text)
    return [(starts[token.map[0]],starts[min(token.map[1],len(starts)-1)])
            for token in tree if token.type in kinds and token.map]

def inline_position(token,position,lines,starts):
    row=token.content.count('\n',0,position); sourcerow=token.map[0]+row
    column=position-token.content.rfind('\n',0,position)-1
    # CommonMark strips list/quote prefixes from inline content.
    column+=max(0,lines[sourcerow].find(token.content.split('\n')[row]))
    return sourcerow,column,starts[sourcerow]+column

def inline_spans(text,tree):
    starts=source_lines(text); lines=text.split('\n'); spans=[]
    for token in tree:
        if token.type!='inline' or not token.map: continue
        for child,_,_,origin in inline_nodes(token.children or []):
            if child.type in ('html_inline','code_inline'):
                a,b=child.meta['source_span']
                spans.append((inline_position(token,origin+a,lines,starts)[2],inline_position(token,origin+b,lines,starts)[2]))
    return spans

def tokens(text):
    """Read CommonMark blocks plus Obsidian comments/wiki links with source locations."""
    text=text.replace('\r\n','\n').replace('\r','\n'); chars=list(text)
    at=0
    while at<len(text):
        current=''.join(chars); match=re.search(r'<!--|%%',current[at:])
        if not match: break
        start=at+match.start(); marker=match[0]
        initial_tree=MARKDOWN.parse(current,{})
        protected=block_spans(current,initial_tree,{'fence','code_block'})+inline_spans(current,initial_tree)
        if escaped(current,start) or any(a<=start<b for a,b in protected):
            at=start+len(marker); continue
        close=current.find('-->' if marker=='<!--' else '%%',start+len(marker))
        if marker=='<!--':
            blockend=next((b for a,b in block_spans(current,initial_tree,{'html_block'}) if a<=start<b),None)
            # Real inline comments are already protected by their parser token. Other
            # inline openers are literal, even if another paragraph contains a closer.
            if blockend is None: at=start+len(marker); continue
            end=blockend if close<0 else min(blockend,close+3)
        else: end=len(current) if close<0 else close+2
        for i in range(start,end):
            if chars[i]!='\n': chars[i]=' '
        at=end
    current=''.join(chars); environment={}; tree=MARKDOWN.parse(current,environment)
    for begin,end in block_spans(current,tree,{'fence','code_block','html_block'}):
        for i in range(begin,end):
            if chars[i]!='\n': chars[i]=' '
    visible=''.join(chars); spans=inline_spans(visible,tree)
    headings=[]; lines=visible.split('\n')
    for index,token in enumerate(tree):
        if token.type=='heading_open' and token.map:
            title=tree[index+1].content
            headings.append((int(token.tag[1:]),title,token.map[0]+1,anchor(title)))
    links=[]; wikispans=[]; starts=source_lines(visible)
    def add(kind,target,label,alias,start,end):
        links.append(dict(kind=kind,target=target,label=label,alias=alias,line=1+visible.count('\n',0,start),end=end-visible.rfind('\n',0,start)-1))
        wikispans.append((start,end))
    for match in re.finditer(r'\[\[([^]\n]+)\]\]',visible):
        if escaped(visible,match.start()) or any(a<=match.start()<b for a,b in spans): continue
        parts=match[1].split('|',1); target=parts[0].strip(); label=parts[1].strip() if len(parts)>1 else target.split('#',1)[0]
        add('wiki',target,label,len(parts)>1,match.start(),match.end())
    for token in tree:
        if token.type!='inline' or not token.map: continue
        children=token.children or []
        for child,label,start,end in inline_links(children):
            sourcerow,_,absolute=inline_position(token,start,lines,starts)
            if any(a<=absolute<b for a,b in wikispans): continue
            endrow,column,_=inline_position(token,end,lines,starts)
            links.append(dict(kind='markdown',target=child.attrGet('src' if child.type=='image' else 'href'),label=label,alias=True,line=sourcerow+1,endLine=endrow+1,end=column))
    return dict(headings=headings,links=sorted(links,key=lambda item:item['line']),lines=lines)

def documentation(root):
    root=Path(root).absolute(); vault=root/'docs'; diagnostics=[]; notes={}
    def error(path,line,code,message,severity='error'):
        diagnostics.append(f'{Path(path).relative_to(root)}:{line}: {severity}: {code}: {message}')
    def note(path):
        if path not in notes:
            try: notes[path]=tokens(safe(root,path).read_text(encoding='utf-8'))
            except (OSError,UnicodeError,ValueError) as exc:
                error(path,1,'unreadable-file',str(exc)); notes[path]={'headings':[],'links':[],'lines':[]}
        return notes[path]
    def resolve(source,link):
        from urllib.parse import unquote
        target=link['target']
        if re.match(r'^[A-Za-z][A-Za-z0-9+.-]*:|^//',target): return None,None
        part=target.split('#',1); filename=unquote(part[0]); fragment=unquote(part[1]) if len(part)>1 else ''
        base=vault if link['kind']=='wiki' else (root if filename.startswith('/') else source.parent)
        dest=Path(os.path.abspath(base/filename.lstrip('/'))) if filename else source
        if link['kind']=='wiki' and filename and dest.suffix!='.md' and (not dest.suffix or not dest.is_file()): dest=Path(str(dest)+'.md')
        safe(root,dest)
        if not dest.exists(): raise ValueError('Target is missing: '+target)
        heading=None
        if fragment:
            if dest.suffix!='.md': raise ValueError('Heading requires Markdown')
            found=[h for h in note(dest)['headings'] if h[1 if link['kind']=='wiki' else 3]==fragment]
            if len(found)!=1: raise ValueError('Heading missing or ambiguous: '+fragment)
            heading=found[0]
        return dest,heading
    if not vault.is_dir(): return {'Passed':False,'Diagnostics':['docs:1: required-path: Required vault missing']}
    for directory, dirs, files in os.walk(vault, followlinks=False):
        parent=Path(directory)
        dirs[:]=[d for d in dirs if d!='.obsidian' and not (parent==vault and d=='Vault Inspector Reports')]
        for name in list(dirs)+files:
            path=parent/name
            if path.is_symlink(): error(path,1,'linked-path','Documentation contains a symbolic link'); dirs[:]=[d for d in dirs if parent/d!=path]
            elif path.is_file() and path.suffix=='.md': note(path)
    for path in root.glob('*.md'):
        if path.is_symlink(): error(path,1,'linked-path','Root document is linked')
        else: note(path)
    for path,data in list(notes.items()):
        for link in data['links']:
            if path.parent==root and link['kind']=='wiki': continue
            try: resolve(path,link)
            except (ValueError,OSError) as exc: error(path,link['line'],'link-target',str(exc))
    for corpus in ('design','decisions','judgements'):
        indexpath=vault/(corpus.upper()+'.md'); topicdir=vault/corpus
        if not indexpath.is_file() or not topicdir.is_dir() or indexpath.is_symlink() or topicdir.is_symlink():
            error(indexpath,1,'required-path','Required index or topical directory missing'); continue
        index=note(indexpath); sections=[h for h in index['headings'] if h[:2]==(2,'Index')]
        if len(sections)!=1: error(indexpath,1,'index-section','Expected one ## Index'); continue
        start=sections[0][2]; end=next((h[2] for h in index['headings'] if h[2]>start and h[0]<=2),len(index['lines'])+1)
        topics=[p for p in notes if p.is_relative_to(topicdir)]; records={}; keys=set()
        for topic in topics:
            data=notes[topic]; titles=[h for h in data['headings'] if h[0]==1]
            if len(titles)!=1: error(topic,1,'topic-title','Expected one top-level title')
            for h in data['headings']:
                if not (h[0]>=2 if corpus=='design' else h[0]==3): continue
                key=(topic,h[1]); record={'count':0,'heading':h,'metadata':None,'incomplete':False}
                if key in records: error(topic,h[2],'duplicate-key','Duplicate heading'); continue
                records[key]=record
                if corpus!='design':
                    if h[1] in keys: error(topic,h[2],'duplicate-key','Citation key already defined')
                    keys.add(h[1])
                if corpus=='decisions':
                    groups=[x for x in data['headings'] if x[2]<h[2] and x[0]<=2]
                    try:
                        if not groups or groups[-1][0]!=2: raise ValueError()
                        datetime.date.fromisoformat(groups[-1][1])
                    except ValueError: error(topic,h[2],'decision-date','Expected a real ## YYYY-MM-DD group')
                if corpus=='judgements':
                    recordend=next((x[2] for x in data['headings'] if x[2]>h[2] and x[0]<=3),len(data['lines'])+1)
                    body=data['lines'][h[2]:recordend-1]; metas=[(n,line) for n,line in enumerate(body) if re.fullmatch(r'\*Judged .+\.\*',line)]
                    if len(metas)!=1 or metas[0][0]!=0: error(topic,h[2],'judgement-metadata','Expected immediate *Judged ... .*'); continue
                    metadata=metas[0][1][1:-2]; record['metadata']=metadata
                    dates=re.findall(r'\b\d{4}-\d{2}-\d{2}\b',metadata); valid=[]
                    for date in dates:
                        try: datetime.date.fromisoformat(date); valid.append(True)
                        except ValueError: valid.append(False)
                    incomplete=('Date not recorded' in metadata or 'Hardware not recorded' in metadata) and 'Incomplete historical record' in '\n'.join(body)
                    hardware='Hardware not applicable' in metadata or any(clause.startswith('on ') and re.search(r'[A-Za-z]',re.sub(r'\d{4}-\d{2}-\d{2}|Date not recorded','',clause[3:])) for clause in metadata.removeprefix('Judged ').split('. ',1)[0].split(', ')[:2])
                    if False in valid or not (True in valid or incomplete and 'Date not recorded' in metadata) or not (hardware or incomplete and 'Hardware not recorded' in metadata): error(topic,h[2]+1,'judgement-fields','Record date and applicable hardware independently')
                    record['incomplete']=incomplete
                    if incomplete: error(topic,h[2],'incomplete-record','Incomplete historical record','warning')
        group=None; counts={}; last=start
        for link in [x for x in index['links'] if start<x['line']<end]:
            if any(last<h[2]<=link['line'] for h in index['headings']): group=None
            last=link['line']
            try: dest,h=resolve(indexpath,link)
            except (ValueError,OSError): continue
            if dest not in topics: continue
            if h is None:
                group=dest; counts[dest]=counts.get(dest,0)+1; titles=[x for x in notes[dest]['headings'] if x[0]==1]
                if len(titles)==1 and link['label']!=titles[0][1]: error(indexpath,link['line'],'topic-title','Topic link label differs')
                continue
            key=(dest,h[1])
            if key not in records: error(indexpath,link['line'],'index-entry','Target is not an indexed record'); continue
            record=records[key]; record['count']+=1
            if group!=dest: error(indexpath,link['line'],'index-group','Entry must be under its topical file link')
            if link['alias'] and link['label']!=h[1]: error(indexpath,link['line'],'index-entry','Indexed title differs')
            if corpus=='judgements' and record['metadata']:
                tail=index['lines'][link.get('endLine',link['line'])-1][link['end']:].strip(); expected='— '+record['metadata']
                if not (tail==expected or tail.startswith(expected+' — ')) or record['incomplete'] and 'Incomplete historical record' not in tail: error(indexpath,link['line'],'judgement-index','Copy the complete Judged statement')
        for topic in topics:
            if counts.get(topic)!=1: error(indexpath,start,'topic-index','Expected one topic group for '+str(topic.relative_to(vault)))
        for (topic,title),record in records.items():
            if record['count']!=1: error(topic,record['heading'][2],'not-indexed' if record['count']==0 else 'duplicate-index',title)
    return {'Passed':not any(': error:' in x for x in diagnostics),'Diagnostics':diagnostics}

def junit(path, gut=False):
    root=ET.parse(path).getroot()
    if root.tag!='testsuites': raise ValueError('Malformed test report root')
    def count(field, optional=False):
        raw=root.get(field)
        if raw is None and optional: return 0
        if not raw or not re.fullmatch(r'\d+',raw): raise ValueError('Malformed test count: '+field)
        return int(raw)
    tests=count('tests'); cases=root.findall('./testsuite/testcase') if gut else root.findall('.//testcase')
    if tests<1 or len(cases)!=tests: raise ValueError('Test report has zero tests or inconsistent testcase counts')
    if count('failures') or count('errors',gut) or root.findall('.//failure') or root.findall('.//error'): raise ValueError('Test report contains failures/errors')
    skipped=sum(c.find('skipped') is not None or c.get('status')=='pending' for c in cases)
    if root.get('skipped') is not None and count('skipped')!=skipped: raise ValueError('Inconsistent skipped count')
    if tests-skipped<1: raise ValueError('Zero executed non-skipped tests')
    return tests

def gut_totals(path, tests):
    totals=read_json(path)
    if totals.get('hookComplete') is not True or totals.get('failed') is not False: raise ValueError('GUT hook did not complete cleanly; unexpected errors or orphan nodes')
    for field in ('scripts','tests','asserts','seconds'):
        value=totals.get(field)
        if type(value) not in (int,float) or value<0: raise ValueError('Malformed GUT totals: '+field)
    if totals['tests']!=tests or totals['scripts']<1 or totals['asserts']<1: raise ValueError('GUT totals have zero assertions or disagree with cases')
    return totals

def godot_executable():
    executable=shutil.which(os.environ['GODOT']) if os.environ.get('GODOT') else shutil.which('godot') or shutil.which('godot4')
    if not executable: raise ValueError('Godot 4.7 stable missing; set GODOT or add godot to PATH')
    return executable

def godot_sources(directory):
    for child in Path(directory).iterdir():
        if child.is_symlink(): raise ValueError('Linked Godot source: '+str(child))
        if child.is_file(): yield child
        elif not child.name.startswith('.') and not (child/'.gdignore').exists() and not (child/'project.godot').exists(): yield from godot_sources(child)

def tauri_release(metadata, selected, exact=False):
    if not re.fullmatch(r'\d+\.\d+\.\d+',selected): raise ValueError('Invalid selected Tauri release')
    root=metadata.get('resolve',{}).get('root'); nodes=[n for n in metadata.get('resolve',{}).get('nodes',[]) if n['id']==root]
    if not root or len(nodes)!=1: raise ValueError('Cargo metadata does not identify one application root')
    deps=[d for d in nodes[0]['deps'] if d['name']=='tauri']
    packages=[p for p in metadata['packages'] if len(deps)==1 and p['id']==deps[0]['pkg'] and p['name']=='tauri']
    if len(packages)!=1 or not re.fullmatch(r'\d+\.\d+\.\d+',packages[0]['version']): raise ValueError('Expected one direct stable Tauri dependency')
    version=packages[0]['version']; a=tuple(map(int,version.split('.'))); b=tuple(map(int,selected.split('.')))
    if (exact and a!=b) or a[0]!=b[0] or a<b: raise ValueError('Application Tauri version differs from selected release '+selected)

def npm_lock(root):
    package=read_json(root/'package.json'); lock=read_json(root/'package-lock.json'); app=lock.get('packages',{}).get('')
    if lock.get('lockfileVersion',0)<2 or not app or any(app.get(k)!=package.get(k) for k in ('name','version')): raise ValueError('npm lockfile application is stale')
    for key in ('dependencies','devDependencies'):
        if app.get(key,{})!=package.get(key,{}): raise ValueError('npm lockfile '+key+' is stale')

def verify(root, exact=False, runner=process):
    root=Path(root).absolute(); stages=[]; diagnostics=[]; binary=None
    def stage(name, action):
        try:
            result=action(); stages.append({'Name':name,'Passed':True,'ExitCode':0,'Diagnostics':[]}); return result
        except Exception as exc:
            diagnostics.append(name+' failed: '+str(exc)); stages.append({'Name':name,'Passed':False,'ExitCode':1,'Diagnostics':[str(exc)]}); raise
    try:
        config=read_json(root/'tools/verify.json'); preset=config.get('preset'); required=config.get('requiredChecks')
        if config.get('schemaVersion')!=1 or preset not in REQUIRED or not isinstance(required,list) or len(set(required))!=len(required) or not set(REQUIRED[preset])<=set(required) or set(required)-set(REQUIRED[preset]+(['gut-rendered'] if preset=='godot' else [])): raise ValueError('Invalid verification configuration or required checks')
    except Exception as exc: return {'Passed':False,'Stages':[],'Diagnostics':[str(exc)]}
    docs=documentation(root); stages.append({'Name':'documentation','Passed':docs['Passed'],'ExitCode':0 if docs['Passed'] else 1,'Diagnostics':docs['Diagnostics']}); diagnostics+=docs['Diagnostics']
    try:
        if preset=='godot':
            settings=config.get('godot',{})
            if settings.get('versionFamily')!='4.7' or type(settings.get('renderedTests')) is not bool: raise ValueError('Godot requires versionFamily 4.7 and renderedTests boolean')
            exe=godot_executable()
            def imported():
                version=runner([exe,'--version'],root).strip()
                if not re.match(r'^4\.7(?:\.\d+)?\.stable(?:\.|$)',version): raise ValueError('Unsupported Godot version: '+version)
                for name in ('project.godot','addons/gut/gut_cmdln.gd','addons/gut/plugin.cfg','tools/check_scripts.gd','tools/verify_pre_run.gd','tools/verify_post_run.gd'):
                    if not (root/name).is_file(): raise ValueError('Required Godot source missing: '+name)
                runner([exe,'--headless','--path',root,'--import'],root)
                for file in godot_sources(root):
                    if file.suffix=='.import' and re.search(r'^valid=false\s*$',file.read_text(),re.M): raise ValueError('Assets failed to import: '+file.name)
            stage('godot-import',imported)
            stage('godot-compile',lambda:runner([exe,'--headless','--path',root,'--script','res://tools/check_scripts.gd'],root))
            dirs={False:set(),True:set()}
            if (root/'test').is_dir():
                for file in godot_sources(root/'test'):
                    if file.match('test_*.gd'):
                        rel=file.parent.relative_to(root).as_posix(); dirs[rel=='test/rendered' or rel.startswith('test/rendered/')].add('res://'+rel)
            for rendered in [False]+([True] if settings['renderedTests'] or 'gut-rendered' in required or dirs[True] else []):
                name='gut-rendered' if rendered else 'gut-headless'
                def gut_run():
                    if not dirs[rendered]: raise ValueError(name+' found no tests.')
                    report=root/'.godot'/('ba-verify-'+uuid.uuid4().hex); report.mkdir(parents=True)
                    (report/'config.json').write_text(json.dumps({'dirs':sorted(dirs[rendered]),'include_subdirs':False}))
                    rel=report.relative_to(root).as_posix()
                    args=['--windowed','--resolution','640x480'] if rendered else ['--headless']
                    runner([exe,*args,'--path',root,'--script','res://addons/gut/gut_cmdln.gd',f'-gconfig=res://{rel}/config.json','-gexit','-gpre_run_script=res://tools/verify_pre_run.gd','-gpost_run_script=res://tools/verify_post_run.gd',f'-gjunit_xml_file=res://{rel}/results.xml'],root,{'BA_VERIFY_RESULTS':str(report/'results.xml'),'BA_VERIFY_TOTALS':str(report/'totals.json')})
                    try:
                        tests=junit(report/'results.xml',True)
                    except ValueError as exc:
                        if 'Zero executed' in str(exc): raise ValueError(name+' found zero executed non-skipped tests.') from exc
                        raise
                    try: gut_totals(report/'totals.json',tests)
                    except ValueError as exc:
                        if 'zero assertions' in str(exc): raise ValueError(name+' found zero assertions.') from exc
                        raise
                stage(name,gut_run)
        elif preset=='tauri':
            settings=config.get('tauri',{}); selected=settings.get('selectedRelease',''); crate=settings.get('crateName','')
            if not re.fullmatch(r'[a-z][a-z0-9-]*',crate): raise ValueError('Invalid Tauri crate name')
            for name in ('package.json','package-lock.json','src-tauri/Cargo.toml','src-tauri/Cargo.lock'):
                if not (root/name).is_file(): raise ValueError('Required locked Tauri source missing: '+name)
            if not (root/'node_modules').is_dir(): raise ValueError('Frontend dependencies missing; run npm ci')
            npm_lock(root); locks={p:(root/p).read_bytes() for p in ('package-lock.json','src-tauri/Cargo.lock')}
            env={'CARGO_TARGET_DIR':str(root/'src-tauri/target')}
            metadata=json.loads(runner(['cargo','metadata','--manifest-path','src-tauri/Cargo.toml','--locked','--format-version','1','--quiet'],root,env)); tauri_release(metadata,selected,exact)
            runner(['npm','ci','--dry-run','--ignore-scripts','--no-audit','--no-fund'],root,env)
            report=root/'.test-results'/('tauri-'+uuid.uuid4().hex); report.mkdir(parents=True)
            commands=[('typescript',['npm','run','typecheck']),('frontend-tests',['npm','run','test','--','--run','--reporter=junit','--outputFile='+str(report/'frontend.xml')]),('frontend-build',['npm','run','build']),('rust-format',['cargo','fmt','--manifest-path','src-tauri/Cargo.toml','--all','--','--check']),('rust-lint',['cargo','clippy','--manifest-path','src-tauri/Cargo.toml','--locked','--all-targets','--','-D','warnings']),('rust-tests',['cargo','test','--manifest-path','src-tauri/Cargo.toml','--locked']),('tauri-build',['npm','run','tauri','--','build','--no-bundle','--ci','--','--locked'])]
            for name,args in commands:
                def native():
                    runner(args,root,{**env,'BA_TAURI_STAGE':name,'BA_TAURI_RESULTS':str(report/'frontend.xml')})
                    if name=='frontend-tests': junit(report/'frontend.xml')
                    if name=='tauri-build':
                        app=root/'src-tauri/target/release'/crate
                        if not app.is_file() or not app.stat().st_size: raise ValueError('Native build produced no application binary: '+str(app))
                stage(name,native)
            binary=str(root/'src-tauri/target/release'/crate)
            for path,before in locks.items():
                if (root/path).read_bytes()!=before: raise ValueError('Verification mutated lockfile: '+path)
    except Exception as exc:
        if str(exc) not in diagnostics: diagnostics.append(str(exc))
    for name in required:
        if sum(s['Name']==name for s in stages)!=1: stages.append({'Name':name,'Passed':False,'ExitCode':1,'Diagnostics':['Required stage did not report exactly once']})
    return {'Passed':all(s['Passed'] for s in stages) and not any(x for x in diagnostics if ': warning:' not in x),'Stages':stages,'Diagnostics':diagnostics,'BinaryPath':binary}

if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--json',action='store_true'); parser.add_argument('--require-exact-prepared-versions',action='store_true'); args=parser.parse_args()
    report=verify(Path(__file__).resolve().parent.parent,args.require_exact_prepared_versions)
    if args.json: print(json.dumps(report))
    else:
        for message in report['Diagnostics']: print(message)
        for item in report['Stages']: print(item['Name']+(': passed' if item['Passed'] else ': FAILED'))
        if report['Passed']: print('Verification passed: complete project gate.')
    sys.exit(0 if report['Passed'] else 1)

#!/usr/bin/env python3
"""Native SDK integration checks; all repositories/remotes are disposable local fixtures."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('ba_bootstrap_native',ROOT/'skills/ba-bootstrap/scripts/bootstrap_linux.py'); b=importlib.util.module_from_spec(spec); spec.loader.exec_module(b)

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--preset',choices=('godot','tauri','all'),default='all'); parser.add_argument('--fixture-parent',type=Path,default=Path(tempfile.gettempdir())); parser.add_argument('--evidence-root',type=Path,default=ROOT/'.test-results/ba-bootstrap-presets'); args=parser.parse_args()
    runname='ba-native-'+uuid.uuid4().hex[:12]; parent=args.fixture_parent.absolute(); run=b.owned(parent,parent/runname); evidence=b.owned(args.evidence_root.absolute(),args.evidence_root.absolute()/runname)
    if run.exists(): raise ValueError('Native fixture path already exists')
    run.mkdir(parents=True); evidence.mkdir(parents=True); commands=[]; results=[]
    def runner(command,cwd=None,env=None,check=True,timeout=900):
        result=b.command(command,cwd=cwd,env=env,check=False,timeout=timeout); log=evidence/('command-'+str(len(commands))+'.log'); log.write_text(result.stdout)
        commands.append(dict(executable=str(command[0]),arguments=[str(a) for a in command[1:]],directory=str(cwd) if cwd else None,exitCode=result.returncode,log=str(log)))
        if check and result.returncode: raise RuntimeError('Native command failed ('+str(result.returncode)+'); see '+str(log))
        return result
    def git(directory,*args,check=True): return runner(['git','-C',str(directory),*args],cwd=run,check=check)
    def lfs(directory):
        attrs=git(directory,'ls-files','-z','--','.gitattributes','**/.gitattributes').stdout.split('\0'); use=False
        for path in attrs:
            if path and re.search(r'\bfilter=lfs\b',(directory/path).read_text()): use=True
        available=git(directory,'lfs','version',check=False).returncode==0
        if available:
            listing=git(directory,'lfs','ls-files').stdout; use=use or bool(listing.strip())
        if use:
            if not available: raise ValueError('Git LFS is required for native fixture assets')
            git(directory,'lfs','pull'); listing=git(directory,'lfs','ls-files').stdout
            if re.search(r'^[0-9a-f]+ - ',listing,re.M): raise ValueError('Native fixture contains LFS pointers')
    def gate(directory,label,pattern=None):
        print('Native gate: '+label,flush=True); result=runner(['bash',str(directory/'tools/verify.sh')],cwd=directory,check=False)
        if pattern:
            if not result.returncode or not re.search(pattern,result.stdout,re.I): raise ValueError('Expected '+label+' failure was not detected: '+result.stdout)
        elif result.returncode: raise ValueError(label+' gate failed: '+result.stdout)
        return dict(label=label,exitCode=result.returncode,output=result.stdout)
    def tree(directory,manifest,preset):
        b.assert_bytes(directory,manifest); status=git(directory,'status','--porcelain').stdout.strip()
        if status: raise ValueError('Native gate left checkout dirty: '+status)
        paths=git(directory,'ls-tree','-rz','--name-only','HEAD').stdout.rstrip('\0').split('\0')
        if sorted(paths)!=sorted(e['path'] for e in manifest): raise ValueError('Initial tree differs from frozen paths')
        engine.initial_commit(directory,manifest,git(directory,'rev-parse','HEAD').stdout.strip()); engine.ignore_rules(directory,manifest,preset)
        extra=['docs/.obsidian/app.json','docs/Vault Inspector Reports/native.md']
        for path in extra:
            if git(directory,'check-ignore','--no-index','--',path,check=False).returncode: raise ValueError('Generated output not ignored: '+path)
        if preset['name']=='godot' and git(directory,'check-ignore','--no-index','--','addons/x/bin/lib.dll','assets/obj/ship.obj.import','bin/source.gd','obj/source.gd',check=False).returncode!=1: raise ValueError('Godot addon/source is ignored')
        return dict(status=status,sourceHash=b.manifest_hash(manifest),trackedPaths=len(manifest),binaryPaths=[e['path'] for e in manifest if Path(e['path']).suffix in ('.png','.ico','.icns')])
    def negative(directory,label,relative,fixture,pattern):
        path=b.owned(run,directory/relative); before=path.read_bytes()
        try: path.write_bytes((ROOT/'tests/bootstrap/fixtures/native'/fixture).read_bytes()); return gate(directory,label,pattern)
        finally: path.write_bytes(before)
    try:
        variants=['compatibility','forward-plus','mobile'] if args.preset=='godot' else ['tauri'] if args.preset=='tauri' else ['compatibility','forward-plus','mobile','tauri']
        for variant in variants:
            kind='tauri' if variant=='tauri' else 'godot'; id=b.identity('Native '+kind+' '+variant,'Local native bootstrap validation.',str(run/'original with spaces')); selected=b.selection(id,kind,renderer=variant if kind=='godot' else None)
            engine=b.Bootstrap(run/('state-'+variant),request=lambda *_:(_ for _ in ()).throw(ValueError('GitHub mutations are forbidden in native preset checks')),runner=runner)
            prerequisites=engine.prereqs(selected)
            if not prerequisites['passed']: raise ValueError('Native prerequisites: '+json.dumps(prerequisites))
            journal=engine.new_journal(id,selected); engine.save(journal); print('Preparing native '+variant+' starter',flush=True); source,manifest=engine.prepare(journal); engine.freeze(journal,source,manifest); _,manifest=engine.snapshot(journal)
            original=Path(id['projectPath']); b.write_manifest(original,manifest); engine.locked_install(original,selected)
            bare=run/(variant+'.git'); runner(['git','init','--bare','--initial-branch=main',str(bare)],cwd=run); git(original,'init','--initial-branch=main'); lfs(original)
            git(original,'config','user.name','Bootstrap Native Test'); git(original,'config','user.email','bootstrap-native@example.invalid'); git(original,'add','-f','--',*(e['path'] for e in manifest)); git(original,'-c','commit.gpgSign=false','commit','-m','Frozen native starter'); git(original,'push',str(bare),'main')
            original_gate=gate(original,variant+' original'); original_tree=tree(original,manifest,selected)
            clone=run/'fresh clone with spaces'/variant; runner(['git','clone','--no-hardlinks',str(bare),str(clone)],cwd=run); lfs(clone); engine.locked_install(clone,selected); clone_gate=gate(clone,variant+' fresh clone'); clone_tree=tree(clone,manifest,selected); negatives=[]
            if variant in ('compatibility','tauri'):
                negatives.append(negative(clone,'broken docs','README.md','broken-docs.md','documentation: FAILED'))
                if kind=='godot':
                    negatives.append(negative(clone,'Godot compilation','test/test_main.gd','broken-godot.gd','godot-(compile|import): FAILED')); dependency=clone/'addons/gut/gut_cmdln.gd'
                else:
                    for label,path,fixture,pattern in [('TypeScript compilation','src/main.ts','broken-typescript.ts','typescript: FAILED'),('frontend assertion','src/main.test.ts','failing-frontend.test.ts','frontend-tests: FAILED'),('frontend all skipped','src/main.test.ts','skipped-frontend.test.ts','frontend-tests: FAILED'),('Rust compilation','src-tauri/src/lib.rs','broken-rust.rs','(rust-lint|rust-tests|tauri-build): FAILED')]: negatives.append(negative(clone,label,path,fixture,pattern))
                    dependency=clone/'src-tauri/Cargo.lock'
                hidden=b.owned(run,Path(str(dependency)+'.native-hidden')); os.rename(dependency,hidden)
                try: negatives.append(gate(clone,'missing required dependency',r'(gut-headless|tauri): FAILED|Missing|required.*missing|source missing'))
                finally: os.rename(hidden,dependency)
                gate(clone,variant+' restored'); clone_tree=tree(clone,manifest,selected)
                if kind=='godot': runner(['bash',str(clone/'tools/verify_selftest.sh')],cwd=clone)
            roots=list((clone/'.godot').glob('ba-verify-*')) if kind=='godot' else [clone/'.test-results']; reports=[]
            for reportroot in roots:
                reports.extend(dict(path=str(file),content=file.read_text()) for file in reportroot.rglob('*') if file.is_file() and file.suffix in ('.json','.xml'))
            if not reports: raise ValueError('Native gate produced no retained test reports')
            results.append(dict(preset=selected,prerequisites=prerequisites,resolution=journal['resolution'],manifest=journal['manifest'],original=str(original),clone=str(clone),originalGate=original_gate,cloneGate=clone_gate,originalTree=original_tree,cloneTree=clone_tree,negative=negatives,testReports=reports)); b.atomic_json(evidence/'receipt.json',dict(passed=True,results=results,commands=commands))
        print('Native preset validation passed. Evidence: '+str(evidence)+'; retained fixtures: '+str(run)); return 0
    except Exception as exc:
        b.atomic_json(evidence/'receipt.json',dict(passed=False,error=str(exc),results=results,commands=commands)); print(str(exc)+'\nEvidence: '+str(evidence)+'; retained fixtures: '+str(run),file=sys.stderr); return 1
if __name__=='__main__': sys.exit(main())

#!/usr/bin/env python3
"""Run verifier failure probes in disposable copies; retain all evidence."""
import argparse
import fnmatch
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
sys.dont_write_bytecode=True

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--only',default='*'); args=parser.parse_args()
    tools=Path(__file__).resolve().parent; root=tools.parent
    spec=importlib.util.spec_from_file_location('project_gate',tools/'verify_linux.py'); gate=importlib.util.module_from_spec(spec); spec.loader.exec_module(gate)
    work=Path(tempfile.mkdtemp(prefix='ba-godot-selftest-')); cases=failures=0
    for expectation in ('fails','passes'):
        for case in sorted((tools/'verify_probes'/expectation).iterdir()):
            name=expectation+'/'+case.name
            if not case.is_dir() or not fnmatch.fnmatchcase(name,args.only): continue
            cases+=1; copy=work/(expectation+'-'+case.name)
            def ignored(directory,names):
                return [n for n in names if n in ('.git','.godot','dist','.test-results','__pycache__')]
            for directory,dirs,files in os.walk(root,followlinks=False):
                for entry in dirs+files:
                    if (Path(directory)/entry).is_symlink(): raise ValueError('Self-test refuses linked project paths')
                dirs[:]=[d for d in dirs if d not in ignored(directory,dirs)]
            shutil.copytree(root,copy,ignore=ignored)
            for file in case.rglob('*'):
                if file.is_symlink(): raise ValueError('Self-test refuses linked probe paths')
                if not file.is_file() or file.name in ('expect.txt','remove.txt'): continue
                relative=file.relative_to(case); target=gate.safe(copy,copy/relative); target.parent.mkdir(parents=True,exist_ok=True); shutil.copyfile(file,target)
            remove=case/'remove.txt'
            if remove.exists():
                targets=[gate.safe(copy,Path(os.path.abspath(copy/line.strip()))) for line in remove.read_text().splitlines() if line.strip()]
                if copy in targets: raise ValueError('Probe cannot remove its copy root')
                for target in targets:
                    if target.is_dir(): shutil.rmtree(target)
                    elif target.exists(): target.unlink()
            result=gate.run_process(['bash',str(copy/'tools/verify.sh')],cwd=copy,check=False,timeout=900); Path(str(copy)+'.log').write_text(result.stdout)
            ok=(result.returncode==0)==(expectation=='passes')
            if expectation=='fails': ok=ok and all(line.strip() in result.stdout for line in (case/'expect.txt').read_text().splitlines() if line.strip())
            print(('PASS ' if ok else 'FAIL ')+name+('' if ok else ': '+result.stdout)); failures+=not ok
    print(f'Godot verifier self-tests: {cases} cases, {failures} failures. Evidence: {work}')
    return 1 if not cases or failures else 0
if __name__=='__main__': sys.exit(main())

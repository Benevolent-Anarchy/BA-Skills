#!/usr/bin/env python3
"""Install canonical Linux skill aliases, preflighting all targets before writes."""
import argparse
import json
from pathlib import Path
import sys


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--skill',choices=['all','ba-bootstrap','ba-integrate','ba-release','ba-crossreview'],default='all')
    p.add_argument('--home',type=Path,default=Path.home())
    p.add_argument('--check-only',action='store_true')
    a=p.parse_args();root=Path(__file__).resolve().parents[1]
    names=['ba-bootstrap','ba-integrate','ba-release','ba-crossreview'] if a.skill=='all' else [a.skill]
    selected=[]
    for name in names:
        source=(root/'skills'/name).resolve(strict=True)
        if not (source/'SKILL.md').is_file():raise RuntimeError('Missing skill source: '+str(source))
        for alias in ('.agents','.claude'):
            target=a.home.absolute()/alias/'skills'/name
            if target.is_symlink():
                if target.resolve()!=source:raise RuntimeError('Conflicting link preserved: '+str(target))
                status='installed'
            elif target.exists():raise RuntimeError('Conflicting path preserved: '+str(target))
            else:status='would-install' if a.check_only else 'installed'
            parent=target.parent
            while not parent.exists():parent=parent.parent
            if not parent.is_dir():raise RuntimeError('Parent is not a directory: '+str(parent))
            selected.append((source,target,status,name))
    # Sources and all targets were validated before creating any directories or aliases.
    created=[]
    try:
        if not a.check_only:
            for source,target,_,_ in selected:
                if not target.is_symlink():
                    target.parent.mkdir(parents=True,exist_ok=True);target.symlink_to(source,target_is_directory=True);created.append(target)
    except Exception:
        for target in reversed(created):target.unlink()
        raise
    print(json.dumps([dict(skill=name,source=str(source),target=str(target),status=status) for source,target,status,name in selected]))

if __name__=='__main__':
    try:main()
    except Exception as e:print(json.dumps({'error':str(e)}));sys.exit(1)

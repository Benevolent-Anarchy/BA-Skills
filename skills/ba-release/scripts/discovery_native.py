#!/usr/bin/env python3
"""Inspect installed agent inventories over bounded stdio control protocols."""
import argparse
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import sys
import time
from release_native import ReleaseError, Cancellation, install_cancellation_handlers, terminate_process_group

class Inventory:
    def __init__(self,command,directory,timeout):
        executable=shutil.which(command[0])
        if not executable:raise ReleaseError('Agent executable is missing.')
        self.process=subprocess.Popen([executable,*command[1:]],cwd=directory,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        self.timeout=timeout;self.buffer=b'';self.selector=selectors.DefaultSelector();self.selector.register(self.process.stdout,selectors.EVENT_READ)
    def send(self,message):
        try:self.process.stdin.write((json.dumps(message)+'\n').encode());self.process.stdin.flush()
        except (BrokenPipeError,OSError):raise ReleaseError('Agent discovery client closed before inventory.') from None
    def receive(self,matches):
        deadline=time.monotonic()+self.timeout
        while True:
            while b'\n' in self.buffer:
                line,self.buffer=self.buffer.split(b'\n',1)
                try:message=json.loads(line)
                except (ValueError,UnicodeDecodeError):continue
                if isinstance(message,dict) and matches(message):return message
            remaining=deadline-time.monotonic()
            if remaining<=0 or not self.selector.select(max(remaining,0)):raise ReleaseError('Agent discovery inventory timed out.')
            data=os.read(self.process.stdout.fileno(),65536)
            if not data:raise ReleaseError('Agent discovery client closed before inventory.')
            self.buffer+=data
            if len(self.buffer)>16*1024*1024:raise ReleaseError('Agent discovery response exceeded inventory limit.')
    def close(self):
        self.selector.close()
        terminate_process_group(self.process,grace=max(.05,min(self.timeout,.2)))

def discover(directory,timeout=30):
    results=[];errors=[]
    for agent in ['codex','claude']:
        inventory=None
        try:
            command=['codex','app-server','--stdio'] if agent=='codex' else ['claude','-p','--input-format','stream-json','--output-format','stream-json','--verbose','--no-session-persistence','--permission-mode','dontAsk']
            inventory=Inventory(command,directory,timeout)
            if agent=='codex':
                inventory.send({'id':1,'method':'initialize','params':{'clientInfo':{'name':'ba-release-discovery','version':'1.0'}}});initial=inventory.receive(lambda m:m.get('id')==1)
                if 'error' in initial:raise ReleaseError('Codex initialization failed.')
                inventory.send({'method':'initialized','params':{}});inventory.send({'id':2,'method':'skills/list','params':{'cwds':[str(directory)],'forceReload':True}});response=inventory.receive(lambda m:m.get('id')==2)
                if 'error' in response:raise ReleaseError('Codex skills/list failed.')
                skills=[s for group in response.get('result',{}).get('data',[]) for s in group.get('skills',[]) if s.get('name')=='ba-release']
                if len(skills)!=1 or not skills[0].get('enabled'):raise ReleaseError('Codex must discover exactly one enabled ba-release skill.')
                results.append({'agent':agent,'discovered':True,'path':skills[0].get('path'),'scope':skills[0].get('scope')})
            else:
                inventory.send({'type':'control_request','request_id':'ba-release-discovery','request':{'subtype':'initialize'}});response=inventory.receive(lambda m:m.get('type')=='control_response' and m.get('response',{}).get('request_id')=='ba-release-discovery')['response']
                if response.get('subtype')!='success':raise ReleaseError('Claude inventory initialization failed.')
                skills=[s for s in response.get('response',{}).get('commands',[]) if s.get('name')=='ba-release']
                if len(skills)!=1:raise ReleaseError('Claude must discover exactly one ba-release command.')
                results.append({'agent':agent,'discovered':True,'command':skills[0]['name'],'description':skills[0].get('description')})
        except Cancellation:raise
        except (ReleaseError,OSError,KeyError,TypeError):errors.append(agent+': inventory failed, unavailable or timed out; inspect its installed skill connection.')
        finally:
            if inventory:inventory.close()
    return {'results':results,'errors':errors}

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--directory',default=str(Path(__file__).resolve().parents[3]));parser.add_argument('--timeout-seconds',type=float,default=30)
    args=parser.parse_args()
    if not 0<args.timeout_seconds<=60:parser.error('timeout must be above zero and at most 60 seconds')
    result=discover(Path(args.directory).resolve(),args.timeout_seconds);print(json.dumps(result,indent=2));return 1 if result['errors'] else 0

if __name__=='__main__':
    install_cancellation_handlers()
    try:sys.exit(main())
    except ReleaseError as error:
        print(json.dumps({'results':[],'errors':[str(error)]}));sys.exit(1)

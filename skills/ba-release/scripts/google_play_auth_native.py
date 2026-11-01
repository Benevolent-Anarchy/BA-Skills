#!/usr/bin/env python3
"""Run exactly one explicit command with a short-lived keyless Play token."""
import argparse
import json
import os
import sys
from release_native import ReleaseError, with_google_play_token, run, install_cancellation_handlers

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--account',required=True)
    parser.add_argument('--service-account',required=True)
    parser.add_argument('--gcloud-config-directory',required=True)
    parser.add_argument('--gcloud-executable',default='gcloud')
    parser.add_argument('command',nargs=argparse.REMAINDER)
    args=parser.parse_args();command=args.command
    if command and command[0]=='--':command=command[1:]
    if not command:parser.error('An explicit action command after -- is required.')
    def action():
        # The native release owns separate tool groups and needs its own TERM
        # grace plus time to journal uncertainty before this wrapper escalates.
        code,output=run(command[0],command[1:],cwd=os.getcwd(),cleanup_grace=5)
        print(output,end='')
        return code
    try:
        return with_google_play_token(args.account,args.service_account,args.gcloud_config_directory,
                                     action,args.gcloud_executable)
    except (ReleaseError,OSError) as exc:
        print(json.dumps({'error':str(exc) if isinstance(exc,ReleaseError) else 'Authorized action could not start.'}));return 1

if __name__=='__main__':
    install_cancellation_handlers()
    sys.exit(main())

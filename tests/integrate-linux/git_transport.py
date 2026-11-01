#!/usr/bin/env python3
"""Route fixture Git transport locally without altering URL identity queries."""
import os
import sys

args = sys.argv[1:]
index = 0
while index < len(args) and args[index].startswith('-'):
    index += 2 if args[index] in ('-C', '-c', '--git-dir', '--work-tree') else 1
command = args[index] if index < len(args) else None
remote = os.environ.get('FIXTURE_REMOTE')
transport = []
if remote and command in ('push', 'fetch', 'ls-remote'):
    transport = ['-c', f'url.{remote}.insteadOf=https://github.com/test/repo.git']
real_git = os.environ['FIXTURE_REAL_GIT']
os.execv(real_git, [real_git, *transport, *args])

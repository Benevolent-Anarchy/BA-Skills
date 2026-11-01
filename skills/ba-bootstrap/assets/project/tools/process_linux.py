"""Bounded Linux command execution with cancellation propagation to owned processes."""
import contextlib
import os
from pathlib import Path
import signal
import subprocess
import threading

class ProcessCancelled(RuntimeError):
    pass

@contextlib.contextmanager
def cancellation_handlers():
    """Convert termination into an exception while a command has cleanup obligations."""
    if threading.current_thread() is not threading.main_thread():
        yield
        return
    previous={sig:signal.getsignal(sig) for sig in (signal.SIGTERM,signal.SIGINT)}
    def cancelled(sig,frame):
        raise ProcessCancelled('Process cancelled by '+signal.Signals(sig).name)
    try:
        for sig in previous: signal.signal(sig,cancelled)
        yield
    finally:
        for sig,handler in previous.items(): signal.signal(sig,handler)

@contextlib.contextmanager
def uninterrupted_cleanup():
    previous={}
    if threading.current_thread() is threading.main_thread():
        previous={sig:signal.getsignal(sig) for sig in (signal.SIGTERM,signal.SIGINT)}
        for sig in previous: signal.signal(sig,signal.SIG_IGN)
    try: yield
    finally:
        for sig,handler in previous.items(): signal.signal(sig,handler)

def process_identity(pid):
    try:
        # starttime prevents a recycled PID from becoming cleanup authority.
        tail=Path(f'/proc/{pid}/stat').read_text().rsplit(') ',1)[1].split()
        return (int(tail[1]),int(tail[2]),tail[19])  # parent, process group, starttime
    except (FileNotFoundError,ProcessLookupError,PermissionError,ValueError,IndexError):
        return None

def descendants(pid):
    entries={}
    for path in Path('/proc').iterdir():
        if path.name.isdigit():
            identity=process_identity(int(path.name))
            if identity: entries[int(path.name)]=identity
    owned={pid}; changed=True
    while changed:
        additions={child for child,identity in entries.items() if identity[0] in owned}-owned
        changed=bool(additions); owned.update(additions)
    return {child:entries[child] for child in owned if child in entries}

def signal_group(group,sig):
    try: os.killpg(group,sig)
    except ProcessLookupError: pass

def stop(child,grace_seconds):
    # Native verification may itself run another isolated process group (e.g. Godot).
    # First let that intermediary receive TERM and propagate cancellation. Retain the
    # observed descendants as a fallback if it fails to finish its own cleanup.
    observed=descendants(child.pid)
    signal_group(child.pid,signal.SIGTERM)
    try:
        child.communicate(timeout=grace_seconds)
    except subprocess.TimeoutExpired:
        pass
    finally:
        groups={child.pid}
        for pid,identity in observed.items():
            current=process_identity(pid)
            if current and current[2]==identity[2]: groups.add(current[1])
        for group in groups: signal_group(group,signal.SIGKILL)
    try:
        child.communicate(timeout=grace_seconds)
    except subprocess.TimeoutExpired:
        # A detached process must not make cancellation wait indefinitely on its pipe.
        if child.stdout: child.stdout.close()
        if child.stderr: child.stderr.close()
        child.wait(timeout=grace_seconds)

def run(args,cwd=None,env=None,check=True,timeout=900,grace_seconds=1.0):
    with cancellation_handlers():
        child=subprocess.Popen([str(a) for a in args],cwd=cwd,env={**os.environ,**(env or {})},stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
        try:
            output,_=child.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            with uninterrupted_cleanup(): stop(child,grace_seconds)
            raise RuntimeError('Process timed out: '+str(args[0])) from None
        except BaseException:
            # The group remains ours after its leader exits: a grandchild can still
            # hold stdout open, so child.poll() is never a reason to skip cleanup.
            with uninterrupted_cleanup(): stop(child,grace_seconds)
            raise
    result=subprocess.CompletedProcess(args,child.returncode,output)
    if check and result.returncode:
        raise RuntimeError(f'{args[0]} failed (exit {result.returncode}): {result.stdout}')
    return result

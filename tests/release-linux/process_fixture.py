"""Read Linux process state without a /proc disappearance race."""
import errno
from pathlib import Path

def process_stopped(pid):
    try:return (Path('/proc')/str(pid)/'stat').read_text().split()[2]=='Z'
    except OSError as error:
        if error.errno in [errno.ENOENT,errno.ESRCH]:return True
        raise

import ctypes
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time

binary = Path(sys.argv[2]).resolve()
action = sys.argv[1]
label = 'com.github.shivexe.siri-flow-guard'
target = f'gui/{os.getuid()}/{label}'
agent = Path.home() / 'Library' / 'LaunchAgents' / f'{label}.plist'
lock = Path(tempfile.gettempdir()) / f'flow-siri-guard-{os.getuid()}.lock'
log = binary.parents[3] / 'guard.log'


def running_pid():
    try:
        pid = int(lock.read_text().strip())
        if pid <= 1:
            return None
        buffer = ctypes.create_string_buffer(4096)
        libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
        libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        libproc.proc_pidpath.restype = ctypes.c_int
        if libproc.proc_pidpath(pid, buffer, len(buffer)) <= 0:
            return None
        if Path(os.fsdecode(buffer.value)).resolve() != binary:
            return None
        return pid
    except (OSError, ValueError):
        return None


def loaded():
    return subprocess.run(['launchctl', 'print', target], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0


def recent_log():
    try:
        return '\n'.join(log.read_text(errors='replace').splitlines()[-8:])
    except OSError:
        return ''


if action == 'status':
    pid = running_pid()
    print(f'Guard: running (PID {pid})' if pid else 'Guard: stopped', flush=True)
    print(f'Start at login: {"enabled" if agent.exists() else "disabled"}', flush=True)
    sys.exit(subprocess.call([str(binary), '--status']))

if action == 'stop':
    pid = running_pid()
    if loaded():
        result = subprocess.run(['launchctl', 'bootout', target], capture_output=True, text=True)
        if result.returncode:
            print(result.stderr.strip() or 'Could not stop login service.', file=sys.stderr)
            sys.exit(result.returncode)
    elif pid:
        os.kill(pid, signal.SIGTERM)
    agent.unlink(missing_ok=True)
    for _ in range(60):
        if running_pid() is None:
            print('Guard stopped; start at login disabled.')
            sys.exit(0)
        time.sleep(0.05)
    print('Guard has not exited; no force-kill was sent.', file=sys.stderr)
    sys.exit(1)

if action == 'start':
    if running_pid() and not loaded():
        print('A foreground or older detached guard is running. Stop it before enabling the login service.', file=sys.stderr)
        sys.exit(1)
    agent.parent.mkdir(parents=True, exist_ok=True)
    data = {
        'Label': label,
        'ProgramArguments': [str(binary), '--run'],
        'RunAtLoad': True,
        'KeepAlive': True,
        'ThrottleInterval': 10,
        'ProcessType': 'Interactive',
        'StandardOutPath': str(log),
        'StandardErrorPath': str(log),
    }
    expected = plistlib.dumps(data)
    if agent.exists() and agent.read_bytes() != expected:
        if loaded():
            result = subprocess.run(['launchctl', 'bootout', target], capture_output=True, text=True)
            if result.returncode:
                print(result.stderr.strip() or 'Could not replace login service.', file=sys.stderr)
                sys.exit(result.returncode)
        agent.unlink()
    if not agent.exists():
        fd = os.open(agent, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(expected)
    if not loaded():
        result = subprocess.run(['launchctl', 'bootstrap', f'gui/{os.getuid()}', str(agent)],
                                capture_output=True, text=True)
        if result.returncode:
            print(result.stderr.strip() or 'Could not start login service.', file=sys.stderr)
            agent.unlink(missing_ok=True)
            sys.exit(result.returncode)
    deadline = time.monotonic() + 5
    while running_pid() is None and time.monotonic() < deadline:
        time.sleep(0.05)
    pid = running_pid()
    if pid is None:
        subprocess.run(['launchctl', 'bootout', target], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        agent.unlink(missing_ok=True)
        print('Guard did not start. Recent diagnostics:\n' + recent_log(), file=sys.stderr)
        sys.exit(1)
    print(f'Guard running (PID {pid}); starts at login. Log: {log}')
    sys.exit(0)

print('Expected start, stop, or status.', file=sys.stderr)
sys.exit(64)

#!/usr/bin/env python3
"""Measure direct Mac-to-Linux encrypted process echo; requires prebuilt Swift tests.

Run after coordinating with other checkout users:
    python3 scripts/benchmark-remote.py
No builds, installations, firewall edits or existing Koi sessions are involved.
SSH carries setup/credentials only; timed input/output uses direct UDP.
"""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import select
import shlex
import signal
import subprocess
import sys
import tempfile
import time


# This fixture owns one private directory, foreground server and pane. Keeping
# SSH stdin open holds it alive; EOF, signals or a watchdog trigger cleanup.
REMOTE_FIXTURE = r'''
import json, os, select, shlex, shutil, signal, socket, struct, subprocess, sys, tempfile, time


def interrupted(signum, frame):
    """Unwind through the same cleanup path on SSH/session termination."""
    raise SystemExit(1)


def receive(sock, count):
    """Read an exact bounded frame; EOF is always a fixture failure."""
    result = bytearray()
    while len(result) < count:
        part = sock.recv(count - len(result))
        if not part:
            raise RuntimeError('fixture socket closed')
        result.extend(part)
    return result


def request(kind, body, expected):
    """Use only this fixture's Unix socket, never CLI auto-start/discovery."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(5)
        sock.connect(os.path.join(directory, 'server-6.sock'))
        payload = json.dumps(body).encode() if body is not None else b''
        sock.sendall(struct.pack('<BI', kind, len(payload)) + payload)
        header = receive(sock, 5)
        response, size = struct.unpack('<BI', header)
        if response != expected or size > 65536:
            raise RuntimeError('unexpected fixture frame')
        return json.loads(receive(sock, size))


os.umask(0o077)
for sig in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT, signal.SIGALRM):
    signal.signal(sig, interrupted)
directory = tempfile.mkdtemp(prefix='koi-echo-', dir='/tmp')
server = None
pane = None
attachment = None
try:
    # Remote lifetime is bounded even if SSH stops delivering data or EOF.
    signal.alarm(180)
    size = int(sys.argv[1])
    if not 0 < size <= 32 * 1024 * 1024:
        raise RuntimeError('invalid fixture binary size')
    data = sys.stdin.buffer.read(size)
    if len(data) != size:
        raise RuntimeError('incomplete fixture upload')
    binary = os.path.join(directory, 'koi')
    with open(binary, 'xb') as output:
        output.write(data)
    os.chmod(binary, 0o700)
    environment = dict(os.environ, KOI_DIR=directory, HOME=directory,
                       ZDOTDIR=directory, XDG_CONFIG_HOME=directory)
    server = subprocess.Popen([binary, '--server'], env=environment,
                              stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
    deadline = time.monotonic() + 10
    while True:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
            probe.settimeout(0.2)
            try:
                probe.connect(os.path.join(directory, 'server-6.sock'))
                break
            except OSError:
                if server.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError('private server startup failed')
        time.sleep(0.02)
    # Explicit /bin/sh keeps the user's login-shell syntax out of the fixture.
    echo = ("stty -echo; printf 'benchmark-ready\\n'; "
            "while IFS= read -r line; do printf 'echo:%s:done\\n' \"$line\"; done")
    made = request(7, {'op': 'newTab', 'cwd': directory,
                       'startup': 'exec /bin/sh -c ' + shlex.quote(echo)}, 70)
    pane = made.get('pane')
    if not pane or made.get('error'):
        raise RuntimeError('private pane creation failed')
    # Keep a second attachment solely to confirm the server reaps its child:
    # .exited is sent only after pane cleanup, not merely tree removal.
    attachment = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    attachment.settimeout(5)
    attachment.connect(os.path.join(directory, 'server-6.sock'))
    payload = json.dumps(dict(pane=pane, cols=100, rows=24, cellWidth=8, cellHeight=16)).encode()
    attachment.sendall(struct.pack('<BI', 1, len(payload)) + payload)
    offer = request(8, None, 71)
    # stdout is a pipe consumed by the Mac parent, never a terminal/log.
    print(json.dumps(dict(offer, pane=pane)), flush=True)
    select.select([sys.stdin], [], [], 150)
finally:
    signal.alarm(0)
    # Ignore repeated signals while closing only the pane/server we created.
    for sig in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, signal.SIG_IGN)
    cleanup_ok = True
    if pane:
        try:
            request(7, {'op': 'closePane', 'pane': pane}, 70)
            deadline = time.monotonic() + 5
            while attachment is not None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise RuntimeError('pane cleanup deadline')
                attachment.settimeout(remaining)
                kind, size = struct.unpack('<BI', receive(attachment, 5))
                if size > 64 * 1024 * 1024:
                    raise RuntimeError('oversized pane frame')
                receive(attachment, size)
                if kind == 68:
                    break
            if attachment is None:
                cleanup_ok = False
        except Exception:
            cleanup_ok = False
    if attachment is not None:
        attachment.close()
    if server is not None:
        if server.poll() is None:
            server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait(timeout=5)
    shutil.rmtree(directory)
    if not cleanup_ok:
        raise RuntimeError('pane cleanup unconfirmed')
'''


def read_offer(process):
    """Read one small credential record without logging it or hanging on SSH."""
    deadline = time.monotonic() + 25
    record = bytearray()
    while time.monotonic() < deadline:
        if select.select([process.stdout], [], [], min(1, max(0, deadline - time.monotonic())))[0]:
            chunk = os.read(process.stdout.fileno(), 4096)
            if not chunk:
                break
            record.extend(chunk)
            if len(record) > 4096:
                break
            if b'\n' in record:
                return json.loads(record.split(b'\n', 1)[0])
    raise RuntimeError('SSH fixture did not supply a bounded offer')


def interrupted(signum, frame):
    """Let termination unwind owned SSH and temporary-file scopes."""
    raise KeyboardInterrupt


def main():
    """Hold the shared build lock, own SSH lifetime and run only the opt-in test."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', default=str(Path(__file__).resolve().parent.parent / 'build/core/koi-linux-x86_64'),
                        help='local Linux binary copied into the disposable remote fixture')
    parser.add_argument('--ssh-host', default='server', help='SSH host alias for the Linux test host')
    parser.add_argument('--udp-host', help='direct UDP host override; defaults to ssh -G server hostname')
    args = parser.parse_args()
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    if sys.platform != 'darwin':
        raise RuntimeError('run this benchmark on the Mac')
    root = Path(__file__).resolve().parent.parent
    key = hashlib.sha256(os.path.realpath(root).encode()).hexdigest()[:24]
    lock_path = f'/tmp/koi-test-build-{os.getuid()}-{key}.lock'
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'r+') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('checkout tests/build are active; coordinate before running') from None
        config = subprocess.run(['ssh', '-G', args.ssh_host], check=True, capture_output=True,
                                text=True, timeout=10).stdout
        hostname = next((line.split(None, 1)[1] for line in config.splitlines()
                         if line.startswith('hostname ')), None)
        host = args.udp_host or hostname
        if not host or host in ('localhost', '127.0.0.1', '::1'):
            raise RuntimeError('supply a directly reachable server with --udp-host')
        binary = Path(args.binary)
        if not 0 < binary.stat().st_size <= 32 * 1024 * 1024:
            raise RuntimeError('invalid local Linux binary size')
        data = binary.read_bytes()
        remote = 'python3 -u -c ' + shlex.quote(REMOTE_FIXTURE) + ' ' + str(len(data))
        ssh = subprocess.Popen(['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
                                '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=2',
                                args.ssh_host, remote], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL)
        try:
            # Bound upload time as well as setup and echo; leave stdin open for ownership.
            os.set_blocking(ssh.stdin.fileno(), False)
            deadline = time.monotonic() + 25
            offset = 0
            while offset < len(data):
                if time.monotonic() >= deadline:
                    raise RuntimeError('fixture upload timed out')
                if select.select([], [ssh.stdin], [], 1)[1]:
                    try:
                        offset += os.write(ssh.stdin.fileno(), data[offset:offset + 65536])
                    except BlockingIOError:
                        pass
            offer = read_offer(ssh)
            offer['host'] = host
            with tempfile.TemporaryDirectory(prefix='koi-echo-') as directory:
                path = Path(directory) / 'offer.json'
                # The parent is private too; credentials never enter argv/env.
                private_fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(private_fd, 'w') as output:
                    json.dump(offer, output)
                environment = dict(os.environ, KOI_REMOTE_BENCHMARK='1',
                                   KOI_REMOTE_BENCHMARK_FILE=str(path))
                runner = subprocess.Popen(['swift', 'test', '--skip-build', '--filter',
                                           'actualRemoteProcessEchoRoundTrip'], cwd=root,
                                          env=environment, stdout=subprocess.PIPE,
                                          stderr=subprocess.PIPE, text=True, start_new_session=True)
                try:
                    stdout, _ = runner.communicate(timeout=110)
                finally:
                    if runner.returncode is None:
                        # The test executable can be a child of SwiftPM. Own a
                        # process group so timeout/interrupt stops both of them.
                        os.killpg(runner.pid, signal.SIGKILL)
                        runner.communicate(timeout=5)
                # Only forward the credential-free measurement, never raw diagnostics.
                measurements = [line for line in stdout.splitlines()
                                if line.startswith('REMOTE_ECHO_COMPLETE ')]
                if runner.returncode or len(measurements) != 1:
                    raise RuntimeError('benchmark failed or prebuilt test is missing; coordinate a focused test build')
                print(measurements[0])
        finally:
            ssh.stdin.close()
            try:
                status = ssh.wait(timeout=15)
            except subprocess.TimeoutExpired:
                ssh.terminate()
                try:
                    ssh.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    ssh.kill()
                    ssh.wait(timeout=5)
                raise RuntimeError('SSH cleanup unconfirmed; remote watchdog expires within 180 seconds') from None
            if status:
                raise RuntimeError('remote fixture failed; cleanup could not be confirmed')


if __name__ == '__main__':
    try:
        main()
    except (Exception, KeyboardInterrupt) as error:
        # Subprocess exceptions can include captured credential data; never print them.
        message = str(error) if isinstance(error, RuntimeError) else 'benchmark interrupted or setup failed'
        print(message, file=sys.stderr)
        sys.exit(1)

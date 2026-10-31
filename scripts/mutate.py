#!/usr/bin/env python3
"""Plant known bugs in a copy of the core and check that the tests notice.

Line counts say little about a suite; whether it fails when behavior breaks
says a lot. Each mutation below breaks one guarantee Koi relies on: who may
connect, which directories are trusted, when a dead peer is dropped, when the
server exits, and the ceilings on frames, input, panes and the log. The tests
should fail for every one. A mutation that survives is a guarantee nothing
checks, so add the test, not an entry here.

    ./x mutate [--app] [NAME_SUBSTRING]

By default the core (Zig) mutations run, about half a minute each. `--app` runs
the Swift app's instead, through the hosted tests CI runs, a few minutes each.
Works in a copy-on-write clone beside the checkout (APFS `cp -c`, else a plain
copy), so the working tree is never edited. Exits 1 if any mutation survives.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# (name, file, text to replace, replacement); the app ones follow. Each `old` must appear exactly
# once; tests/scripts/mutationTests.py keeps the list from rotting. A mutant
# must still compile, so it keeps every name it replaces in use (an unused
# parameter or unreachable code is a compile error, reported as INVALID).
MUTATIONS = [
    ("a peer of another user is admitted", "src/core/server.zig",
     "return sys.peerIsUser(fd, uid) and !self.connectionsFull();",
     "return (sys.peerIsUser(fd, uid) or true) and !self.connectionsFull();"),
    ("connections are never refused", "src/core/server.zig",
     "if (open < max_connections) return false;",
     "if (true) return false;"),
    ("panes are never refused", "src/core/server.zig",
     "return self.panes.items.len < max_panes;",
     "return true;"),
    ("the server never exits when idle", "src/core/server.zig",
     "sys.elapsedMillis() - self.idle_since > idle_exit_ms;",
     "sys.elapsedMillis() - self.idle_since > idle_exit_ms and false;"),
    ("the log never rolls", "src/core/server.zig",
     "if (info.size < limit) return false;",
     "if (info.size <= limit +| (1 << 60)) return false;"),
    ("a directory's mode is not checked", "src/core/paths.zig",
     "if (st.uid != sys.c.getuid() or st.mode & 0o777 != 0o700) return error.UnsafeDirectory;",
     "if (st.uid != sys.c.getuid()) return error.UnsafeDirectory;"),
    ("a world-writable ancestor is accepted", "src/core/paths.zig",
     "if (mode & 0o002 != 0 and !sticky_root) return false;",
     "if (false) return false;"),
    ("a silent link peer never expires", "src/core/link.zig",
     "if (now - self.last_received >= 10_000) {",
     "if (now - self.last_received >= 10_000_000) {"),
    ("an oversized frame is accepted", "src/core/wire.zig",
     "if (len > max_payload) return error.Protocol;",
     "if (false) return error.Protocol;"),
    ("held input is unbounded", "src/core/pane.zig",
     "const count = @min(bytes.len - off, max_held_input - self.held_input.items.len);",
     "const count = bytes.len - off;"),
]


APP_MUTATIONS = [
    ("an oversized frame is accepted by the app", "src/app/wire.swift",
     "guard len <= Self.maxPayload, let kind = Wire.Kind(rawValue: buffer[start]) else {",
     "guard len <= Self.maxPayload || true, let kind = Wire.Kind(rawValue: buffer[start]) else {"),
    ("a long socket path is not moved", "src/app/paths.swift",
     "candidate.appendingPathComponent(socketName).path.utf8.count < 100",
     "candidate.appendingPathComponent(socketName).path.utf8.count < 100_000"),
    ("an app directory's mode is not checked", "src/app/paths.swift",
     "guard info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {",
     "guard info.st_uid == getuid() else {"),
    ("an app world-writable ancestor is accepted", "src/app/paths.swift",
     "info.st_mode & 0o022 == 0 || (info.st_uid == 0 && info.st_mode & 0o1000 != 0)",
     "true || (info.st_uid == 0 && info.st_mode & 0o1000 != 0)"),
    ("a changed remote server is not reinstalled", "src/app/remote.swift",
     "if lines.dropFirst().first != hash {",
     "if lines.dropFirst().first != hash && false {"),
    ("the app's write queue is unbounded", "src/app/transport.swift",
     "guard queuedWrites < 4096, bytes.count <= maxQueued - queued else { return false }",
     "guard queuedWrites < 4096_000, bytes.count <= maxQueued - queued else { return false }"),
    ("a server of another protocol version is accepted", "src/app/connections.swift",
     "if let version = result.protocolVersion, version != Wire.version {",
     "if let version = result.protocolVersion, version != Wire.version && false {"),
]


def classify(returncode, output):
    """'survived' when every test still passed, 'caught' when a test failed,
    'invalid' when the mutant did not compile or nothing ran."""
    if returncode == 0:
        return "survived"
    if "\u2718" in output or re.search(r"error: '", output):
        return "caught"
    return "invalid"


def clone(destination):
    """A copy-on-write clone where the filesystem supports it."""
    flags = ["-cR"] if sys.platform == "darwin" else ["-a"]
    subprocess.run(["cp", *flags, str(ROOT), str(destination)], check=True)


def run_tests(tree, app):
    state = tempfile.mkdtemp(prefix="koi-mutate-")
    try:
        env = dict(os.environ, KOI_DIR=state)
        env.pop("KOI_SERVER_BIN", None)
        command = ["./x", "testa"] if app else ["zig", "build", "-j2", "test", "--summary", "all"]
        proc = subprocess.run(command, cwd=tree, env=env, capture_output=True, text=True)
        return proc.returncode, proc.stdout + proc.stderr
    finally:
        shutil.rmtree(state, ignore_errors=True)


def main(argv):
    app = "--app" in argv
    names = [a for a in argv if a != "--app"]
    mutations = APP_MUTATIONS if app else MUTATIONS
    wanted = [m for m in mutations if not names or any(a in m[0] for a in names)]
    if not wanted:
        print("no mutation matches", file=sys.stderr)
        return 2
    work = Path(tempfile.mkdtemp(prefix="koi-mutants-", dir=ROOT.parent))
    tree = work / "tree"
    try:
        clone(tree)
        code, output = run_tests(tree, app)
        if code != 0:
            # A timing-sensitive test can fail on a busy machine; look once more
            # before blaming the tree, and show what failed rather than the tail.
            code, output = run_tests(tree, app)
        if code != 0:
            failures = [l for l in output.splitlines() if "\u2718" in l or "error:" in l]
            print("The unmodified tree already fails its tests; fix that first.\n" + "\n".join(failures[:12]))
            return 2
        survivors = 0
        for name, relative, old, new in wanted:
            path = tree / relative
            original = path.read_text()
            if original.count(old) != 1:
                print(f"INVALID   {name}: target text not found exactly once in {relative}")
                survivors += 1
                continue
            path.write_text(original.replace(old, new))
            started = time.time()
            try:
                code, output = run_tests(tree, app)
            finally:
                path.write_text(original)
            verdict = classify(code, output)
            survivors += verdict != "caught"
            print(f"{verdict.upper():9} {name}  ({time.time() - started:.0f}s)", flush=True)
        print(f"\n{len(wanted) - survivors} of {len(wanted)} caught")
        return 1 if survivors else 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

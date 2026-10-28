#!/bin/sh
# Exercise test-run isolation and cleanup using only disposable mock servers.
set -eu
repo=$(cd "$(dirname "$0")/../.." && pwd)
fixture=$(mktemp -d /tmp/kt-XXXXXXXX)
cleanup() {
  if [ -d "$fixture/records" ]; then
    for pidfile in "$fixture"/records/*.pid; do
      [ -f "$pidfile" ] || continue
      kill "$(cat "$pidfile")" 2>/dev/null || true
    done
  fi
  rm -rf "$fixture"
}
trap cleanup EXIT
mkdir -p "$fixture/repo/scripts" "$fixture/repo/zig-out/bin" "$fixture/bin" "$fixture/records" "$fixture/tmp"
cp "$repo/scripts/koid" "$fixture/repo/scripts/koid"
cat > "$fixture/server.py" <<'PY'
#!/usr/bin/python3
import os, socket, sys, time
assert sys.argv[1:] == ['--server']
path = os.environ['KOI_DIR']
s = socket.socket(socket.AF_UNIX)
s.bind(path + '/server-mock.sock')
with open(path + '/pid', 'w') as f:
    f.write(str(os.getpid()))
while True:
    time.sleep(1)
PY
chmod +x "$fixture/server.py"
cat > "$fixture/repo/scripts/build-ghostty-vt.sh" <<'MOCK'
#!/bin/sh
set -eu
active="$RECORDS/build-active-${REPO##*/}"
mkdir "$active" || { touch "$RECORDS/build-overlap"; exit 1; }
trap 'rmdir "$active"' EXIT
printf '%s ghostty\n' "$RUN" >> "$RECORDS/build-events-${REPO##*/}"
sleep 0.2
[ "${FAIL_PREP:-}" != ghostty ]
MOCK
cat > "$fixture/repo/scripts/build-core.sh" <<'MOCK'
#!/bin/sh
set -eu
active="$RECORDS/build-active-${REPO##*/}"
mkdir "$active" || { touch "$RECORDS/build-overlap"; exit 1; }
trap 'rmdir "$active"' EXIT
printf '%s core\n' "$RUN" >> "$RECORDS/build-events-${REPO##*/}"
sleep 0.2
cp "$SERVER" "$REPO/zig-out/bin/koi"
printf '\n# built for %s\n' "$RUN" >> "$REPO/zig-out/bin/koi"
MOCK
chmod +x "$fixture/repo/scripts/build-ghostty-vt.sh" "$fixture/repo/scripts/build-core.sh"
cat > "$fixture/bin/zig" <<'MOCK'
#!/bin/sh
[ "$*" = 'build test' ] || exit 1
printf '%s\n%s\n' "$TMPDIR" "$KOI_DIR" > "$RECORDS/$RUN.zig"
[ "$KOI_TEST_ROOT" = "$TMPDIR" ]
[ "${KOI_SERVER_BIN##*/}" = koi ]
mkdir -p "$KOI_DIR"
"$KOI_SERVER_BIN" --server &
pid=$!
printf '%s\n' "$pid" > "$RECORDS/$RUN.zig.pid"
printf '%s\n' "$KOI_SERVER_BIN" > "$RECORDS/proc-$pid"
while [ ! -f "$KOI_DIR/pid" ]; do sleep 0.02; done
printf '%s\n' "$pid" > "$TMPDIR/server.pid"
[ "${FAIL_STAGE:-}" != zig ] || exit 23
MOCK
cat > "$fixture/bin/swift" <<'MOCK'
#!/bin/sh
[ "$*" = test ] || exit 1
printf '%s\n%s\n' "$TMPDIR" "$KOI_DIR" > "$RECORDS/$RUN.swift"
[ "$KOI_TEST_ROOT" = "$TMPDIR" ]
dir="$TMPDIR/nested/custom"
mkdir -p "$dir"
KOI_DIR="$dir" "$KOI_SERVER_BIN" --server &
pid=$!
printf '%s\n' "$pid" > "$RECORDS/$RUN.swift.pid"
printf '%s\n' "$KOI_SERVER_BIN" > "$RECORDS/proc-$pid"
while [ ! -f "$dir/pid" ]; do sleep 0.02; done
printf '%s\n' "$pid" > "$dir/server.pid"
printf '%s\n' "$KOI_SERVER_BIN" > "$RECORDS/$RUN.binary"
tail -n 1 "$KOI_SERVER_BIN" > "$RECORDS/$RUN.version"
touch "$RECORDS/$RUN.ready"
while [ ! -f "$RECORDS/$RUN.release" ]; do sleep 0.05; done
[ "${FAIL_STAGE:-}" != swift ] || exit 24
MOCK
cat > "$fixture/bin/mktemp" <<'MOCK'
#!/bin/sh
path=$(/usr/bin/mktemp "$@") || exit
printf '%s\n' "$path" > "$RECORDS/$RUN.root"
printf '%s\n' "$path"
MOCK
cat > "$fixture/bin/ps" <<'MOCK'
#!/bin/sh
[ "$1" = -ww ] && [ "$2" = -p ] && [ "$4" = -o ] || exit 1
kill -0 "$3" 2>/dev/null || exit 1
[ -f "$RECORDS/proc-$3" ] || exit 1
printf '%s --server\n' "$(cat "$RECORDS/proc-$3")"
MOCK
chmod +x "$fixture/bin/zig" "$fixture/bin/swift" "$fixture/bin/ps" "$fixture/bin/mktemp"
export PATH="$fixture/bin:$PATH" RECORDS="$fixture/records" SERVER="$fixture/server.py" REPO="$fixture/repo" TMPDIR="$fixture/tmp"
KOI_DIR="$fixture/daily"
export KOI_DIR
mkdir "$KOI_DIR"
wait_file() {
  n=0
  while [ ! -f "$1" ]; do
    n=$((n + 1))
    [ "$n" -lt 200 ] || { echo "timed out waiting for $1" >&2; exit 1; }
    sleep 0.05
  done
}
assert_stopped() {
  pid=$(cat "$1")
  n=0
  while kill -0 "$pid" 2>/dev/null; do
    n=$((n + 1))
    [ "$n" -lt 100 ] || { echo "mock server $pid still running" >&2; exit 1; }
    sleep 0.05
  done
}
# Keep a similarly named foreign directory to detect broad cleanup.
mkdir "$TMPDIR/koi-tests-foreign"
RUN=a "$fixture/repo/scripts/koid" test & a=$!
wait_file "$RECORDS/a.ready"
# A different checkout has its own lock and can run while A is in Swift.
mkdir -p "$fixture/other/scripts" "$fixture/other/zig-out/bin"
cp "$fixture/repo/scripts/koid" "$fixture/repo/scripts/build-ghostty-vt.sh" "$fixture/repo/scripts/build-core.sh" "$fixture/other/scripts/"
RUN=c REPO="$fixture/other" "$fixture/other/scripts/koid" test & c=$!
wait_file "$RECORDS/c.ready"
touch "$RECORDS/c.release"
wait "$c"
assert_stopped "$RECORDS/c.zig.pid"
assert_stopped "$RECORDS/c.swift.pid"
RUN=b "$fixture/repo/scripts/koid" test & b=$!
wait_file "$RECORDS/b.root"
b_root=$(cat "$RECORDS/b.root")
n=0
while [ ! -d "$b_root/tmp" ]; do
  n=$((n + 1))
  [ "$n" -lt 200 ] || exit 1
  sleep 0.05
done
[ ! -e "$RECORDS/b.zig" ]
sleep 0.3
[ ! -e "$RECORDS/b.zig" ]
[ "$(wc -l < "$RECORDS/build-events-repo" | tr -d ' ')" = 2 ]
[ ! -e "$RECORDS/build-overlap" ]
a_tmp=$(sed -n '1p' "$RECORDS/a.zig")
[ "$(sed -n '2p' "$RECORDS/a.zig")" = "${a_tmp%/tmp}/state" ]
cmp "$RECORDS/a.zig" "$RECORDS/a.swift"
[ "$(cat "$RECORDS/a.version")" = '# built for a' ]
[ "$(tail -n 1 "$(cat "$RECORDS/a.binary")")" = '# built for a' ]
# A stale marker naming another live process must not signal it.
mkdir "$fixture/foreign-server"
KOI_DIR="$fixture/foreign-server" "$SERVER" --server & foreign=$!
printf '%s\n' "$foreign" > "$RECORDS/foreign.pid"
printf '%s\n' "$SERVER" > "$RECORDS/proc-$foreign"
mkdir "$a_tmp/stale"
printf '%s\n' "$foreign" > "$a_tmp/stale/server.pid"
touch "$RECORDS/a.release"
wait "$a"
kill -0 "$foreign"
kill "$foreign"
wait "$foreign" || true
[ ! -e "${a_tmp%/tmp}" ]
[ -d "$b_root/tmp" ]
[ -d "$TMPDIR/koi-tests-foreign" ]
[ -d "$KOI_DIR" ]
assert_stopped "$RECORDS/a.zig.pid"
assert_stopped "$RECORDS/a.swift.pid"
wait_file "$RECORDS/b.ready"
b_tmp=$(sed -n '1p' "$RECORDS/b.zig")
[ "$a_tmp" != "$b_tmp" ]
[ "${b_tmp%/tmp}" = "$b_root" ]
[ "$(sed -n '2p' "$RECORDS/b.zig")" = "$b_root/state" ]
cmp "$RECORDS/b.zig" "$RECORDS/b.swift"
[ "$(cat "$RECORDS/a.binary")" != "$(cat "$RECORDS/b.binary")" ]
[ "$(cat "$RECORDS/b.version")" = '# built for b' ]
[ ! -e "$RECORDS/build-overlap" ]
awk 'NR == 1 { if ($0 != "a ghostty") exit 1 }
     NR == 2 { if ($0 != "a core") exit 1 }
     NR == 3 { if ($0 != "b ghostty") exit 1 }
     NR == 4 { if ($0 != "b core") exit 1 }
     END { if (NR != 4) exit 1 }' "$RECORDS/build-events-repo"
kill -0 "$(cat "$RECORDS/b.zig.pid")"
kill -0 "$(cat "$RECORDS/b.swift.pid")"
touch "$RECORDS/b.release"
wait "$b"
[ ! -e "${b_tmp%/tmp}" ]
assert_stopped "$RECORDS/b.zig.pid"
assert_stopped "$RECORDS/b.swift.pid"
# Both early and late test failures must clean up all servers started so far.
status=0
RUN=failzig FAIL_STAGE=zig "$fixture/repo/scripts/koid" test || status=$?
[ "$status" = 23 ]
fail_tmp=$(sed -n '1p' "$RECORDS/failzig.zig")
[ ! -e "${fail_tmp%/tmp}" ]
assert_stopped "$RECORDS/failzig.zig.pid"
touch "$RECORDS/failswift.release"
status=0
RUN=failswift FAIL_STAGE=swift "$fixture/repo/scripts/koid" test || status=$?
[ "$status" = 24 ]
fail_tmp=$(sed -n '1p' "$RECORDS/failswift.zig")
[ ! -e "${fail_tmp%/tmp}" ]
assert_stopped "$RECORDS/failswift.zig.pid"
assert_stopped "$RECORDS/failswift.swift.pid"
# A failed preparation releases the lock for the next invocation.
if RUN=failprep FAIL_PREP=ghostty "$fixture/repo/scripts/koid" test 2>"$RECORDS/failprep.log"; then exit 1; fi
# A signal received while the test command runs also cleans its fixtures.
RUN=term "$fixture/repo/scripts/koid" test & term=$!
wait_file "$RECORDS/term.ready"
term_tmp=$(sed -n '1p' "$RECORDS/term.zig")
kill -TERM "$term"
touch "$RECORDS/term.release"
if wait "$term"; then echo 'TERM unexpectedly succeeded' >&2; exit 1; fi
[ ! -e "${term_tmp%/tmp}" ]
assert_stopped "$RECORDS/term.zig.pid"
assert_stopped "$RECORDS/term.swift.pid"
# A selected alternative binary is copied and used for the fixture regardless
# of the default build, and cleanup does not need its CLI protocol.
cp "$SERVER" "$fixture/alternate"
printf '\n# alternative server\n' >> "$fixture/alternate"
touch "$RECORDS/alternate.release"
RUN=alternate KOI_SERVER_BIN="$fixture/alternate" "$fixture/repo/scripts/koid" test
[ "$(cat "$RECORDS/alternate.version")" = '# alternative server' ]
assert_stopped "$RECORDS/alternate.zig.pid"
assert_stopped "$RECORDS/alternate.swift.pid"
echo 'koid test isolation: passed'

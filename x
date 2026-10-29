#!/bin/sh
# Shared local/CI commands. Checks never install or launch Koi or Koid.
set -eu
cd "$(dirname "$0")"

# List the deliberately small interface; development controls stay in koid.
usage() {
  cat <<'EOF'
usage: ./x [command]
  check        Default: scripts, catalog, full isolated tests, signed bundle
  scripts      Portable script and CI regressions (Python 3, no native builds)
  programs     Application catalog and artwork checks (Python 3)
  test         Full isolated core and Swift suite (Mac with Metal)
  test-core    Core tests only; prepares engine source (Zig)
  test-app     Hosted Swift subset through Koid's isolated runner (Mac)
  bundle       Release bundle and signature verification; never installs
  help         Show this help
EOF
}

task=${1:-check}
if [ "$#" -gt 0 ]; then shift; fi
[ "$#" -eq 0 ] || { usage >&2; exit 2; }
case "$task" in
  check) ./x scripts; ./x programs; ./x test; ./x bundle ;;
  scripts)
    sh tests/scripts/koid-test-isolation.sh
    python3 tests/scripts/buildProvenanceTests.py
    python3 tests/scripts/ciTests.py
    ;;
  programs)
    python3 scripts/check-programs.py
    python3 tests/scripts/programsTests.py
    ;;
  test) exec scripts/koid test ;;
  test-core)
    scripts/build-ghostty-vt.sh --source-only
    KOI_DIR=$(mktemp -d /tmp/koi-core-tests-XXXXXXXX)
    export KOI_DIR
    trap 'rm -rf "$KOI_DIR"' EXIT
    zig build -j2 test
    ;;
  test-app) exec scripts/koid test --headless ;;
  bundle)
    scripts/bundle.sh
    codesign --verify --deep --strict "${KOI_BUNDLE_OUTPUT:-$PWD/build/Koi.app}"
    ;;
  help|--help|-h) usage ;;
  *) usage >&2; exit 2 ;;
esac

#!/bin/sh
# Shared local/CI commands. Checks never install or launch Koi or Koid.
set -eu
cd "$(dirname "$0")"

# List the deliberately small interface; development controls stay in koid.
usage() {
  cat <<'EOF'
usage: ./x [command]
  check        Default: scripts, catalog, full isolated correctness tests
  scripts      Script and CI regressions (Python 3, no Mac toolchain)
  programs     Application catalog and artwork checks (Python 3)
  deps         Discover stable Ghostty updates without editing (Python 3, gh)
  test [FILTER] Full correctness suite or focused Swift tests (Mac)
  testc [FILTER] Isolated core tests; optional Zig test-name filter
  bench        Isolated Swift benchmarks (Mac with Metal)
  mutate [--app] [NAME] Plant known bugs in a copy of the core (or the app); tests must catch each
  testa        Hosted app test subset with isolated fixtures (Mac)
  bundle       Release bundle and signature verification; never installs
  help         Show this help

Aliases: test-core = testc; test-app = testa
EOF
}

task=${1:-check}
if [ "$#" -gt 0 ]; then shift; fi
# Preserve existing scripts and muscle memory while presenting short command names.
case "$task" in
  test-core) task=testc ;;
  test-app) task=testa ;;
esac
case "$task" in
  test|testc)
    [ "$#" -le 1 ] || { usage >&2; exit 2; }
    if [ "$#" -eq 1 ]; then
      case "$1" in ''|-*) usage >&2; exit 2 ;; esac
      if [ "$task" = test ]; then exec scripts/koid test --filter "$1"; fi
      exec scripts/koid test --core "$1"
    fi
    if [ "$task" = test ]; then exec scripts/koid test; fi
    exec scripts/koid test --core ;;
  mutate) exec python3 scripts/mutate.py "$@" ;;
esac
[ "$#" -eq 0 ] || { usage >&2; exit 2; }
case "$task" in
  check) ./x scripts; ./x programs; ./x test ;;
  scripts)
    sh tests/scripts/koid-test-isolation.sh
    python3 tests/scripts/buildProvenanceTests.py
    python3 tests/scripts/ciTests.py
    python3 tests/scripts/dependencyUpdatesTests.py
    python3 tests/scripts/actionPinsTests.py
    python3 tests/scripts/releaseTests.py
    python3 tests/scripts/mutationTests.py
    ;;
  programs)
    python3 scripts/check-programs.py
    python3 tests/scripts/programsTests.py
    ;;
  deps) exec python3 scripts/update-dependencies.py plan ;;
  bench) exec scripts/koid test --bench ;;
  testa) exec scripts/koid test --headless ;;
  bundle)
    scripts/bundle.sh
    codesign --verify --deep --strict "${KOI_BUNDLE_OUTPUT:-$PWD/build/Koi.app}"
    ;;
  help|--help|-h) usage ;;
  *) usage >&2; exit 2 ;;
esac

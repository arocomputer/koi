#!/bin/sh
# Builds libghostty-vt, Ghostty's terminal engine, from a pinned commit into
# vendor/GhosttyVt.xcframework, which Package.swift links. Rerun after
# changing GHOSTTY_COMMIT; it does nothing when the framework is current.
# --source-only prepares the pinned checkout for core tests without building
# the Apple framework. The framework needs Zig and Apple's SDK tools.
set -eu

case "$#:${1:-}" in
  0:|1:--source-only) ;;
  *) echo 'usage: scripts/build-ghostty-vt.sh [--source-only]' >&2; exit 2 ;;
esac

GHOSTTY_COMMIT=0fe113a35370667d8c4d6970ee5c1704825dce6b

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/scripts/build-metadata.sh"
src="$root/vendor/ghostty"
out="$root/vendor/GhosttyVt.xcframework"
stamp="$root/vendor/.ghostty-commit"

mkdir -p "$root/vendor"
if [ ! -d "$src/.git" ]; then
  [ ! -e "$src" ] || { echo 'build: vendor/ghostty exists without a Git checkout; preserve it before retrying' >&2; exit 1; }
  # A failed download must not leave an unborn checkout that breaks retries.
  checkout=$(mktemp -d "$root/vendor/.ghostty-source-XXXXXXXX")
  trap 'rm -rf "$checkout"' EXIT
  git init --quiet "$checkout"
  git -C "$checkout" remote add origin https://github.com/ghostty-org/ghostty
  git -C "$checkout" fetch --quiet --depth=1 origin "$GHOSTTY_COMMIT"
  git -C "$checkout" checkout --quiet --detach "$GHOSTTY_COMMIT"
  mv "$checkout" "$src"
  trap - EXIT
fi
head=$(ghostty_head)
if [ "$head" != "$GHOSTTY_COMMIT" ]; then
  git -C "$src" fetch --quiet origin "$GHOSTTY_COMMIT"
  git -C "$src" checkout --quiet --detach "$GHOSTTY_COMMIT"
  head=$(ghostty_head)
fi
[ "$head" = "$GHOSTTY_COMMIT" ] || { echo "build: Ghostty checkout does not match pin" >&2; exit 1; }
[ "${1:-}" != --source-only ] || exit 0
zig_info=$(zig_identity)
sdk_info=$(apple_sdk_identity)
key=$({ printf '%s\n' "$head" "$zig_info" "$sdk_info"; shasum -a 256 "$root/scripts/build-ghostty-vt.sh" "$root/scripts/build-metadata.sh"; } | shasum -a 256 | cut -d' ' -f1)
if [ -d "$out" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$key" ]; then
  exit 0
fi

rm -f "$stamp"
(cd "$src" && zig build -Demit-lib-vt -Doptimize=ReleaseFast)

rm -rf "$out"
cp -R "$src/zig-out/lib/ghostty-vt.xcframework" "$out"

echo "$key" > "$stamp"
echo "built $out"

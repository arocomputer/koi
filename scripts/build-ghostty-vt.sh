#!/bin/sh
# Builds libghostty-vt, Ghostty's terminal engine, from a pinned commit into
# vendor/GhosttyVt.xcframework, which Package.swift links. Rerun after
# changing GHOSTTY_COMMIT; it does nothing when the framework is current.
# Needs Zig (the version Ghostty's build.zig.zon asks for).
set -eu

GHOSTTY_COMMIT=0fe113a35370667d8c4d6970ee5c1704825dce6b

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/scripts/build-metadata.sh"
src="$root/vendor/ghostty"
out="$root/vendor/GhosttyVt.xcframework"
stamp="$root/vendor/.ghostty-commit"

mkdir -p "$root/vendor"
if [ ! -d "$src/.git" ]; then
  git clone --filter=blob:none https://github.com/ghostty-org/ghostty "$src"
fi
head=$(ghostty_head)
if [ "$head" != "$GHOSTTY_COMMIT" ]; then
  git -C "$src" fetch --quiet origin "$GHOSTTY_COMMIT"
  git -C "$src" checkout --quiet --detach "$GHOSTTY_COMMIT"
  head=$(ghostty_head)
fi
[ "$head" = "$GHOSTTY_COMMIT" ] || { echo "build: Ghostty checkout does not match pin" >&2; exit 1; }
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

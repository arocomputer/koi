#!/bin/sh
# Builds Koi's core: the `koi` binary for this Mac and for Linux x86_64 into
# build/core/, and libkoi (the link client the app links) into
# vendor/libkoi/. Needs Zig and the engine source that
# scripts/build-ghostty-vt.sh clones. --mac-only prepares the app and fixtures.
set -eu

case "$#:${1:-}" in
  0:) mac_only=0 ;;
  1:--mac-only) mac_only=1 ;;
  *) echo 'usage: scripts/build-core.sh [--mac-only]' >&2; exit 2 ;;
esac

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
. "$root/scripts/build-metadata.sh"
# The version stamp: the package version plus a digest of the core sources,
# computed here because zig's configure phase is memoized and would reuse a
# stale digest when only sources changed.
head=$(ghostty_head)
pin=$(sed -n 's/^GHOSTTY_COMMIT=//p' scripts/build-ghostty-vt.sh)
if [ "$head" != "$pin" ]; then
  echo "build: vendor/ghostty HEAD does not match the pinned commit; run scripts/build-ghostty-vt.sh" >&2
  exit 1
fi
package=$(package_version)
zig_info=$(zig_identity)
sdk_info=$(apple_sdk_identity)
# Hash paths and contents as well as the effective build arguments per target.
core_version() {
  digest=$({
    printf '%s\n' "$head" "$zig_info" "$sdk_info" "-Doptimize=ReleaseFast" "-Dtarget=$1"
    { printf '%s\n' build.zig build.zig.zon scripts/build-core.sh scripts/build-ghostty-vt.sh scripts/build-metadata.sh; find src/core -type f \( -name '*.zig' -o -name '*.h' \); } | LC_ALL=C sort | while IFS= read -r file; do
      printf '%s\n' "$file"
      shasum -a 256 "$file" | cut -d' ' -f1
    done
  } | shasum -a 256 | cut -d' ' -f1)
  printf '%s+%s\n' "$package" "$digest"
}
# Validate restored outputs against the same inputs that identify the binaries.
mac_version=$(core_version aarch64-macos.26.0)
mac_stamp="$root/build/core/.inputs-mac"
linux_stamp="$root/build/core/.inputs-linux"
if [ "$(cat "$mac_stamp" 2>/dev/null)" != "$mac_version" ] ||
   [ ! -f "$root/build/core/koi" ] || [ ! -f "$root/vendor/libkoi/lib/libkoi.a" ] ||
   [ ! -f "$root/vendor/libkoi/include/koi.h" ] || [ ! -f "$root/vendor/libkoi/module.modulemap" ]; then
  rm -f "$mac_stamp"
  # This Mac's binary and libkoi target the app's minimum macOS.
  zig build -Doptimize=ReleaseFast -Dtarget=aarch64-macos.26.0 -Dversion="$mac_version"
  mkdir -p "$root/build/core" "$root/vendor/libkoi/lib" "$root/vendor/libkoi/include"
  # Replace binaries through a new inode to avoid macOS's stale signature cache.
  cp zig-out/bin/koi "$root/build/core/koi.new" && mv -f "$root/build/core/koi.new" "$root/build/core/koi"
  cp zig-out/lib/libkoi.a "$root/vendor/libkoi/lib/"
  cp src/core/include/koi.h "$root/vendor/libkoi/include/"
  printf 'module CKoi {\n    header "include/koi.h"\n    export *\n}\n' > "$root/vendor/libkoi/module.modulemap"
  printf '%s\n' "$mac_version" > "$mac_stamp"
  echo "built build/core/koi, vendor/libkoi"
fi
if [ "$mac_only" = 0 ]; then
  linux_version=$(core_version x86_64-linux-musl)
  if [ "$(cat "$linux_stamp" 2>/dev/null)" != "$linux_version" ] || [ ! -f "$root/build/core/koi-linux-x86_64" ]; then
    rm -f "$linux_stamp"
    zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl --prefix zig-out-linux-x86_64 -Dversion="$linux_version"
    mkdir -p "$root/build/core"
    cp zig-out-linux-x86_64/bin/koi "$root/build/core/koi-linux-x86_64.new" && mv -f "$root/build/core/koi-linux-x86_64.new" "$root/build/core/koi-linux-x86_64"
    printf '%s\n' "$linux_version" > "$linux_stamp"
    echo "built build/core/koi-linux-x86_64"
  fi
fi

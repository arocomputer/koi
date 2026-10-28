#!/bin/sh
# Shared build metadata; callers set root to the repository directory.

# Read the package version and require the numeric form accepted by macOS.
package_version() {
  # shellcheck disable=SC2154 # Set by the sourcing build script.
  version=$(sed -n 's/^[[:space:]]*\.version = "\([^"]*\)",.*/\1/p' "$root/build.zig.zon")
  if ! printf '%s\n' "$version" | LC_ALL=C grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "build: build.zig.zon must contain one numeric major.minor.patch version" >&2
    return 1
  fi
  printf '%s\n' "$version"
}

# Identify the exact Zig executable as well as its reported version.
zig_identity() {
  zig version
  shasum -a 256 "$(command -v zig)" | cut -d' ' -f1
}

# Header and SDK selection also affect Apple framework and core outputs.
apple_sdk_identity() {
  xcodebuild -version
  xcrun --sdk macosx --show-sdk-version
  xcrun --sdk macosx --show-sdk-path
}

# Refuse to change or build a checkout with tracked local edits.
ghostty_head() {
  changes=$(git -C "$root/vendor/ghostty" status --porcelain --untracked-files=no) || return 1
  if [ -n "$changes" ]; then
    echo "build: vendor/ghostty has tracked local changes; preserve or remove them before building" >&2
    return 1
  fi
  git -C "$root/vendor/ghostty" rev-parse HEAD
}

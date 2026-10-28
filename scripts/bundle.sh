#!/bin/sh
# Builds Koi in release mode and wraps it in build/Koi.app. With --dev,
# installs "~/Applications/Koid.app" instead: the same app under its own
# name, bundle id and state (see scripts/koid), at one fixed home so every
# worktree rebuilds the one pinned Koid. With --install, builds Koi as
# usual, then promotes the bundle to /Applications/Koi.app, the daily
# driver; plain builds never touch it, so a routine build can't clobber it.
# Signs with "Koi Dev" when that certificate exists (scripts/signing-cert.sh
# makes it), so macOS keeps the app's permissions across rebuilds;
# otherwise ad hoc. KOI_BUNDLE_OUTPUT overrides the ordinary Koi bundle path.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/scripts/build-metadata.sh"
version=$(package_version)
name=Koi
id=com.fschrhunt.koi
icon=Koi
dev=0
install=0
case "${1:-}" in
  --dev)
    name="Koid"
    id=com.fschrhunt.koid
    icon=Koid
    dev=1 ;;
  --install)
    install=1 ;;
esac
# Resolve existing symlinks and normalize missing path components without
# creating the output directory. The result is used only for safety checks.
canonical_path() (
  set -f
  IFS=/
  # Split path components deliberately, with globbing disabled.
  # shellcheck disable=SC2086
  set -- $1
  path=/
  for part do
    case "$part" in
      ''|.) continue ;;
      ..) path=$(dirname "$path") ;;
      *)
        if [ -d "$path/$part" ]; then
          path=$(cd -P "$path/$part" && pwd -P) || exit 1
        else
          path="${path%/}/$part"
        fi ;;
    esac
  done
  printf '%s\n' "$path"
)

# Koid has a fixed destination; ordinary builds may select another bundle.
if [ "$dev" = 1 ]; then app="$HOME/Applications/Koid.app"; else app="${KOI_BUNDLE_OUTPUT:-$root/build/$name.app}"; fi
case "$app" in
  /*.app) ;;
  *) echo "bundle: output must be an absolute .app path" >&2; exit 1 ;;
esac
dest="/Applications/Koi.app"
app_path=$(canonical_path "$app")
dest_path=$(canonical_path "$dest")
# Reject case variants too, including when the destination does not yet exist
# on a case-insensitive volume.
app_check=$(printf '%s' "$app_path" | LC_ALL=C tr '[:upper:]' '[:lower:]')
dest_check=$(printf '%s' "$dest_path" | LC_ALL=C tr '[:upper:]' '[:lower:]')
case "$app_check/" in
  "$dest_check/"*) echo "bundle: output cannot be the daily app or inside it" >&2; exit 1 ;;
esac
if [ -e "$app" ] && [ -e "$dest" ] && [ "$app" -ef "$dest" ]; then
  echo "bundle: output cannot be the daily app" >&2
  exit 1
fi

"$root/scripts/build-ghostty-vt.sh"
"$root/scripts/build-core.sh"
set -- --package-path "$root" -c release
if [ "$dev" = 1 ]; then set -- "$@" -Xswiftc -DKOID; fi
swift build "$@"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build "$@" --show-bin-path)/Koi" "$app/Contents/MacOS/koi"
cp -R "$root/src/app/resources/programs" "$app/Contents/Resources/programs"
cp -R "$root/src/app/resources/shell" "$app/Contents/Resources/shell"
cp "$root/LICENSE" "$root/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/"
cp -R "$root/licenses" "$app/Contents/Resources/licenses"
for bin in koi koi-linux-x86_64; do
  # A new inode each time: see build-core.sh on stale signature caches.
  cp "$root/build/core/$bin" "$app/Contents/Resources/$bin.new" && mv -f "$app/Contents/Resources/$bin.new" "$app/Contents/Resources/$bin"
done
# Compile the selected Icon Composer source from src/app/resources into
# the app's asset catalog for Liquid Glass.
xcrun actool "$root/src/app/resources/$icon.icon" --compile "$app/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon "$icon" --output-partial-info-plist /dev/null \
  --output-format human-readable-text >/dev/null
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleExecutable</key><string>koi</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleIconFile</key><string>$icon</string>
  <key>CFBundleIconName</key><string>$icon</string>
</dict>
</plist>
EOF
identity=-
security find-identity -v -p codesigning 2>/dev/null | grep -q '"Koi Dev"' && identity="Koi Dev"
codesign --force --sign "$identity" "$app" >/dev/null
echo "built $app"

# Promote the freshly built bundle to the daily driver. The build above ran
# unprivileged into build/; only this copy needs to reach /Applications, so
# a non-admin account is told to sudo just the copy, not a root recompile.
if [ "$install" = 1 ]; then
  if [ ! -w /Applications ]; then
    echo "bundle: cannot write /Applications; promote it with: sudo cp -R \"$app\" \"$dest\"" >&2
    exit 1
  fi
  rm -rf "$dest"
  cp -R "$app" "$dest"
  echo "installed $dest"
fi

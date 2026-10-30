#!/usr/bin/env bash
# Gate an immutable release commit, or sign/notarize an explicit prebuilt bundle.
set -euo pipefail
set +x
cd "$(dirname "$0")/.."

case "${1:-}" in
  gate|resolve-tag)
    RELEASE_MODE=$1 python3 - <<'PY'
import json, os, re, subprocess

def api(path):
    """Read GitHub metadata using the workflow's built-in token."""
    return json.loads(subprocess.check_output(['gh', 'api', 'repos/' + os.environ['GITHUB_REPOSITORY'] + '/' + path]))

tag = os.environ['RELEASE_TAG']
if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag):
    raise SystemExit('Release requires a stable vMAJOR.MINOR.PATCH tag')
obj = api('git/ref/tags/' + tag)['object']
for _ in range(8):
    if not re.fullmatch(r'[0-9a-f]{40}', obj['sha']):
        raise SystemExit('Invalid tag object')
    if obj['type'] == 'commit':
        sha = obj['sha']
        break
    if obj['type'] != 'tag':
        raise SystemExit('Tag must reference a commit')
    obj = api('git/tags/' + obj['sha'])['object']
else:
    raise SystemExit('Too many nested tags')
if os.environ['RELEASE_MODE'] == 'resolve-tag':
    print(sha)
    raise SystemExit(0)
if os.environ.get('METAL_ATTESTATION') != 'Full Metal suite passed at ' + sha:
    raise SystemExit('Missing exact-commit full Metal suite attestation')
# `permission` reports maintainers as "write"; only `role_name` names the role.
role = api('collaborators/' + os.environ['GITHUB_ACTOR'] + '/permission').get('role_name')
if role not in ('admin', 'maintain'):
    raise SystemExit('Release requires a maintainer')
comparison = api('compare/' + sha + '...main')
if comparison['status'] not in ('ahead', 'identical') or comparison['merge_base_commit']['sha'] != sha:
    raise SystemExit('Release commit must be an ancestor of main')
# Only main CI qualifies: a push run, or a manual run when a later merge
# cancelled it. Either may select fewer checks than a release; the build job
# reruns all of them itself.
runs = api('actions/workflows/ci.yml/runs?head_sha=' + sha + '&branch=main&per_page=100')['workflow_runs']
latest = next((r for r in runs if r['head_sha'] == sha and r.get('event') in ('push', 'workflow_dispatch')
               and r['status'] == 'completed' and r['conclusion'] == 'success'), None)
if latest is None:
    raise SystemExit('No green main CI for this exact commit')
content = subprocess.check_output(['gh', 'api', '-H', 'Accept: application/vnd.github.raw+json',
    'repos/' + os.environ['GITHUB_REPOSITORY'] + '/contents/build.zig.zon?ref=' + sha], text=True)
version = re.search(r'\.version\s*=\s*"([^"]+)"', content)
if not version or tag != 'v' + version[1]:
    raise SystemExit('Tag does not match build.zig.zon')
with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
    output.write('sha=' + sha + '\n')
PY
    ;;
  sign)
    : "${APPLE_CERTIFICATE_BASE64:?Missing signing certificate}"
    : "${APPLE_CERTIFICATE_PASSWORD:?Missing certificate password}"
    : "${APPLE_SIGNING_IDENTITY:?Missing Developer ID Application identity}"
    : "${APPLE_API_KEY_BASE64:?Missing notarization API key}"
    : "${APPLE_API_KEY_ID:?Missing notarization key ID}"
    : "${APPLE_API_ISSUER:?Missing notarization issuer}"
    : "${RELEASE_TAG:?Missing tag}"
    [[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
    [[ "$APPLE_SIGNING_IDENTITY" == 'Developer ID Application: '* ]] || {
      echo 'Distribution requires Developer ID Application signing.' >&2; exit 1;
    }
    [[ $# == 3 && -d "$2/Contents/MacOS" && ! -e "$3" ]] || {
      echo 'Expected prebuilt bundle and new output directory.' >&2; exit 1;
    }
    umask 077
    private=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/koi-release.XXXXXX")
    keychain="$private/signing.keychain-db"
    # The keychain is never added to the user's search list or made default.
    cleanup() {
      status=$?
      trap - EXIT
      if [[ -e "$keychain" ]]; then
        security delete-keychain "$keychain" >/dev/null 2>&1 || status=1
      fi
      rm -rf "$private"
      exit "$status"
    }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mkdir "$private/work"
    ditto "$2" "$private/work/Koi.app"
    app="$private/work/Koi.app"
    printf '%s' "$APPLE_CERTIFICATE_BASE64" | base64 --decode > "$private/cert.p12"
    printf '%s' "$APPLE_API_KEY_BASE64" | base64 --decode > "$private/key.p8"
    password=$(openssl rand -hex 32)
    security create-keychain -p "$password" "$keychain"
    security set-keychain-settings -lut 21600 "$keychain"
    security unlock-keychain -p "$password" "$keychain"
    security import "$private/cert.p12" -k "$keychain" -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
    security find-identity -v -p codesigning "$keychain" | grep -F "\"$APPLE_SIGNING_IDENTITY\"" >/dev/null
    # Sign actual Mach-O files inside out; the Linux payload is deliberately skipped.
    # Only the app executable, the process macOS holds responsible for what a pane
    # asks for, carries the resource-access entitlements; the bundled server does not.
    entitlements=src/app/resources/Koi.entitlements
    while IFS= read -r -d '' binary; do
      if file -b "$binary" | grep -q 'Mach-O'; then
        extra=()
        [[ "$binary" == "$app/Contents/MacOS/koi" ]] && extra=(--entitlements "$entitlements")
        codesign --force --sign "$APPLE_SIGNING_IDENTITY" --keychain "$keychain" --options runtime --timestamp ${extra[@]+"${extra[@]}"} "$binary"
      fi
    done < <(find "$app" -depth -type f -print0)
    codesign --force --sign "$APPLE_SIGNING_IDENTITY" --keychain "$keychain" --options runtime --timestamp --entitlements "$entitlements" "$app"
    codesign --verify --deep --strict --verbose=2 "$app"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$private/submit.zip"
    xcrun notarytool submit "$private/submit.zip" --key "$private/key.p8" --key-id "$APPLE_API_KEY_ID" \
      --issuer "$APPLE_API_ISSUER" --wait --timeout 30m --output-format json > "$private/notary.json"
    python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("status") == "Accepted" else "Notarization was not Accepted")' "$private/notary.json"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    codesign --verify --deep --strict --verbose=2 "$app"
    spctl --assess --type execute --verbose=2 "$app"
    # Repack after stapling and validate a private installation from the final archive.
    archive="Koi-$RELEASE_TAG-macos-arm64.zip"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$private/$archive"
    mkdir "$private/install"
    ditto -x -k "$private/$archive" "$private/install"
    staged="$private/install/Koi.app"
    codesign --verify --deep --strict --verbose=2 "$staged"
    xcrun stapler validate "$staged"
    spctl --assess --type execute --verbose=2 "$staged"
    python3 - "$staged" "$RELEASE_TAG" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
with (app / 'Contents/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
assert info['CFBundleIdentifier'] == 'com.fschrhunt.koi'
assert info['CFBundleShortVersionString'] == sys.argv[2][1:]
assert info['CFBundleVersion'] == sys.argv[2][1:]
for name in ('MacOS/koi', 'Resources/koi', 'Resources/koi-linux-x86_64'):
    assert (app / 'Contents' / name).is_file(), name
PY
    mkdir "$3"
    cp "$private/$archive" "$3/"
    (cd "$3"; shasum -a 256 "$archive" > SHA256SUMS)
    ;;
  *) echo 'Usage: release.sh gate | resolve-tag | sign BUNDLE NEW_OUTPUT_DIRECTORY' >&2; exit 1 ;;
esac

#!/usr/bin/env python3
"""Exercise release refusals, signing order and cleanup without Apple credentials."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SHA = 'a' * 40
MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys, zipfile
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['LOG'], 'a') as out:
    out.write(json.dumps([name] + args) + '\n')
if os.environ.get('FAIL') == name:
    sys.exit(1)
if name == 'security':
    if args[0] == 'create-keychain': pathlib.Path(args[-1]).touch()
    if args[0] == 'delete-keychain': pathlib.Path(args[-1]).unlink()
    if args[0] == 'find-identity': print('1) HASH "Developer ID Application: Fixture"')
elif name == 'file':
    print('ELF' if 'linux' in args[-1] else 'Mach-O 64-bit executable')
elif name == 'ditto':
    if args[0] == '-c':
        source, dest = map(pathlib.Path, args[-2:])
        with zipfile.ZipFile(dest, 'w') as archive:
            for item in source.rglob('*'):
                if item.is_file(): archive.write(item, str(item.relative_to(source.parent)))
    elif args[0] == '-x':
        with zipfile.ZipFile(args[-2]) as archive: archive.extractall(args[-1])
    else: shutil.copytree(*args)
elif name == 'xcrun' and args[0] == 'notarytool':
    print(json.dumps({'status': os.environ.get('NOTARY_STATUS', 'Accepted')}))
elif name == 'gh':
    path = args[-1]
    sha = 'a' * 40
    if 'contents/' in path:
        print('.version = "0.1.0",')
    elif '/git/ref/tags/' in path:
        if os.environ.get('TAG_MISSING'): sys.exit(1)
        print(json.dumps({'object': {'sha': sha, 'type': 'tag' if os.environ.get('ANNOTATED') else 'commit'}}))
    elif '/git/tags/' in path: print(json.dumps({'object': {'sha': sha, 'type': 'commit'}}))
    elif '/collaborators/' in path:
        # GitHub reports a maintainer's `permission` as write; `role_name` is exact.
        role = os.environ.get('PERMISSION', 'maintain')
        print(json.dumps({'permission': 'write' if role == 'maintain' else role, 'role_name': role}))
    elif '/compare/' in path: print(json.dumps({'status': os.environ.get('ANCESTRY', 'ahead'), 'merge_base_commit': {'sha': sha}}))
    else: print(json.dumps({'workflow_runs': [{'head_sha': os.environ.get('CI_SHA', sha), 'event': os.environ.get('CI_EVENT', 'push'), 'status': 'completed', 'conclusion': os.environ.get('CI_RESULT', 'success')}]}))
'''


class ReleaseTests(unittest.TestCase):
    """Run the real shell entry point with isolated tool stand-ins."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        tools = self.base / 'bin'
        tools.mkdir()
        mock = tools / 'mock'
        mock.write_text(MOCK)
        mock.chmod(0o755)
        for name in ('security', 'codesign', 'file', 'ditto', 'xcrun', 'spctl', 'gh'):
            (tools / name).symlink_to(mock)
        self.log = self.base / 'log'
        self.env = dict(os.environ, PATH=str(tools) + ':' + os.environ['PATH'],
                        LOG=str(self.log), RUNNER_TEMP=str(self.base),
                        RELEASE_TAG='v0.1.0', METAL_ATTESTATION='Full Metal suite passed at ' + SHA,
                        GITHUB_REPOSITORY='fixture/koi', GITHUB_ACTOR='maintainer',
                        GITHUB_OUTPUT=str(self.base / 'output'), GH_TOKEN='fixture')
        for name in ('APPLE_CERTIFICATE_BASE64', 'APPLE_API_KEY_BASE64'):
            self.env[name] = 'Zml4dHVyZQ=='
        for name in ('APPLE_CERTIFICATE_PASSWORD', 'APPLE_API_KEY_ID', 'APPLE_API_ISSUER'):
            self.env[name] = 'fixture'
        self.env['APPLE_SIGNING_IDENTITY'] = 'Developer ID Application: Fixture'
        self.app = self.base / 'Koi.app'
        for name in ('MacOS/koi', 'Resources/koi', 'Resources/koi-linux-x86_64'):
            path = self.app / 'Contents' / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        with (self.app / 'Contents/Info.plist').open('wb') as stream:
            plistlib.dump(dict(CFBundleIdentifier='com.fschrhunt.koi',
                              CFBundleVersion='0.1.0', CFBundleShortVersionString='0.1.0'), stream)

    def run_release(self, mode):
        """Capture diagnostics without displaying signing arguments."""
        args = [str(ROOT / 'scripts/release.sh'), mode]
        if mode == 'sign': args += [str(self.app), str(self.base / 'dist')]
        return subprocess.run(args, env=self.env, capture_output=True, text=True)

    def calls(self):
        """Return mock calls in execution order."""
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_workflow_separates_build_from_credentials_and_only_drafts(self):
        workflow = (ROOT / '.github/workflows/release.yml').read_text()
        build, signing = workflow.split('  sign-publish:', 1)
        self.assertNotIn('secrets.', build)
        self.assertNotIn('contents: write', build)
        self.assertIn('needs: build', signing)
        self.assertNotIn('setup-zig', signing)
        self.assertNotIn('./x ', signing)
        self.assertIn('GH_TOKEN: ${{ github.token }}', signing)
        self.assertIn('--draft --verify-tag', signing)
        self.assertIn('"$resolved" == "$RELEASE_SHA"', signing)

    def test_gate_refuses_unverified_commit(self):
        for key, value in [('METAL_ATTESTATION', 'yes'), ('PERMISSION', 'write'),
                           ('ANCESTRY', 'diverged'), ('CI_RESULT', 'failure'), ('CI_SHA', 'b' * 40),
                           ('RELEASE_TAG', 'v9.0.0'), ('TAG_MISSING', '1'), ('CI_EVENT', 'pull_request')]:
            with self.subTest(key=key):
                old = self.env.get(key)
                self.env[key] = value
                self.assertNotEqual(self.run_release('gate').returncode, 0)
                if old is None: self.env.pop(key)
                else: self.env[key] = old
        # A manual main run stands in for a push run a later merge cancelled.
        self.env['CI_EVENT'] = 'workflow_dispatch'
        self.assertEqual(self.run_release('gate').returncode, 0)
        self.env.pop('CI_EVENT')
        (self.base / 'output').unlink()
        self.assertEqual(self.run_release('gate').returncode, 0)
        self.assertEqual((self.base / 'output').read_text(), 'sha=' + SHA + '\n')
        self.env['ANNOTATED'] = '1'
        result = self.run_release('resolve-tag')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), SHA)

    def test_missing_credentials_and_adhoc_refused_before_tools(self):
        for key in ('APPLE_API_KEY_BASE64', 'APPLE_CERTIFICATE_BASE64', 'APPLE_CERTIFICATE_PASSWORD'):
            old = self.env.pop(key)
            self.assertNotEqual(self.run_release('sign').returncode, 0)
            self.env[key] = old
        self.env['APPLE_SIGNING_IDENTITY'] = '-'
        self.assertNotEqual(self.run_release('sign').returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_notary_rejection_and_tool_failure_clean_keychain(self):
        for key, value in [('NOTARY_STATUS', 'Invalid'), ('FAIL', 'codesign'), ('FAIL', 'xcrun')]:
            with self.subTest(value=value):
                self.env[key] = value
                self.assertNotEqual(self.run_release('sign').returncode, 0)
                self.assertIn('delete-keychain', [c[1] for c in self.calls() if c[0] == 'security'])
                self.assertFalse(list(self.base.glob('koi-release.*')))
                self.assertFalse((self.base / 'dist').exists())
                self.env.pop(key)
                self.log.unlink()

    def test_signed_stapled_archive_is_staged_before_success(self):
        result = self.run_release('sign')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        signs = [c for c in calls if c[0] == 'codesign' and '--sign' in c]
        self.assertTrue(signs[-1][-1].endswith('/Koi.app'))
        self.assertTrue(any(c[-1].endswith('/Resources/koi') for c in signs))
        self.assertFalse(any('linux' in c[-1] for c in signs))
        for call in signs:
            self.assertIn('--timestamp', call)
            self.assertIn('runtime', call)
        commands = [(c[0], c[1]) for c in calls]
        self.assertLess(commands.index(('xcrun', 'notarytool')), commands.index(('xcrun', 'stapler')))
        self.assertTrue(any(c[0] == 'spctl' and '/install/Koi.app' in c[-1] for c in calls))
        self.assertTrue((self.base / 'dist/SHA256SUMS').is_file())
        self.assertFalse(list(self.base.glob('koi-release.*')))
        self.assertFalse(any(c[0] in ('swift', 'zig', 'open') for c in calls))


if __name__ == '__main__':
    unittest.main()

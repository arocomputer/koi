#!/usr/bin/env python3
"""Exercise build provenance and bundle assembly with isolated fake tools."""
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PIN = '0fe113a35370667d8c4d6970ee5c1704825dce6b'


class BuildProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        for path in ('scripts', 'src/core', 'src/app/resources/programs',
                     'src/app/resources/shell', 'vendor/ghostty/.git', 'bin', 'licenses'):
            (self.root / path).mkdir(parents=True)
        for name in ('build-core.sh', 'build-ghostty-vt.sh', 'build-metadata.sh', 'bundle.sh'):
            shutil.copy(ROOT / 'scripts' / name, self.root / 'scripts' / name)
        for name, content in {'build.zig': 'build', 'build.zig.zon': '.version = "0.1.0",\n',
                              'src/core/main.zig': 'core', 'src/core/koi.h': 'header',
                              'src/core/include/koi.h': 'header', 'LICENSE': 'license',
                              'THIRD_PARTY_NOTICES.md': '[license](licenses/test)',
                              'licenses/test': 'notice'}.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        self.tool('git', '''case "$3" in
 status) [ ! -f "$FIXTURE/dirty" ] || echo ' M file';;
 rev-parse) cat "$FIXTURE/head";;
 fetch) :;;
 checkout) echo "$PIN" > "$FIXTURE/head";;
esac''')
        self.tool('zig', '''if [ "$1" = version ]; then cat "$FIXTURE/zig-version"; exit; fi
printf '%s\\n' "$*" >> "$FIXTURE/zig-log"
case "$PWD" in
 */vendor/ghostty) mkdir -p zig-out/lib/ghostty-vt.xcframework; echo engine > zig-out/lib/ghostty-vt.xcframework/data;;
 *) mkdir -p zig-out/bin zig-out/lib zig-out-linux-x86_64/bin; touch zig-out/bin/koi zig-out/lib/libkoi.a zig-out-linux-x86_64/bin/koi;;
esac''')
        self.tool('swift', '''case " $* " in *' --show-bin-path '*) echo "$FIXTURE/swift-bin";; esac''')
        self.tool('xcrun', 'cat "$FIXTURE/sdk-version"')
        self.tool('xcodebuild', 'cat "$FIXTURE/sdk-version"')
        self.tool('security', 'exit 1')
        self.tool('codesign', 'printf \'%s\\n\' "$*" >> "$FIXTURE/codesign-log"')
        (self.root / 'swift-bin').mkdir()
        (self.root / 'swift-bin/Koi').touch()
        (self.root / 'head').write_text(PIN)
        (self.root / 'zig-version').write_text('0.17.0')
        (self.root / 'sdk-version').write_text('27.1')
        self.env = {**os.environ, 'PATH': str(self.root / 'bin') + ':' + os.environ['PATH'],
                    'FIXTURE': str(self.root), 'PIN': PIN}

    def tearDown(self):
        self.tmp.cleanup()

    def tool(self, name, body):
        path = self.root / 'bin' / name
        path.write_text('#!/bin/sh\nset -eu\n' + body + '\n')
        path.chmod(0o755)

    def codesign_calls(self):
        log = self.root / 'codesign-log'
        return [line.split() for line in log.read_text().splitlines()] if log.exists() else []

    def run_script(self, name, *args, **env):
        return subprocess.run([str(self.root / 'scripts' / name), *args], env={**self.env, **env},
                              text=True, capture_output=True)

    def test_framework_cache_and_dirty_checkout(self):
        self.assertEqual(self.run_script('build-ghostty-vt.sh').returncode, 0)
        log = self.root / 'zig-log'
        first = log.read_text()
        self.assertEqual(self.run_script('build-ghostty-vt.sh').returncode, 0)
        self.assertEqual(log.read_text(), first)
        (self.root / 'sdk-version').write_text('27.2')
        self.assertEqual(self.run_script('build-ghostty-vt.sh').returncode, 0)
        self.assertNotEqual(log.read_text(), first)
        first = log.read_text()
        (self.root / 'zig-version').write_text('0.17.1')
        self.assertEqual(self.run_script('build-ghostty-vt.sh').returncode, 0)
        self.assertNotEqual(log.read_text(), first)
        first = log.read_text()
        with (self.root / 'bin/zig').open('a') as zig:
            zig.write('# changed executable\n')
        self.assertEqual(self.run_script('build-ghostty-vt.sh').returncode, 0)
        self.assertNotEqual(log.read_text(), first)
        first = log.read_text()
        with (self.root / 'scripts/build-ghostty-vt.sh').open('a') as script:
            script.write('# changed script\n')
        self.assertEqual(self.run_script('build-ghostty-vt.sh').returncode, 0)
        self.assertNotEqual(log.read_text(), first)
        (self.root / 'head').write_text('different')
        self.assertEqual(self.run_script('build-ghostty-vt.sh').returncode, 0)
        self.assertEqual((self.root / 'head').read_text().strip(), PIN)
        (self.root / 'dirty').touch()
        result = self.run_script('build-ghostty-vt.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('tracked local changes', result.stderr)

    def test_core_versions_track_target_source_and_toolchain(self):
        def versions():
            result = self.run_script('build-core.sh')
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = (self.root / 'zig-log').read_text().splitlines()[-2:]
            return [line.split('-Dversion=')[1].split()[0] for line in lines]
        first = versions()
        self.assertNotEqual(*first)
        self.assertEqual(first, versions())
        (self.root / 'src/core/main.zig').write_text('changed')
        changed = versions()
        self.assertNotEqual(first, changed)
        (self.root / 'sdk-version').write_text('27.2')
        sdk_changed = versions()
        self.assertNotEqual(changed, sdk_changed)
        (self.root / 'zig-version').write_text('0.17.1')
        self.assertNotEqual(sdk_changed, versions())
        (self.root / 'dirty').touch()
        self.assertNotEqual(self.run_script('build-core.sh').returncode, 0)
        (self.root / 'dirty').unlink()
        (self.root / 'head').write_text('different')
        self.assertNotEqual(self.run_script('build-core.sh').returncode, 0)

    def test_core_targets_validate_independently_and_source_only_skips_framework(self):
        self.assertEqual(self.run_script('build-ghostty-vt.sh', '--source-only').returncode, 0)
        self.assertFalse((self.root / 'zig-log').exists())
        self.assertEqual(self.run_script('build-core.sh', '--mac-only').returncode, 0)
        log = self.root / 'zig-log'
        self.assertEqual(len(log.read_text().splitlines()), 1)
        self.assertFalse((self.root / 'build/core/koi-linux-x86_64').exists())
        self.assertEqual(self.run_script('build-core.sh').returncode, 0)
        self.assertEqual(len(log.read_text().splitlines()), 2)
        self.assertIn('x86_64-linux-musl', log.read_text().splitlines()[-1])
        first = log.read_text()
        (self.root / 'vendor/libkoi/lib/libkoi.a').unlink()
        self.assertEqual(self.run_script('build-core.sh').returncode, 0)
        lines = log.read_text()[len(first):].splitlines()
        self.assertEqual(len(lines), 1)
        self.assertIn('aarch64-macos', lines[0])
        first = log.read_text()
        (self.root / 'build/core/koi-linux-x86_64').unlink()
        self.assertEqual(self.run_script('build-core.sh').returncode, 0)
        lines = log.read_text()[len(first):].splitlines()
        self.assertEqual(len(lines), 1)
        self.assertIn('x86_64-linux-musl', lines[0])
        first = log.read_text()
        self.assertEqual(self.run_script('build-core.sh').returncode, 0)
        self.assertEqual(log.read_text(), first)

    def test_bundle_revalidates_both_targets_after_mac_only_build(self):
        self.assertEqual(self.run_script('build-core.sh', '--mac-only').returncode, 0)
        (self.root / 'src/core/main.zig').write_text('changed')
        result = self.run_script('bundle.sh', KOI_BUNDLE_OUTPUT=str(self.root / 'release/Test.app'))
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = (self.root / 'zig-log').read_text().splitlines()
        self.assertEqual(sum('aarch64-macos' in line for line in lines), 2)
        self.assertEqual(sum('x86_64-linux-musl' in line for line in lines), 1)

    def test_failed_initial_fetch_can_be_retried_without_manual_cleanup(self):
        # A real local repository exercises unborn HEADs without network access.
        upstream = self.root / 'upstream'
        upstream.mkdir()
        git = shutil.which('git')
        def run_git(*args):
            """Run real Git against the fixture upstream, never the project checkout."""
            return subprocess.check_output([git, '-C', str(upstream), *args], text=True).strip()
        run_git('init', '-q')
        (upstream / 'file').write_text('engine source')
        run_git('add', '.')
        run_git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                'commit', '-qm', 'engine')
        pin = run_git('rev-parse', 'HEAD')
        shutil.rmtree(self.root / 'vendor/ghostty')
        script = self.root / 'scripts/build-ghostty-vt.sh'
        script.write_text(script.read_text().replace(PIN, pin).replace(
            'https://github.com/ghostty-org/ghostty', shlex.quote(str(upstream))))
        self.tool('git', '''if [ "${3:-}" = fetch ] && [ ! -f "$FIXTURE/fetch-failed" ]; then
  touch "$FIXTURE/fetch-failed"
  exit 23
fi
exec ''' + shlex.quote(git) + ' "$@"')
        self.assertEqual(self.run_script('build-ghostty-vt.sh', '--source-only').returncode, 23)
        self.assertFalse((self.root / 'vendor/ghostty').exists())
        self.assertEqual(list((self.root / 'vendor').glob('.ghostty-source-*')), [])
        result = self.run_script('build-ghostty-vt.sh', '--source-only')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'vendor/ghostty/file').read_text(), 'engine source')

    def test_bundle_output_and_licenses(self):
        output = self.root / 'release/Test.app'
        result = self.run_script('bundle.sh', KOI_BUNDLE_OUTPUT=str(output))
        self.assertEqual(result.returncode, 0, result.stderr)
        resources = output / 'Contents/Resources'
        self.assertEqual((resources / 'licenses/test').read_text(), 'notice')
        self.assertTrue((resources / 'LICENSE').exists())
        self.assertTrue((resources / 'THIRD_PARTY_NOTICES.md').exists())
        plist = (output / 'Contents/Info.plist').read_text()
        self.assertIn('<key>CFBundleVersion</key><string>0.1.0</string>', plist)
        self.assertIn('<key>CFBundleShortVersionString</key><string>0.1.0</string>', plist)
        self.assertFalse((self.root / 'build/Koi.app').exists())

    def test_bundle_declares_what_a_pane_may_ask_macos_for(self):
        output = self.root / 'release/Test.app'
        result = self.run_script('bundle.sh', KOI_BUNDLE_OUTPUT=str(output))
        self.assertEqual(result.returncode, 0, result.stderr)
        plist = (output / 'Contents/Info.plist').read_text()
        # Every resource the entitlements unlock needs its prompt text, named
        # for the bundle the prompt is attributed to.
        for key in ('NSAppleEventsUsageDescription', 'NSCameraUsageDescription',
                    'NSMicrophoneUsageDescription', 'NSContactsUsageDescription',
                    'NSCalendarsUsageDescription', 'NSLocationUsageDescription',
                    'NSPhotoLibraryUsageDescription'):
            self.assertRegex(plist, r'<key>%s</key><string>A program running in Koi wants' % key)
        signed = [c for c in self.codesign_calls() if c and c[-1] == str(output)]
        self.assertTrue(any('--entitlements' in c for c in signed), signed)

    def test_bundle_rejects_non_app_output_before_replacing_it(self):
        output = self.root / 'keep'
        output.mkdir()
        marker = output / 'unrelated.txt'
        marker.write_text('preserve')
        result = self.run_script('bundle.sh', KOI_BUNDLE_OUTPUT=str(output))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('absolute .app path', result.stderr)
        self.assertEqual(marker.read_text(), 'preserve')

    def test_bundle_rejects_daily_app_aliases_before_build(self):
        # Replace the promotion destination only in the isolated fixture.
        applications = self.root / 'Applications'
        daily = applications / 'Koi.app'
        daily.mkdir(parents=True)
        marker = daily / 'keep'
        marker.write_text('preserve')
        script = self.root / 'scripts/bundle.sh'
        script.write_text(script.read_text().replace('/Applications', str(applications)))
        alias = self.root / 'apps-link'
        alias.symlink_to(applications, target_is_directory=True)
        direct_alias = self.root / 'daily-link.app'
        direct_alias.symlink_to(daily, target_is_directory=True)
        outputs = (daily, applications / '..' / 'Applications' / 'Koi.app',
                   alias / 'Koi.app', direct_alias, daily / 'nested.app',
                   applications / 'koi.app')
        for output in outputs:
            for args in ((), ('--install',)):
                with self.subTest(output=output, args=args):
                    result = self.run_script('bundle.sh', *args, KOI_BUNDLE_OUTPUT=str(output))
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('daily app', result.stderr)
                    self.assertEqual(marker.read_text(), 'preserve')
                    self.assertFalse((self.root / 'zig-log').exists())

    def test_install_promotes_separate_fixture_bundle(self):
        applications = self.root / 'Applications'
        applications.mkdir()
        script = self.root / 'scripts/bundle.sh'
        script.write_text(script.read_text().replace('/Applications', str(applications)))
        output = self.root / 'release/Koi.app'
        result = self.run_script('bundle.sh', '--install', KOI_BUNDLE_OUTPUT=str(output))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((output / 'Contents/Info.plist').exists())
        self.assertTrue((applications / 'Koi.app/Contents/Info.plist').exists())


if __name__ == '__main__':
    unittest.main()

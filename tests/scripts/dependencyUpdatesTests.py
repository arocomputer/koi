#!/usr/bin/env python3
"""Protect stable engine selection, pin-only changes and exact-commit publication."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('updates', ROOT / 'scripts/update-dependencies.py')
updates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updates)
OLD, NEW = 'a' * 40, 'b' * 40
PIN_FILE = f'#!/bin/sh\nGHOSTTY_COMMIT={OLD}\necho keep-this-command\n'
PROPOSAL = {'from': OLD, 'to': NEW, 'tag': 'v1.4.0'}
BEFORE = {'version': '1.3.2-dev', 'minimum_zig_version': '0.17.0'}
AFTER = {'version': '1.4.0', 'minimum_zig_version': '0.17.0'}


class DependencyUpdatesTests(unittest.TestCase):
    """Use private repositories and fake APIs; never update project files or GitHub."""

    def test_selects_stable_same_major_and_refuses_divergence_or_toolchain_change(self):
        tags = [{'name': 'v2.0.0', 'commit': {'sha': 'c' * 40}},
                {'name': 'v1.5.0-rc1', 'commit': {'sha': 'd' * 40}},
                {'name': 'v1.4.0', 'commit': {'sha': NEW}}]
        for status in ('ahead', 'behind', 'diverged'):
            with self.subTest(status=status), patch.object(updates, 'manifest', side_effect=[BEFORE, AFTER]), \
                    patch.object(updates, 'api', side_effect=[tags, {'status': status}]):
                if status == 'diverged':
                    with self.assertRaises(ValueError): updates.resolve(OLD)
                else:
                    self.assertEqual(updates.resolve(OLD), PROPOSAL if status == 'ahead' else {})
        with patch.object(updates, 'manifest', side_effect=[BEFORE, {**AFTER, 'minimum_zig_version': '0.18.0'}]), \
                patch.object(updates, 'api', side_effect=[tags, {'status': 'ahead'}]):
            with self.assertRaises(ValueError): updates.resolve(OLD)

    def test_only_pin_changes_and_moved_or_malformed_proposals_leave_files_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / updates.FILE
            path.parent.mkdir()
            path.write_text(PIN_FILE)
            for proposal in ({}, {**PROPOSAL, 'to': 'bad'}, {**PROPOSAL, 'from': NEW},
                             {**PROPOSAL, 'command': 'injected'}, PROPOSAL):
                with patch.object(updates, 'resolve', return_value={}), self.assertRaises(ValueError):
                    updates.apply(root, proposal)
                self.assertEqual(path.read_text(), PIN_FILE)
            with patch.object(updates, 'resolve', return_value=PROPOSAL):
                updates.apply(root, PROPOSAL)
            self.assertEqual(path.read_text(), PIN_FILE.replace(OLD, NEW))

    def test_publication_keeps_failed_commit_draft_and_preserves_human_branch(self):
        for mode in ('success', 'failed-ci', 'human', 'forged', 'open', 'other-bot', 'head-race', 'orphan', 'wrong-ci-sha'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / 'repo'
                root.mkdir()
                remote = Path(directory) / 'remote.git'
                subprocess.run(['git', 'init', '-q', '--bare', str(remote)], check=True)
                def git(*args):
                    """Run real Git only in the private fixture repository."""
                    return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()
                git('init', '-q', '-b', 'main')
                git('config', 'user.name', 'Fixture')
                git('config', 'user.email', 'fixture@example.invalid')
                (root / 'scripts').mkdir()
                for name in ('update-dependencies.py', 'publish-dependency-updates.sh'):
                    shutil.copy(ROOT / 'scripts' / name, root / 'scripts' / name)
                (root / updates.FILE).write_text(PIN_FILE)
                git('add', '.')
                git('commit', '-qm', 'base')
                base = git('rev-parse', 'HEAD')
                git('remote', 'add', 'origin', str(remote))
                git('push', '-q', 'origin', 'main')
                remote_sha = base
                if mode in ('forged', 'open'):
                    git('switch', '-qc', 'chore/dependency-updates')
                    pending = (PIN_FILE + 'echo preserve-this-edit\n' if mode == 'forged'
                               else PIN_FILE.replace(OLD, 'c' * 40))
                    (root / updates.FILE).write_text(pending)
                    git('add', updates.FILE)
                    git('commit', '-qm', 'chore: update dependencies')
                    remote_sha = git('rev-parse', 'HEAD')
                    git('push', '-q', 'origin', 'HEAD:refs/heads/chore/dependency-updates')
                    git('switch', '-q', 'main')
                elif mode in ('human', 'other-bot', 'orphan'):
                    git('push', '-q', 'origin', 'HEAD:refs/heads/chore/dependency-updates')
                binary = root / 'bin'
                binary.mkdir()
                gh = binary / 'gh'
                gh.write_text('''#!/usr/bin/env python3
import json, os, subprocess, sys
args = sys.argv[1:]
with open(os.environ['GH_LOG'], 'a') as log:
    log.write(json.dumps(args) + '\\n')
if args[:1] == ['api']:
    if '/actions/runs/' in args[1]:
        sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
        print('c' * 40 if os.environ['MODE'] == 'wrong-ci-sha' else sha, 'completed', 'failure' if os.environ['MODE'] == 'failed-ci' else 'success', sep=' ')
    elif '/contents/' in args[1]:
        import base64
        version = '1.3.2-dev' if args[1].endswith('a' * 40) else '1.4.0'
        content = f'.version = "{version}", .minimum_zig_version = "0.17.0"'
        print(json.dumps({'content': base64.b64encode(content.encode()).decode()}))
    elif '/tags?' in args[1]:
        print(json.dumps([{'name': 'v1.4.0', 'commit': {'sha': 'b' * 40}}]))
    else:
        print(json.dumps({'status': 'ahead'}))
elif args[:2] == ['pr', 'list']:
    print(json.dumps([{'number': 42, 'author': {'login': 'app/other' if os.environ['MODE'] == 'other-bot' else 'app/github-actions'},
                      'headRefOid': os.environ['REMOTE_SHA']}] if os.environ['MODE'] in ('human', 'forged', 'open', 'other-bot') else []))
elif args[:2] == ['pr', 'view']:
    field = args[args.index('--json') + 1]
    if field == 'commits': print('human-commit' if os.environ['MODE'] == 'human' else '')
    elif field == 'number': print('42')
    elif field == 'isDraft': print('true')
    elif field == 'headRefOid':
        calls = [json.loads(line) for line in open(os.environ['GH_LOG'])]
        raced = os.environ['MODE'] == 'head-race' and any(call[:2] == ['pr', 'ready'] for call in calls)
        print('c' * 40 if raced else subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip())
elif args[:2] == ['run', 'list']:
    print('123')
''')
                gh.chmod(0o755)
                log = root / 'gh.log'
                env = {**os.environ, 'PATH': str(binary) + ':' + os.environ['PATH'],
                       'GH_TOKEN': 'fixture-not-a-credential', 'GITHUB_REPOSITORY': 'fixture/koi',
                       'UPDATE_BASE': base, 'DEPENDENCY_UPDATE': json.dumps(PROPOSAL),
                       'RUNNER_TEMP': directory, 'GH_LOG': str(log), 'MODE': mode, 'REMOTE_SHA': remote_sha}
                result = subprocess.run(['bash', str(root / 'scripts/publish-dependency-updates.sh')],
                                        cwd=root, env=env, capture_output=True, text=True)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                ready = [call for call in calls if call[:2] == ['pr', 'ready'] and '--undo' not in call]
                if mode in ('success', 'human', 'forged', 'open'):
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(len(ready), 1 if mode == 'success' else 0)
                else:
                    self.assertNotEqual(result.returncode, 0)
                    if mode == 'head-race':
                        self.assertTrue(any(call[:2] == ['pr', 'ready'] and '--undo' in call for call in calls))
                    else:
                        self.assertEqual(ready, [])
                if mode in ('human', 'forged', 'open', 'other-bot', 'orphan'):
                    self.assertEqual(git('ls-remote', 'origin', 'refs/heads/chore/dependency-updates').split()[0], remote_sha)
                    self.assertFalse(any(call[:2] in (['pr', 'edit'], ['pr', 'create'], ['workflow', 'run']) for call in calls))
                else:
                    self.assertTrue(any(call[:2] == ['pr', 'create'] and '--draft' in call for call in calls))
                    dispatch = [call for call in calls if call[:2] == ['workflow', 'run']]
                    self.assertEqual(dispatch, [['workflow', 'run', 'ci.yml', '--repo', 'fixture/koi', '--ref', 'chore/dependency-updates']])
                    self.assertFalse(any(call[:2] == ['pr', 'edit'] for call in calls))


if __name__ == '__main__':
    unittest.main()

#!/usr/bin/env python3
"""Protect Action update scope and draft publication on failed CI."""
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
spec = importlib.util.spec_from_file_location('updates', ROOT / 'scripts/update-actions.py')
updates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updates)
OLD, NEW = 'a' * 40, 'b' * 40
KEY = 'actions/checkout@v6'
WORKFLOW = f'name: CI\njobs:\n  test:\n    steps:\n      - uses: actions/checkout@{OLD} # v6\n'


class ActionUpdatesTests(unittest.TestCase):
    """Use private files and fake APIs; no network or project checkout writes."""

    def test_annotated_tag_resolves_to_commit_and_rewinds_are_rejected(self):
        responses = [{'object': {'type': 'tag', 'sha': 'c' * 40}},
                     {'object': {'type': 'commit', 'sha': NEW}}, {'status': 'ahead'}]
        with patch.object(updates, 'api', side_effect=responses):
            self.assertEqual(updates.resolve(KEY, OLD), NEW)
        for status in ('behind', 'diverged'):
            with self.subTest(status=status), patch.object(updates, 'api', side_effect=[
                    {'object': {'type': 'commit', 'sha': NEW}}, {'status': status}]):
                with self.assertRaises(ValueError):
                    updates.resolve(KEY, OLD)

    def test_apply_preserves_everything_except_all_matching_pins(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / '.github/workflows'
            folder.mkdir(parents=True)
            for name in ('ci.yml', 'deps.yml'):
                (folder / name).write_text(WORKFLOW)
            with patch.object(updates, 'resolve', return_value=NEW):
                updates.apply(root, {KEY: NEW})
            for path in folder.iterdir():
                self.assertEqual(path.read_text(), WORKFLOW.replace(OLD, NEW))

    def test_invalid_or_moved_proposals_never_edit_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / '.github/workflows/ci.yml'
            path.parent.mkdir(parents=True)
            path.write_text(WORKFLOW)
            for proposed in ({'attacker/action@v1': NEW}, {KEY: 'not-a-sha'},
                             {KEY: OLD}, {KEY: NEW}):
                with self.subTest(proposed=proposed), patch.object(updates, 'resolve', return_value='c' * 40):
                    with self.assertRaises(ValueError):
                        updates.apply(root, proposed)
                    self.assertEqual(path.read_text(), WORKFLOW)

    def test_discovery_noop_and_inconsistent_pins(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / '.github/workflows/ci.yml'
            path.parent.mkdir(parents=True)
            path.write_text(WORKFLOW)
            with patch.object(updates, 'resolve', return_value=OLD):
                self.assertEqual(updates.plan(root), {})
            (path.parent / 'deps.yml').write_text(WORKFLOW.replace(OLD, NEW))
            with self.assertRaises(ValueError):
                updates.plan(root)

    def test_unpinned_remote_use_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / '.github/workflows/ci.yml'
            path.parent.mkdir(parents=True)
            path.write_text('steps:\n  - uses: actions/checkout@v6\n')
            with self.assertRaises(ValueError):
                updates.workflows(Path(directory))

    def test_publication_keeps_failed_commit_draft_and_preserves_human_branch(self):
        for mode in ('success', 'failed-ci', 'human', 'forged', 'refresh', 'other-app', 'head-race'):
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
                for name in ('update-actions.py', 'publish-action-updates.sh'):
                    shutil.copy(ROOT / 'scripts' / name, root / 'scripts' / name)
                (root / '.github/workflows').mkdir(parents=True)
                (root / '.github/workflows/ci.yml').write_text(WORKFLOW)
                git('add', '.')
                git('commit', '-qm', 'base')
                base = git('rev-parse', 'HEAD')
                git('remote', 'add', 'origin', str(remote))
                git('push', '-q', 'origin', 'main')
                remote_sha = base
                if mode in ('forged', 'refresh'):
                    git('switch', '-qc', 'chore/action-updates')
                    pending = (WORKFLOW + '      - run: echo preserve-this-edit\n' if mode == 'forged'
                               else WORKFLOW.replace(OLD, 'c' * 40))
                    (root / '.github/workflows/ci.yml').write_text(pending)
                    git('add', '.github/workflows/ci.yml')
                    git('commit', '-qm', 'chore: update Action pins')
                    remote_sha = git('rev-parse', 'HEAD')
                    git('push', '-q', 'origin', 'HEAD:refs/heads/chore/action-updates')
                    git('switch', '-q', 'main')
                elif mode in ('human', 'other-app'):
                    git('push', '-q', 'origin', 'HEAD:refs/heads/chore/action-updates')
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
        print(sha, 'completed', 'failure' if os.environ['MODE'] == 'failed-ci' else 'success', sep=' ')
    else:
        print(json.dumps({'status': 'ahead'} if '/compare/' in args[1] else
                         {'object': {'type': 'commit', 'sha': 'b' * 40}}))
elif args[:2] == ['pr', 'list']:
    print(json.dumps([{'number': 42, 'author': {'login': 'app/other' if os.environ['MODE'] == 'other-app' else 'app/fixture'},
                      'headRefOid': os.environ['REMOTE_SHA']}] if os.environ['MODE'] in ('human', 'forged', 'refresh', 'other-app') else []))
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
                       'UPDATE_APP_SLUG': 'fixture', 'UPDATE_BASE': base, 'ACTION_UPDATES': json.dumps({KEY: NEW}),
                       'RUNNER_TEMP': directory, 'GH_LOG': str(log), 'MODE': mode, 'REMOTE_SHA': remote_sha}
                result = subprocess.run(['bash', str(root / 'scripts/publish-action-updates.sh')],
                                        cwd=root, env=env, capture_output=True, text=True)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                ready = [call for call in calls if call[:2] == ['pr', 'ready'] and '--undo' not in call]
                if mode in ('success', 'refresh'):
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(len(ready), 1)
                else:
                    self.assertNotEqual(result.returncode, 0)
                    if mode == 'head-race':
                        self.assertTrue(any(call[:2] == ['pr', 'ready'] and '--undo' in call for call in calls))
                    else:
                        self.assertEqual(ready, [])
                if mode in ('human', 'forged', 'other-app'):
                    self.assertEqual(git('ls-remote', 'origin', 'refs/heads/chore/action-updates').split()[0], remote_sha)
                    self.assertIn({'human': 'human changes', 'forged': 'non-pin workflow changes',
                                   'other-app': 'another author'}[mode], result.stderr)
                elif mode != 'refresh':
                    self.assertTrue(any(call[:2] == ['pr', 'create'] and '--draft' in call for call in calls))


if __name__ == '__main__':
    unittest.main()

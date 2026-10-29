#!/usr/bin/env python3
"""Check read-only Action pin reporting and upstream direction."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('updates', ROOT / 'scripts/check-actions.py')
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


if __name__ == '__main__':
    unittest.main()

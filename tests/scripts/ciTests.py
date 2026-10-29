#!/usr/bin/env python3
"""Protect selective CI from missed native changes and falsely green gates."""
import copy
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("ci", ROOT / "scripts/ci.py")
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


class CITests(unittest.TestCase):
    """Exercise the boundaries that decide whether expensive checks may be skipped."""

    def test_docs_and_catalog_skip_native_but_packaged_files_do_not(self):
        self.assertEqual(ci.select(["docs/cli.md", "src/app/resources/programs/logos/new.svg"]),
                         {"core": False, "app": False, "bundle": False})
        for path in ("THIRD_PARTY_NOTICES.md", "licenses/new.txt", "src/app/resources/shell/koi.zsh"):
            with self.subTest(path=path):
                self.assertTrue(ci.select([path])["bundle"])

    def test_app_core_and_unknown_changes_select_their_consumers(self):
        self.assertEqual(ci.select(["tests/app/wireTests.swift"]), {"core": False, "app": True, "bundle": False})
        self.assertEqual(ci.select(["src/app/wire.swift"]), {"core": False, "app": True, "bundle": False})
        self.assertEqual(ci.select(["tests/scripts/ciTests.py", "scripts/update-actions.py"]),
                         {"core": False, "app": False, "bundle": False})
        self.assertEqual(ci.select(["tests/scripts/koid-test-isolation.sh"]),
                         {"core": False, "app": True, "bundle": False})
        self.assertFalse(ci.select(["LICENSE"])["app"])
        for path in ("src/core/wire.zig", "build.zig.zon", "scripts/bundle.sh",
                     ".github/workflows/ci.yml", "x", "new-build-input"):
            with self.subTest(path=path):
                self.assertEqual(ci.select([path]), {"core": True, "app": True, "bundle": True})

    def test_complete_diff_includes_renamed_source_and_unusual_filenames(self):
        with tempfile.TemporaryDirectory() as directory:
            def git(*args):
                """Run Git only against this test's private repository."""
                return subprocess.check_output(["git", "-C", directory, *args]).decode().strip()
            git("init", "-q")
            git("config", "user.name", "Fixture")
            git("config", "user.email", "fixture@example.invalid")
            root = Path(directory)
            (root / "src/core").mkdir(parents=True)
            (root / "src/core/old.zig").write_text("code")
            git("add", ".")
            git("commit", "-qm", "base")
            base = git("rev-parse", "HEAD")
            (root / "docs").mkdir()
            (root / "src/core/old.zig").rename(root / "docs/renamed\nfile.md")
            git("add", "-A")
            git("commit", "-qm", "move source")
            (root / "README.md").write_text("latest commit is just docs")
            git("add", ".")
            git("commit", "-qm", "docs")
            original = subprocess.check_output
            with patch.object(ci.subprocess, "check_output",
                              side_effect=lambda args: original(args, cwd=directory)):
                paths = ci.changed_paths(base, "HEAD")
            self.assertIn("src/core/old.zig", paths)
            self.assertIn("docs/renamed\nfile.md", paths)
            self.assertTrue(ci.select(paths)["core"])

    def test_non_pr_and_missing_history_run_everything(self):
        self.assertEqual(ci.selection("workflow_dispatch", {}), {"core": True, "app": True, "bundle": True})
        push = {"ref": "refs/heads/main", "before": "base", "after": "head"}
        for paths, expected in [
            (["docs/ci.md"], {"core": False, "app": False, "bundle": False}),
            (["src/app/tabs.swift"], {"core": False, "app": True, "bundle": True}),
            (["tests/app/tabsTests.swift"], {"core": False, "app": True, "bundle": False}),
        ]:
            with patch.object(ci, "changed_paths", return_value=paths):
                self.assertEqual(ci.selection("push", push), expected)
        with patch.object(ci, "changed_paths", side_effect=subprocess.CalledProcessError(1, "git")):
            event = {"pull_request": {"base": {"sha": "base"}, "head": {"sha": "head"}}}
            self.assertEqual(ci.selection("pull_request", event), {"core": True, "app": True, "bundle": True})
            self.assertEqual(ci.selection("push", push), {"core": True, "app": True, "bundle": True})
        self.assertEqual(ci.selection("push", {**push, "before": "0" * 40}),
                         {"core": True, "app": True, "bundle": True})

    def test_gate_rejects_failure_cancellation_and_unexpected_skip(self):
        for selected in ((), ("app",), ("bundle",), ("core", "app", "bundle")):
            needs = {
                "checks": {"result": "success", "outputs": {
                    name: str(name in selected).lower() for name in ("core", "app", "bundle")}},
                "native": {"result": "success" if selected else "skipped", "outputs": {
                    name: "success" if name in selected else "skipped" for name in ("core", "app", "bundle")}},
            }
            ci.check_results(needs)
            for name in needs:
                unexpected = "skipped" if name == "checks" or selected else "success"
                for result in ("failure", "cancelled", unexpected):
                    bad = copy.deepcopy(needs)
                    bad[name]["result"] = result
                    with self.subTest(selected=selected, name=name, result=result), self.assertRaises(ValueError):
                        ci.check_results(bad)
            if selected:
                for step in selected:
                    for result in ("failure", "cancelled", "skipped", ""):
                        bad = copy.deepcopy(needs)
                        bad["native"]["outputs"][step] = result
                        with self.subTest(step=step, result=result), self.assertRaises(ValueError):
                            ci.check_results(bad)
                bad = copy.deepcopy(needs)
                del bad["native"]["outputs"]
                with self.assertRaises(ValueError):
                    ci.check_results(bad)
            needs["checks"]["outputs"]["core"] = ""
            with self.assertRaises(ValueError):
                ci.check_results(needs)

if __name__ == "__main__":
    unittest.main()

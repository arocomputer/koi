#!/usr/bin/env python3
"""Keep the mutation list pointed at real code, and its verdicts honest."""
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("mutate", ROOT / "scripts/mutate.py")
mutate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mutate)


class MutationListTests(unittest.TestCase):
    def test_every_mutation_still_matches_one_place_in_the_source(self):
        # A refactor that renames the line would otherwise turn a mutation into
        # a silent no-op that always "survives" or never applies.
        for name, relative, old, new in mutate.MUTATIONS + mutate.APP_MUTATIONS:
            text = (ROOT / relative).read_text()
            self.assertEqual(text.count(old), 1, f"{name}: {relative}")
            self.assertNotEqual(old, new, name)

    def test_names_are_unique(self):
        names = [m[0] for m in mutate.MUTATIONS + mutate.APP_MUTATIONS]
        self.assertEqual(len(names), len(set(names)))

    def test_verdicts(self):
        zig_failed = "error: 'server.test.x' terminated\nBuild Summary: 45/46 steps succeeded; 111/112 tests passed"
        swift_failed = "\u2718 Test oversizedFramesAreRejected() recorded an issue at wireTests.swift:9:9"
        self.assertEqual(mutate.classify(0, "112/112 tests passed"), "survived")
        self.assertEqual(mutate.classify(1, zig_failed), "caught")
        self.assertEqual(mutate.classify(1, swift_failed), "caught")
        self.assertEqual(mutate.classify(1, "wire.swift:3:4: error: cannot find 'x' in scope"), "invalid")
        self.assertEqual(mutate.classify(1, "src/core/x.zig:1:1: error: expected ';'"), "invalid")


if __name__ == "__main__":
    unittest.main()

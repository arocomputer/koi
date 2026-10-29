"""Focused catalogue and SVG validation regressions using private temporary fixtures."""

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "check_programs", Path(__file__).resolve().parents[2] / "scripts/check-programs.py")
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)
SVG = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">{}</svg>'


class ProgramsTests(unittest.TestCase):
    """Pin catalogue diagnostics and asset integrity without touching real resources."""

    def setUp(self):
        """Create a valid catalogue with an unused, attributed SVG."""
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "logos").mkdir()
        self.entries = [{"runs": ["tool"], "name": "Tool", "text": "T",
                         "colors": ["123ABC", "abcdef"], "mark": {"symbol": "terminal"}}]
        self.manifest = {"license": "CC0-1.0", "repository": "https://example.org/icons",
                         "revision": "a" * 40, "files": []}
        self.asset("")

    def asset(self, content):
        """Replace the fixture SVG and its matching provenance digest."""
        data = SVG.format(content).encode()
        (self.root / "logos/tool.svg").write_bytes(data)
        self.manifest["files"] = [{"file": "tool.svg", "sha256": hashlib.sha256(data).hexdigest()}]

    def errors(self):
        """Persist the fixture and collect all diagnostics."""
        (self.root / "programs.json").write_text(json.dumps(self.entries))
        (self.root / "logos/sources.json").write_text(json.dumps(self.manifest))
        return "\n".join(VALIDATOR.validate(self.root))

    def test_unused_asset_and_source_overrides(self):
        self.assertEqual(self.errors(), "")
        self.manifest["files"][0].update(source="https://example.org/other", license="MIT", revision="b" * 40)
        self.assertEqual(self.errors(), "")
        del self.manifest["files"][0]["license"]
        self.assertIn("custom source needs its own license and revision", self.errors())
        self.manifest["files"][0]["license"] = "MIT"
        self.manifest["files"][0]["source"] = "http://example.org/other"
        self.assertIn("files[0].source", self.errors())

    def test_duplicate_alias_paths(self):
        self.entries.append(dict(self.entries[0]))
        self.assertIn("programs.json[1].runs[0]: duplicate alias 'tool'; first at programs.json[0].runs[0]", self.errors())
        self.entries[0]["runs"] = ["tool", "tool", "Bad/path"]
        self.assertIn("programs.json[0].runs[1]: duplicate alias", self.errors())
        self.assertIn("programs.json[0].runs[2]: expected lowercase", self.errors())

    def test_typo_color_and_glyph(self):
        self.entries[0].update(colours=[], colors=["#123456", "abcdef"], symbol="", mark={"text": " "})
        errors = self.errors()
        for path in (".colours", ".colors", "programs.json[0]: expected exactly one", ".mark"):
            self.assertIn(path, errors)

    def test_missing_and_tampered_assets(self):
        self.entries[0].pop("text")
        self.entries[0]["logo"] = "tool"
        (self.root / "logos/tool.svg").write_text(SVG.format("<path/>"))
        self.assertIn(".sha256: SHA256 mismatch", self.errors())
        (self.root / "logos/tool.svg").unlink()
        self.assertIn("programs.json[0].logo: missing logos/tool.svg", self.errors())

    def test_executable_and_external_svg(self):
        for content in ('<script/>', '<foreignObject/>', '<path onload="run()"/>',
                        '<use href="https://example.org/a.svg#x"/>',
                        '<style>path {fill:url(https://example.org/a)}</style>'):
            with self.subTest(content=content):
                self.asset(content)
                self.assertIn("logos/tool.svg:", self.errors())

    def test_provenance_and_svg_contract(self):
        self.manifest["files"].append(dict(self.manifest["files"][0]))
        self.assertIn("duplicate source record", self.errors())
        self.manifest["files"] = []
        self.assertIn("missing source record", self.errors())
        for data in (b'<!DOCTYPE svg><svg viewBox="0 0 1 1"/>',
                     b'<svg viewBox="0 0 0 24"/>', b'<svg', b' ' * (128 * 1024 + 1)):
            with self.subTest(data=data[:40]):
                self.assertIsNotNone(VALIDATOR.svg_error(data))


if __name__ == "__main__":
    unittest.main()

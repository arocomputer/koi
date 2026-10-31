#!/usr/bin/env python3
"""Validate the program catalogue and all bundled SVG provenance, without dependencies."""

import hashlib
import json
import math
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET

ALIAS = r"[a-z0-9][a-z0-9.+_-]*"
BASENAME = r"[a-zA-Z0-9][a-zA-Z0-9_-]*"


def matches(pattern, value):
    """Match a complete string, treating other JSON types as invalid."""
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def nonempty(value):
    """Accept only strings containing visible content."""
    return isinstance(value, str) and bool(value.strip())


def svg_error(data):
    """Return an error for malformed, executable or externally dependent SVG."""
    if len(data) > 128 * 1024:
        return "SVG exceeds 128 KiB"
    try:
        source = data.decode("utf-8")
        if re.search(r"<!\s*(?:DOCTYPE|ENTITY)|<\?(?!xml\s)", source, re.I):
            return "SVG DTD, entities and processing instructions are forbidden"
        root = ET.fromstring(source)
        if root.tag not in ("svg", "{http://www.w3.org/2000/svg}svg"):
            return "expected SVG root"
        box = [float(v) for v in re.split(r"[\s,]+", root.get("viewBox", "").strip())]
        if len(box) != 4 or not all(math.isfinite(v) for v in box) or min(box[2:]) <= 0:
            return "viewBox must have four finite numbers and positive dimensions"
        for node in root.iter():
            tag = node.tag.rsplit("}", 1)[-1].lower()
            if tag in {"script", "foreignobject", "animate", "animatemotion", "animatetransform", "set"}:
                return f"executable SVG element {tag} is forbidden"
            for key, value in node.attrib.items():
                key = key.rsplit("}", 1)[-1].lower()
                if key.startswith("on") or key == "base":
                    return f"executable or external SVG attribute {key} is forbidden"
                if key in {"href", "src"} and not re.fullmatch(r"#[\w.-]+", value):
                    return f"external SVG reference in {key}"
            css = " ".join(node.attrib.values()) + (node.text or "" if tag == "style" else "")
            if "\\" in css or "@" in css:
                return "SVG CSS escapes and at-rules are forbidden"
            for target in re.findall(r"url\s*\((.*?)\)", css, re.I | re.S):
                if not re.fullmatch(r"#[\w.-]+", target.strip().strip("\"'")):
                    return "external SVG url reference"
    except (UnicodeError, ET.ParseError, ValueError) as exc:
        return f"invalid SVG or viewBox: {exc}"
    return None


def validate(directory) -> list[str]:
    """Return path-qualified diagnostics for a directory containing programs.json and logos/."""
    directory = Path(directory)
    errors, aliases = [], {}

    def check(condition, path, message):
        """Accumulate a diagnostic when a required condition fails."""
        if not condition:
            errors.append(f"{path}: {message}")

    def load(relative, expected):
        """Read a JSON container, recording failures without aborting other checks."""
        try:
            value = json.loads((directory / relative).read_text(encoding="utf-8"))
            if not isinstance(value, expected):
                raise ValueError(f"expected {expected.__name__}")
            return value
        except (OSError, ValueError, UnicodeError) as exc:
            errors.append(f"{relative}: {exc}")
            return expected()

    entries = load("programs.json", list)
    check(bool(entries), "programs.json", "catalogue must be nonempty")
    for i, entry in enumerate(entries):
        path = f"programs.json[{i}]"
        if not isinstance(entry, dict):
            check(False, path, "expected entry object")
            continue
        for key in entry.keys() - {"runs", "name", "logo", "symbol", "text", "colors", "ink", "mark", "agent"}:
            check(False, f"{path}.{key}", "unknown entry field")
        check(nonempty(entry.get("name")), path + ".name", "expected nonempty name")
        runs = entry.get("runs")
        check(isinstance(runs, list) and bool(runs), path + ".runs", "expected nonempty alias list")
        for j, alias in enumerate(runs if isinstance(runs, list) else []):
            location = f"{path}.runs[{j}]"
            if not matches(ALIAS, alias):
                check(False, location, "expected lowercase executable basename")
            else:
                check(alias not in aliases, location, f"duplicate alias {alias!r}; first at {aliases.get(alias)}")
                aliases.setdefault(alias, location)
        for glyph, keys, location in [(entry, {"logo", "symbol", "text"}, path),
                                       *([(entry["mark"], {"symbol", "text"}, path + ".mark")] if "mark" in entry else [])]:
            check(isinstance(glyph, dict) and len(keys & glyph.keys()) == 1
                  and all(nonempty(glyph[k]) for k in keys & glyph.keys()), location,
                  "expected exactly one nonempty " + "/".join(sorted(keys)))
            if location.endswith(".mark") and isinstance(glyph, dict):
                check(not glyph.keys() - keys, location, "unknown mark field")
        if "agent" in entry:
            check(isinstance(entry["agent"], bool), path + ".agent", "expected boolean")
        colors = entry.get("colors")
        check(isinstance(colors, list) and len(colors) == 2 and all(matches(r"[0-9a-fA-F]{6}", c) for c in colors),
              path + ".colors", "expected two six-digit hex colors without #")
        if "ink" in entry:
            check(matches(r"[0-9a-fA-F]{6}", entry["ink"]), path + ".ink", "expected six-digit hex color")
        if "logo" in entry:
            logo = entry["logo"]
            safe = matches(BASENAME, logo)
            check(safe, path + ".logo", "expected safe logo basename without extension")
            if safe:
                check((directory / "logos" / (logo + ".svg")).is_file(), path + ".logo", f"missing logos/{logo}.svg")

    manifest = load("logos/sources.json", dict)
    records = manifest.get("files")
    check(isinstance(records, list), "logos/sources.json.files", "expected source record list")
    seen = set()
    for i, record in enumerate(records if isinstance(records, list) else []):
        path = f"logos/sources.json.files[{i}]"
        if not isinstance(record, dict):
            check(False, path, "expected source record object")
            continue
        filename = record.get("file")
        if not matches(BASENAME + r"\.svg", filename):
            check(False, path + ".file", "expected safe SVG filename")
            continue
        check(filename not in seen, path + ".file", f"duplicate source record for {filename}")
        seen.add(filename)
        source = record.get("source", manifest.get("repository"))
        try:
            url = urlsplit(source if isinstance(source, str) else "")
            valid_url = url.scheme == "https" and bool(url.hostname) and not url.username and not url.password
        except ValueError:
            valid_url = False
        check(valid_url, path + ".source", "expected HTTPS source (or manifest repository)")
        if "source" in record:
            check("license" in record and "revision" in record, path,
                  "a custom source needs its own license and revision")
        check(nonempty(record.get("license", manifest.get("license"))), path + ".license", "expected nonempty license")
        check(matches(r"[0-9a-fA-F]{40}", record.get("revision", manifest.get("revision"))), path + ".revision", "expected 40-hex revision")
        try:
            digest = hashlib.sha256((directory / "logos" / filename).read_bytes()).hexdigest()
            check(matches(r"[0-9a-fA-F]{64}", record.get("sha256")) and record["sha256"].lower() == digest,
                  path + ".sha256", f"SHA256 mismatch for logos/{filename}")
        except OSError as exc:
            check(False, path + ".file", str(exc))
    for asset in sorted((directory / "logos").glob("*.svg")):
        check(asset.name in seen, f"logos/{asset.name}", "missing source record")
        try:
            problem = svg_error(asset.read_bytes())
            check(problem is None, f"logos/{asset.name}", problem)
        except OSError as exc:
            check(False, f"logos/{asset.name}", str(exc))
    return errors


if __name__ == "__main__":
    problems = validate(Path(__file__).resolve().parent.parent / "src/app/resources/programs")
    print("\n".join(problems) if problems else "Program catalogue and SVG sources are valid.",
          file=sys.stderr if problems else sys.stdout)
    sys.exit(bool(problems))

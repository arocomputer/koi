#!/usr/bin/env python3
"""Select tests and packaging from PR inputs; enforce every selected step."""
import json
import os
from pathlib import Path
import subprocess
import sys


def select(paths):
    """Keep test-only edits out of packaging; unknown build inputs run everything."""
    core = app = bundle = False
    for path in paths:
        if path in {"README.md", "CONTRIBUTING.md", "AGENTS.md", "CLAUDE.md"}:
            continue
        if path.startswith(("docs/", ".github/PULL_REQUEST_TEMPLATE/", ".github/ISSUE_TEMPLATE/")):
            continue
        if path.startswith("src/app/resources/programs/"):
            continue  # Validated by Programs; runtime artwork checks remain local.
        if path in {"scripts/check-programs.py", "tests/scripts/programsTests.py"}:
            continue
        if path == "tests/scripts/koid-test-isolation.sh":
            app = True  # Its process-ownership checks also have a Darwin path.
            continue
        if path.startswith("tests/scripts/") or path in {
            "scripts/ci.py", "scripts/update-dependencies.py", "scripts/publish-dependency-updates.sh",
            "scripts/check-actions.py", "scripts/benchmark-remote.py",
            ".github/CODEOWNERS",
        } or path.startswith(".github/rulesets/"):
            continue
        if path.startswith("tests/app/"):
            app = True
        elif path.startswith("src/app/") and path.endswith(".swift"):
            app = True  # Optimized tests compile Swift; packaging runs on main.
        elif path.startswith("src/app/") or path == "Package.swift":
            app = bundle = True
        elif path == "THIRD_PARTY_NOTICES.md" or path == "LICENSE" or path.startswith("licenses/"):
            bundle = True  # Package changes need assembly, not unrelated Swift tests.
        else:
            core = app = bundle = True  # Includes workflows, build scripts and unknown inputs.
    return {"core": core, "app": app, "bundle": bundle}


def changed_paths(base, head):
    """Read the complete PR diff, including both paths of renames, without API limits."""
    data = subprocess.check_output([
        "git", "diff", "--no-renames", "--name-only", "-z", f"{base}...{head}", "--",
    ])
    return [os.fsdecode(path) for path in data.split(b"\0") if path]


def selection(event_name, event):
    """Select changed inputs; main packages Swift edits, manual/unknown history runs all."""
    try:
        if event_name == "pull_request":
            pr = event["pull_request"]
            return select(changed_paths(pr["base"]["sha"], pr["head"]["sha"]))
        if event_name == "push" and event.get("ref") == "refs/heads/main":
            before = event["before"]
            if not before or before == "0" * 40:
                raise ValueError("no previous main commit")
            paths = changed_paths(before, event["after"])
            chosen = select(paths)
            if any(path.startswith("src/app/") and path.endswith(".swift") for path in paths):
                chosen["bundle"] = True
            return chosen
    except (KeyError, ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Cannot determine changed inputs; running all checks: {error}", file=sys.stderr)
    return {"core": True, "app": True, "bundle": True}


def check_results(needs):
    """Require the portable job and each selected native step, not just a green job."""
    if needs["checks"]["result"] != "success":
        raise ValueError(f"checks: {needs['checks']['result']}")
    selections = needs["checks"]["outputs"]
    for name in ("core", "app", "bundle"):
        if selections.get(name) not in ("true", "false"):
            raise ValueError(f"{name}: missing or invalid selection")
    linux = needs["linux-core"]["result"]
    expected = "success" if selections["core"] == "true" else "skipped"
    if linux != expected:
        raise ValueError(f"linux-core: expected {expected}, got {linux}")
    native = needs["native"]
    selected = any(selections[name] == "true" for name in ("core", "app", "bundle"))
    expected = "success" if selected else "skipped"
    if native["result"] != expected:
        raise ValueError(f"native: expected {expected}, got {native['result']}")
    if not selected:
        return
    for name in ("core", "app", "bundle"):
        result = native.get("outputs", {}).get(name)
        expected = "success" if selections[name] == "true" else "skipped"
        if result != expected:
            raise ValueError(f"{name}: expected {expected}, got {result}")


def main():
    """Use Actions event/needs data via files and environment, never shell interpolation."""
    if sys.argv[1:] == ["select"]:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        chosen = selection(os.environ["GITHUB_EVENT_NAME"], event)
        output = "".join(f"{name}={str(value).lower()}\n" for name, value in chosen.items())
        print(output, end="")
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            stream.write(output)
    elif sys.argv[1:] == ["gate"]:
        check_results(json.loads(os.environ["CI_NEEDS"]))
        print("All required checks passed; unaffected native jobs were skipped.")
    else:
        raise ValueError("usage: scripts/ci.py select|gate")


if __name__ == "__main__":
    main()

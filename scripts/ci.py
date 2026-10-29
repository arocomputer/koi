#!/usr/bin/env python3
"""Select native PR checks and enforce their results; unknown changes run all."""
import json
import os
from pathlib import Path
import subprocess
import sys


def select(paths):
    """Skip native checks only for known inputs that cannot change native code."""
    core = app = False
    for path in paths:
        if path in {"README.md", "CONTRIBUTING.md", "AGENTS.md", "CLAUDE.md"}:
            continue
        if path.startswith(("docs/", ".github/PULL_REQUEST_TEMPLATE/", ".github/ISSUE_TEMPLATE/")):
            continue
        if path.startswith("src/app/resources/programs/"):
            continue  # Validated by Programs; runtime artwork checks remain local.
        if path in {"scripts/check-programs.py", "tests/scripts/programsTests.py"}:
            continue
        if path.startswith(("src/app/", "tests/app/")) or path == "Package.swift":
            app = True
        elif path == "THIRD_PARTY_NOTICES.md" or path == "LICENSE" or path.startswith("licenses/"):
            app = True  # These are bundled product files, not ordinary prose.
        else:
            core = app = True  # Includes CI, build scripts and new/unknown inputs.
    return {"core": core, "app": app}


def changed_paths(base, head):
    """Read the complete PR diff, including both paths of renames, without API limits."""
    data = subprocess.check_output([
        "git", "diff", "--no-renames", "--name-only", "-z", f"{base}...{head}", "--",
    ])
    return [os.fsdecode(path) for path in data.split(b"\0") if path]


def selection(event_name, event):
    """PRs select work; main/manual runs and unavailable history validate everything."""
    if event_name == "pull_request":
        try:
            pr = event["pull_request"]
            return select(changed_paths(pr["base"]["sha"], pr["head"]["sha"]))
        except (KeyError, OSError, subprocess.CalledProcessError) as error:
            print(f"Cannot determine PR changes; running all checks: {error}", file=sys.stderr)
    return {"core": True, "app": True}


def check_results(needs):
    """Require successful fast checks and selected native jobs; reject unexpected skips."""
    for name in ("changes", "scripts", "programs"):
        if needs[name]["result"] != "success":
            raise ValueError(f"{name}: {needs[name]['result']}")
    for name in ("core", "app"):
        selected = needs["changes"]["outputs"][name]
        if selected not in ("true", "false"):
            raise ValueError(f"{name}: missing or invalid selection")
        result = needs[name]["result"]
        expected = "success" if selected == "true" else "skipped"
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

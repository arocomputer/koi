#!/usr/bin/env python3
"""Report forward same-major Action updates without changing any file."""
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PIN = re.compile(
    r'^(?P<prefix>[ \t]*(?:-[ \t]+)?uses:[ \t]+)'
    r'(?P<action>[\w.-]+/[\w.-]+(?:/[\w./-]+)*)@'
    r'(?P<sha>[0-9a-f]{40})(?P<suffix>[ \t]+# v(?P<major>[1-9][0-9]*)[ \t]*)$',
    re.MULTILINE,
)
SHA = re.compile(r'[0-9a-f]{40}')


def api(path):
    """Read GitHub through gh's configured credential without handling token values."""
    return json.loads(subprocess.check_output(['gh', 'api', path], text=True))


def workflows(root):
    """Read tracked workflow-shaped files; reject symlinks and unsupported uses syntax."""
    result = {}
    for path in sorted((root / '.github/workflows').glob('*')):
        if path.suffix not in ('.yml', '.yaml'):
            continue
        if path.is_symlink():
            raise ValueError(f'{path}: workflow symlinks are not supported')
        content = path.read_text()
        # Local Actions need no external pin. Every remote use must be explicit.
        for line in content.splitlines():
            if re.match(r'^\s*(?:-\s+)?uses:', line) and not PIN.fullmatch(line):
                if not re.match(r'^\s*(?:-\s+)?uses:\s+\./[^\s]+\s*$', line):
                    raise ValueError(f'{path}: use a 40-character SHA followed by # vMAJOR')
        result[path] = content
    if not result:
        raise ValueError('no workflow files found')
    return result


def pins(contents):
    """Collect each repository/major once, requiring consistent existing pins."""
    result = {}
    for content in contents.values():
        for match in PIN.finditer(content):
            repo = '/'.join(match['action'].split('/')[:2])
            key = f'{repo}@v{match["major"]}'
            if key in result and result[key] != match['sha']:
                raise ValueError(f'{key}: inconsistent pins across workflows')
            result[key] = match['sha']
    return result


def resolve(key, current):
    """Resolve a major tag to a commit; refuse rewinds, divergent histories and bad refs."""
    repo, tag = key.split('@')
    obj = api(f'repos/{repo}/git/ref/tags/{tag}')['object']
    for _ in range(8):
        if not SHA.fullmatch(obj['sha']):
            raise ValueError(f'{key}: invalid upstream SHA')
        if obj['type'] == 'commit':
            proposed = obj['sha']
            break
        if obj['type'] != 'tag':
            raise ValueError(f'{key}: tag does not reference a commit')
        obj = api(f'repos/{repo}/git/tags/{obj["sha"]}')['object']
    else:
        raise ValueError(f'{key}: too many nested tags')
    if proposed != current:
        status = api(f'repos/{repo}/compare/{current}...{proposed}')['status']
        if status != 'ahead':
            raise ValueError(f'{key}: upstream moved {status}; review manually')
    return proposed


def plan(root):
    """Return only changed pins; do not edit files or publish anything."""
    updates = {}
    for key, current in sorted(pins(workflows(root)).items()):
        proposed = resolve(key, current)
        if proposed != current:
            updates[key] = proposed
    return updates


def main():
    """Report available same-major Action pins without editing workflows."""
    for key, sha in plan(ROOT).items():
        print(f'- `{key}`: `{sha}` (manual review)')


if __name__ == '__main__':
    main()

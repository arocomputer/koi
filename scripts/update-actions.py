#!/usr/bin/env python3
"""Resolve same-major Action pins; apply only verified SHA substitutions."""
import json
import os
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


def verify_branch(base, head):
    """Refuse to replace a branch containing anything beyond existing workflow pin edits."""
    def git(*args):
        """Read the two immutable revisions without checking out branch contents."""
        return subprocess.check_output(['git', *args])
    if git('diff', '--summary', base, head, '--').strip():
        raise ValueError('update branch adds/removes files or changes modes; preserve it manually')
    names = git('diff', '--no-renames', '--name-only', '-z', base, head, '--').split(b'\0')
    for raw in filter(None, names):
        path = os.fsdecode(raw)
        if not re.fullmatch(r'\.github/workflows/[^/]+\.ya?ml', path):
            raise ValueError('update branch contains changes outside workflow pins')
        before = git('show', f'{base}:{path}').decode()
        after = git('show', f'{head}:{path}').decode()
        # Normalize only the hash span. Commands, majors, comments and layout must match.
        def without_hashes(content):
            """Leave every byte outside a recognized SHA span intact."""
            return PIN.sub(lambda match: match[0].replace(match['sha'], '0' * 40, 1), content)
        if without_hashes(before) != without_hashes(after):
            raise ValueError('update branch contains non-pin workflow changes')


def apply(root, updates):
    """Recheck a proposed map against trusted files and upstream before writing any file."""
    contents = workflows(root)
    current = pins(contents)
    if not isinstance(updates, dict) or not updates:
        raise ValueError('expected a nonempty update map')
    for key, proposed in updates.items():
        if key not in current or not isinstance(proposed, str) or not SHA.fullmatch(proposed):
            raise ValueError('update map contains an unknown Action or invalid SHA')
        if proposed == current[key] or resolve(key, current[key]) != proposed:
            raise ValueError(f'{key}: proposal no longer matches upstream; rerun discovery')
    for path, content in contents.items():
        def replace(match):
            """Preserve the complete line except for the commit SHA."""
            repo = '/'.join(match['action'].split('/')[:2])
            key = f'{repo}@v{match["major"]}'
            return f'{match["prefix"]}{match["action"]}@{updates.get(key, match["sha"])}{match["suffix"]}'
        changed = PIN.sub(replace, content)
        if changed != content:
            path.write_text(changed)
    print('| Action | From | To |')
    print('| --- | --- | --- |')
    for key, proposed in sorted(updates.items()):
        repo = key.split('@')[0]
        print(f'| `{key}` | `{current[key][:12]}` | [{proposed[:12]}](https://github.com/{repo}/commit/{proposed}) |')


def main():
    """Expose discovery for local/CI use and a narrowly scoped internal apply command."""
    if sys.argv[1:] == ['plan']:
        updates = plan(ROOT)
        print('changed=' + str(bool(updates)).lower())
        print('updates=' + json.dumps(updates, sort_keys=True, separators=(',', ':')))
    elif sys.argv[1:] == ['apply']:
        apply(ROOT, json.loads(os.environ['ACTION_UPDATES']))
    elif len(sys.argv) == 4 and sys.argv[1] == 'verify-branch':
        verify_branch(sys.argv[2], sys.argv[3])
    else:
        raise ValueError('usage: scripts/update-actions.py plan|apply|verify-branch BASE HEAD')


if __name__ == '__main__':
    main()

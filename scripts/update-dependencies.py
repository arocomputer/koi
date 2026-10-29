#!/usr/bin/env python3
"""Propose forward stable Ghostty pins without changing toolchains or workflows."""
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
REPO = 'ghostty-org/ghostty'
FILE = 'scripts/build-ghostty-vt.sh'
PIN = re.compile(r'^GHOSTTY_COMMIT=([0-9a-f]{40})$', re.MULTILINE)
SHA = re.compile(r'[0-9a-f]{40}')
STABLE = re.compile(r'v([0-9]+)\.([0-9]+)\.([0-9]+)')


def api(path):
    """Read GitHub with gh's existing authentication; never handle token values."""
    return json.loads(subprocess.check_output(['gh', 'api', path], text=True))


def current_pin(root):
    """Require one ordinary tracked pin file with one unambiguous commit."""
    path = root / FILE
    if path.is_symlink():
        raise ValueError('dependency pin must not be a symlink')
    content = path.read_text()
    matches = PIN.findall(content)
    if len(matches) != 1:
        raise ValueError('expected exactly one Ghostty commit pin')
    return content, matches[0]


def manifest(sha):
    """Read version and compiler requirements at an immutable upstream commit."""
    data = api(f'repos/{REPO}/contents/build.zig.zon?ref={sha}')
    content = base64.b64decode(data['content'], validate=False).decode()
    fields = {}
    for key in ('version', 'minimum_zig_version'):
        matches = re.findall(r'\.' + key + r'\s*=\s*"([^"]+)"', content)
        if len(matches) != 1:
            raise ValueError(f'upstream manifest has ambiguous {key}')
        fields[key] = matches[0]
    return fields


def resolve(current):
    """Choose the newest stable same-major tag ahead of the pin with unchanged Zig."""
    before = manifest(current)
    version = re.fullmatch(r'(\d+)\.(\d+)\.(\d+)(?:-[\w.-]+)?', before['version'])
    if not version:
        raise ValueError('unrecognized current Ghostty version')
    tags = []
    page = 1
    while True:
        batch = api(f'repos/{REPO}/tags?per_page=100&page={page}')
        for tag in batch:
            match = STABLE.fullmatch(tag['name'])
            if match and int(match[1]) == int(version[1]):
                tags.append((tuple(map(int, match.groups())), tag))
        if len(batch) < 100:
            break
        page += 1
    if not tags:
        return {}
    _, latest = max(tags, key=lambda item: item[0])
    proposed = latest['commit']['sha']
    if not SHA.fullmatch(proposed):
        raise ValueError('invalid upstream commit')
    if proposed == current:
        return {}
    status = api(f'repos/{REPO}/compare/{current}...{proposed}')['status']
    if status == 'behind':
        return {}  # A development pin can already contain the latest stable tag.
    if status != 'ahead':
        raise ValueError(f'latest stable tag is {status}; review manually')
    after = manifest(proposed)
    if after['version'] != latest['name'][1:]:
        raise ValueError('stable tag and manifest version disagree')
    if after['minimum_zig_version'] != before['minimum_zig_version']:
        raise ValueError('candidate changes Zig requirements; review manually')
    return {'from': current, 'to': proposed, 'tag': latest['name']}


def plan(root):
    """Discover a single engine update; leave every local file untouched."""
    return resolve(current_pin(root)[1])


def apply(root, proposal):
    """Re-resolve a strict proposal before replacing only the pin's hash bytes."""
    content, current = current_pin(root)
    if (not isinstance(proposal, dict) or set(proposal) != {'from', 'to', 'tag'}
            or any(not isinstance(value, str) for value in proposal.values())
            or not SHA.fullmatch(proposal['to']) or proposal['from'] != current
            or proposal['to'] == current or not STABLE.fullmatch(proposal['tag'])
            or resolve(current) != proposal):
        raise ValueError('candidate no longer matches discovery; rerun the updater')
    (root / FILE).write_text(PIN.sub('GHOSTTY_COMMIT=' + proposal['to'], content))
    print(f"Ghostty {proposal['tag']}: [{current[:12]} → {proposal['to'][:12]}]"
          f"(https://github.com/{REPO}/compare/{current}...{proposal['to']}).")


def main():
    """Expose read-only discovery and narrow workflow publication operations."""
    if sys.argv[1:] == ['plan']:
        proposal = plan(ROOT)
        print('changed=' + str(bool(proposal)).lower())
        print('update=' + json.dumps(proposal, sort_keys=True, separators=(',', ':')))
    elif sys.argv[1:] == ['apply']:
        apply(ROOT, json.loads(os.environ['DEPENDENCY_UPDATE']))
    else:
        raise ValueError('usage: update-dependencies.py plan|apply')


if __name__ == '__main__':
    main()

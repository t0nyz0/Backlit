#!/usr/bin/env python3
"""Fail before publication when tracked text contains private host data.

This complements Gitleaks; neither check establishes that code is risk-free.
Public t0nyz links/branding are deliberate. No matching values are printed.
"""
from pathlib import Path
import re
import hashlib
import subprocess

root = Path(__file__).resolve().parents[1]
patterns = {
    'private host path': r'/Users/|/Volumes/|/var/folders/',
    'personal email': r'[A-Za-z0-9._%+-]+@(?:gmail|icloud|yahoo|outlook|hotmail)\.[A-Za-z]+',
    'private key': r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
}
# The checker contains the search patterns as intentional examples.
files = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')
failures = []
for name in filter(None, files):
    if Path(name).name.lower() in {"roadmap.md", "todo.md", "agents.md"} or name.startswith("private/"):
        failures.append(f'{name}: private planning or local guidance must not be tracked')
    if name == 'scripts/check_privacy.py':
        continue
    try:
        text = (root / name).read_text()
    except (UnicodeError, OSError):
        continue
    # Required upstream notices contain their authors' public contact details.
    # Only this exact pinned license may use the personal-email exception.
    upstream_license = name == 'docs/licenses/Sparkle.txt' and hashlib.sha256((root/name).read_bytes()).hexdigest() == '389a4e4e9a32f059775b13a06e25a591445ba229d2838d26dd3e7c0c45127cfe'
    for kind, pattern in patterns.items():
        if upstream_license and kind == 'personal email':
            continue
        # The owner approved this public security contact in this file only.
        if name == 'SECURITY.md' and kind == 'personal email':
            checked = re.sub(r'(?<![\w.%+@-])tonyz@outlook\.com(?![\w.%+@-])', '', text)
            found = re.search(pattern, checked) is not None
        else:
            found = re.search(pattern, text) is not None
        if found:
            failures.append(f'{name}: {kind}')
for line in subprocess.check_output(['git', 'log', '--all', '--format=%ae|%ce'], cwd=root).decode().splitlines():
    if any(not email.endswith('@users.noreply.github.com') for email in line.split('|')):
        failures.append('Git author/committer email is not a GitHub noreply address')
bundle = root/'dist/Backlit.app'
if bundle.exists():
    for file in bundle.rglob('*'):
        if file.is_file() and not file.is_symlink():
            data = file.read_bytes()
            if any(value in data for value in [str(Path.home()).encode(), b'/Users/', b'/var/folders/']):
                failures.append(f'App bundle contains a private host path: {file.relative_to(bundle)}')
if failures:
    raise SystemExit('\n'.join(sorted(set(failures))))
print('Tracked text and reachable commit-email privacy checks passed.')

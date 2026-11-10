#!/usr/bin/env python3
"""Fail before publication when tracked text contains private host data.

This complements Gitleaks; neither check establishes that code is risk-free.
Public t0nyz links/branding are deliberate. No matching values are printed.
"""
from pathlib import Path
import re
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
    for kind, pattern in patterns.items():
        if re.search(pattern, text):
            failures.append(f'{name}: {kind}')
for line in subprocess.check_output(['git', 'log', '--all', '--format=%ae|%ce'], cwd=root).decode().splitlines():
    if any(not email.endswith('@users.noreply.github.com') for email in line.split('|')):
        failures.append('Git author/committer email is not a GitHub noreply address')
binary=root/'dist/Backlit.app/Contents/MacOS/Backlit'
if binary.exists() and str(Path.home()).encode() in binary.read_bytes():
    failures.append('Compiled app contains the local home path')
if failures:
    raise SystemExit('\n'.join(sorted(set(failures))))
print('Tracked text and reachable commit-email privacy checks passed.')

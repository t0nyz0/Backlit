#!/usr/bin/env python3
"""Verify current documentation assets, version and local file links."""
import json
from pathlib import Path
import plistlib
import re

root = Path(__file__).resolve().parents[1]
files = [root/'README.md', root/'CONTRIBUTING.md', root/'SECURITY.md', *root.joinpath('docs').glob('*.md')]
# Historical research retains its original context and is not the public package.
historical = {'PRODUCT-WORKSHOP.md','PROJECT-BRIEF.md','FEATURE-IDEAS.md','HARDWARE-RESEARCH.md'}
count = 0
for file in files:
    if file.name in historical:
        continue
    text = file.read_text()
    targets = re.findall(r'\]\(([^)]+)\)', text) + re.findall(r'(?:src|srcset|href)="([^"]+)"', text)
    for target in targets:
        if target.startswith(('https://','http://','mailto:','#')):
            continue
        target = target.split('#')[0].strip('<>')
        if not target:
            continue
        assert (file.parent/target).exists(), f'{file.relative_to(root)}: missing {target}'
        count += 1
info = plistlib.loads(root.joinpath('assets/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'local.backlit'
assert info['CFBundleShortVersionString'] in root.joinpath('README.md').read_text()
assert 'https://buymeacoffee.com/tonyz' in root.joinpath('README.md').read_text()
assert root.joinpath('README.md').read_text().rstrip().endswith('alt="Buy t0nyz a coffee"></a></p>')
manifest = json.loads(root.joinpath('homeassistant/custom_components/backlit/manifest.json').read_text())
assert manifest['version'] == info['CFBundleShortVersionString']
print(f'Checked {count} local documentation references, version metadata, and the coffee badge/link.')

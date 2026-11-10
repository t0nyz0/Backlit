#!/usr/bin/env python3
"""Inspect PNGs and remove metadata chunks without changing image pixels."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import zlib

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--strip', action='store_true')
args = parser.parse_args()
forbidden = {b'eXIf', b'tEXt', b'zTXt', b'iTXt'}
images = {}
for file in sorted([*root.joinpath('docs/media').glob('*.png'), *root.joinpath('assets').glob('*.png')]):
    raw = file.read_bytes()
    assert raw[:8] == b'\x89PNG\r\n\x1a\n', file
    position = 8
    kept = [raw[:8]]
    width = height = 0
    removed = []
    while position < len(raw):
        length = struct.unpack('>I', raw[position:position+4])[0]
        kind = raw[position+4:position+8]
        payload = raw[position+8:position+8+length]
        end = position+12+length
        assert end <= len(raw), f'Truncated PNG: {file}'
        assert zlib.crc32(kind+payload) & 0xffffffff == struct.unpack('>I', raw[end-4:end])[0], f'Bad CRC: {file}'
        if kind == b'IHDR':
            width, height = struct.unpack('>II', payload[:8])
        if kind in forbidden:
            removed.append(kind.decode())
        else:
            kept.append(raw[position:end])
        position = end
    if removed and not args.strip:
        raise SystemExit(f'Metadata remains in {file.name}: {removed}; use --strip')
    if args.strip and removed:
        file.write_bytes(b''.join(kept))
    assert width and height
    if file.parent.name == 'media':
        images[file.name] = {'width': width, 'height': height, 'sha256': hashlib.sha256(file.read_bytes()).hexdigest()}
version = plistlib.loads(root.joinpath('assets/Info.plist').read_bytes())['CFBundleShortVersionString']
record = {'app_version': version, 'native_capture': True, 'isolated_preview': True,
          'source': 'Backlit --capture-suite docs/media',
          'notes': 'Owned native views, not mockups. Preview performs no hardware writes. Badge is an attributed official third-party asset. Metadata removed without changing IDAT pixels.',
          'images': images}
root.joinpath('docs/media/PROVENANCE.json').write_text(json.dumps(record, indent=2)+'\n')
print(f'Checked {len(images)} README images; PNG CRCs and metadata verified.')

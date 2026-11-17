#!/usr/bin/env python3
"""Validate PNG provenance; explicitly strip metadata without relabeling captures."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import zlib

FORBIDDEN = {b'eXIf', b'tEXt', b'zTXt', b'iTXt'}


def check_media(root: Path, strip: bool = False) -> int:
    manifest = root / 'docs/media/PROVENANCE.json'
    record = json.loads(manifest.read_text())
    if not isinstance(record.get('app_version'), str) or not record['app_version']:
        raise ValueError('Provenance must identify the actual capture version.')
    images = {}
    for file in sorted([*root.joinpath('docs/media').glob('*.png'), *root.joinpath('assets').glob('*.png')]):
        raw = file.read_bytes()
        assert raw[:8] == b'\x89PNG\r\n\x1a\n', file
        position = 8
        kept = [raw[:8]]
        width = height = 0
        removed = []
        while position < len(raw):
            assert position + 12 <= len(raw), f'Truncated PNG: {file}'
            length = struct.unpack('>I', raw[position:position+4])[0]
            kind = raw[position+4:position+8]
            payload = raw[position+8:position+8+length]
            end = position+12+length
            assert end <= len(raw), f'Truncated PNG: {file}'
            assert zlib.crc32(kind+payload) & 0xffffffff == struct.unpack('>I', raw[end-4:end])[0], f'Bad CRC: {file}'
            if kind == b'IHDR':
                width, height = struct.unpack('>II', payload[:8])
            if kind in FORBIDDEN:
                removed.append(kind.decode())
            else:
                kept.append(raw[position:end])
            position = end
        if removed and not strip:
            raise ValueError(f'Metadata remains in {file.name}: {removed}; use --strip')
        if strip and removed:
            raw = b''.join(kept)
            file.write_bytes(raw)
        assert width and height
        if file.parent.name == 'media':
            images[file.name] = {'width': width, 'height': height, 'sha256': hashlib.sha256(raw).hexdigest()}
    if images != record.get('images'):
        if not strip:
            raise ValueError('README image hashes or dimensions differ from PROVENANCE.json; review the changed media before updating provenance.')
        # --strip is an explicit media-maintenance operation. Preserve the
        # recorded capture version and all other provenance, even when the
        # current app package has a newer version. New captures must record
        # their actual version deliberately; a validation run cannot infer it.
        record['images'] = images
        manifest.write_text(json.dumps(record, indent=2)+'\n')
    return len(images)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--strip', action='store_true', help='Remove PNG metadata and refresh image hashes, preserving the recorded capture version.')
    args = parser.parse_args()
    try:
        count = check_media(Path(__file__).resolve().parents[1], strip=args.strip)
    except (ValueError, AssertionError) as error:
        raise SystemExit(str(error)) from error
    print(f'Checked {count} README images; PNG CRCs, metadata and provenance verified.')


if __name__ == '__main__':
    main()

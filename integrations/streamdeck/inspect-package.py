#!/usr/bin/env python3
"""Verify local CLI output without installing or executing it."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import stat
import sys
import zipfile

artifact, bundle = map(Path, sys.argv[1:])
root = bundle.name
with zipfile.ZipFile(artifact) as archive:
    if archive.testzip() is not None:
        raise SystemExit('Plugin archive failed its CRC check.')
    names = archive.namelist()
    if len(names) != len(set(names)):
        raise SystemExit('Plugin archive contains duplicate paths.')
    for entry in archive.infolist():
        name = PurePosixPath(entry.filename)
        if name.is_absolute() or '..' in name.parts or not name.parts or name.parts[0] != root:
            raise SystemExit('Plugin archive contains an unsafe or unexpected root path.')
        if stat.S_ISLNK(entry.external_attr >> 16):
            raise SystemExit('Plugin archive contains a symbolic link.')
    actual = {name for name in names if not name.endswith('/')}
    expected = {root + '/' + str(p.relative_to(bundle).as_posix()) for p in bundle.rglob('*') if p.is_file()}
    if actual != expected:
        raise SystemExit('Plugin package does not match the validated bundle files.')
    for name in actual:
        relative = PurePosixPath(name).relative_to(root)
        source = bundle.joinpath(*relative.parts)
        if str(relative) == 'manifest.json':
            # The official CLI reformats its staging manifest. Values must
            # remain identical; whitespace is not a change to the manifest.
            def unique_object(pairs):
                value = {}
                for key, item in pairs:
                    if key in value:
                        raise ValueError('Duplicate manifest key')
                    value[key] = item
                return value
            try:
                packed = json.loads(archive.read(name), object_pairs_hook=unique_object)
                original = json.loads(source.read_bytes(), object_pairs_hook=unique_object)
            except (ValueError, UnicodeError):
                raise SystemExit('Plugin archive manifest is invalid or ambiguous.')
            if packed != original:
                raise SystemExit('Plugin archive manifest values differ from the validated source bundle.')
        elif hashlib.sha256(archive.read(name)).digest() != hashlib.sha256(source.read_bytes()).digest():
            raise SystemExit('Plugin archive content differs from its validated source bundle.')
    manifest = json.loads(archive.read(root + '/manifest.json'))
    if manifest['UUID'] != 'com.t0nyz.backlit':
        raise SystemExit('Plugin manifest has an unexpected identifier.')
    for name in ['LICENSE', 'THIRD-PARTY-LICENSES.txt', manifest['CodePath'], manifest['PropertyInspectorPath']]:
        if not archive.read(root + '/' + name):
            raise SystemExit('Required plugin payload is empty.')
print(f'Verified {len(actual)} files under one .sdPlugin root; manifest, runtime, inspector, licenses, hashes and CRCs match.')

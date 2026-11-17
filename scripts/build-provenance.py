#!/usr/bin/env python3
"""Bind a locally built bundle to its clean source revision before packaging.

Development/source-archive builds remain possible. Only a clean, versioned
build may be packaged for release; an old signed bundle is not build evidence.
"""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[1]
RELATIVE = Path('Contents/Resources/BuildProvenance.json')


def identity(root):
    try:
        top = subprocess.check_output(['git', '-C', str(root), 'rev-parse', '--show-toplevel'], stderr=subprocess.DEVNULL, text=True).strip()
        if Path(top).resolve() != root.resolve():
            return None, None
        commit = subprocess.check_output(['git', '-C', str(root), 'rev-parse', '--verify', 'HEAD'], stderr=subprocess.DEVNULL, text=True).strip()
        dirty = bool(subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain'], stderr=subprocess.DEVNULL))
        return commit, dirty
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None, None


def versions(path):
    info = plistlib.loads(path.read_bytes())
    values = tuple(info.get(key) for key in ('CFBundleShortVersionString', 'CFBundleVersion'))
    if any(not isinstance(value, str) or not value for value in values):
        raise ValueError('Missing bundle version metadata.')
    return values


def capture(root):
    version, build = versions(root / 'assets/Info.plist')
    commit, dirty = identity(root)
    return {'format': 1, 'source_commit': commit, 'source_dirty': dirty, 'version': version, 'build': build}


def write(root, app, snapshot):
    if not isinstance(snapshot, dict) or snapshot != capture(root):
        raise ValueError('Source changed during the build; rebuild from a stable checkout.')
    if versions(app / 'Contents/Info.plist') != (snapshot['version'], snapshot['build']):
        raise ValueError('Built app version/build differs from the captured build input.')
    target = app / RELATIVE
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(snapshot, indent=2, sort_keys=True) + '\n')


def verify(root, app):
    expected = versions(root / 'assets/Info.plist')
    actual = versions(app / 'Contents/Info.plist')
    if actual != expected:
        raise ValueError('Built app version/build differs from source; rebuild before packaging.')
    try:
        record = json.loads((app / RELATIVE).read_text())
    except (OSError, ValueError) as error:
        raise ValueError('Built app has no valid source provenance; rebuild before packaging.') from error
    commit, dirty = identity(root)
    if (not commit or dirty is not False or not isinstance(record, dict) or
            type(record.get('format')) is not int or record.get('format') != 1 or record.get('source_dirty') is not False or
            record.get('source_commit') != commit or
            (record.get('version'), record.get('build')) != expected):
        raise ValueError('Built app is not from this clean source revision; rebuild before packaging.')
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['capture', 'write', 'verify'])
    parser.add_argument('target', type=Path, help='Snapshot file for capture; app bundle otherwise')
    parser.add_argument('--snapshot', type=Path, help='Pre-compilation snapshot required for write')
    parser.add_argument('--output', type=Path, help='Save the verified record for packaging')
    args = parser.parse_args()
    if args.action == 'write' and args.snapshot is None:
        parser.error('write requires --snapshot from before compilation')
    try:
        if args.action == 'capture':
            args.target.parent.mkdir(parents=True, exist_ok=True)
            args.target.write_text(json.dumps(capture(ROOT), indent=2, sort_keys=True) + '\n')
        elif args.action == 'write':
            write(ROOT, args.target, json.loads(args.snapshot.read_text()))
        else:
            record = verify(ROOT, args.target)
            if args.output:
                args.output.write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
            print('Built bundle version and clean source provenance verified.')
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Bind a locally built bundle to its clean source revision before packaging.

Development/source-archive builds remain possible. Only a clean, versioned
build may be packaged for release; an old signed bundle is not build evidence.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
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


def bundle_digest(app):
    """Hash bundle bytes, paths, link targets and modes without following links."""
    digest = hashlib.sha256()

    def metadata(value):
        return (value.st_dev, value.st_ino, value.st_mode, value.st_size,
                value.st_mtime_ns, value.st_ctime_ns)

    def add(value):
        raw = json.dumps(value, ensure_ascii=True, separators=(',', ':')).encode()
        digest.update(len(raw).to_bytes(8, 'big'))
        digest.update(raw)

    def visit(path, relative):
        before = path.lstat()
        mode = stat.S_IMODE(before.st_mode)
        if stat.S_ISLNK(before.st_mode):
            add([relative, 'link', mode, os.readlink(path)])
        elif stat.S_ISDIR(before.st_mode):
            add([relative, 'directory', mode])
            for child in sorted(path.iterdir(), key=lambda value: value.name):
                visit(child, str(child.relative_to(app)))
        elif stat.S_ISREG(before.st_mode):
            file_digest = hashlib.sha256()
            flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
            with os.fdopen(os.open(path, flags), 'rb') as stream:
                opened = os.fstat(stream.fileno())
                if metadata(opened) != metadata(before):
                    raise ValueError('App bundle changed while calculating its identity.')
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    file_digest.update(chunk)
                if metadata(os.fstat(stream.fileno())) != metadata(before):
                    raise ValueError('App bundle changed while calculating its identity.')
            add([relative, 'file', mode, file_digest.hexdigest()])
        else:
            raise ValueError('App bundle contains an unsupported special file.')
        if metadata(path.lstat()) != metadata(before):
            raise ValueError('App bundle changed while calculating its identity.')

    if app.is_symlink() or not app.is_dir():
        raise ValueError('App bundle must be a real directory.')
    visit(app, '.')
    return digest.hexdigest()


def freeze(root, app):
    record = verify(root, app)
    digest = bundle_digest(app)
    if verify(root, app) != record:
        raise ValueError('Source or app changed while packaging; retry from a stable build.')
    return {'format': 1, 'provenance': record, 'bundle_sha256': digest}


def verify_frozen(root, app, frozen):
    if (not isinstance(frozen, dict) or type(frozen.get('format')) is not int or
            frozen.get('format') != 1 or not isinstance(frozen.get('provenance'), dict) or
            not isinstance(frozen.get('bundle_sha256'), str) or
            len(frozen['bundle_sha256']) != 64 or
            any(value not in '0123456789abcdef' for value in frozen['bundle_sha256'])):
        raise ValueError('Invalid frozen package identity.')
    record = verify(root, app)
    if (record != frozen['provenance'] or bundle_digest(app) != frozen['bundle_sha256'] or
            verify(root, app) != record):
        raise ValueError('Source or app changed while packaging; retry from a stable build.')
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['capture', 'write', 'verify', 'freeze'])
    parser.add_argument('target', type=Path, help='Snapshot file for capture; app bundle otherwise')
    parser.add_argument('--snapshot', type=Path, help='Pre-compilation snapshot required for write')
    parser.add_argument('--output', type=Path, help='Save the verified record for packaging')
    parser.add_argument('--frozen', type=Path, help='Require the exact source and app identity frozen at packaging start')
    args = parser.parse_args()
    if args.action == 'freeze' and args.output is None:
        parser.error('freeze requires --output')
    if args.frozen is not None and args.action != 'verify':
        parser.error('--frozen is only valid with verify')
    if args.action == 'write' and args.snapshot is None:
        parser.error('write requires --snapshot from before compilation')
    try:
        if args.action == 'capture':
            args.target.parent.mkdir(parents=True, exist_ok=True)
            args.target.write_text(json.dumps(capture(ROOT), indent=2, sort_keys=True) + '\n')
        elif args.action == 'write':
            write(ROOT, args.target, json.loads(args.snapshot.read_text()))
        elif args.action == 'freeze':
            args.output.write_text(json.dumps(freeze(ROOT, args.target), indent=2, sort_keys=True) + '\n')
        else:
            record = (verify_frozen(ROOT, args.target, json.loads(args.frozen.read_text()))
                      if args.frozen is not None else verify(ROOT, args.target))
            if args.output:
                args.output.write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
            print('Built bundle version and clean source provenance verified.')
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()

"""Headless release provenance checks in a disposable repository and bundle."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2] / 'scripts/build-provenance.py'
spec = importlib.util.spec_from_file_location('build_provenance', SOURCE)
provenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provenance)


class BuildProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='backlit-provenance-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'dist/Backlit.app'
        self.info = {'CFBundleShortVersionString': '0.2.8', 'CFBundleVersion': '50'}
        (self.root / 'assets').mkdir()
        (self.root / 'assets/Info.plist').write_bytes(plistlib.dumps(self.info))
        (self.root / '.gitignore').write_text('dist/\n')
        (self.app / 'Contents').mkdir(parents=True)
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))
        self.git('init', '-q'); self.git('add', '.'); self.git('commit', '-qm', 'Disposable fixture')

    def git(self, *args):
        env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        return subprocess.run(['git', '-C', str(self.root), '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', '-c', 'user.name=Backlit fixture', '-c', 'user.email=backlit-fixture@users.noreply.github.com', *args], env=env, capture_output=True, check=True, text=True, timeout=10)

    def test_clean_matching_build_is_accepted(self):
        provenance.write(self.root, self.app, provenance.capture(self.root))
        record = provenance.verify(self.root, self.app)
        self.assertEqual(record['source_commit'], self.git('rev-parse', 'HEAD').stdout.strip())
        self.assertIs(record['source_dirty'], False)

    def test_stale_signed_bundle_version_or_build_is_rejected(self):
        for key, value in [('CFBundleShortVersionString', '0.2.7'), ('CFBundleVersion', '49')]:
            with self.subTest(key=key):
                info = dict(self.info); info[key] = value
                (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))
                provenance.write(self.root, self.app, provenance.capture(self.root))
                (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
                with self.assertRaisesRegex(ValueError, 'version/build differs'):
                    provenance.verify(self.root, self.app)

    def test_missing_or_malformed_provenance_is_rejected(self):
        target = self.app / provenance.RELATIVE
        for data in [None, b'not json', b'[]', b'null', b'{"format": 2}']:
            with self.subTest(data=data):
                if data is not None:
                    target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(data)
                with self.assertRaises(ValueError): provenance.verify(self.root, self.app)

    def test_build_from_another_commit_is_rejected_even_with_same_version(self):
        provenance.write(self.root, self.app, provenance.capture(self.root))
        (self.root / 'source.txt').write_text('later source\n')
        self.git('add', '.'); self.git('commit', '-qm', 'New source, same version')
        with self.assertRaisesRegex(ValueError, 'clean source revision'):
            provenance.verify(self.root, self.app)

    def test_dirty_development_build_requires_rebuild_after_commit(self):
        (self.root / 'source.txt').write_text('uncommitted source\n')
        provenance.write(self.root, self.app, provenance.capture(self.root))
        self.git('add', '.'); self.git('commit', '-qm', 'Commit the changed source')
        with self.assertRaisesRegex(ValueError, 'clean source revision'):
            provenance.verify(self.root, self.app)

    def test_commit_changed_during_compile_cannot_be_stamped_as_the_new_source(self):
        snapshot = provenance.capture(self.root)
        (self.root / 'source.txt').write_text('changed while compiling\n')
        self.git('add', '.'); self.git('commit', '-qm', 'Concurrent source change')
        with self.assertRaisesRegex(ValueError, 'Source changed during the build'):
            provenance.write(self.root, self.app, snapshot)

    def test_version_changed_during_compile_is_rejected(self):
        snapshot = provenance.capture(self.root)
        info = dict(self.info); info['CFBundleVersion'] = '51'
        (self.root / 'assets/Info.plist').write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, 'Source changed during the build'):
            provenance.write(self.root, self.app, snapshot)

    def test_current_dirty_tree_is_rejected(self):
        provenance.write(self.root, self.app, provenance.capture(self.root))
        (self.root / 'source.txt').write_text('changed source\n')
        with self.assertRaisesRegex(ValueError, 'clean source revision'):
            provenance.verify(self.root, self.app)

    def test_packager_rejects_stale_or_unproven_bundle_before_deleting_old_output(self):
        project = SOURCE.parents[1]
        (self.root / 'scripts').mkdir()
        for name in ['package.sh', 'build-provenance.py']:
            (self.root / 'scripts' / name).write_bytes((project / 'scripts' / name).read_bytes())
        self.git('add', '.'); self.git('commit', '-qm', 'Packaging fixture')
        bins = self.root / 'dist/mock-bin'; bins.mkdir(parents=True)
        signer = bins / 'codesign'; signer.write_text('#!/bin/sh\nexit 0\n'); signer.chmod(0o700)
        output = self.root / 'dist/packages'; output.mkdir()
        sentinel = output / 'old-output.txt'; sentinel.write_text('keep until validation passes')
        env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        env['PATH'] = str(bins) + os.pathsep + env['PATH']
        for stale, message in [(False, 'no valid source provenance'), (True, 'version/build differs')]:
            with self.subTest(stale=stale):
                info = dict(self.info)
                if stale: info['CFBundleVersion'] = '49'
                (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
                result = subprocess.run(['bash', 'scripts/package.sh'], cwd=self.root, env=env,
                    capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertEqual(sentinel.read_text(), 'keep until validation passes')

    def test_packager_freezes_identity_and_refuses_a_concurrent_commit(self):
        project = SOURCE.parents[1]
        (self.root / 'scripts').mkdir()
        for name in ['package.sh', 'build-provenance.py']:
            (self.root / 'scripts' / name).write_bytes((project / 'scripts' / name).read_bytes())
        (self.root / 'scripts/check_privacy.py').write_text('print("inert privacy fixture")\n')
        exporter = self.root / 'scripts/public-source.sh'
        exporter.write_text('#!/bin/sh\nset -eu\nref="${1:?Frozen source commit required}"\nprintf "%s" "$ref" > dist/exported-ref.txt\nshort="$(git rev-parse --short "$ref")"\ntouch "dist/Backlit-public-source-$short.zip"\n')
        (self.root / 'source.txt').write_text('initial source\n')
        self.git('add', '.'); self.git('commit', '-qm', 'Packaging race fixture')
        original = self.git('rev-parse', 'HEAD').stdout.strip()
        provenance.write(self.root, self.app, provenance.capture(self.root))
        bins = self.root / 'dist/mock-bin'; bins.mkdir(parents=True)
        bodies = {
            'codesign': '#!/bin/sh\nexit 0\n',
            'lipo': '#!/bin/sh\necho arm64\n',
            'ditto': '#!/bin/sh\nfor last; do :; done\ncase "$1" in -c) touch "$last";; *) /bin/cp -R "$1" "$2";; esac\n',
            'hdiutil': '#!/bin/sh\nset -eu\nfor last; do :; done\ntouch "$last"\nprintf changed > source.txt\ngit add source.txt\ngit -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name="Backlit fixture" -c user.email=backlit-fixture@users.noreply.github.com commit -qm "Concurrent change"\n',
        }
        for name, body in bodies.items():
            tool = bins / name; tool.write_text(body); tool.chmod(0o700)
        output = self.root / 'dist/packages'; output.mkdir()
        sentinel = output / 'old-output.txt'; sentinel.write_text('previous package')
        env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        env['PATH'] = str(bins) + os.pathsep + env['PATH']
        result = subprocess.run(['bash', 'scripts/package.sh'], cwd=self.root, env=env,
            capture_output=True, text=True, timeout=15)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('clean source revision', result.stderr)
        self.assertEqual((self.root / 'dist/exported-ref.txt').read_text(), original)
        self.assertEqual(sentinel.read_text(), 'previous package')
        self.assertFalse(list((self.root / 'dist').glob('package-work.*')))

    def test_archive_nested_in_another_repository_cannot_borrow_its_identity(self):
        archive = self.root / 'dist/source-archive'
        archive.mkdir(parents=True)
        self.assertEqual(provenance.identity(archive), (None, None))

    def test_source_archive_can_build_but_cannot_claim_release_provenance(self):
        with tempfile.TemporaryDirectory(prefix='backlit-unversioned-') as temp:
            root = Path(temp); (root / 'assets').mkdir()
            (root / 'assets/Info.plist').write_bytes(plistlib.dumps(self.info))
            provenance.write(root, self.app, provenance.capture(root))
            record = json.loads((self.app / provenance.RELATIVE).read_text())
            self.assertIsNone(record['source_commit'])
            self.assertIsNone(record['source_dirty'])
            with self.assertRaisesRegex(ValueError, 'clean source revision'):
                provenance.verify(root, self.app)


if __name__ == '__main__': unittest.main()

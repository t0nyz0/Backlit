"""Media checks must not relabel historical screenshots as a new app release."""
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import zlib

SPEC = importlib.util.spec_from_file_location('check_media', Path(__file__).resolve().parents[2] / 'scripts/check_media.py')
MEDIA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MEDIA)


def chunk(kind, payload):
    return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload) & 0xffffffff)


def png(metadata=False):
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0))
            + (chunk(b'tEXt', b'fixture\x00metadata') if metadata else b'')
            + chunk(b'IDAT', zlib.compress(b'\x00\x00\x00\x00')) + chunk(b'IEND', b''))


class MediaProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / 'docs/media').mkdir(parents=True)
        (self.root / 'assets').mkdir()
        self.image = self.root / 'docs/media/fixture.png'
        self.image.write_bytes(png())
        self.manifest = self.root / 'docs/media/PROVENANCE.json'
        self.record = {'app_version': '0.2.5', 'native_capture': True, 'isolated_preview': True,
                       'source': 'fixture capture', 'notes': 'Preserve provenance verbatim.',
                       'images': {'fixture.png': {'width': 1, 'height': 1, 'sha256': hashlib.sha256(png()).hexdigest()}}}
        # Deliberate formatting makes accidental serialization detectable too.
        self.manifest.write_text(json.dumps(self.record, separators=(',', ':')) + '\n')
        self.package_version('0.2.5')

    def package_version(self, version):
        (self.root / 'assets/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': version}))

    def test_package_version_bump_is_read_only_and_retains_capture_version(self):
        before_manifest, before_image = self.manifest.read_bytes(), self.image.read_bytes()
        for version in ['0.2.8', '0.2.9', '9.0.0']:
            self.package_version(version)
            self.assertEqual(MEDIA.check_media(self.root), 1)
            self.assertEqual(self.manifest.read_bytes(), before_manifest)
            self.assertEqual(self.image.read_bytes(), before_image)
            self.assertEqual(json.loads(self.manifest.read_text())['app_version'], '0.2.5')

    def test_mismatched_provenance_is_rejected_not_silently_refreshed(self):
        self.record['images']['fixture.png']['sha256'] = '0' * 64
        self.manifest.write_text(json.dumps(self.record))
        before_manifest, before_image = self.manifest.read_bytes(), self.image.read_bytes()
        with self.assertRaisesRegex(ValueError, 'differ from PROVENANCE'):
            MEDIA.check_media(self.root)
        self.assertEqual(self.manifest.read_bytes(), before_manifest)
        self.assertEqual(self.image.read_bytes(), before_image)

    def test_default_rejects_metadata_without_modifying_any_file(self):
        self.image.write_bytes(png(metadata=True))
        before_manifest, before_image = self.manifest.read_bytes(), self.image.read_bytes()
        with self.assertRaisesRegex(ValueError, 'Metadata remains'):
            MEDIA.check_media(self.root)
        self.assertEqual(self.manifest.read_bytes(), before_manifest)
        self.assertEqual(self.image.read_bytes(), before_image)

    def test_explicit_strip_preserves_capture_version_and_provenance(self):
        self.package_version('0.2.9')
        self.image.write_bytes(png(metadata=True))
        self.record['images']['fixture.png']['sha256'] = hashlib.sha256(self.image.read_bytes()).hexdigest()
        self.manifest.write_text(json.dumps(self.record))
        MEDIA.check_media(self.root, strip=True)
        after = json.loads(self.manifest.read_text())
        self.assertEqual(after['app_version'], '0.2.5')
        self.assertEqual({k: v for k, v in after.items() if k != 'images'},
                         {k: v for k, v in self.record.items() if k != 'images'})
        self.assertEqual(self.image.read_bytes(), png())
        self.assertEqual(after['images']['fixture.png']['sha256'], hashlib.sha256(png()).hexdigest())
        before = self.manifest.read_bytes()
        MEDIA.check_media(self.root)
        self.assertEqual(self.manifest.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()

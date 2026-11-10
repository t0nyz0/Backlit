"""Optional integration checks against Sparkle's official sign_update tool.

Only ephemeral fixture keys are supplied over stdin; Keychain is never used.
Set BACKLIT_SPARKLE_SIGN_TOOL to a locally verified Sparkle distribution tool.
These test signatures, not an application installation or rollback.
"""
import base64
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

TOOL = os.environ.get('BACKLIT_SPARKLE_SIGN_TOOL')

@unittest.skipUnless(TOOL, 'official Sparkle sign_update tool not configured')
class UpdateSignatureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.key = base64.b64encode(os.urandom(32))

    def run_tool(self, *args, key=None):
        return subprocess.run([TOOL, '--ed-key-file', '-', *map(str, args)],
                              input=self.key if key is None else key,
                              capture_output=True, timeout=15)

    def archive(self):
        file = self.root/'fixture.zip'
        file.write_bytes(b'isolated fixture payload; not executable' + os.urandom(128))
        result = self.run_tool('-p', file)
        self.assertEqual(result.returncode, 0)
        return file, result.stdout.strip().decode()

    def test_archive_signature_accepts_original_and_rejects_tamper_truncation(self):
        file, signature = self.archive()
        original = file.read_bytes()
        self.assertEqual(self.run_tool('--verify', file, signature).returncode, 0)
        for bad in [original+b'x', original[:-1], bytes([original[0]^1])+original[1:]]:
            file.write_bytes(bad)
            self.assertNotEqual(self.run_tool('--verify', file, signature).returncode, 0)

    def test_archive_rejects_wrong_key_and_missing_signature(self):
        file, signature = self.archive()
        wrong = base64.b64encode(os.urandom(32))
        self.assertNotEqual(self.run_tool('--verify', file, signature, key=wrong).returncode, 0)
        self.assertNotEqual(self.run_tool('--verify', file, 'AA==').returncode, 0)

    def test_signed_feed_rejects_modified_and_unsigned_metadata(self):
        file = self.root/'appcast.xml'
        source = b'<?xml version="1.0"?><rss version="2.0"><channel><title>Fixture</title></channel></rss>'
        file.write_bytes(source)
        self.assertNotEqual(self.run_tool('--verify', file).returncode, 0)
        self.assertEqual(self.run_tool(file).returncode, 0)
        self.assertEqual(self.run_tool('--verify', file).returncode, 0)
        signed = file.read_bytes()
        file.write_bytes(signed.replace(b'Fixture', b'Altered'))
        self.assertNotEqual(self.run_tool('--verify', file).returncode, 0)
        file.write_bytes(signed)
        self.assertNotEqual(self.run_tool('--verify', file, key=base64.b64encode(os.urandom(32))).returncode, 0)

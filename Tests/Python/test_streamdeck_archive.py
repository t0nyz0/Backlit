"""Archive checks use tiny fixtures, without Node, Stream Deck or app execution."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

CHECKER = Path(__file__).resolve().parents[2] / 'integrations/streamdeck/inspect-package.py'


class StreamDeckArchiveTests(unittest.TestCase):
    def check_fixture(self, manifest_change=None, runtime_change=False, duplicate=False):
        with tempfile.TemporaryDirectory(prefix='backlit-plugin-fixture-') as folder:
            root = Path(folder)
            bundle = root / 'com.t0nyz.backlit.sdPlugin'
            bundle.mkdir()
            manifest = {'UUID': 'com.t0nyz.backlit', 'CodePath': 'plugin.js', 'PropertyInspectorPath': 'settings.html'}
            (bundle / 'manifest.json').write_text(json.dumps(manifest, separators=(',', ':')))
            for name in ['plugin.js', 'settings.html', 'LICENSE', 'THIRD-PARTY-LICENSES.txt']:
                (bundle / name).write_text('fixture ' + name)
            if manifest_change:
                manifest.update(manifest_change)
            package = root / 'fixture.streamDeckPlugin'
            with zipfile.ZipFile(package, 'w') as archive:
                for file in bundle.iterdir():
                    content = file.read_bytes()
                    if file.name == 'manifest.json':
                        content = json.dumps(manifest, indent=4).encode()
                        if duplicate:
                            content = content[:-1] + b', "UUID":"com.t0nyz.backlit"}'
                    elif file.name == 'plugin.js' and runtime_change:
                        content += b' changed runtime'
                    archive.writestr(bundle.name + '/' + file.name, content)
            return subprocess.run([sys.executable, str(CHECKER), str(package), str(bundle)], capture_output=True)

    def test_cli_manifest_formatting_is_accepted(self):
        result = self.check_fixture()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_changed_manifest_values_are_rejected(self):
        self.assertNotEqual(self.check_fixture({'UUID': 'different'}).returncode, 0)

    def test_changed_runtime_is_rejected(self):
        self.assertNotEqual(self.check_fixture(runtime_change=True).returncode, 0)

    def test_duplicate_manifest_keys_are_rejected(self):
        self.assertNotEqual(self.check_fixture(duplicate=True).returncode, 0)

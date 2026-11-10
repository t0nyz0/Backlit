"""Exercise the supported local install script in a disposable filesystem.

This does not test Sparkle's installer or touch /Applications, permissions,
logo ownership, or running applications. All external commands are fixtures.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2]/'scripts/install.sh'

class LocalInstallerTests(unittest.TestCase):
    def fixture(self, failure):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); (root/'scripts').mkdir(); apps=root/'Applications'; apps.mkdir()
            old=apps/'Backlit.app'; old.mkdir(); (old/'marker').write_text('old')
            new=root/'dist/Backlit.app/Contents/MacOS'; new.mkdir(parents=True)
            (new.parents[1]/'marker').write_text('new')
            executable=new/'Backlit'; executable.write_text('#!/bin/sh\nexit 0\n'); executable.chmod(0o700)
            script=SOURCE.read_text().replace('app_target="/Applications/Backlit.app"','app_target="'+str(old)+'"').replace('/Applications/.backlit-install.',str(apps)+'/.backlit-install.')
            (root/'scripts/install.sh').write_text(script)
            bins=root/'bin'; bins.mkdir()
            commands={
                'ditto': '#!/bin/sh\n[ "$FAILURE" = copy ] && exit 1\n[ "$FAILURE" = interrupt ] && kill -TERM "$PPID" && exit 1\n/bin/cp -R "$1" "$2"\n',
                'codesign': '#!/bin/sh\n[ "$FAILURE" = signature ] && exit 1\nexit 0\n',
                'mv': '#!/bin/sh\ncase "$1" in */Backlit.app) [ "$FAILURE" = swap ] && [ "$2" = "$TEST_TARGET" ] && exit 1;; esac\n/bin/mv "$@"\n',
                'open': '#!/bin/sh\nif [ "$FAILURE" = launch ] && [ "$(cat "$1/marker")" = new ]; then exit 1; fi\nprintf "%s\\n" "$(cat "$1/marker")" >> "$OPEN_LOG"\n'
            }
            for name,content in commands.items():
                p=bins/name; p.write_text(content); p.chmod(0o700)
            env=dict(os.environ, PATH=str(bins)+':/usr/bin:/bin',FAILURE=failure,TEST_TARGET=str(old),OPEN_LOG=str(root/'open.log'))
            result=subprocess.run(['/bin/bash',str(root/'scripts/install.sh')],env=env,capture_output=True,timeout=10)
            return result.returncode,(old/'marker').read_text(), list(apps.glob('.backlit-install.*'))
    def test_success_installs_only_new_bundle(self):
        code,marker,stages=self.fixture('none')
        self.assertEqual(code,0); self.assertEqual(marker,'new'); self.assertFalse(stages)
    def test_signature_copy_swap_launch_and_interruption_preserve_previous_bundle(self):
        for failure in ['signature','copy','swap','launch','interrupt']:
            with self.subTest(failure=failure):
                code,marker,stages=self.fixture(failure)
                self.assertNotEqual(code,0); self.assertEqual(marker,'old'); self.assertFalse(stages)

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
            root = Path(temp)
            (root/'scripts').mkdir()
            apps = root/'Applications'
            apps.mkdir()
            old = apps/'Backlit.app'
            old.mkdir()
            (old/'marker').write_text('old')
            new = root/'dist/Backlit.app/Contents/MacOS'
            new.mkdir(parents=True)
            (new.parents[1]/'marker').write_text('new')
            executable = new/'Backlit'
            executable.write_text('#!/bin/sh\nexit 0\n')
            executable.chmod(0o700)
            script = SOURCE.read_text().replace(
                'app_target="/Applications/Backlit.app"', 'app_target="'+str(old)+'"'
            ).replace('/Applications/.backlit-install.', str(apps)+'/.backlit-install.')
            (root/'scripts/install.sh').write_text(script)
            bins = root/'bin'
            bins.mkdir()
            commands = {
                'ditto': '''#!/bin/sh
[ "$FAILURE" = copy ] && exit 1
[ "$FAILURE" = interrupt ] && kill -TERM "$PPID" && exit 1
case "$2" in
  */install-backups/*) if [ "$FAILURE" = backup_copy ]; then /bin/cp -R "$1" "$2"; exit 1; fi;;
esac
/bin/cp -R "$1" "$2"
''',
                'codesign': '''#!/bin/sh
[ "$FAILURE" = signature ] && exit 1
for last; do :; done
case "$last" in */install-backups/*) [ "$FAILURE" = backup_signature ] && exit 1;; esac
printf '%s\\n' "$last" >> "$VERIFY_LOG"
exit 0
''',
                'mv': '''#!/bin/sh
case "$1" in */Backlit.app) [ "$FAILURE" = swap ] && [ "$2" = "$TEST_TARGET" ] && exit 1;; esac
if [ "$FAILURE" = prior_move ] && [ "$1" = "$TEST_TARGET" ]; then exit 1; fi
if [ "$FAILURE" = rollback_new_move ] && [ "$1" = "$TEST_TARGET" ] && [ "$(cat "$1/marker")" = new ]; then exit 1; fi
case "$1" in */Previous.app) [ "$FAILURE" = rollback_restore ] && exit 1;; esac
/bin/mv "$@"
''',
                'open': '''#!/bin/sh
marker="$(cat "$1/marker")"
case "$FAILURE" in launch|rollback_new_move|rollback_restore) [ "$marker" = new ] && exit 1;; esac
printf '%s\\n' "$marker" >> "$OPEN_LOG"
# Simulate accepted launch followed by immediate runtime failure. The installer
# sees status zero, exactly as it would from a successful Launch Services request.
if [ "$FAILURE" = accepted_crash ] && [ "$marker" = new ]; then
  printf 'crashed immediately\\n' > "$RUNTIME_LOG"
fi
exit 0
'''
            }
            for name, content in commands.items():
                p = bins/name
                p.write_text(content)
                p.chmod(0o700)
            env = dict(os.environ, PATH=str(bins)+':/usr/bin:/bin', FAILURE=failure,
                       TEST_TARGET=str(old), OPEN_LOG=str(root/'open.log'),
                       VERIFY_LOG=str(root/'verify.log'), RUNTIME_LOG=str(root/'runtime.log'))
            result = subprocess.run(['/bin/bash', str(root/'scripts/install.sh')],
                                    env=env, capture_output=True, timeout=10)
            backups = []
            for backup in sorted((root/'dist/install-backups').glob('previous.*')):
                bundle = backup/'Previous.app'
                backups.append({
                    'marker': (bundle/'marker').read_text() if (bundle/'marker').exists() else None,
                    'verified': (backup/'VALIDATION.txt').exists(),
                    'validation': (backup/'VALIDATION.txt').read_text() if (backup/'VALIDATION.txt').exists() else '',
                })
            return {
                'code': result.returncode,
                'marker': (old/'marker').read_text() if (old/'marker').exists() else None,
                'stages': list(apps.glob('.backlit-install.*')),
                'staged_previous': [
                    (stage/'Previous.app/marker').read_text()
                    for stage in apps.glob('.backlit-install.*')
                    if (stage/'Previous.app/marker').exists()
                ],
                'backups': backups,
                'stdout': result.stdout.decode(), 'stderr': result.stderr.decode(),
                'runtime': (root/'runtime.log').read_text() if (root/'runtime.log').exists() else None,
                'verification_count': len((root/'verify.log').read_text().splitlines()) if (root/'verify.log').exists() else 0,
            }

    def test_success_retains_signature_verified_prior_bundle_after_normal_exit(self):
        result = self.fixture('none')
        self.assertEqual(result['code'], 0)
        self.assertEqual(result['marker'], 'new')
        self.assertFalse(result['stages'])
        self.assertEqual(len(result['backups']), 1)
        backup = result['backups'][0]
        self.assertEqual(backup['marker'], 'old')
        self.assertTrue(backup['verified'])
        self.assertIn('NOT been verified', backup['validation'])
        self.assertGreaterEqual(result['verification_count'], 3)
        self.assertIn('startup health is not yet verified', result['stdout'])

    def test_accepted_launch_followed_by_immediate_crash_still_has_recoverable_prior_bundle(self):
        result = self.fixture('accepted_crash')
        self.assertEqual(result['code'], 0, 'Accepted launch alone is not a health check')
        self.assertEqual(result['runtime'], 'crashed immediately\n')
        self.assertEqual(result['marker'], 'new')
        self.assertFalse(result['stages'])
        self.assertEqual(result['backups'][0]['marker'], 'old')
        self.assertTrue(result['backups'][0]['verified'])
        self.assertIn('startup health is not yet verified', result['stdout'])
        self.assertNotIn('reopened', result['stdout'])

    def test_signature_copy_swap_launch_and_interruption_restore_previous_bundle(self):
        for failure in ['signature', 'copy', 'swap', 'launch', 'interrupt']:
            with self.subTest(failure=failure):
                result = self.fixture(failure)
                self.assertNotEqual(result['code'], 0)
                self.assertEqual(result['marker'], 'old')
                self.assertFalse(result['stages'])
                for backup in result['backups']:
                    if backup['verified']:
                        self.assertEqual(backup['marker'], 'old')

    def test_failed_backup_copy_verification_or_prior_move_never_deletes_existing_bundle(self):
        for failure in ['backup_copy', 'backup_signature', 'prior_move']:
            with self.subTest(failure=failure):
                result = self.fixture(failure)
                self.assertNotEqual(result['code'], 0)
                self.assertEqual(result['marker'], 'old')
                self.assertFalse(result['stages'])
                if failure == 'prior_move':
                    self.assertEqual(result['backups'][0]['marker'], 'old')
                    self.assertTrue(result['backups'][0]['verified'])
                else:
                    self.assertFalse(any(backup['verified'] for backup in result['backups']))

    def test_failed_rollback_move_retains_both_recovery_copies(self):
        for failure in ['rollback_new_move', 'rollback_restore']:
            with self.subTest(failure=failure):
                result = self.fixture(failure)
                self.assertNotEqual(result['code'], 0)
                self.assertEqual(result['staged_previous'], ['old'])
                self.assertEqual(result['backups'][0]['marker'], 'old')
                self.assertTrue(result['backups'][0]['verified'])
                self.assertIn('Rollback could not', result['stderr'])

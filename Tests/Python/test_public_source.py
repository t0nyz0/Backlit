"""Exercise the real source exporter in a disposable committed Git repository.

No production repository, app, settings or signing keys are used. The archive's
links are checked after export: working-tree checks cannot catch an allowlist
that omits a newly linked public document.
"""
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import shutil
import subprocess
import tempfile
import unittest
import zipfile


PROJECT = Path(__file__).resolve().parents[2]
PUBLIC_DOCS = [
    'HOME-ASSISTANT.md', 'MCP.md', 'SHORTCUTS.md', 'ICON.md', 'PRIVACY.md',
    'ATTRIBUTION.md', 'VALIDATION.md', 'RELEASE.md', 'LOCALIZATION.md',
    'USER-GUIDE.md',
]


def local_targets(text):
    targets = re.findall(r'\]\(([^)]+)\)', text)
    targets += re.findall(r'(?:src|srcset|href)="([^"]+)"', text)
    for target in targets:
        if target.startswith(('https://', 'http://', 'mailto:', '#')):
            continue
        target = target.split('#')[0].strip('<>')
        if target:
            yield target


@unittest.skipUnless(shutil.which('git') and shutil.which('ditto'),
                     'source-export integration requires Git and macOS ditto')
class PublicSourceArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='backlit-public-source-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        # Do not inherit a caller's repository selection. Author identity and
        # hook/signing settings below apply only to this disposable fixture.
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith('GIT_')}
        self.git('init', '--quiet')
        for directory in ['.github', 'Sources', 'Tests', 'assets',
                          'integrations', 'docs/licenses', 'docs/media']:
            self.write(directory + '/fixture.txt', 'public fixture\n')
        for file in ['README.md', 'LICENSE', '.github/SECURITY.md', '.github/CONTRIBUTING.md',
                     'Package.swift', 'Package.resolved', '.gitignore']:
            self.write(file, (PROJECT / file).read_text())
        self.write('scripts/public-source.sh',
                   (PROJECT / 'scripts/public-source.sh').read_text())
        for name in PUBLIC_DOCS:
            self.write('docs/' + name, (PROJECT / 'docs' / name).read_text())
        self.write('docs/media/README.md',
                   (PROJECT / 'docs/media/README.md').read_text())
        self.write('docs/header.png', 'placeholder public image\n')
        self.write('integrations/homeassistant/custom_components/backlit/manifest.json',
                   (PROJECT / 'integrations/homeassistant/custom_components/backlit/manifest.json').read_text())
        # Stub public linked assets, but keep the project's real documentation
        # and links. New README links expose future source-allowlist omissions.
        for document in [self.root / 'README.md', *self.root.joinpath('docs').rglob('*.md'),
                         *self.root.joinpath('.github').glob('*.md')]:
            for target in local_targets(document.read_text()):
                path = document.parent / target
                if not path.exists():
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text('public linked fixture\n')
        for file in ['AGENTS.md', 'private/ROADMAP.md', 'docs/reference/research.md',
                     'docs/PROJECT-BRIEF.md', '.env']:
            self.write(file, 'PRIVATE FIXTURE: must never be exported\n')
        self.git('add', '--force', '.')
        self.git('commit', '--quiet', '-m', 'Disposable public-source fixture')
        self.commit = self.git('rev-parse', 'HEAD').stdout.strip()

    def write(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def git(self, *args):
        return subprocess.run(
            ['git', '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false',
             '-c', 'user.name=Backlit export fixture',
             '-c', 'user.email=backlit-fixture@users.noreply.github.com', *args],
            cwd=self.root, env=self.env, capture_output=True, text=True,
            check=True, timeout=15)

    def export(self):
        result = subprocess.run(['bash', 'scripts/public-source.sh'], cwd=self.root,
                                env=self.env, capture_output=True, text=True,
                                timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        archives = list(self.root.joinpath('dist').glob('Backlit-public-source-*.zip'))
        self.assertEqual(len(archives), 1)
        return zipfile.ZipFile(archives[0])

    def test_exported_archive_contains_current_docs_and_resolves_public_links(self):
        with self.export() as archive:
            names = set(archive.namelist())
            for name in ['MCP.md', 'SHORTCUTS.md', 'ICON.md']:
                self.assertEqual(archive.read('Backlit/docs/' + name),
                                 (PROJECT / 'docs' / name).read_bytes())
            self.assertIn('Backlit/integrations/homeassistant/custom_components/backlit/manifest.json', names)
            self.assertFalse(any(name.startswith('Backlit/homeassistant/') for name in names))
            documents = [name for name in names if name == 'Backlit/README.md' or
                         name.startswith(('Backlit/docs/', 'Backlit/.github/')) and name.endswith('.md')]
            for name in ['CONTRIBUTING.md', 'SECURITY.md']:
                self.assertIn('Backlit/.github/' + name, names)
                self.assertNotIn('Backlit/' + name, names)
            for name in documents:
                for target in local_targets(archive.read(name).decode()):
                    resolved = posixpath.normpath(posixpath.join(
                        str(PurePosixPath(name).parent), target))
                    self.assertTrue(resolved in names or
                                    any(entry.startswith(resolved.rstrip('/') + '/')
                                        for entry in names),
                                    f'Exported {name} links to missing {target}')

    def test_export_uses_committed_bytes_and_excludes_private_files_and_history(self):
        original = (self.root / 'docs/MCP.md').read_bytes()
        self.write('docs/MCP.md', 'UNCOMMITTED PRIVATE CHANGE\n')
        with self.export() as archive:
            names = archive.namelist()
            self.assertEqual(archive.read('Backlit/docs/MCP.md'), original)
            for forbidden in ['AGENTS.md', 'private/', 'docs/reference/',
                              'docs/PROJECT-BRIEF.md', '.env', '.git/']:
                self.assertFalse(any(name == 'Backlit/' + forbidden or
                                     name.startswith('Backlit/' + forbidden)
                                     for name in names), forbidden)
            provenance = json.loads(archive.read('Backlit/PUBLICATION.json'))
            self.assertEqual(provenance['source_commit'], self.commit)
            self.assertIs(provenance['contains_git_history'], False)
            self.assertIs(provenance['visibility_changed'], False)


if __name__ == '__main__':
    unittest.main()

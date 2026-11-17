"""Exercise the actual packager in disposable repositories with inert native tools.

No app is built, launched, signed or mounted, and no production output is changed.
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

PROJECT = Path(__file__).resolve().parents[2]
TOOL = r'''#!/usr/bin/env python3
import json,os,pathlib,plistlib,shutil,signal,subprocess,sys,zipfile
root=pathlib.Path.cwd();name=pathlib.Path(sys.argv[0]).name;args=sys.argv[1:]
with (root/'dist/tool-events.jsonl').open('a') as f:f.write(json.dumps([name,args])+'\n')
def mutate(phase):
    if os.environ.get('RACE_PHASE')!=phase or (root/'dist/mutated').exists():return
    (root/'dist/mutated').touch();kind=os.environ.get('RACE_KIND','rebuild');app=root/'dist/Backlit.app'
    if kind=='snapshot':
        target=next(root.glob('dist/package-work.*/app/Backlit.app/Contents/MacOS/Backlit'))
        target.write_text('changed private snapshot\n');return
    if kind!='samecommit':
        (root/'source.txt').write_text('source B\n')
        if kind=='rebuild':
            info=plistlib.loads((root/'assets/Info.plist').read_bytes());info['CFBundleVersion']='52'
            (root/'assets/Info.plist').write_bytes(plistlib.dumps(info))
        command=['git','-c','core.hooksPath=/dev/null','-c','commit.gpgsign=false','-c','user.name=Backlit package fixture','-c','user.email=backlit-fixture@users.noreply.github.com']
        subprocess.run(command+['add','.'],check=True,capture_output=True)
        subprocess.run(command+['commit','-qm','Concurrent source B'],check=True,capture_output=True)
    if kind in {'rebuild','samecommit'}:
        subprocess.run([sys.executable,'-B','scripts/build-provenance.py','capture','dist/input-b.json'],check=True,capture_output=True)
        shutil.copyfile(root/'assets/Info.plist',app/'Contents/Info.plist')
        (app/'Contents/MacOS/Backlit').write_text('inert executable B\n')
        subprocess.run([sys.executable,'-B','scripts/build-provenance.py','write',str(app),'--snapshot','dist/input-b.json'],check=True,capture_output=True)
def archive(source,target,parent=False):
    with zipfile.ZipFile(target,'w') as z:
        for p in sorted(source.rglob('*')):
            if p.is_file() and not p.is_symlink():
                z.write(p,(source.name+'/' if parent else '')+str(p.relative_to(source)))
if name=='codesign':
    if os.environ.get('FAILURE')=='signature' and '/package-work.' in args[-1]:sys.exit(31)
    sys.exit(0)
if name=='lipo':print('arm64')
elif name=='ditto':
    if args[0]=='-c':
        archive(pathlib.Path(args[-2]),pathlib.Path(args[-1]),True);mutate('afterzip')
    else:
        mutate('copy')
        if os.environ.get('FAILURE')=='copy':sys.exit(32)
        if os.environ.get('FAILURE')=='interruptcopy':
            os.kill(os.getppid(),signal.SIGTERM);sys.exit(1)
        shutil.copytree(args[0],args[1],symlinks=True)
        if os.environ.get('FAILURE')=='corruptcopy':
            pathlib.Path(args[1]).joinpath('Contents/MacOS/Backlit').write_text('corrupt snapshot\n')
elif name=='hdiutil':archive(pathlib.Path(args[args.index('-srcfolder')+1]),pathlib.Path(args[-1]))
elif name=='backlit-fixture-export':
    ref=args[0];short=subprocess.check_output(['git','rev-parse','--short',ref],text=True).strip()
    (root/'dist/exported-ref.txt').write_text(ref)
    with zipfile.ZipFile(root/('dist/Backlit-public-source-'+short+'.zip'),'w') as z:
        z.writestr('Backlit/PUBLICATION.json',json.dumps({'source_commit':ref}))
        z.writestr('Backlit/assets/Info.plist',subprocess.check_output(['git','show',ref+':assets/Info.plist']))
    mutate('finalcheck')
elif name=='mv':
    failure=os.environ.get('FAILURE')
    if failure=='prior_move' and args[0]==str(root/'dist/packages'):sys.exit(34)
    if failure in {'swap','restore'} and args[-1]==str(root/'dist/packages') and args[0].endswith('/packages'):sys.exit(33)
    if failure=='restore' and args[0].endswith('/previous-packages'):sys.exit(34)
    os.execv('/bin/mv',['/bin/mv',*args])
'''


class PackageSnapshotTests(unittest.TestCase):
    def fixture(self, phase='', kind='rebuild', failure='', tag=None):
        with tempfile.TemporaryDirectory(prefix='backlit-package-snapshot-') as temp:
            root=Path(temp);(root/'scripts').mkdir();(root/'assets').mkdir()
            app=root/'dist/Backlit.app';(app/'Contents/MacOS').mkdir(parents=True)
            for name in ['package.sh','build-provenance.py']:
                shutil.copyfile(PROJECT/'scripts'/name,root/'scripts'/name)
            (root/'scripts/check_privacy.py').write_text('print("inert privacy fixture")\n')
            (root/'scripts/public-source.sh').write_text('#!/bin/sh\nset -eu\nbacklit-fixture-export "${1:?Frozen ref required}"\n')
            (root/'.gitignore').write_text('dist/\n')
            info={'CFBundleShortVersionString':'0.2.8','CFBundleVersion':'51'}
            (root/'assets/Info.plist').write_bytes(plistlib.dumps(info))
            (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            (app/'Contents/MacOS/Backlit').write_text('inert executable A\n')
            (root/'source.txt').write_text('source A\n')
            env={k:v for k,v in os.environ.items() if not k.startswith('GIT_')}
            def git(*args):
                return subprocess.run(['git','-C',str(root),'-c','core.hooksPath=/dev/null','-c','commit.gpgsign=false','-c','user.name=Backlit package fixture','-c','user.email=backlit-fixture@users.noreply.github.com',*args],env=env,check=True,capture_output=True,text=True,timeout=10).stdout.strip()
            git('init','-q');git('add','.');git('commit','-qm','Disposable source A');commit=git('rev-parse','HEAD')
            for args in [['capture','dist/input-a.json'],['write',str(app),'--snapshot','dist/input-a.json']]:
                subprocess.run(['python3','-B','scripts/build-provenance.py',*args],cwd=root,env=env,check=True,capture_output=True,timeout=10)
            bins=root/'dist/mock-bin';bins.mkdir()
            for name in ['codesign','lipo','ditto','hdiutil','backlit-fixture-export','mv']:
                tool=bins/name;tool.write_text(TOOL);tool.chmod(0o700)
            output=root/'dist/packages';output.mkdir();sentinel=output/'old-output.txt';sentinel.write_text('previous output')
            # The disposable app is version 0.2.8, independent of the host CI tag.
            env['GITHUB_REF'] = tag if tag is not None else 'refs/tags/v' + info['CFBundleShortVersionString']
            env.update(PATH=str(bins)+os.pathsep+env['PATH'],PYTHONDONTWRITEBYTECODE='1',RACE_PHASE=phase,RACE_KIND=kind,FAILURE=failure)
            run=subprocess.run(['bash','scripts/package.sh'],cwd=root,env=env,capture_output=True,text=True,timeout=20)
            result={'code':run.returncode,'stdout':run.stdout,'stderr':run.stderr,'commit':commit,
                    'head':git('rev-parse','HEAD'),'sentinel':sentinel.read_text() if sentinel.exists() else None,
                    'stages':list((root/'dist').glob('package-work.*')),'events':[],
                    'retained_previous':[p.read_text() for p in root.glob('dist/package-work.*/previous-packages/old-output.txt')]}
            if (root/'dist/tool-events.jsonl').exists():
                result['events']=[json.loads(line) for line in (root/'dist/tool-events.jsonl').read_text().splitlines()]
            if (output/'BUILD-INFO.json').exists():
                result['manifest']=json.loads((output/'BUILD-INFO.json').read_text())
                for label,suffix in [('zip','zip'),('dmg','dmg')]:
                    with zipfile.ZipFile(output/('Backlit-0.2.8-macOS-arm64.'+suffix)) as z:
                        result[label]=json.loads(z.read('Backlit.app/Contents/Resources/BuildProvenance.json'))
                with zipfile.ZipFile(output/'Backlit-0.2.8-source.zip') as z:
                    result['source']=json.loads(z.read('Backlit/PUBLICATION.json'))
            return result

    def assert_rejected(self,result):
        self.assertNotEqual(result['code'],0,result)
        self.assertEqual(result['sentinel'],'previous output',result)
        self.assertFalse(result['stages'],result)
        self.assertNotIn('manifest',result)

    def test_host_release_tag_cannot_contaminate_disposable_fixture(self):
        with patch.dict(os.environ, {'GITHUB_REF': 'refs/tags/v9.9.9'}):
            result = self.fixture()
        self.assertEqual(result['code'], 0, result)

    def test_mismatched_fixture_tag_still_rejects_before_replacing_output(self):
        result = self.fixture(tag='refs/tags/v9.9.9')
        self.assert_rejected(result)
        self.assertIn('Tag and app version differ.', result['stderr'])

    def test_clean_success_uses_one_private_bundle_for_both_formats_and_architecture(self):
        result=self.fixture();self.assertEqual(result['code'],0,result)
        for name in ['manifest','zip','dmg','source']:
            self.assertEqual(result[name]['source_commit'],result['commit'])
        self.assertEqual(result['zip'],result['dmg'])
        self.assertEqual(result['manifest']['build'],'51')
        self.assertFalse(result['stages'])
        self.assertIsNone(result['sentinel'])
        lipo_paths=[args[-1] for name,args in result['events'] if name=='lipo']
        self.assertTrue(lipo_paths)
        self.assertTrue(all('/package-work.' in p and '/app/Backlit.app/' in p for p in lipo_paths),lipo_paths)
        signatures=[args[-1] for name,args in result['events'] if name=='codesign']
        self.assertGreaterEqual(sum('/app/Backlit.app' in p for p in signatures),2,signatures)

    def test_completed_rebuild_during_private_copy_is_rejected(self):
        self.assert_rejected(self.fixture('copy'))

    def test_completed_rebuild_between_zip_and_dmg_is_rejected(self):
        self.assert_rejected(self.fixture('afterzip'))

    def test_completed_rebuild_before_final_check_is_rejected(self):
        self.assert_rejected(self.fixture('finalcheck'))

    def test_commit_only_race_remains_rejected(self):
        self.assert_rejected(self.fixture('finalcheck','commit-only'))

    def test_same_commit_app_replacement_is_rejected(self):
        result=self.fixture('afterzip','samecommit');self.assert_rejected(result)
        self.assertIn('changed while packaging',result['stderr'])

    def test_snapshot_copy_failure_preserves_output_and_cleans_stage(self):
        result=self.fixture(failure='copy');self.assert_rejected(result)
        self.assertEqual(result['code'],32,result)

    def test_snapshot_signature_failure_preserves_output_and_cleans_stage(self):
        result=self.fixture(failure='signature');self.assert_rejected(result)
        self.assertEqual(result['code'],31,result)

    def test_copy_content_mismatch_is_rejected_even_if_signature_tool_accepts(self):
        result=self.fixture(failure='corruptcopy');self.assert_rejected(result)
        self.assertIn('changed while packaging',result['stderr'])

    def test_mutated_private_snapshot_is_rejected_before_output_replacement(self):
        result=self.fixture('finalcheck','snapshot');self.assert_rejected(result)
        self.assertIn('changed while packaging',result['stderr'])

    def test_interrupted_snapshot_copy_preserves_output_and_cleans_stage(self):
        result=self.fixture(failure='interruptcopy');self.assert_rejected(result)
        self.assertEqual(result['code'],130,result)

    def test_failed_prior_output_move_preserves_output_and_cleans_stage(self):
        self.assert_rejected(self.fixture(failure='prior_move'))

    def test_failed_output_restore_retains_recoverable_previous_packages(self):
        result=self.fixture(failure='restore')
        self.assertNotEqual(result['code'],0,result)
        self.assertEqual(result['retained_previous'],['previous output'],result)
        self.assertIn('Could not restore previous packages; retained at',result['stderr'])

    def test_output_swap_failure_restores_previous_packages(self):
        self.assert_rejected(self.fixture(failure='swap'))


if __name__=='__main__':unittest.main()

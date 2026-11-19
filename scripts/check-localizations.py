#!/usr/bin/env python3
"""Verify native catalog completeness, generated parity and standalone-app resources."""
from pathlib import Path
import argparse, importlib.util, plistlib
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('compile_localizations',ROOT/'scripts/compile-localizations.py')
compiler=importlib.util.module_from_spec(spec);spec.loader.exec_module(compiler)
def bundle_resources(bundle):
    """Foundation accepts macOS Contents/Resources bundles and flat SwiftPM bundles."""
    nested=bundle/'Contents/Resources'
    if nested.is_dir(): return nested
    return bundle

def check(app=None):
    compiler.compile_catalogs(write=False)
    guard_spec=importlib.util.spec_from_file_location('ui_localization_coverage',ROOT/'scripts/check-ui-localizations.py')
    guard=importlib.util.module_from_spec(guard_spec);guard_spec.loader.exec_module(guard)
    guard.check()
    info=plistlib.loads((app/'Contents/Info.plist' if app else ROOT/'assets/Info.plist').read_bytes())
    assert set(info['CFBundleLocalizations'])==compiler.LOCALES
    assert info.get('CFBundleDevelopmentRegion')=='en'
    if app:
        resources=app/'Contents/Resources'
        interface=resources/'Backlit_Backlit.bundle'
        assert interface.is_dir(),'Missing packaged SwiftPM interface bundle'
        for name,base in [('Localizable',bundle_resources(interface)),('InfoPlist',resources)]:
            tables=compiler.validate_catalog(ROOT/f'assets/Localizations/{name}.xcstrings')
            for code in sorted(compiler.LOCALES):
                matches=[p for p in base.iterdir() if p.name.lower()==f'{code}.lproj'.lower()]
                assert len(matches)==1,(code,'missing or duplicate language directory')
                assert compiler.read_strings(matches[0]/f'{name}.strings')==tables[code],(code,name,'packaged translation differs from catalog')
        print('Verified standalone app interface and privacy resources for all 10 languages.')
    else:
        print('Verified source catalogs and Apple-generated interface/privacy resources for all 10 languages.')

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--app',type=Path);args=parser.parse_args()
    check(args.app)

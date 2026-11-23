#!/usr/bin/env python3
"""Compile Xcode string catalogs with Apple's tool. Generated .strings are never edited by hand."""
import argparse, json, plistlib, re, subprocess, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
LOCALES={'en','es','fr','de','ja','ko','pt-BR','zh-Hans','zh-Hant','th','it','nl','pl','tr','vi','id'}
PRIVACY_KEYS={'NSAudioCaptureUsageDescription','NSScreenCaptureUsageDescription','NSLocalNetworkUsageDescription'}
CORE_INTERFACE_KEYS={'Settings','System Default'}
def read_strings(path):
    return plistlib.loads(subprocess.check_output(['plutil','-convert','xml1','-o','-',str(path)]))
def validate_catalog(path):
    catalog=json.loads(path.read_text())
    if catalog.get('sourceLanguage')!='en' or catalog.get('version')!='1.0': raise ValueError(f'{path}: unsupported catalog format')
    strings=catalog.get('strings')
    if not isinstance(strings,dict) or not strings: raise ValueError(f'{path}: catalog must contain strings')
    if path.stem=='InfoPlist' and set(strings)!=PRIVACY_KEYS: raise ValueError(f'{path}: privacy catalog must contain exactly the three required permission keys')
    if path.stem=='Localizable' and not CORE_INTERFACE_KEYS.issubset(strings): raise ValueError(f'{path}: missing core interface keys')
    tables={locale:{} for locale in LOCALES}
    for key,entry in strings.items():
        if set(entry.get('localizations',{}))!=LOCALES: raise ValueError(f'{path}: incomplete locales for {key}')
        for locale,item in entry['localizations'].items():
            unit=item.get('stringUnit',{}); value=unit.get('value')
            if unit.get('state')!='translated' or not isinstance(value,str) or not value.strip(): raise ValueError(f'{locale}: incomplete translation for {key}')
            if sorted(re.findall(r'\{[A-Za-z][A-Za-z0-9_]*\}',key))!=sorted(re.findall(r'\{[A-Za-z][A-Za-z0-9_]*\}',value)): raise ValueError(f'{locale}: placeholder mismatch for {key}')
            tables[locale][key]=value
    return tables

def compile_catalogs(write=False):
    tool=subprocess.check_output(['xcrun','--find','xcstringstool'],text=True).strip()
    specs=[('Localizable',ROOT/'Sources/Backlit/Resources'),('InfoPlist',ROOT/'assets/Localizations')]
    for name,target in specs:
        source=ROOT/f'assets/Localizations/{name}.xcstrings'; tables=validate_catalog(source)
        with tempfile.TemporaryDirectory(prefix='backlit-catalog-') as directory:
            output=Path(directory)
            subprocess.run([tool,'compile',str(source),'--output-directory',str(output),'--serialization-format','text'],check=True)
            expected={f'{locale}.lproj/{name}.strings' for locale in LOCALES}
            actual={str(p.relative_to(output)) for p in output.rglob('*') if p.is_file()}
            if actual!=expected: raise ValueError(f'{name}: unexpected compiled resource inventory: {actual^expected}')
            for relative in sorted(expected):
                compiled=output/relative; destination=target/relative; locale=Path(relative).parts[0].removesuffix('.lproj')
                if read_strings(compiled)!=tables[locale]: raise ValueError(f'{name}/{locale}: compiler output differs from source')
                if write:
                    destination.parent.mkdir(parents=True,exist_ok=True)
                    if not destination.exists() or destination.read_bytes()!=compiled.read_bytes(): destination.write_bytes(compiled.read_bytes())
                elif not destination.exists() or read_strings(destination)!=tables[locale]:
                    raise ValueError(f'{destination}: generated resource is stale; run python3 scripts/compile-localizations.py --write')
        print(f'{name}: verified {len(tables["en"])} strings across {len(LOCALES)} languages')

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--write',action='store_true',help='refresh generated resources from .xcstrings');args=parser.parse_args()
    compile_catalogs(args.write)

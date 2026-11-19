"""Schema regressions do not require Xcode or modify generated resources."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('compile_localizations',ROOT/'scripts/compile-localizations.py')
compiler=importlib.util.module_from_spec(spec)
spec.loader.exec_module(compiler)

class CatalogSchemaTests(unittest.TestCase):
    def validate(self,name,catalog):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/(name+'.xcstrings')
            path.write_text(json.dumps(catalog))
            return compiler.validate_catalog(path)
    def source(self,name):
        return json.loads((ROOT/f'assets/Localizations/{name}.xcstrings').read_text())
    def test_current_catalogs_validate(self):
        for name in ('Localizable','InfoPlist'):
            self.assertEqual(set(self.validate(name,self.source(name))),compiler.LOCALES)
    def test_reconnect_accessibility_template_matches_actual_ui_and_all_locales(self):
        import re
        ui=(ROOT/'Sources/Backlit/Views.swift').read_text()
        match=re.search(r'installation\.canDisconnect \? "(Reconnect \{agent\} coding status hooks)" : "(Connect \{agent\} coding status hooks)"',ui)
        self.assertIsNotNone(match, 'Reconnect accessibility branch moved: update this integration regression')
        catalog=self.source('Localizable')['strings']
        for key in ('Reconnect', *match.groups()):
            self.assertIn(key,catalog)
            self.assertEqual(set(catalog[key]['localizations']),compiler.LOCALES)
            for locale,entry in catalog[key]['localizations'].items():
                value=entry['stringUnit']['value']
                self.assertTrue(value.strip())
                self.assertEqual(value.count('{agent}'),key.count('{agent}'))
                if locale!='en':self.assertNotEqual(value,key)
        for locale in compiler.LOCALES:
            self.assertNotEqual(catalog[match[1]]['localizations'][locale]['stringUnit']['value'],catalog[match[2]]['localizations'][locale]['stringUnit']['value'])
    def test_empty_catalogs_rejected(self):
        for name in ('Localizable','InfoPlist'):
            catalog=self.source(name);catalog['strings']={}
            with self.assertRaisesRegex(ValueError,'must contain strings'):self.validate(name,catalog)
    def test_each_missing_permission_key_rejected(self):
        for key in compiler.PRIVACY_KEYS:
            catalog=self.source('InfoPlist');del catalog['strings'][key]
            with self.assertRaisesRegex(ValueError,'exactly the three'):self.validate('InfoPlist',catalog)
    def test_extra_permission_key_rejected(self):
        catalog=self.source('InfoPlist');catalog['strings']['Unexpected']=copy.deepcopy(next(iter(catalog['strings'].values())))
        with self.assertRaisesRegex(ValueError,'exactly the three'):self.validate('InfoPlist',catalog)
    def test_missing_core_interface_keys_rejected(self):
        for key in compiler.CORE_INTERFACE_KEYS:
            catalog=self.source('Localizable');del catalog['strings'][key]
            with self.assertRaisesRegex(ValueError,'core interface'):self.validate('Localizable',catalog)
    def test_missing_locale_rejected(self):
        catalog=self.source('Localizable');del catalog['strings']['Settings']['localizations']['de']
        with self.assertRaisesRegex(ValueError,'incomplete locales'):self.validate('Localizable',catalog)
    def test_missing_placeholder_rejected(self):
        catalog=self.source('Localizable');catalog['strings']['Currently using {language}']['localizations']['de']['stringUnit']['value']='Aktuelle Sprache'
        with self.assertRaisesRegex(ValueError,'placeholder mismatch'):self.validate('Localizable',catalog)
    def test_empty_translation_rejected(self):
        catalog=self.source('Localizable');catalog['strings']['Settings']['localizations']['de']['stringUnit']['value']=' '
        with self.assertRaisesRegex(ValueError,'incomplete translation'):self.validate('Localizable',catalog)

class PackagedResourceLayoutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec=importlib.util.spec_from_file_location('check_localizations',ROOT/'scripts/check-localizations.py')
        cls.checker=importlib.util.module_from_spec(spec);spec.loader.exec_module(cls.checker)
    def test_standalone_build_never_uses_development_resource_fallback(self):
        root=Path(__file__).resolve().parents[2]
        source=(root/'Sources/Backlit/LocalizationCatalogs.swift').read_text()
        standalone=source.split('#if BACKLIT_STANDALONE',1)[1].split('#else',1)[0]
        self.assertNotIn('Bundle.module',standalone)
        self.assertIn('fatalError("Missing packaged localization resources.")',standalone)
        self.assertIn('return Bundle.module',source.split('#else',1)[1])
        compile_command=(root/'scripts/build.sh').read_text().split('swift build -c release',1)[1].split('binary_dir=',1)[0]
        self.assertIn('-Xswiftc -D -Xswiftc BACKLIT_STANDALONE',compile_command)

    def test_macos_bundle_resources_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle=Path(directory)/'Backlit_Backlit.bundle'
            resources=bundle/'Contents/Resources';(resources/'de.lproj').mkdir(parents=True)
            self.assertEqual(self.checker.bundle_resources(bundle),resources)
            self.assertTrue((self.checker.bundle_resources(bundle)/'de.lproj').is_dir())
    def test_flat_swiftpm_bundle_resources_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle=Path(directory)/'Backlit_Backlit.bundle';(bundle/'de.lproj').mkdir(parents=True)
            self.assertEqual(self.checker.bundle_resources(bundle),bundle)

if __name__=='__main__':unittest.main()

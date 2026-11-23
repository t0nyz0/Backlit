import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
class ControlCenterBoundaryTests(unittest.TestCase):
    def test_normal_release_does_not_enable_or_embed_experiment(self):
        script = (ROOT / 'scripts/build.sh').read_text()
        for text in ['build-control-extension', 'BacklitControl.appex']:
            self.assertNotIn(text, script)
        self.assertRegex(script, r'experimental_flags=\(\)\nif \[ "\$\{BACKLIT_LOCAL_CONTROL_BUILD:-0\}" = "1" \]; then[\s\S]*?experimental_flags=\(-Xswiftc -D -Xswiftc BACKLIT_CONTROL_CENTER')
        self.assertEqual(script.count('BACKLIT_CONTROL_CENTER'), 1)
        self.assertNotIn('application-groups', (ROOT / 'assets/Backlit.entitlements').read_text())
    def test_shared_intent_and_host_are_compilation_gated(self):
        shared = (ROOT / 'Sources/Backlit/ControlCenterShared.swift').read_text()
        host = (ROOT / 'Sources/Backlit/ControlCenterHost.swift').read_text()
        self.assertTrue(shared.startswith('#if BACKLIT_CONTROL_CENTER'))
        self.assertIn('#if BACKLIT_CONTROL_CENTER', host)
        self.assertIn('.requiresLocalDeviceAuthentication', shared)
        self.assertIn('static let supportedModes: IntentModes = .background', shared)
        self.assertIn('@available(macOS 27.0, *)', shared)
        self.assertNotIn('.foreground(.immediate)', shared)
        for text in ['RuntimeServices', 'LogoDevice', 'HomeBridge']: self.assertNotIn(text, shared)
        self.assertIn('try model.performControlCenterPower(value)', host)
    def test_extension_does_not_claim_paused_for_unknown_effective_state(self):
        extension = (ROOT / 'integrations/control-center/BacklitControl.swift').read_text()
        self.assertNotIn('Enabled · paused', extension)
        self.assertIn('try LogoLightControlState.currentValue()', extension)
        self.assertNotIn('try?', extension)
if __name__ == '__main__': unittest.main()

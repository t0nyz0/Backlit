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
    def test_control_and_public_artifact_guard_use_same_backlit_identity(self):
        widget = (ROOT / 'integrations/control-center/BacklitControl.swift').read_text()
        shared = (ROOT / 'Sources/Backlit/ControlCenterShared.swift').read_text()
        self.assertIn('ControlWidgetToggle(\n                "Backlit",', widget)
        self.assertIn('.displayName("Backlit")', widget)
        self.assertIn('static let kind = "local.backlit.control-center.power"', shared)
        self.assertIn('struct SetBacklitControlPowerIntent: SetValueIntent', shared)
        self.assertIn('action: SetBacklitControlPowerIntent()', widget)
        for file in ['scripts/build-control-extension.sh', 'scripts/package.sh']:
            self.assertIn('SetBacklitControlPowerIntent', (ROOT / file).read_text())

    def test_extension_does_not_claim_paused_for_unknown_effective_state(self):
        extension = (ROOT / 'integrations/control-center/BacklitControl.swift').read_text()
        self.assertNotIn('Enabled · paused', extension)
        self.assertIn('try BacklitControlState.currentValue()', extension)
        self.assertNotIn('try?', extension)
if __name__ == '__main__': unittest.main()

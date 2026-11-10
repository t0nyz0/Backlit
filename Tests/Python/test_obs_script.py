"""Mock-only OBS worker regression cases. They never load OBS or call Keychain."""
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, Mock, patch


class OBSScriptTests(unittest.TestCase):
    def setUp(self):
        source = Path(__file__).resolve().parents[2] / "integrations/obs/backlit_obs.py"
        spec = importlib.util.spec_from_file_location("backlit_obs_fixture", source)
        self.module = importlib.util.module_from_spec(spec)
        self.obs = SimpleNamespace(
            obs_data_get_int=lambda settings, key: settings.get(key, 48261),
            obs_data_get_bool=lambda settings, key: settings.get(key, False),
            obs_frontend_recording_active=lambda: True,
            obs_frontend_streaming_active=lambda: False,
        )
        with patch.dict("sys.modules", {"obspython": self.obs}):
            spec.loader.exec_module(self.module)

    def worker(self):
        # Suppress Thread.start; tests drive the state machine synchronously.
        with patch.object(self.module.threading, "Thread"):
            return self.module._SignalWorker(48261)

    def test_loading_disabled_settings_creates_no_worker(self):
        with patch.object(self.module, "_SignalWorker") as constructor:
            self.module.script_update({"enabled": False, "port": 48261})
            constructor.assert_not_called()
        self.assertIsNone(self.module._worker)

    def test_stop_supersedes_queued_start_before_any_network_dispatch(self):
        worker = self.worker()
        worker.set_active("recording", True)
        old = worker._desired["recording"]
        worker.set_active("recording", False)
        worker._pairing_key = Mock(return_value="fixture-pairing-key")
        with patch.object(self.module.urllib.request, "build_opener") as opener:
            self.assertFalse(worker._post("recording", "active", expected=old))
            opener.assert_not_called()

    def test_same_port_disable_and_reenable_preserve_serial_worker(self):
        worker = self.worker()
        self.module._worker = worker
        worker.set_active("recording", True)
        self.module.script_update({"enabled": False, "port": 48261})
        self.assertIs(self.module._worker, worker)
        self.assertEqual(worker._desired["recording"][0], "clear")
        self.module.script_update({"enabled": True, "port": 48261})
        self.assertIs(self.module._worker, worker)
        self.assertEqual(worker._desired["recording"][0], "active")

    def test_idle_worker_waits_without_a_polling_timeout(self):
        worker = self.worker()
        waits = []

        class Condition:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def wait(self, timeout=None):
                waits.append(timeout)
                worker._closing = True

        worker._condition = Condition()
        worker._post = Mock()
        worker._run()
        self.assertEqual(waits, [None])
        worker._post.assert_not_called()

    def test_inflight_start_is_followed_by_latest_stop_in_serial_order(self):
        worker = self.worker()
        worker.set_active("recording", True)
        states = []

        def post(category, state, expected=None):
            states.append(state)
            if state == "active":
                worker.set_active(category, False)
            else:
                worker.close()
            return True

        worker._post = post
        worker._run()
        self.assertEqual(states, ["active", "complete"])
        self.assertFalse(worker._active_attempts)

    def test_http_request_is_loopback_only_with_no_proxy_or_redirect(self):
        worker = self.worker()
        worker._pairing_key = Mock(return_value="fixture-pairing-key")
        response = MagicMock()
        response.__enter__.return_value.status = 200
        opener = Mock()
        opener.open.return_value = response
        with patch.object(self.module.urllib.request, "build_opener", return_value=opener) as build:
            self.assertTrue(worker._post("streaming", "active"))
        self.assertEqual(build.call_args.args[0].proxies, {})
        redirect = build.call_args.args[1]
        self.assertIsNone(redirect.redirect_request(None, None, 302, "redirect", {}, "https://example.invalid"))
        request = opener.open.call_args.args[0]
        self.assertEqual(request.full_url, "http://127.0.0.1:48261/v1/signal")
        self.assertEqual(opener.open.call_args.kwargs["timeout"], 0.75)
        self.assertEqual(json.loads(request.data), {"category": "streaming", "state": "active", "duration": 90})

    def test_keychain_denial_is_not_retried_until_explicit_reenable(self):
        worker = self.worker()
        denied = SimpleNamespace(returncode=1, stdout="")
        with patch.object(self.module.subprocess, "run", return_value=denied) as lookup:
            self.assertIsNone(worker._pairing_key())
            self.assertIsNone(worker._pairing_key())
            self.assertEqual(lookup.call_count, 1)
            worker.set_enabled(False)
            worker.set_enabled(True)
            self.assertIsNone(worker._pairing_key())
            self.assertEqual(lookup.call_count, 2)
            self.assertFalse(lookup.call_args.kwargs.get("shell", False))

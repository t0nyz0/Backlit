"""Real OBS-worker threads against isolated HTTP fixtures, with no OBS or Keychain.

The fake frontend supplies only recording/streaming booleans and callbacks. All
network I/O is restricted to test-owned ephemeral loopback servers, never the running app's default port.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
from pathlib import Path
from threading import Condition, Event, Thread
import time
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

TOKEN = 'fixture-key-0000000000000000'
SOURCE = Path(__file__).resolve().parents[2] / 'integrations/obs/backlit_obs.py'
_REAL_THREAD = Thread


class Clock:
    def __init__(self):
        self.value = 1000.0
        self.lock = Condition()

    def monotonic(self):
        with self.lock:
            return self.value

    def advance(self, seconds):
        with self.lock:
            self.value += seconds


class TracedCondition:
    """Observe actual production wait arguments without replacing worker logic."""
    def __init__(self, condition):
        self.condition = condition
        self.timeouts = []

    def __enter__(self):
        self.condition.__enter__()
        return self

    def __exit__(self, *args):
        return self.condition.__exit__(*args)

    def wait(self, timeout=None):
        self.timeouts.append(timeout)
        return self.condition.wait(timeout)

    def notify(self, *args):
        return self.condition.notify(*args)

    def notify_all(self):
        return self.condition.notify_all()

    def waits(self):
        with self.condition:
            return tuple(self.timeouts)


class HTTPFixture:
    def __init__(self):
        self.condition = Condition()
        self.requests = []
        self.statuses = []
        self.redirect = None
        self.block = None
        self.blocked = Event()
        self.release = Event()
        self.used_block = False
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                try:
                    count = int(self.headers.get('Content-Length', '0'))
                    payload = json.loads(self.rfile.read(count))
                except (ValueError, TypeError):
                    self.send_error(400)
                    return
                with fixture.condition:
                    fixture.requests.append((self.path, self.headers.get('Authorization'), payload))
                    status = fixture.statuses.pop(0) if fixture.statuses else 200
                    hold = fixture.block == (payload.get('category'), payload.get('state')) and not fixture.used_block
                    if hold:
                        fixture.used_block = True
                    fixture.condition.notify_all()
                if hold:
                    fixture.blocked.set()
                    fixture.release.wait(timeout=2)
                body = b'{}'
                try:
                    self.send_response(status)
                    if status == 302:
                        self.send_header('Location', fixture.redirect)
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.port = self.server.server_port
        if self.port == 48261:
            self.server.server_close()
            raise AssertionError('Fixture must not use Backlit’s live default port')
        self.thread = _REAL_THREAD(target=lambda: self.server.serve_forever(poll_interval=0.01), daemon=True)
        self.thread.start()

    def snapshot(self):
        with self.condition:
            return list(self.requests)

    def states(self, category):
        return [payload['state'] for _, _, payload in self.snapshot() if payload['category'] == category]

    def wait_states(self, category, expected, timeout=2):
        with self.condition:
            return self.condition.wait_for(
                lambda: [payload['state'] for _, _, payload in self.requests if payload['category'] == category] == expected,
                timeout=timeout,
            )

    def stop(self):
        self.release.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


class OBSWorkerEndToEndTests(unittest.TestCase):
    def setUp(self):
        self.workers = []
        self.servers = []
        self.patchers = []
        self.callbacks = []
        self.frontend = {'recording': False, 'streaming': False}
        self.clock = Clock()
        self.addCleanup(self.cleanup)
        self.obs = SimpleNamespace(
            obs_data_get_int=lambda settings, key: settings.get(key, 48261),
            obs_data_get_bool=lambda settings, key: settings.get(key, False),
            obs_frontend_recording_active=lambda: self.frontend['recording'],
            obs_frontend_streaming_active=lambda: self.frontend['streaming'],
            obs_frontend_add_event_callback=lambda callback: self.callbacks.append(callback),
            obs_frontend_remove_event_callback=lambda callback: self.callbacks.remove(callback) if callback in self.callbacks else None,
            OBS_FRONTEND_EVENT_RECORDING_STARTED=1,
            OBS_FRONTEND_EVENT_RECORDING_STOPPED=2,
            OBS_FRONTEND_EVENT_STREAMING_STARTED=3,
            OBS_FRONTEND_EVENT_STREAMING_STOPPED=4,
        )
        spec = importlib.util.spec_from_file_location('backlit_obs_e2e_fixture', SOURCE)
        self.module = importlib.util.module_from_spec(spec)
        with patch.dict('sys.modules', {'obspython': self.obs}):
            spec.loader.exec_module(self.module)
        self.module.time = self.clock
        self.original_key_provider = self.module._SignalWorker._pairing_key
        self.key_provider = Mock(return_value=TOKEN)
        self.start_patch(patch.object(self.module._SignalWorker, '_pairing_key', self.key_provider))
        # Fail closed if any unexpected code tries to use the actual security CLI.
        self.start_patch(patch.object(self.module.subprocess, 'run', side_effect=AssertionError('No live Keychain calls in e2e tests')))

        def traced_thread(*args, **kwargs):
            target = kwargs.get('target')
            owner = getattr(target, '__self__', None)
            if isinstance(owner, self.module._SignalWorker):
                owner._condition = TracedCondition(owner._condition)
                self.workers.append(owner)
            return _REAL_THREAD(*args, **kwargs)

        self.start_patch(patch.object(self.module.threading, 'Thread', side_effect=traced_thread))

    def start_patch(self, patcher):
        value = patcher.start()
        self.patchers.append(patcher)
        return value

    def fixture(self):
        fixture = HTTPFixture()
        self.servers.append(fixture)
        return fixture

    def wait(self, predicate, timeout=2):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return True
            Event().wait(0.005)
        return bool(predicate())

    def settled(self, worker):
        with worker._condition:
            return bool(worker._condition.timeouts) and all(worker._sent.get(key) == value for key, value in worker._desired.items())

    def advance(self, worker, seconds):
        count = len(worker._condition.waits())
        self.clock.advance(seconds)
        with worker._condition:
            worker._condition.notify_all()
        self.assertTrue(self.wait(lambda: len(worker._condition.waits()) > count), 'worker did not process virtual timer wake')

    def emit(self, category, active):
        self.frontend[category] = active
        event = {('recording', True): 1, ('recording', False): 2, ('streaming', True): 3, ('streaming', False): 4}[(category, active)]
        for callback in tuple(self.callbacks):
            callback(event)

    def cleanup(self):
        for fixture in self.servers:
            fixture.release.set()
        if hasattr(self, 'module'):
            self.module.script_unload()
        for worker in self.workers:
            worker.close()
        try:
            for worker in self.workers:
                worker._thread.join(timeout=3)
                self.assertFalse(worker._thread.is_alive(), 'test-owned OBS worker leaked')
        finally:
            for fixture in self.servers:
                fixture.stop()
            for patcher in reversed(self.patchers):
                patcher.stop()

    def test_disabled_load_and_unload_do_not_create_worker_or_read_key(self):
        server = self.fixture()
        self.module.script_load({'enabled': False, 'port': server.port})
        self.assertEqual(len(self.callbacks), 1)
        self.assertIsNone(self.module._worker)
        self.assertFalse(self.workers)
        self.assertFalse(server.snapshot())
        self.key_provider.assert_not_called()
        self.module.script_unload()
        self.assertFalse(self.callbacks)

    def test_record_stream_stop_disable_and_unload_over_real_http(self):
        server = self.fixture()
        self.module.script_load({'enabled': True, 'port': server.port})
        worker = self.module._worker
        self.assertTrue(server.wait_states('recording', ['clear']))
        self.assertTrue(server.wait_states('streaming', ['clear']))
        self.emit('recording', True)
        self.emit('streaming', True)
        self.assertTrue(server.wait_states('recording', ['clear', 'active']))
        self.assertTrue(server.wait_states('streaming', ['clear', 'active']))
        self.emit('recording', False)
        self.assertTrue(server.wait_states('recording', ['clear', 'active', 'complete']))
        self.module.script_update({'enabled': False, 'port': server.port})
        self.assertTrue(server.wait_states('recording', ['clear', 'active', 'complete', 'clear']))
        self.assertTrue(server.wait_states('streaming', ['clear', 'active', 'clear']))
        self.assertTrue(self.wait(lambda: self.settled(worker)))
        self.assertIsNone(worker._condition.waits()[-1], 'disabled worker should wait indefinitely, not poll')
        for path, authorization, payload in server.snapshot():
            self.assertEqual(path, '/v1/signal')
            self.assertEqual(authorization, 'Bearer ' + TOKEN)
            self.assertTrue(set(payload).issubset({'category', 'state', 'duration'}))
        self.module.script_unload()
        worker._thread.join(timeout=2)
        self.assertFalse(worker._thread.is_alive())
        self.assertFalse(self.callbacks)

    def test_failed_send_retries_at_heartbeat_not_in_a_busy_loop(self):
        server = self.fixture()
        server.statuses = [503]
        self.frontend['recording'] = True
        self.module.script_load({'enabled': True, 'port': server.port})
        worker = self.module._worker
        self.assertTrue(server.wait_states('recording', ['active']))
        self.assertTrue(self.wait(lambda: self.settled(worker)))
        self.assertEqual(server.states('recording'), ['active'])
        self.assertGreaterEqual(worker._condition.waits()[-1], 29)
        self.advance(worker, 29)
        self.assertEqual(server.states('recording'), ['active'])
        self.advance(worker, 2)
        self.assertTrue(server.wait_states('recording', ['active', 'active']))
        self.assertTrue(self.wait(lambda: self.settled(worker)))
        self.assertGreaterEqual(worker._condition.waits()[-1], 29)

    def test_unauthorized_key_does_not_retry_keychain_until_reenabled(self):
        server = self.fixture()
        server.statuses = [401]
        self.frontend['recording'] = True
        self.start_patch(patch.object(self.module._SignalWorker, '_pairing_key', self.original_key_provider))
        lookup = self.start_patch(patch.object(self.module.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=TOKEN + '\n')))
        self.module.script_load({'enabled': True, 'port': server.port})
        worker = self.module._worker
        self.assertTrue(server.wait_states('recording', ['active']))
        self.assertTrue(self.wait(lambda: self.settled(worker)))
        self.assertEqual(lookup.call_count, 1)
        self.advance(worker, 31)
        self.assertEqual(server.states('recording'), ['active'])
        self.assertEqual(lookup.call_count, 1)
        self.module.script_update({'enabled': False, 'port': server.port})
        self.module.script_update({'enabled': True, 'port': server.port})
        self.assertTrue(server.wait_states('recording', ['active', 'active']))
        self.assertTrue(self.wait(lambda: self.settled(worker)))
        self.assertEqual(lookup.call_count, 2)

    def test_port_return_orders_old_cleanup_before_new_active_request(self):
        first, second = self.fixture(), self.fixture()
        self.frontend['recording'] = True
        self.module.script_load({'enabled': True, 'port': first.port})
        old = self.module._worker
        self.assertTrue(first.wait_states('recording', ['active']))
        self.assertTrue(self.wait(lambda: self.settled(old)))
        first.block = ('recording', 'clear')
        self.module.script_update({'enabled': True, 'port': second.port})
        self.assertTrue(first.blocked.wait(timeout=2), 'old clear did not reach HTTP fixture')
        self.module.script_update({'enabled': True, 'port': first.port})
        current = self.module._worker
        self.assertIsNot(current, old)
        self.assertEqual(first.states('recording'), ['active', 'clear'])
        first.release.set()
        self.assertTrue(first.wait_states('recording', ['active', 'clear', 'active']))
        self.assertTrue(self.wait(lambda: self.settled(current)))

    def test_unload_clears_active_leases_and_stops_real_worker(self):
        server = self.fixture()
        self.frontend.update(recording=True, streaming=True)
        self.module.script_load({'enabled': True, 'port': server.port})
        worker = self.module._worker
        self.assertTrue(server.wait_states('recording', ['active']))
        self.assertTrue(server.wait_states('streaming', ['active']))
        self.assertTrue(self.wait(lambda: self.settled(worker)))
        self.module.script_unload()
        worker._thread.join(timeout=2)
        self.assertFalse(worker._thread.is_alive())
        self.assertIsNone(self.module._worker)
        self.assertFalse(self.callbacks)
        self.assertEqual(server.states('recording'), ['active', 'clear'])
        self.assertEqual(server.states('streaming'), ['active', 'clear'])

    def test_transport_timeout_keeps_worker_alive_and_retries_on_heartbeat(self):
        server = self.fixture()
        server.block = ('recording', 'active')
        self.frontend['recording'] = True
        self.module.script_load({'enabled': True, 'port': server.port})
        worker = self.module._worker
        self.assertTrue(server.blocked.wait(timeout=2))
        self.assertTrue(self.wait(lambda: self.settled(worker)))
        self.assertTrue(worker._thread.is_alive())
        self.assertEqual(server.states('recording'), ['active'])
        self.assertGreaterEqual(worker._condition.waits()[-1], 29)
        server.release.set()
        self.advance(worker, 31)
        self.assertTrue(server.wait_states('recording', ['active', 'active']))
        self.assertTrue(self.wait(lambda: self.settled(worker)))

    def test_redirect_does_not_forward_pairing_key_to_another_server(self):
        first, redirect_target = self.fixture(), self.fixture()
        first.statuses = [302]
        first.redirect = f'http://127.0.0.1:{redirect_target.port}/v1/signal'
        self.frontend['recording'] = True
        self.module.script_load({'enabled': True, 'port': first.port})
        worker = self.module._worker
        self.assertTrue(first.wait_states('recording', ['active']))
        self.assertTrue(self.wait(lambda: self.settled(worker)))
        self.assertFalse(redirect_target.snapshot(), 'redirect leaked credentials/request to a second server')

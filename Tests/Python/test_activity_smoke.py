"""Real, isolated HTTP/job fixtures; never connects to a running Backlit."""
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'integrations/activity/backlit_signal.py'


@contextmanager
def fixture():
    events = []

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            if self.headers.get('Authorization') != 'Bearer isolated-job-fixture':
                self.send_error(401)
                return
            events.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
            body = b'{}'
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    assert server.server_port != 48261
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    environment = dict(os.environ, BACKLIT_TOKEN='isolated-job-fixture', PYTHONDONTWRITEBYTECODE='1')
    try:
        yield server.server_port, environment, events
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


@unittest.skipUnless(sys.platform == 'darwin', 'requires macOS kqueue process-exit monitoring')
class ActivitySmokeTests(unittest.TestCase):
    def test_real_job_exit_status_and_only_metadata_reach_fixture(self):
        with fixture() as (port, environment, events):
            result = subprocess.run([sys.executable, str(SCRIPT), '--port', str(port), 'run', 'build', '--',
                                     sys.executable, '-c', 'raise SystemExit(7)'], env=environment,
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 7, result.stderr)
            self.assertEqual(events, [{'category': 'build', 'state': 'active', 'duration': 90},
                                      {'category': 'build', 'state': 'attention', 'duration': 8}])

    def test_spawned_job_does_not_inherit_blocked_cancellation_signals(self):
        job = ('import signal; blocked=signal.pthread_sigmask(signal.SIG_BLOCK, []); '
               'raise SystemExit(9 if blocked.intersection({signal.SIGINT,signal.SIGTERM}) else 0)')
        with fixture() as (port, environment, events):
            result = subprocess.run([sys.executable, str(SCRIPT), '--port', str(port), 'run', 'build', '--',
                                     sys.executable, '-c', job], env=environment,
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual([event['state'] for event in events], ['active', 'complete'])

    @unittest.skipUnless(os.name == 'posix', 'requires POSIX process groups')
    def test_sigterm_reaps_only_owned_job_and_clears_signal(self):
        with fixture() as (port, environment, events), tempfile.TemporaryDirectory(prefix='backlit-job-fixture-') as folder:
            pidfile = Path(folder) / 'pid'
            job = f'import os,time; from pathlib import Path; Path({str(pidfile)!r}).write_text(str(os.getpid())); time.sleep(60)'
            wrapper = subprocess.Popen([sys.executable, str(SCRIPT), '--port', str(port), 'run', 'backup', '--',
                                        sys.executable, '-c', job], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            child = None
            try:
                deadline = time.monotonic() + 5
                while not pidfile.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(pidfile.exists(), 'fixture child did not start')
                child = int(pidfile.read_text())
                self.assertEqual(os.getpgid(child), child, 'job must own an isolated process group')
                wrapper.send_signal(signal.SIGTERM)
                _, stderr = wrapper.communicate(timeout=10)
                self.assertEqual(wrapper.returncode, 128 + signal.SIGTERM, stderr)
                with self.assertRaises(ProcessLookupError):
                    os.kill(child, 0)
                child = None
                self.assertEqual([event['state'] for event in events], ['active', 'clear'])
            finally:
                if wrapper.poll() is None:
                    wrapper.kill()
                wrapper.communicate(timeout=5)
                if child is not None:
                    try:
                        if os.getpgid(child) == child:
                            os.killpg(child, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    @unittest.skipUnless(os.name == 'posix', 'requires POSIX process groups')
    def test_cancellation_stops_stubborn_grandchild_after_leader_exits(self):
        for event in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(event=event), fixture() as (port, environment, events), tempfile.TemporaryDirectory(prefix='backlit-grandchild-fixture-') as folder:
                ready = Path(folder) / 'grandchild'
                parent_ready = Path(folder) / 'parent'
                grandchild_code = (
                    'import os,signal,time; from pathlib import Path; '
                    'signal.signal(signal.SIGINT,signal.SIG_IGN); '
                    'signal.signal(signal.SIGTERM,signal.SIG_IGN); '
                    f'Path({str(ready)!r}).write_text(str(os.getpid())); time.sleep(60)'
                )
                parent_code = (
                    'import os,signal,subprocess,sys,time; from pathlib import Path; '
                    'signal.signal(signal.SIGINT,lambda *args: os._exit(0)); '
                    'signal.signal(signal.SIGTERM,lambda *args: os._exit(0)); '
                    f'child=subprocess.Popen([sys.executable,"-c",{grandchild_code!r}]); '
                    f'path=Path({str(ready)!r}); '
                    '\nwhile not path.exists(): time.sleep(0.01)\n'
                    f'Path({str(parent_ready)!r}).write_text(str(os.getpid())); time.sleep(60)'
                )
                wrapper = subprocess.Popen([sys.executable, str(SCRIPT), '--port', str(port), 'run', 'build', '--',
                                            sys.executable, '-c', parent_code], env=environment,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                leader = descendant = None
                try:
                    deadline = time.monotonic() + 5
                    while not parent_ready.exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue(parent_ready.exists(), 'fixture family did not become ready')
                    leader = int(parent_ready.read_text())
                    descendant = int(ready.read_text())
                    self.assertEqual(os.getpgid(descendant), leader)
                    wrapper.send_signal(event)
                    _, stderr = wrapper.communicate(timeout=10)
                    self.assertEqual(wrapper.returncode, 128 + event, stderr)
                    with self.assertRaises(ProcessLookupError):
                        os.kill(leader, 0)
                    # Orphan reaping belongs to the OS; a zombie is terminated,
                    # not a surviving job. Never mistake parent exit for proof.
                    deadline = time.monotonic() + 2
                    while time.monotonic() < deadline:
                        state = subprocess.run(['/bin/ps', '-p', str(descendant), '-o', 'stat='],
                                               capture_output=True, text=True, timeout=1).stdout.strip()
                        if not state or state.startswith('Z'):
                            break
                        time.sleep(0.02)
                    self.assertTrue(not state or state.startswith('Z'), 'stubborn grandchild survived cancellation')
                    descendant = None
                    self.assertEqual([item['state'] for item in events], ['active', 'clear'])
                finally:
                    if wrapper.poll() is None:
                        wrapper.kill()
                    if descendant is not None and leader is not None:
                        try:
                            if os.getpgid(descendant) == leader:
                                os.killpg(leader, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    wrapper.communicate(timeout=5)

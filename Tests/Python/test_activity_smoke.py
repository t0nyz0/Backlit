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


class ActivitySmokeTests(unittest.TestCase):
    def test_real_job_exit_status_and_only_metadata_reach_fixture(self):
        with fixture() as (port, environment, events):
            result = subprocess.run([sys.executable, str(SCRIPT), '--port', str(port), 'run', 'build', '--',
                                     sys.executable, '-c', 'raise SystemExit(7)'], env=environment,
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 7, result.stderr)
            self.assertEqual(events, [{'category': 'build', 'state': 'active', 'duration': 90},
                                      {'category': 'build', 'state': 'attention', 'duration': 8}])

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

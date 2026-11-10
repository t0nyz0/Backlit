"""Source-only background regression coverage. Mocks prevent job/network/Keychain access."""
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import MagicMock, Mock, patch

path = Path(__file__).resolve().parents[2] / 'integrations/activity/backlit_signal.py'
spec = importlib.util.spec_from_file_location('backlit_job_signal', path)
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)


class ActivityClientTests(unittest.TestCase):
    def setUp(self):
        # Main-loop tests exercise policy without touching a process observer.
        self.monitor = MagicMock()
        self.monitor.__enter__.return_value = self.monitor
        observer = patch.object(client, 'JobExitMonitor', return_value=self.monitor)
        observer.start()
        self.addCleanup(observer.stop)

    def test_invalid_signal_is_rejected_before_pairing_key_read(self):
        with patch.object(client, 'pairing_key') as key:
            with self.assertRaises(SystemExit):
                client.main(['signal', 'build', 'active', '--progress', 'nan'])
            key.assert_not_called()

    def test_empty_job_does_not_read_keychain(self):
        with patch.object(client, 'pairing_key') as key:
            with self.assertRaises(SystemExit):
                client.main(['run', 'build'])
            key.assert_not_called()

    def test_job_status_preserves_argv_and_exit_code_without_output_capture(self):
        job = Mock()
        with patch.object(client, 'wait_for_job_exit', return_value=9), patch.object(client, 'pairing_key', return_value='fixture-key'), patch.object(client, 'send_signal') as signal, patch.object(client.subprocess, 'Popen', return_value=job) as launch:
            self.assertEqual(client.main(['run', 'build', '--', 'tool', 'literal;argument']), 9)
            launch.assert_called_once_with(['tool', 'literal;argument'], start_new_session=True)
            self.assertEqual([call.args[4] for call in signal.call_args_list], ['active', 'attention'])

    def test_long_job_refreshes_bounded_lease_and_completes(self):
        job = Mock()
        with patch.object(client, 'wait_for_job_exit', side_effect=[subprocess.TimeoutExpired('fixture', 30), 0]), patch.object(client, 'pairing_key', return_value='fixture-key'), patch.object(client, 'send_signal') as signal, patch.object(client.subprocess, 'Popen', return_value=job):
            self.assertEqual(client.main(['run', 'backup', 'tool']), 0)
            self.assertEqual([call.args[4] for call in signal.call_args_list], ['active', 'active', 'complete'])

    def test_unavailable_backlit_does_not_block_job(self):
        job = Mock()
        with patch.object(client, 'wait_for_job_exit', return_value=0), patch.object(client, 'pairing_key', side_effect=ValueError()), patch.object(client.subprocess, 'Popen', return_value=job):
            self.assertEqual(client.main(['run', 'export', 'tool']), 0)

    def test_cancellation_forwards_interrupt_and_reaps_owned_job(self):
        job = Mock(pid=321, returncode=None)
        job.wait.return_value = 0
        with patch.object(client, 'wait_for_job_exit', side_effect=KeyboardInterrupt()), patch.object(client, 'pairing_key', return_value='fixture-key'), patch.object(client, 'send_signal') as signal, patch.object(client.subprocess, 'Popen', return_value=job), patch.object(client.os, 'killpg') as interrupt, patch.object(client, '_wait_for_group_exit', return_value=True):
            self.assertEqual(client.main(['run', 'build', 'tool']), 130)
            interrupt.assert_called_once_with(321, client.signal.SIGINT)
            self.assertEqual([call.args[4] for call in signal.call_args_list], ['active', 'clear'])
            self.assertEqual(job.wait.call_count, 1)

    def test_cancellation_escalates_before_reaping_even_when_parent_exits_first(self):
        job = Mock(pid=321, returncode=None)
        order = []
        job.wait.side_effect = lambda **kwargs: order.append('reap') or 0
        with patch.object(client.os, 'killpg', side_effect=lambda group, event: order.append((group, event))), patch.object(client, '_wait_for_group_exit', side_effect=[False, False]):
            self.assertTrue(client.cancel_job(job))
        self.assertEqual(order, [(321, client.signal.SIGINT), (321, client.signal.SIGTERM), (321, client.signal.SIGKILL), 'reap'])
        self.assertEqual(job.wait.call_count, 1)

    def test_already_reaped_leader_never_signals_a_reused_group(self):
        job = Mock(pid=321, returncode=0)
        with patch.object(client.os, 'killpg') as interrupt:
            self.assertTrue(client.cancel_job(job))
            interrupt.assert_not_called()
            job.wait.assert_not_called()

    def test_uninterruptible_leader_has_a_bounded_reap_timeout(self):
        job = Mock(pid=321, returncode=None)
        job.wait.side_effect = subprocess.TimeoutExpired('fixture', 2)
        with patch.object(client.os, 'killpg'), patch.object(client, '_wait_for_group_exit', return_value=False):
            self.assertFalse(client.cancel_job(job, first_signal=client.signal.SIGTERM))
            job.wait.assert_called_once()

    def test_group_probe_permission_denial_is_not_reported_as_exit(self):
        with patch.object(client.os, 'killpg', side_effect=PermissionError()), patch.object(client.time, 'sleep') as sleep:
            self.assertFalse(client._wait_for_group_exit(321, 2))
            sleep.assert_not_called()

    def test_denied_escalation_still_reaps_owned_leader_without_claiming_success(self):
        job = Mock(pid=321, returncode=None)
        job.wait.return_value = 0
        with patch.object(client.os, 'killpg', side_effect=[None, PermissionError()]) as interrupt, patch.object(client, '_wait_for_group_exit', return_value=False):
            self.assertFalse(client.cancel_job(job, first_signal=client.signal.SIGTERM))
            self.assertEqual([call.args for call in interrupt.call_args_list], [(321, client.signal.SIGTERM), (321, client.signal.SIGKILL)])
            job.wait.assert_called_once()

    def test_probe_permission_denial_during_cancellation_preserves_exit_code(self):
        job = Mock(pid=321, returncode=None)
        job.wait.return_value = 0

        def signal_group(group, event):
            if event == 0:
                raise PermissionError()

        with patch.object(client, 'wait_for_job_exit', side_effect=client.JobCancelled(client.signal.SIGTERM)), patch.object(client, 'pairing_key', return_value='fixture-key'), patch.object(client, 'send_signal') as send, patch.object(client.subprocess, 'Popen', return_value=job), patch.object(client.os, 'killpg', side_effect=signal_group):
            self.assertEqual(client.main(['run', 'build', 'tool']), 143)
            job.wait.assert_called_once()
            self.assertEqual([call.args[4] for call in send.call_args_list], ['active', 'clear'])

    def test_termination_request_forwards_and_restores_signal_handler(self):
        job = Mock(pid=321, returncode=None)
        job.wait.return_value = 0
        previous = object()
        with patch.object(client, 'wait_for_job_exit', side_effect=client.JobCancelled(client.signal.SIGTERM)), patch.object(client, 'pairing_key', return_value='fixture-key'), patch.object(client, 'send_signal') as signal, patch.object(client.subprocess, 'Popen', return_value=job), patch.object(client.os, 'killpg') as interrupt, patch.object(client, '_wait_for_group_exit', return_value=True), patch.object(client.signal, 'signal', return_value=previous) as handlers:
            self.assertEqual(client.main(['run', 'build', 'tool']), 143)
            interrupt.assert_called_once_with(321, client.signal.SIGTERM)
            self.assertEqual([call.args[4] for call in signal.call_args_list], ['active', 'clear'])
            self.assertEqual(handlers.call_args_list[-1].args, (client.signal.SIGTERM, previous))

    def test_unsupported_observer_never_launches_a_job(self):
        with patch.object(client, 'JobExitMonitor', side_effect=OSError('unsupported')), patch.object(client, 'pairing_key', return_value='fixture-key'), patch.object(client, 'send_signal'), patch.object(client.subprocess, 'Popen') as launch:
            self.assertEqual(client.main(['run', 'build', 'tool']), 127)
            launch.assert_not_called()

    def test_registration_failure_cleans_up_owned_child(self):
        job = Mock(pid=321, returncode=None)
        self.monitor.watch.side_effect = OSError('registration failed')
        with patch.object(client, 'pairing_key', return_value='fixture-key'), patch.object(client, 'send_signal') as send, patch.object(client.subprocess, 'Popen', return_value=job), patch.object(client, 'cancel_job', return_value=True) as cancel:
            self.assertEqual(client.main(['run', 'build', 'tool']), 127)
            cancel.assert_called_once_with(job, first_signal=client.signal.SIGTERM)
            self.assertEqual([call.args[4] for call in send.call_args_list], ['active', 'attention'])

    def test_cancellation_during_spawn_is_deferred_until_child_is_owned(self):
        job = Mock(pid=321, returncode=None)
        handlers = {}

        def install(event, handler):
            previous = handlers.get(event, client.signal.SIG_DFL)
            handlers[event] = handler
            return previous

        def spawn(*args, **kwargs):
            handlers[client.signal.SIGTERM](client.signal.SIGTERM, None)
            return job

        with patch.object(client.signal, 'signal', side_effect=install), patch.object(client.signal, 'pthread_sigmask') as mask, patch.object(client, 'pairing_key', return_value='fixture-key'), patch.object(client, 'send_signal'), patch.object(client.subprocess, 'Popen', side_effect=spawn), patch.object(client, 'cancel_job', return_value=True) as cancel:
            self.assertEqual(client.main(['run', 'build', 'tool']), 143)
            self.monitor.watch.assert_called_once_with(job)
            cancel.assert_called_once_with(job, first_signal=client.signal.SIGTERM)
            mask.assert_not_called()

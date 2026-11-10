"""Source-only background regression coverage. Mocks prevent job/network/Keychain access."""
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import Mock, patch

path = Path(__file__).resolve().parents[2] / 'integrations/activity/backlit_signal.py'
spec = importlib.util.spec_from_file_location('backlit_job_signal', path)
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)


class ActivityClientTests(unittest.TestCase):
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
        job.wait.return_value = 9
        with patch.object(client, 'pairing_key', return_value='fixture-key'), patch.object(client, 'send_signal') as signal, patch.object(client.subprocess, 'Popen', return_value=job) as launch:
            self.assertEqual(client.main(['run', 'build', '--', 'tool', 'literal;argument']), 9)
            launch.assert_called_once_with(['tool', 'literal;argument'], start_new_session=True)
            self.assertEqual([call.args[4] for call in signal.call_args_list], ['active', 'attention'])

    def test_long_job_refreshes_bounded_lease_and_completes(self):
        job = Mock()
        job.wait.side_effect = [subprocess.TimeoutExpired('fixture', 30), 0]
        with patch.object(client, 'pairing_key', return_value='fixture-key'), patch.object(client, 'send_signal') as signal, patch.object(client.subprocess, 'Popen', return_value=job):
            self.assertEqual(client.main(['run', 'backup', 'tool']), 0)
            self.assertEqual([call.args[4] for call in signal.call_args_list], ['active', 'active', 'complete'])

    def test_unavailable_backlit_does_not_block_job(self):
        job = Mock()
        job.wait.return_value = 0
        with patch.object(client, 'pairing_key', side_effect=ValueError()), patch.object(client.subprocess, 'Popen', return_value=job):
            self.assertEqual(client.main(['run', 'export', 'tool']), 0)

    def test_cancellation_forwards_interrupt_and_reaps_owned_job(self):
        job = Mock(pid=321)
        job.wait.side_effect = [KeyboardInterrupt(), 0]
        with patch.object(client, 'pairing_key', return_value='fixture-key'), patch.object(client, 'send_signal') as signal, patch.object(client.subprocess, 'Popen', return_value=job), patch.object(client.os, 'killpg') as interrupt:
            self.assertEqual(client.main(['run', 'build', 'tool']), 130)
            interrupt.assert_called_once_with(321, client.signal.SIGINT)
            self.assertEqual([call.args[4] for call in signal.call_args_list], ['active', 'clear'])
            self.assertEqual(job.wait.call_count, 2)

    def test_cancellation_escalates_only_owned_group_when_job_ignores_interrupt(self):
        job = Mock(pid=321)
        job.wait.side_effect = [subprocess.TimeoutExpired('fixture', 2), subprocess.TimeoutExpired('fixture', 2), 0]
        with patch.object(client.os, 'killpg') as interrupt:
            client.cancel_job(job)
            self.assertEqual([call.args for call in interrupt.call_args_list], [(321, client.signal.SIGINT), (321, client.signal.SIGTERM), (321, client.signal.SIGKILL)])
            self.assertEqual(job.wait.call_count, 3)

    def test_termination_request_forwards_and_restores_signal_handler(self):
        job = Mock(pid=321)
        job.wait.side_effect = [client.JobCancelled(client.signal.SIGTERM), 0]
        previous = object()
        with patch.object(client, 'pairing_key', return_value='fixture-key'), patch.object(client, 'send_signal') as signal, patch.object(client.subprocess, 'Popen', return_value=job), patch.object(client.os, 'killpg') as interrupt, patch.object(client.signal, 'signal', return_value=previous) as handlers:
            self.assertEqual(client.main(['run', 'build', 'tool']), 143)
            interrupt.assert_called_once_with(321, client.signal.SIGTERM)
            self.assertEqual([call.args[4] for call in signal.call_args_list], ['active', 'clear'])
            self.assertEqual(handlers.call_args_list[-1].args, (client.signal.SIGTERM, previous))

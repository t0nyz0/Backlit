"""Mocked process-exit ownership tests; never spawn or signal a process."""
import errno
import importlib.util
from pathlib import Path
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

path = Path(__file__).resolve().parents[2] / 'integrations/activity/backlit_signal.py'
spec = importlib.util.spec_from_file_location('backlit_completion_fixture', path)
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)


class CompletionMonitorTests(unittest.TestCase):
    def setUp(self):
        self.queue = Mock()
        self.api = SimpleNamespace(
            kqueue=Mock(return_value=self.queue), kevent=Mock(),
            KQ_FILTER_PROC=-5, KQ_NOTE_EXIT=0x80000000,
            KQ_EV_ADD=1, KQ_EV_ONESHOT=16, KQ_EV_ERROR=0x4000,
        )
        for target, name, value in ((client, 'select', self.api), (client.sys, 'platform', 'darwin')):
            replacement = patch.object(target, name, value)
            replacement.start()
            self.addCleanup(replacement.stop)
        self.job = Mock(pid=321, args=['fixture'], returncode=None)

    def exit_event(self):
        return SimpleNamespace(ident=321, filter=self.api.KQ_FILTER_PROC,
                               fflags=self.api.KQ_NOTE_EXIT, flags=0, data=0)

    def test_exit_observation_precedes_atomic_reap_and_pending_cancellation(self):
        order = []

        def observe(*args):
            order.append('observe-exit')
            return [self.exit_event()]

        def reap(**kwargs):
            order.append('reap-and-assign')
            self.job.returncode = 7
            return 7

        def mask(how, events):
            if how == client.signal.SIG_BLOCK:
                order.append('block-cancellation')
                return set()
            order.append('restore-cancellation')
            self.assertEqual(self.job.returncode, 7)
            raise client.JobCancelled(client.signal.SIGTERM)

        self.queue.control.side_effect = observe
        self.job.wait.side_effect = reap
        with client.JobExitMonitor() as monitor, patch.object(client.signal, 'pthread_sigmask', side_effect=mask), patch.object(client.os, 'killpg') as kill:
            with self.assertRaises(client.JobCancelled):
                client.wait_for_job_exit(self.job, monitor)
            self.assertTrue(client.cancel_job(self.job))
            kill.assert_not_called()
        self.assertEqual(order, ['observe-exit', 'block-cancellation', 'reap-and-assign', 'restore-cancellation'])
        self.job.wait.assert_called_once_with(timeout=None)
        self.queue.control.assert_called_once_with([], 1, 30)
        self.queue.close.assert_called_once()

    def test_lease_timeout_does_not_poll_or_reap_leader(self):
        self.queue.control.return_value = []
        with client.JobExitMonitor() as monitor, patch.object(client.signal, 'pthread_sigmask') as mask:
            with self.assertRaises(subprocess.TimeoutExpired):
                client.wait_for_job_exit(self.job, monitor)
            self.job.wait.assert_not_called()
            self.job.poll.assert_not_called()
            mask.assert_not_called()
        self.queue.control.assert_called_once_with([], 1, 30)

    def test_fast_exit_before_registration_uses_only_masked_nonblocking_reap(self):
        self.queue.control.side_effect = OSError(errno.ESRCH, 'already exited')

        def reap(**kwargs):
            self.job.returncode = 0
            return 0

        self.job.wait.side_effect = reap
        with client.JobExitMonitor() as monitor, patch.object(client.signal, 'pthread_sigmask', return_value=set()) as mask:
            monitor.watch(self.job)
            self.assertEqual(client.wait_for_job_exit(self.job, monitor), 0)
        self.job.wait.assert_called_once_with(timeout=0)
        self.assertEqual(mask.call_args_list[0].args, (client.signal.SIG_BLOCK, {client.signal.SIGINT, client.signal.SIGTERM}))
        self.assertEqual(mask.call_args_list[1].args, (client.signal.SIG_SETMASK, set()))
        self.assertEqual(self.queue.control.call_count, 1)

    def test_failed_registration_of_running_job_remains_unreaped(self):
        error = OSError(errno.ESRCH, 'registration failed')
        self.queue.control.side_effect = error
        self.job.wait.side_effect = subprocess.TimeoutExpired('fixture', 0)
        with client.JobExitMonitor() as monitor, patch.object(client.signal, 'pthread_sigmask', return_value=set()):
            with self.assertRaises(OSError) as failure:
                monitor.watch(self.job)
        self.assertIs(failure.exception, error)
        self.assertIsNone(self.job.returncode)
        self.job.wait.assert_called_once_with(timeout=0)

    def test_error_event_does_not_reap_or_release_group_identity(self):
        event = self.exit_event()
        event.flags = self.api.KQ_EV_ERROR
        event.data = errno.EINVAL
        self.queue.control.return_value = [event]
        with client.JobExitMonitor() as monitor:
            with self.assertRaises(OSError):
                client.wait_for_job_exit(self.job, monitor)
        self.job.wait.assert_not_called()
        self.assertIsNone(self.job.returncode)

    def test_unsupported_platform_fails_before_creating_observer(self):
        with patch.object(client.sys, 'platform', 'unsupported'):
            with self.assertRaises(OSError):
                client.JobExitMonitor()
        self.api.kqueue.assert_not_called()

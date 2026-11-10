#!/usr/bin/env python3
"""Explicit local job signals. Job output stays in the terminal, never in Backlit."""
import argparse
from contextlib import contextmanager
import errno
import json
import os
import select
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request

CATEGORIES = ("build", "export", "backup", "focus", "recording", "streaming")
STATES = ("active", "complete", "attention", "clear")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def pairing_key():
    value = os.environ.get("BACKLIT_TOKEN")
    if not value:
        result = subprocess.run(
            ["/usr/bin/security", "find-generic-password", "-s", "local.backlit", "-a", "home-assistant", "-w"],
            capture_output=True, text=True, timeout=5, check=False,
        )
        if result.returncode:
            raise ValueError("No local pairing key is available. Enable Backlit's local connection first.")
        value = result.stdout.strip()
    if not value or any(c in value for c in "\r\n") or len(value) > 256:
        raise ValueError("The pairing key is invalid.")
    return value


def send_signal(opener, token, port, category, state, duration=None, progress=None):
    body = {"category": category, "state": state}
    if duration is not None:
        body["duration"] = duration
    if progress is not None:
        body["progress"] = progress
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/signal", data=json.dumps(body, allow_nan=False).encode(),
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"}, method="POST",
    )
    with opener.open(request, timeout=0.75) as response:
        if response.status != 200:
            raise ValueError("Backlit rejected the signal.")


class JobCancelled(BaseException):
    def __init__(self, event):
        self.event = event


@contextmanager
def job_signals():
    def terminate(event, frame):
        raise JobCancelled(event)
    previous = {event: signal.signal(event, terminate) for event in (signal.SIGINT, signal.SIGTERM)}
    try:
        yield
    finally:
        for event, handler in previous.items():
            signal.signal(event, handler)


@contextmanager
def creation_signals_deferred():
    """Finish recording ownership before cancellation can unwind a spawn."""
    pending = []

    def defer(event, frame):
        if not pending:
            pending.append(event)

    previous = {event: signal.signal(event, defer) for event in (signal.SIGINT, signal.SIGTERM)}
    try:
        yield
    finally:
        for event, handler in previous.items():
            signal.signal(event, handler)
        if pending:
            raise JobCancelled(pending[0])


@contextmanager
def completion_signals_blocked():
    """Keep reaping and Popen.returncode assignment atomic to cancellation."""
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
    try:
        yield
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def _reap_completed(child, timeout=None):
    with completion_signals_blocked():
        return child.wait(timeout=timeout)


class JobExitMonitor:
    """Observe exit without reaping, keeping the owned PID/PGID pinned.

    Only the final wait after NOTE_EXIT reaps the leader. Unlike Popen's
    timeout wait, the kernel event wait does not repeatedly poll waitpid.
    """
    def __init__(self):
        if sys.platform != "darwin" or not all(hasattr(select, name) for name in
                ("kqueue", "kevent", "KQ_FILTER_PROC", "KQ_NOTE_EXIT", "KQ_EV_ADD", "KQ_EV_ONESHOT", "KQ_EV_ERROR")) or not hasattr(signal, "pthread_sigmask"):
            raise OSError("Job wrapping requires macOS process-exit monitoring.")
        self.queue = select.kqueue()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.queue.close()

    def watch(self, child):
        event = select.kevent(child.pid, filter=select.KQ_FILTER_PROC,
                             flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                             fflags=select.KQ_NOTE_EXIT)
        try:
            self.queue.control([event], 0, 0)
        except OSError as error:
            if error.errno != errno.ESRCH:
                raise
            # A very short job may exit before its watch is registered. Reap
            # only if it has already exited; otherwise fail setup and clean up.
            try:
                _reap_completed(child, timeout=0)
            except subprocess.TimeoutExpired:
                raise error

    def wait(self, child, timeout):
        if child.returncode is not None:
            return child.returncode
        events = self.queue.control([], 1, timeout)
        if not events:
            raise subprocess.TimeoutExpired(child.args, timeout)
        event = events[0]
        if event.flags & select.KQ_EV_ERROR:
            raise OSError(event.data, "Could not observe the job's exit.")
        if event.ident != child.pid or event.filter != select.KQ_FILTER_PROC or not event.fflags & select.KQ_NOTE_EXIT:
            raise OSError("Unexpected job completion event.")
        return _reap_completed(child)


def wait_for_job_exit(child, monitor, timeout=30):
    return monitor.wait(child, timeout)


def _wait_for_group_exit(group, timeout):
    deadline = time.monotonic() + timeout
    while True:
        try:
            os.killpg(group, 0)
        except ProcessLookupError:
            return True
        except PermissionError:
            # macOS may report EPERM for an exiting group. This is not proof
            # that every member is gone; continue bounded escalation instead.
            return False
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        try:
            time.sleep(min(0.05, remaining))
        except (KeyboardInterrupt, JobCancelled):
            # Repeated cancellation must not abandon cleanup halfway through.
            continue


def cancel_job(child, first_signal=signal.SIGINT):
    """Escalate across the owned group before reaping its leader.

    The unreaped leader pins its PID/PGID even if it exits on the first signal.
    Waiting for only that child would leave a signal-ignoring grandchild alive.
    Already-reaped leaders cannot safely identify their former group anymore.
    """
    if child.returncode is not None:
        return True
    signals_allowed = True
    events = (signal.SIGINT, signal.SIGTERM, signal.SIGKILL) if first_signal == signal.SIGINT else (signal.SIGTERM, signal.SIGKILL)
    for event in events:
        try:
            os.killpg(child.pid, event)
        except ProcessLookupError:
            break
        except PermissionError:
            # Even if the group cannot be signalled, reap our owned leader
            # when possible. Do not claim that descendants were stopped.
            signals_allowed = False
            break
        if event != signal.SIGKILL and _wait_for_group_exit(child.pid, 2):
            break
    # Do not call poll/wait before the last group signal: that could free the
    # leader's identity for reuse while descendants still need escalation.
    deadline = time.monotonic() + 2
    while True:
        try:
            child.wait(timeout=max(0, deadline - time.monotonic()))
            return signals_allowed
        except subprocess.TimeoutExpired:
            return False
        except (KeyboardInterrupt, JobCancelled):
            if time.monotonic() >= deadline:
                return False


def main(argv=None):
    parser = argparse.ArgumentParser(description="Send local Backlit activity metadata or wrap a job.")
    parser.add_argument("--port", type=int, default=48261)
    commands = parser.add_subparsers(dest="action", required=True)
    signal_parser = commands.add_parser("signal")
    signal_parser.add_argument("category", choices=CATEGORIES)
    signal_parser.add_argument("state", choices=STATES)
    signal_parser.add_argument("--duration", type=float)
    signal_parser.add_argument("--progress", type=float)
    run = commands.add_parser("run")
    run.add_argument("category", choices=("build", "export", "backup"))
    run.add_argument("command", nargs=argparse.REMAINDER)
    options = parser.parse_args(argv)
    if not 1 <= options.port <= 65535:
        parser.error("port must be between 1 and 65535")
    if options.action == "signal":
        import math
        maximum = 14400 if options.state == "active" else 60
        if options.duration is not None and (options.state == "clear" or not math.isfinite(options.duration) or not 1 <= options.duration <= maximum):
            parser.error("duration is invalid for this state")
        if options.progress is not None and (options.state != "active" or not math.isfinite(options.progress) or not 0 <= options.progress <= 1):
            parser.error("progress is only valid for active signals, from 0 to 1")
    else:
        if options.command[:1] == ["--"]:
            options.command = options.command[1:]
        if not options.command:
            parser.error("provide a job after the category")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        token = pairing_key()
    except (OSError, ValueError, subprocess.TimeoutExpired):
        token = None
    warned = False

    def emit(state, duration=None, progress=None):
        nonlocal warned
        try:
            if token is None:
                raise ValueError("Local pairing is unavailable")
            send_signal(opener, token, options.port, options.category, state, duration, progress)
            return True
        except (OSError, ValueError, urllib.error.URLError):
            if not warned:
                print("Backlit signal unavailable; enable local controls and select Signals.", file=sys.stderr)
                warned = True
            return False

    if options.action == "signal":
        return 0 if emit(options.state, options.duration, options.progress) else 2
    arguments = options.command
    with job_signals():
        child = None
        try:
            # Validate/create the observer before launching any job. Setup
            # failure after spawning is handled while its leader is still owned.
            with JobExitMonitor() as monitor:
                emit("active", 90)
                with creation_signals_deferred():
                    # No shell and no output capture. Assignment cannot be
                    # interrupted after spawn while leaving child unknown.
                    # Do not block signals here: jobs would inherit that mask.
                    child = subprocess.Popen(arguments, start_new_session=True)
                    monitor.watch(child)
                while True:
                    try:
                        code = wait_for_job_exit(child, monitor)
                        break
                    except subprocess.TimeoutExpired:
                        emit("active", 90)
        except (KeyboardInterrupt, JobCancelled) as interrupted:
            event = interrupted.event if isinstance(interrupted, JobCancelled) else signal.SIGINT
            if child is not None:
                if not cancel_job(child, first_signal=event):
                    print("The job could not be fully stopped within the cancellation limits.", file=sys.stderr)
            emit("clear")
            return 128 + event
        except OSError:
            if child is not None and not cancel_job(child, first_signal=signal.SIGTERM):
                print("The job could not be fully stopped after setup failure.", file=sys.stderr)
            emit("attention", 8)
            print("Could not start or monitor the requested job.", file=sys.stderr)
            return 127
    emit("complete" if code == 0 else "attention", 8)
    return code if code >= 0 else 128 - code


if __name__ == "__main__":
    raise SystemExit(main())

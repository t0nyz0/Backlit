#!/usr/bin/env python3
"""Explicit local job signals. Job output stays in the terminal, never in Backlit."""
import argparse
import json
import os
import subprocess
import sys
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


def main(argv=None):
    parser = argparse.ArgumentParser(description="Send local Backlit activity metadata or wrap a job.")
    parser.add_argument("--port", type=int, default=48261)
    commands = parser.add_subparsers(dest="action", required=True)
    signal = commands.add_parser("signal")
    signal.add_argument("category", choices=CATEGORIES)
    signal.add_argument("state", choices=STATES)
    signal.add_argument("--duration", type=float)
    signal.add_argument("--progress", type=float)
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
    emit("active", 90)
    try:
        # No shell and no output capture. Only status metadata goes to Backlit.
        child = subprocess.Popen(arguments)
        while True:
            try:
                code = child.wait(timeout=30)
                break
            except subprocess.TimeoutExpired:
                emit("active", 90)
    except KeyboardInterrupt:
        emit("clear")
        return 130
    except OSError:
        emit("attention", 8)
        print("Could not start the requested job.", file=sys.stderr)
        return 127
    emit("complete" if code == 0 else "attention", 8)
    return code if code >= 0 else 128 - code


if __name__ == "__main__":
    raise SystemExit(main())

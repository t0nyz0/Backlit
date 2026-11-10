"""Optional macOS OBS signals for Backlit. Loading keeps control disabled.

Only fixed activity metadata is sent to 127.0.0.1. The existing Backlit pairing
key is read from Keychain in the worker, never stored in OBS settings or logs.
Uses OBS's documented frontend callbacks; no per-frame scripting callback.
"""
# Copyright (c) 2026 t0nyz. PolyForm Perimeter 1.0.0; see project LICENSE.
import json
import subprocess
import threading
import time
import urllib.error
import urllib.request

import obspython as obs

_worker = None


class _SignalWorker:
    def __init__(self, port):
        self.port = port
        self.enabled = True
        self._condition = threading.Condition()
        self._desired = {}
        self._sent = {}
        self._active_attempts = set()
        self._revision = 0
        self._closing = False
        self._token = None
        self._key_attempted = False
        self._next_refresh = time.monotonic()
        self._thread = threading.Thread(target=self._run, name="Backlit OBS signals", daemon=True)
        self._thread.start()

    def set_enabled(self, enabled):
        with self._condition:
            if self._closing or self.enabled == enabled:
                return
            self.enabled = enabled
            if enabled:
                self._key_attempted = False
                self._token = None
            else:
                for category in tuple(self._desired):
                    self._revision += 1
                    self._desired[category] = ("clear", self._revision)
            self._condition.notify()

    def set_active(self, category, active):
        if category not in ("recording", "streaming"):
            return
        with self._condition:
            if self._closing or not self.enabled:
                return
            old = self._desired.get(category)
            if old is not None and (old[0] == "active") == active:
                return
            self._revision += 1
            self._desired[category] = ("active" if active else "complete", self._revision)
            self._condition.notify()

    def close(self):
        # Never block OBS's main callback waiting for network or Keychain.
        with self._condition:
            self._closing = True
            self._condition.notify()

    def _pairing_key(self):
        if self._token is None and not self._key_attempted:
            self._key_attempted = True
            result = subprocess.run(
                ["/usr/bin/security", "find-generic-password", "-s", "local.backlit", "-a", "home-assistant", "-w"],
                capture_output=True, text=True, timeout=2, check=False,
            )
            token = result.stdout.strip()
            if result.returncode == 0 and 16 <= len(token) <= 512 and not any(c.isspace() for c in token):
                self._token = token
        return self._token

    def _post(self, category, state, expected=None):
        try:
            token = self._pairing_key()
            if token is None:
                return False
            if expected is not None:
                with self._condition:
                    if self._closing or self._desired.get(category) != expected:
                        return False
            value = {"category": category, "state": state}
            if state == "active":
                value["duration"] = 90
            elif state == "complete":
                value["duration"] = 8
            request = urllib.request.Request(
                "http://127.0.0.1:%d/v1/signal" % self.port,
                data=json.dumps(value, separators=(",", ":")).encode("utf-8"), method="POST",
                headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
            )
            # Disable environment proxies and redirects: the token stays local.
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())
            with opener.open(request, timeout=0.75) as response:
                response.read(4096)
                return response.status == 200
        except urllib.error.HTTPError as error:
            if error.code == 401:
                self._token = None
            error.close()
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
        return False

    def _run(self):
        while True:
            with self._condition:
                now = time.monotonic()
                if self._closing:
                    clearing = tuple(self._active_attempts)
                    break
                dirty = [(category, desired) for category, desired in self._desired.items()
                         if self._sent.get(category) != desired]
                active = [(category, desired) for category, desired in self._desired.items()
                          if desired[0] == "active"]
                if not dirty and active and now >= self._next_refresh:
                    dirty = active
                if not dirty:
                    timeout = max(0.05, self._next_refresh - now) if active else None
                    self._condition.wait(timeout=timeout)
                    continue
                self._next_refresh = now + 30
            for category, desired in dirty:
                with self._condition:
                    # Stop/disable supersedes an active event before dispatch.
                    if self._closing or self._desired.get(category) != desired:
                        continue
                    if desired[0] != "active" and category not in self._active_attempts:
                        self._sent[category] = desired
                        continue
                    if desired[0] == "active":
                        self._active_attempts.add(category)
                success = self._post(category, desired[0], expected=desired)
                with self._condition:
                    # One serialized worker means an in-flight start is followed
                    # by its newer stop. Failed active sends retry only at the
                    # next heartbeat; stopped/disabled state has no idle polling.
                    self._sent[category] = desired
                    if success and desired[0] != "active":
                        self._active_attempts.discard(category)
        for category in clearing:
            self._post(category, "clear")
        self._token = None


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        return None


def script_description():
    return "Send recording and streaming status to Backlit on this Mac. Disabled until enabled below. Uses the existing pairing key from Keychain."


def script_defaults(settings):
    obs.obs_data_set_default_bool(settings, "enabled", False)
    obs.obs_data_set_default_int(settings, "port", 48261)


def script_properties():
    properties = obs.obs_properties_create()
    obs.obs_properties_add_bool(properties, "enabled", "Send status to Backlit")
    obs.obs_properties_add_int(properties, "port", "Local Backlit port", 1024, 65535, 1)
    return properties


def script_update(settings):
    global _worker
    port = obs.obs_data_get_int(settings, "port")
    enabled = obs.obs_data_get_bool(settings, "enabled") and 1024 <= port <= 65535
    if _worker is not None and _worker.port != port:
        _worker.close()
        _worker = None
    if _worker is None and enabled:
        _worker = _SignalWorker(port)
    if _worker is not None:
        _worker.set_enabled(enabled)
        if enabled:
            _worker.set_active("recording", obs.obs_frontend_recording_active())
            _worker.set_active("streaming", obs.obs_frontend_streaming_active())


def _frontend_event(event):
    worker = _worker
    if worker is None:
        return
    changes = {
        obs.OBS_FRONTEND_EVENT_RECORDING_STARTED: ("recording", True),
        obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED: ("recording", False),
        obs.OBS_FRONTEND_EVENT_STREAMING_STARTED: ("streaming", True),
        obs.OBS_FRONTEND_EVENT_STREAMING_STOPPED: ("streaming", False),
    }
    if event in changes:
        worker.set_active(*changes[event])


def script_load(settings):
    obs.obs_frontend_add_event_callback(_frontend_event)
    script_update(settings)


def script_unload():
    global _worker
    obs.obs_frontend_remove_event_callback(_frontend_event)
    if _worker is not None:
        _worker.close()
        _worker = None

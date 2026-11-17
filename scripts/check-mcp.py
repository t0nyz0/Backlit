#!/usr/bin/env python3
"""Exercise only the headless protocol; never call a live light tool or GUI."""
import argparse
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import time


class Peer:
    def __init__(self, binary):
        self.process = subprocess.Popen([str(binary), '--mcp'], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.buffer = b''

    def send(self, value):
        self.process.stdin.write(json.dumps(value).encode() + b'\n')
        self.process.stdin.flush()

    def read(self, timeout=4):
        deadline = time.monotonic() + timeout
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            while b'\n' not in self.buffer:
                if not selector.select(max(0, deadline - time.monotonic())):
                    raise AssertionError('MCP response timed out')
                block = os.read(self.process.stdout.fileno(), 4096)
                if not block:
                    raise AssertionError('MCP closed before answering')
                self.buffer += block
                if len(self.buffer) > 65536:
                    raise AssertionError('MCP output exceeded the response bound')
            line, self.buffer = self.buffer.split(b'\n', 1)
        return json.loads(line)

    def initialize(self, version='2025-11-25', capabilities=None, client_info=None, identifier=1):
        self.send({'jsonrpc': '2.0', 'id': identifier, 'method': 'initialize', 'params': {
            'protocolVersion': version, 'capabilities': {} if capabilities is None else capabilities,
            'clientInfo': client_info or {'name': 'Backlit subprocess fixture', 'version': '1'}}})
        result = self.read()
        assert result['id'] == identifier
        assert result['result']['protocolVersion'] == version
        assert 'tools' in result['result']['capabilities']
        self.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=4)
            except subprocess.TimeoutExpired:
                self.process.kill()  # This fixture owns no hardware or recovery.
                self.process.wait(timeout=2)
                raise AssertionError('Headless process did not exit on EOF')
        assert self.process.stderr.read() == b'', 'Unexpected headless diagnostic output'
        self.process.stdout.close()
        self.process.stderr.close()


def check(binary):
    peer = Peer(binary)
    try:
        peer.send({'jsonrpc': '2.0', 'id': 0, 'method': 'tools/list'})
        assert 'error' in peer.read(), 'Requests must initialize first'
        peer.initialize()
        peer.send({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'})
        tools = peer.read()['result']['tools']
        assert {item['name'] for item in tools} == {
            'backlit_get_status', 'backlit_set_power', 'backlit_set_brightness', 'backlit_set_mode'}
        for item in tools:
            assert item['inputSchema']['additionalProperties'] is False
            assert item['outputSchema']['type'] == 'object'
            assert item['annotations']['idempotentHint'] is True
        # All calls fail schema validation BEFORE the app/Keychain backend.
        invalid = [
            ('backlit_get_status', {'unexpected': True}),
            ('backlit_set_power', {'enabled': 'yes'}),
            ('backlit_set_brightness', {'percent': 101}),
            ('backlit_set_mode', {'mode': 'arbitrary-command'}),
        ]
        for number, (name, arguments) in enumerate(invalid, 3):
            peer.send({'jsonrpc': '2.0', 'id': number, 'method': 'tools/call',
                       'params': {'name': name, 'arguments': arguments}})
            result = peer.read()['result']
            assert result['isError'] is True
            assert result['structuredContent']['code'] == 'INVALID_ARGUMENT'
        peer.send({'jsonrpc': '2.0', 'id': 8, 'method': 'ping'})
        assert peer.read()['result'] == {}
    finally:
        peer.close()
    assert peer.process.returncode == 0

    for version in ['2025-06-18', '2025-03-26']:
        peer = Peer(binary)
        try:
            peer.initialize(version)
        finally:
            peer.close()
        assert peer.process.returncode == 0

    # Exact capability shape from real Codex CLI 0.155.1 thread-runtime startup.
    # Its inventory-only startup omits experimental and did not expose this bug.
    peer = Peer(binary)
    try:
        peer.initialize('2025-06-18', capabilities={
            'experimental': {'codex/auth-change': {}},
            'elicitation': {'form': {}, 'url': {}}},
            client_info={'name': 'codex-mcp-client', 'title': 'Codex', 'version': '0.155.1'},
            identifier=0)
        peer.send({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list',
                   'params': {'_meta': {'progressToken': 0}}})
        assert len(peer.read()['result']['tools']) == 4
    finally:
        peer.close()
    assert peer.process.returncode == 0

    for termination in [signal.SIGINT, signal.SIGTERM]:
        peer = Peer(binary)
        try:
            peer.initialize()
            peer.process.send_signal(termination)
            peer.process.wait(timeout=3)
        finally:
            peer.close()
        assert peer.process.returncode == -termination

    peer = Peer(binary)
    try:
        peer.initialize()
        peer.process.stdin.write(b'A' * 16385)
        peer.process.stdin.flush()
        peer.process.wait(timeout=3)
    finally:
        peer.close()
    assert peer.process.returncode == 0

    # Ping only: no light tools, credentials or native app control.
    for array_count in [63, 256]:  # request+params add two containers
        payload = (b'{"jsonrpc":"2.0","id":11,"method":"ping","params":{"extra":' +
                   b'[' * array_count + b'0' + b']' * array_count + b'}}\n')
        rejected = subprocess.run([str(binary), '--mcp'], input=payload, capture_output=True, timeout=4)
        assert rejected.returncode == 0, f'deep input exited {rejected.returncode}'
        assert rejected.stdout == b'' and rejected.stderr == b''
    peer = Peer(binary)
    try:
        peer.initialize()
        peer.process.stdin.write(b'{"jsonrpc":"2.0","id":11,"method":"ping","params":{"extra":' +
                                b'[' * 62 + b'0' + b']' * 62 + b'}}\n')
        peer.process.stdin.flush()
        assert peer.read()['id'] == 11
    finally:
        peer.close()
    assert peer.process.returncode == 0

    conflict = subprocess.run([str(binary), '--mcp', '--preview'], capture_output=True, timeout=4)
    assert conflict.returncode == 2 and conflict.stdout == b''
    print('MCP subprocess checks passed: initialization, real Codex capabilities, schemas, strict arguments, version negotiation, EOF, signals, input bound, and iterative JSON depth bounds.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    args = parser.parse_args()
    check(args.binary.resolve(strict=True))

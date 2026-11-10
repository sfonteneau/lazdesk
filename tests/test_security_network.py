#!/usr/bin/env python3
"""Run against YOUR isolated v9 server. Never run against a production desktop.
Requires LAZDESK_TOKEN and LAZDESK_VIEW_TOKEN. Does not type or click anything.
Without --control-tests it never acquires exclusive desktop control.
"""
from __future__ import annotations
import argparse
import os
from pathlib import Path
import secrets
import struct
import sys
import time
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from kvm_ws import WS, Closed, frame, endpoint_args, connection_args

def expect_closed(ws, timeout=6):
    try:
        ws.next_matching(lambda op, data: False, timeout)
    except (Closed, ConnectionResetError, BrokenPipeError):
        return
    raise AssertionError('Connection was not closed')

def main():
    p = argparse.ArgumentParser(description=__doc__)
    endpoint_args(p)
    p.add_argument('--control-tests', action='store_true')
    a = p.parse_args()
    token = os.environ.get('LAZDESK_TOKEN', '')
    view = os.environ.get('LAZDESK_VIEW_TOKEN', '')
    if not token or not view: p.error('Set both test tokens in the environment')
    connect = lambda: WS(**connection_args(a))
    with connect() as ws:
        ws.send(b'P')
        expect_closed(ws)
    print('PASS pre-auth binary rejected')
    with connect() as ws:
        ws.send(('AUTH ' + secrets.token_hex(32) + ' jpeg').encode(), text=True)
        expect_closed(ws)
    print('PASS wrong token rejected')
    with connect() as ws: expect_closed(ws, 8)
    print('PASS unauthenticated connection expires')
    with connect() as ws:
        assert ws.auth(view) == b'OK VIEW'
        ws.send(b'G')
        assert ws.next_matching(lambda op, d: op == 1 and d.startswith(b'CTRL '))[1] == b'CTRL BUSY'
        request = b'U' + struct.pack('<I', 1) + b'not-injected'
        ws.send(request)
        first = ws.next_matching(lambda op, d: op == 2 and d[:1] == b'I')[1]
        assert first == b'I' + struct.pack('<IBH', 1, 1, 0), first
        ws.send(request)
        assert ws.next_matching(lambda op, d: op == 2 and d[:1] == b'I')[1] == first
        ws.send(b'U' + struct.pack('<I', 1) + b'different')
        assert ws.next_matching(lambda op, d: op == 2 and d[:1] == b'I')[1] == b'I' + struct.pack('<IBH', 1, 4, 0)
    print('PASS view-only denial, identical receipt, conflicting serial rejected')
    with connect() as ws:
        ws.auth(view)
        ws.sock.sendall(frame(2, b'?') * 3)
        expect_closed(ws)
    print('PASS malformed command threshold')
    with connect() as ws:
        ws.auth(view)
        ws.send(b'U' + b'x' * 1030)
        expect_closed(ws)
    print('PASS oversized application input rejected')
    with connect() as ws:
        ws.auth(view)
        ws.sock.sendall(frame(2, b'P') * 5000)
        expect_closed(ws)
    print('PASS bounded command-rate flood closes sender')
    if a.control_tests:
        with connect() as first, connect() as second:
            assert first.auth(token) == b'OK CTRL'
            assert second.auth(token) == b'OK CTRL'
            first.next_matching(lambda op, d: op == 2 and len(d) == 7 and d[:2] == b'D\x01', 15)
            first.send(b'G')
            assert first.next_matching(lambda op, d: op == 1 and d.startswith(b'CTRL '))[1] == b'CTRL GRANTED'
            second.send(b'G')
            assert second.next_matching(lambda op, d: op == 1 and d.startswith(b'CTRL '))[1] == b'CTRL BUSY'
            first.send(b'L')
            first.next_matching(lambda op, d: d == b'CTRL RELEASED')
            second.send(b'G')
            assert second.next_matching(lambda op, d: op == 1 and d.startswith(b'CTRL '))[1] == b'CTRL GRANTED'
            second.send(b'L')
        print('PASS exclusive control and relinquish (no keys/mouse injected)')
    print('PASS network cases selected. Does not establish TLS certificate negatives, GUI, session-lock or GPU correctness.')
if __name__ == '__main__':
    try: main()
    except Exception as exc:
        print(f'FAIL/UNAVAILABLE: {type(exc).__name__}: {exc}', file=sys.stderr)
        sys.exit(1)

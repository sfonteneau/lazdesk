#!/usr/bin/env python3
import socket
import struct
import sys
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from kvm_ws import WS,frame,MAX_MESSAGE

class Frames(unittest.TestCase):
    def test_masked_lengths(self):
        for size in (0,1,125,126,127,65535,65536,100000):
            original=b'x'*size;p=frame(2,original);n=p[1]&127;at=2
            self.assertEqual(p[0],0x82);self.assertTrue(p[1]&128)
            if n==126:n=struct.unpack('!H',p[at:at+2])[0];at+=2
            elif n==127:n=struct.unpack('!Q',p[at:at+8])[0];at+=8
            mask=p[at:at+4];raw=p[at+4:]
            self.assertEqual(n,size)
            self.assertEqual(bytes(c^mask[i%4] for i,c in enumerate(raw)),original)
    def pair(self):
        ws=WS.__new__(WS);ws.sock,peer=socket.socketpair();ws.buffer=bytearray();ws.wire_bytes=0
        self.addCleanup(ws.close);self.addCleanup(peer.close);return ws,peer
    def test_fragment_and_ping(self):
        ws,peer=self.pair()
        peer.sendall(b'\x02\x02ab\x89\x01!\x80\x02cd')
        self.assertEqual(ws.receive(),(2,b'abcd'))
        pong=peer.recv(100);self.assertEqual(pong[0],0x8a)
    def test_partial_header_timeout(self):
        ws,peer=self.pair();peer.sendall(b'\x82\x04ab')
        with self.assertRaises(TimeoutError):ws.receive(.01)
        peer.sendall(b'cd');self.assertEqual(ws.receive(),(2,b'abcd'))
    def test_oversized_header(self):
        ws,peer=self.pair();peer.sendall(b'\x82\x7f'+struct.pack('!Q',MAX_MESSAGE+1))
        with self.assertRaises(ValueError):ws.receive()
    def test_masked_server_rejected(self):
        ws,peer=self.pair();peer.sendall(b'\x82\x80')
        with self.assertRaises(ValueError):ws.receive()
    def test_extra_extensions_rejected(self):
        ws,peer=self.pair();peer.sendall(b'\xc2\x00')
        with self.assertRaises(ValueError):ws.receive()
if __name__=='__main__':unittest.main(verbosity=2)

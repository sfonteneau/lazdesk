#!/usr/bin/env python3
"""Real XCB/X11 protocol probes on a PRIVATE Xvfb, not Pascal execution.

The raw requests use the same wire offsets and scalar XCB entry points as
kvm_clipboard_x11.pas. This validates the OS ABI/protocol, not that unit's build.
No access to the user's display, Xauthority or clipboard.
"""
import ctypes as C
import os
import select
import shutil
import struct
import subprocess
import tempfile
import time
import unittest
import sys

if not sys.platform.startswith("linux"):
    raise unittest.SkipTest("Linux/XCB native probe only")

MAX = 65536
class Vec(C.Structure):
    _fields_ = [('base', C.c_void_p), ('length', C.c_size_t)]
class Request(C.Structure):
    _fields_ = [('count', C.c_size_t), ('ext', C.c_void_p),
                ('opcode', C.c_ubyte), ('isvoid', C.c_ubyte)]
lib = C.CDLL('libxcb.so.1')
libc = C.CDLL(None)
libc.free.argtypes = [C.c_void_p]
def fn(name, result, args):
    f = getattr(lib, name); f.restype = result; f.argtypes = args; return f
connect = fn('xcb_connect', C.c_void_p, [C.c_char_p,C.c_void_p])
disconnect = fn('xcb_disconnect', None, [C.c_void_p])
has_error = fn('xcb_connection_has_error', C.c_int, [C.c_void_p])
setup = fn('xcb_get_setup', C.c_void_p, [C.c_void_p])
gen_id = fn('xcb_generate_id', C.c_uint32, [C.c_void_p])
send = fn('xcb_send_request', C.c_uint32,[C.c_void_p,C.c_int,C.c_void_p,C.c_void_p])
wait = fn('xcb_wait_for_reply', C.c_void_p,[C.c_void_p,C.c_uint32,C.c_void_p])
check = fn('xcb_request_check', C.c_void_p,[C.c_void_p,C.c_uint32])
poll = fn('xcb_poll_for_event', C.c_void_p,[C.c_void_p])
flush = fn('xcb_flush', C.c_int,[C.c_void_p])

def put(b, off, v): struct.pack_into('=I',b,off,v)
def u32(b, off): return struct.unpack_from('=I',b,off)[0]
class X:
    def __init__(self, display):
        self.c = connect(display.encode(),None)
        if has_error(self.c):
            disconnect(self.c); self.c=None; raise RuntimeError('XCB failed')
        p=setup(self.c); head=C.string_at(p,40)
        off=40+((struct.unpack_from('=H',head,24)[0]+3)&~3)+head[29]*8
        self.root=u32(C.string_at(p+off,40),0)
        self.win=self.window()
        self.clip=self.atom(b'CLIPBOARD'); self.utf8=self.atom(b'UTF8_STRING')
        self.prop=self.atom(b'LAZDESK_CLIPBOARD_TEXT'); self.incr=self.atom(b'INCR')
    def close(self):
        if self.c: disconnect(self.c); self.c=None
    def req(self, op, data, void=False):
        data=bytearray(data); data.extend(b'\0'*((-len(data))%4))
        buf=(C.c_ubyte*len(data)).from_buffer(data)
        v=(Vec*3)(); v[2]=Vec(C.cast(buf,C.c_void_p),len(data))
        info=Request(1,None,op,int(void))
        seq=send(self.c,1,C.byref(v,2*C.sizeof(Vec)),C.byref(info))
        if not seq: raise RuntimeError('send failed')
        if void:
            error=check(self.c,seq)
            if error: libc.free(error); return False
            return True
        error=C.c_void_p(); p=wait(self.c,seq,C.byref(error))
        if error.value:
            libc.free(error)
            if p: libc.free(p)
            raise RuntimeError('X error')
        if not p: raise RuntimeError('missing reply')
        try:
            h=C.string_at(p,32)
            return C.string_at(p,32+u32(h,4)*4)
        finally: libc.free(p)
    def atom(self,name):
        b=bytearray(8)+name; struct.pack_into('=H',b,4,len(name))
        return u32(self.req(16,b),8)
    def window(self):
        w=gen_id(self.c); b=bytearray(36); put(b,4,w); put(b,8,self.root)
        struct.pack_into('=HH',b,16,1,1); struct.pack_into('=H',b,22,2)
        put(b,28,1<<11); put(b,32,1<<22)
        assert self.req(1,b,True); return w
    def destroy(self,w):
        b=bytearray(8); put(b,4,w); return self.req(4,b,True)
    def own(self):
        b=bytearray(16); put(b,4,self.win); put(b,8,self.clip)
        assert self.req(22,b,True)
    def owner(self):
        b=bytearray(8); put(b,4,self.clip); return u32(self.req(23,b),8)
    def convert(self):
        b=bytearray(24); put(b,4,self.win); put(b,8,self.clip)
        put(b,12,self.utf8); put(b,16,self.prop); assert self.req(24,b,True)
    def property(self,w,atom,kind,data,fmt=8):
        b=bytearray(24)+data; put(b,4,w); put(b,8,atom); put(b,12,kind)
        b[16]=fmt; put(b,20,len(data)//(fmt//8)); return self.req(18,b,True)
    def get(self):
        b=bytearray(24); b[1]=1; put(b,4,self.win); put(b,8,self.prop); put(b,20,MAX//4)
        return self.req(20,b)
    def notify(self,event):
        b=bytearray(44); dest=u32(event,12); put(b,4,dest); b[12]=31
        put(b,16,u32(event,4)); put(b,20,dest); put(b,24,self.clip)
        put(b,28,u32(event,20)); put(b,32,u32(event,24))
        return self.req(25,b,True)
    def events(self):
        out=[]
        for _ in range(32):
            p=poll(self.c)
            if not p: break
            try: out.append(C.string_at(p,32))
            finally: libc.free(p)
        return out
    def event(self,kind,timeout=2):
        end=time.monotonic()+timeout
        while time.monotonic()<end:
            for e in self.events():
                if (e[0]&127)==kind: return e
            time.sleep(.002)
        raise AssertionError('event timeout '+str(kind))

@unittest.skipUnless(shutil.which('Xvfb'),'Xvfb absent')
class NativeClipboardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp=tempfile.TemporaryDirectory(prefix='lazdesk-clipboard-x11-')
        cls.err=open(os.path.join(cls.tmp.name,'xvfb.log'),'wb')
        cls.p=subprocess.Popen(['Xvfb','-displayfd','1','-screen','0','640x480x24','-nolisten','tcp','-noreset'],
            stdout=subprocess.PIPE,stderr=cls.err)
        if not select.select([cls.p.stdout],[],[],5)[0]:
            cls.p.terminate(); raise RuntimeError('private Xvfb did not start')
        cls.display=':'+cls.p.stdout.readline().decode().strip()
        if cls.display==':': raise RuntimeError('no display number')
    @classmethod
    def tearDownClass(cls):
        cls.p.terminate(); cls.p.wait(timeout=5); cls.err.close(); cls.tmp.cleanup()
    def setUp(self): self.a=X(self.display); self.b=X(self.display)
    def tearDown(self): self.b.close(); self.a.close()
    def roundtrip(self,text):
        self.a.own(); self.b.convert(); e=self.a.event(30)
        self.assertEqual(u32(e,12),self.b.win)
        self.assertTrue(self.a.property(self.b.win,self.b.prop,self.b.utf8,text))
        self.assertTrue(self.a.notify(e)); self.b.event(31); reply=self.b.get()
        self.assertEqual(reply[1],8); self.assertEqual(u32(reply,8),self.b.utf8)
        self.assertEqual(u32(reply,12),0)
        self.assertEqual(reply[32:32+u32(reply,16)],text)
    def test_unicode(self): self.roundtrip('Bonjour\n\u00e9\u4e2d\U0001f600'.encode())
    def test_empty(self): self.roundtrip(b'')
    def test_limit(self): self.roundtrip(b'x'*MAX)
    def test_owner_and_clear(self):
        self.a.own(); self.assertEqual(self.b.owner(),self.a.win)
        self.b.own(); self.assertEqual(self.a.owner(),self.b.win)
        self.a.event(29)
    def test_disappeared_requestor_not_fatal(self):
        w=self.b.window(); self.b.destroy(w)
        self.assertFalse(self.a.property(w,self.a.prop,self.a.utf8,b'abc'))
        self.a.own(); self.assertEqual(self.a.owner(),self.a.win)
    def test_incremental_selection(self):
        self.a.own(); self.b.convert(); e=self.a.event(30)
        self.assertTrue(self.a.property(self.b.win,self.b.prop,self.b.incr,struct.pack('=I',30000),32))
        self.a.notify(e); self.b.event(31); header=self.b.get()
        self.assertEqual(u32(header,8),self.b.incr); self.assertEqual(u32(header,32),30000)
        result=b''
        for chunk in [b'a'*10000,b'b'*10000,b'c'*10000,b'']:
            self.assertTrue(self.a.property(self.b.win,self.b.prop,self.b.utf8,chunk))
            self.b.event(28); part=self.b.get(); self.assertEqual(part[1],8)
            result+=part[32:32+u32(part,16)]
        self.assertEqual(result,b'a'*10000+b'b'*10000+b'c'*10000)
    def test_property_reply_is_bounded(self):
        data=b'x'*(MAX+4096)
        self.a.property(self.b.win,self.b.prop,self.b.utf8,data)
        rep=self.b.get()
        self.assertEqual(u32(rep,16),MAX); self.assertEqual(u32(rep,12),4096)

if __name__=='__main__': unittest.main(verbosity=2)

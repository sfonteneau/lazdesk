#!/usr/bin/env python3
"""Exercise the native X11 ABI used by the Pascal backend on a private Xvfb.
This checks native declarations/semantics; it DOES NOT compile/run Pascal.
No third-party Python modules, no interaction with the real desktop.
"""
import ctypes as C
import os
import selectors
import shutil
import subprocess
import time

I, U, UL, P = C.c_int, C.c_uint, C.c_ulong, C.c_void_p
class Image(C.Structure):
    _fields_ = [(n,I) for n in ('width','height','xoffset','format')] + [('data',P)] + \
        [(n,I) for n in ('byte_order','bitmap_unit','bitmap_bit_order','bitmap_pad','depth','bytes_per_line','bits_per_pixel')] + \
        [(n,UL) for n in ('red_mask','green_mask','blue_mask')]
class ShmInfo(C.Structure):
    _fields_ = [('shmseg',UL),('shmid',I),('shmaddr',P),('readOnly',I)]
class XkbState(C.Structure):
    _fields_ = [('group',C.c_ubyte),('locked_group',C.c_ubyte),('base_group',C.c_ushort),('latched_group',C.c_ushort)] + \
        [(n,C.c_ubyte) for n in ('mods','base_mods','latched_mods','locked_mods','compat_state','grab_mods','compat_grab_mods','lookup_mods','compat_lookup_mods')] + [('ptr_buttons',C.c_ushort)]
def bind(lib,name,args,result):
    fn=getattr(lib,name); fn.argtypes=args; fn.restype=result; return fn

def main():
    if not shutil.which('Xvfb'): raise SystemExit('NOT RUN: Xvfb required')
    x=C.CDLL('libX11.so.6'); ext=C.CDLL('libXext.so.6'); xt=C.CDLL('libXtst.so.6'); libc=C.CDLL(None)
    open_=bind(x,'XOpenDisplay',[C.c_char_p],P); close=bind(x,'XCloseDisplay',[P],I)
    screen=bind(x,'XDefaultScreen',[P],I); root=bind(x,'XRootWindow',[P,I],UL)
    visual=bind(x,'XDefaultVisual',[P,I],P); depth=bind(x,'XDefaultDepth',[P,I],I)
    sync=bind(x,'XSync',[P,I],I)
    create=bind(ext,'XShmCreateImage',[P,P,U,I,P,C.POINTER(ShmInfo),U,U],C.POINTER(Image))
    attach=bind(ext,'XShmAttach',[P,C.POINTER(ShmInfo)],I)
    detach=bind(ext,'XShmDetach',[P,C.POINTER(ShmInfo)],I)
    get=bind(ext,'XShmGetImage',[P,UL,C.POINTER(Image),I,I,UL],I)
    destroy=bind(x,'XDestroyImage',[C.POINTER(Image)],I)
    shmget=bind(libc,'shmget',[I,C.c_size_t,I],I)
    shmat=bind(libc,'shmat',[I,P,I],P); shmdt=bind(libc,'shmdt',[P],I)
    shmctl=bind(libc,'shmctl',[I,I,P],I)
    normal=bind(x,'XGetImage',[P,UL,I,I,U,U,UL,I],C.POINTER(Image))
    sub=bind(x,'XGetSubImage',[P,UL,I,I,U,U,UL,I,C.POINTER(Image),I,I],C.POINTER(Image))
    move=bind(xt,'XTestFakeMotionEvent',[P,I,I,I,UL],I)
    query=bind(x,'XQueryPointer',[P,UL,C.POINTER(UL),C.POINTER(UL),C.POINTER(I),C.POINTER(I),C.POINTER(I),C.POINTER(I),C.POINTER(U)],I)
    kb=bind(x,'XkbGetState',[P,U,C.POINTER(XkbState)],I)
    lockmods=bind(x,'XkbLockModifiers',[P,U,U,U],I)
    proc=subprocess.Popen(['Xvfb','-displayfd','1','-screen','0','640x360x24','-nolisten','tcp'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    display=None; image=None; fallback=None; info=ShmInfo(); info.shmid=-1; attached=False
    try:
        poll=selectors.DefaultSelector(); poll.register(proc.stdout,selectors.EVENT_READ)
        if not poll.select(10): raise RuntimeError('Xvfb startup timeout')
        number=proc.stdout.readline().strip()
        if not number.isdigit(): raise RuntimeError(proc.stderr.read().decode())
        for _ in range(50):
            display=open_(b':'+number)
            if display: break
            time.sleep(.05)
        assert display, 'cannot open isolated display'
        sc=screen(display); rt=root(display,sc); mask=UL(-1).value
        image=create(display,visual(display,sc),depth(display,sc),2,None,C.byref(info),640,360)
        assert image, 'XShmCreateImage'
        im=image.contents
        assert (im.width,im.height,im.bits_per_pixel)==(640,360,32)
        assert (im.red_mask,im.green_mask,im.blue_mask)==(0xff0000,0xff00,0xff)
        size=im.bytes_per_line*im.height
        info.shmid=shmget(0,size,0o1000|0o600); assert info.shmid>=0
        info.shmaddr=shmat(info.shmid,None,0); assert info.shmaddr not in (None,P(-1).value)
        image.contents.data=info.shmaddr
        assert attach(display,C.byref(info)); sync(display,0); attached=True
        assert shmctl(info.shmid,0,None)==0
        for _ in range(10): assert get(display,rt,image,0,0,mask)
        sync(display,0)
        print('PASS: XImage/SHM layouts, 0600 shared memory, ten XShmGetImage captures')
        fallback=normal(display,rt,0,0,640,360,mask,2); assert fallback
        original_address=C.addressof(fallback.contents)
        for _ in range(10):
            result=sub(display,rt,0,0,640,360,mask,2,fallback,0,0)
            assert result and C.addressof(result.contents)==original_address
        print('PASS: XGetSubImage fallback reuses the destination image')
        assert move(display,sc,319,179,0); sync(display,0)
        rr,child=UL(),UL(); rx,ry,wx,wy=I(),I(),I(),I(); buttons=U()
        assert query(display,rt,C.byref(rr),C.byref(child),C.byref(rx),C.byref(ry),C.byref(wx),C.byref(wy),C.byref(buttons))
        assert (rx.value,ry.value)==(319,179)
        print('PASS: XTest pointer movement and root coordinates')
        state=XkbState(); assert C.sizeof(state)==18 and kb(display,0x100,C.byref(state))==0
        assert lockmods(display,0x100,2,0); assert lockmods(display,0x100,2,state.locked_mods&2)
        sync(display,0)
        print('PASS: XKB state layout and CapsLock preservation calls')
        # XFixes pixels are unsigned long per element, even on LP64 hosts.
        class CursorImage(C.Structure):
            _fields_=[('x',C.c_short),('y',C.c_short),('width',C.c_ushort),('height',C.c_ushort),
                ('xhot',C.c_ushort),('yhot',C.c_ushort),('serial',UL),('pixels',C.POINTER(UL)),
                ('atom',UL),('name',C.c_char_p)]
        xf=C.CDLL('libXfixes.so.3')
        get_cursor=bind(xf,'XFixesGetCursorImage',[P],C.POINTER(CursorImage))
        free_=bind(x,'XFree',[P],I)
        ci=get_cursor(display)
        assert ci
        try:
            image_=ci.contents
            assert (image_.x,image_.y)==(319,179)
            assert 1<=image_.width<=512 and 1<=image_.height<=512
            assert image_.pixels and image_.xhot<image_.width and image_.yhot<image_.height
            assert any((image_.pixels[k]>>24)&255 for k in range(image_.width*image_.height))
        finally: free_(C.cast(ci,P))
        print('PASS: XFixes cursor position, hotspot, dimensions and native unsigned-long pixels')
    finally:
        if display:
            if attached: detach(display,C.byref(info)); sync(display,0)
            if image:
                image.contents.data=None; destroy(image)
            if fallback: destroy(fallback)
            if info.shmaddr not in (None,P(-1).value): shmdt(info.shmaddr)
            if info.shmid>=0: shmctl(info.shmid,0,None)
            close(display)
        proc.terminate()
        try: proc.wait(timeout=5)
        except subprocess.TimeoutExpired: proc.kill(); proc.wait()
    print('NOTE: native ABI smoke test only; not a Pascal/server/client test')
if __name__=='__main__': main()

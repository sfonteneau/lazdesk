#!/usr/bin/env python3
"""Application-level X11 regression: an actual Tk Entry receives unmapped keys.

Uses a private Xvfb display and the same native X11 primitives as the Pascal
backend. This is not a Pascal compilation or a test of the real Debian desktop.
"""
import ctypes as C
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
import time

CODE = Path(__file__).resolve().parents[1] / 'server/kvm_inject_x11.pas'
assert 'XChangeKeyboardMapping(D, Scratch, Width, @TemporarySyms[0], 1)' in CODE.read_text()


def bind(lib, name, args, result):
    f = getattr(lib, name)
    f.argtypes, f.restype = args, result
    return f


def main():
    for needed in ('Xvfb', 'setxkbmap'):
        if not shutil.which(needed):
            print('SKIP:', needed, 'unavailable')
            return
    try:
        import tkinter  # noqa: F401
    except ImportError:
        print('SKIP: tkinter unavailable')
        return
    I, U, UL, P, B = C.c_int, C.c_uint, C.c_ulong, C.c_void_p, C.c_ubyte
    x, xt = C.CDLL('libX11.so.6'), C.CDLL('libXtst.so.6')
    op = bind(x, 'XOpenDisplay', [C.c_char_p], P)
    close = bind(x, 'XCloseDisplay', [P], I)
    codes = bind(x, 'XDisplayKeycodes', [P, C.POINTER(I), C.POINTER(I)], I)
    get = bind(x, 'XGetKeyboardMapping', [P, B, I, C.POINTER(I)], C.POINTER(UL))
    change = bind(x, 'XChangeKeyboardMapping', [P, I, I, C.POINTER(UL), I], I)
    free = bind(x, 'XFree', [P], I)
    sync = bind(x, 'XSync', [P, I], I)
    fake = bind(xt, 'XTestFakeKeyEvent', [P, U, I, UL], I)
    focus = bind(x, 'XSetInputFocus', [P, UL, I, UL], I)
    xvfb = subprocess.Popen(
        ['Xvfb', '-displayfd', '1', '-screen', '0', '640x360x24', '-nolisten', 'tcp'],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    target, display = None, None
    try:
        reader = selectors.DefaultSelector()
        reader.register(xvfb.stdout, selectors.EVENT_READ)
        assert reader.select(10), 'Xvfb did not start'
        name = ':' + xvfb.stdout.readline().decode().strip()
        subprocess.run(['setxkbmap', '-display', name, '-layout', 'ru'], check=True)
        env = dict(os.environ, DISPLAY=name)
        env.pop('XAUTHORITY', None)
        tk_program = '''import tkinter as tk
root = tk.Tk()
e = tk.Entry(root, width=60)
e.pack()
root.update()
e.focus_force()
root.update()
print('READY', root.winfo_id(), flush=True)
root.after(1500, lambda: (print('CONTENT', repr(e.get()), flush=True), root.destroy()))
root.mainloop()
'''
        target = subprocess.Popen([sys.executable, '-c', tk_program], env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        tk_start = selectors.DefaultSelector()
        tk_start.register(target.stdout, selectors.EVENT_READ)
        assert tk_start.select(10), 'Tk target did not start'
        ready = target.stdout.readline().split()
        assert ready and ready[0] == 'READY', ready
        window = int(ready[1])
        display = op(name.encode())
        assert display
        focus(display, window, 1, 0)
        sync(display, 0)
        lo, hi, width = I(), I(), I()
        codes(display, C.byref(lo), C.byref(hi))
        mapping = get(display, lo.value, hi.value-lo.value+1, C.byref(width))
        assert mapping and width.value > 0
        try:
            scratch = next(code for code in range(hi.value, lo.value-1, -1)
                           if all(mapping[(code-lo.value)*width.value+i] == 0
                                  for i in range(width.value)))
            saved = [mapping[(scratch-lo.value)*width.value+i]
                     for i in range(width.value)]
        finally:
            free(mapping)
        phrase = '#{[|`\\^@]}'
        for char in phrase:
            symbol = ord(char)
            try:
                change(display, scratch, width.value,
                       (UL*width.value)(*([symbol]*width.value)), 1)
                sync(display, 0)
                assert fake(display, scratch, 1, 0)
                assert fake(display, scratch, 0, 0)
                sync(display, 0)
                time.sleep(.025)
            finally:
                change(display, scratch, width.value,
                       (UL*width.value)(*saved), 1)
                sync(display, 0)
        response = target.stdout.readline().rstrip()
        assert response == 'CONTENT ' + repr(phrase), (phrase, response,
                                                     target.stderr.read())
        print('PASS: actual Tk Entry received', repr(phrase), 'on Russian X11 layout')
    finally:
        if display:
            close(display)
        if target:
            try:
                target.wait(timeout=4)
            except subprocess.TimeoutExpired:
                target.terminate()
                target.wait(timeout=3)
        xvfb.terminate()
        try:
            xvfb.wait(timeout=5)
        except subprocess.TimeoutExpired:
            xvfb.kill()


if __name__ == '__main__':
    main()

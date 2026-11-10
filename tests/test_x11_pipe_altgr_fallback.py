#!/usr/bin/env python3
"""Regression for pipe present at XKB AltGr level but not reliably typeable.

Uses Xvfb with an XKB map where pipe is available only via AltGr and an actual Tk text entry. It exercises
X11's unassigned-keycode injection operations and checks that the ordinary
keycode is not remapped. It is NOT a compiled-Pascal or live Debian test.
"""
from __future__ import annotations
import ctypes as C
from pathlib import Path
import os
import selectors
import shutil
import subprocess
import sys
import time

SRC = (Path(__file__).resolve().parents[1] / 'server/kvm_inject_x11.pas').read_text()
assert "(CodePoint = Ord('|')) and ((FoundLevel and 2) <> 0)" in SRC
assert 'FindUnusedXkbKey(D, PressedMap, Scratch, Width, SavedSyms)' in SRC
assert 'FoundCode := Scratch;' in SRC and 'FoundLevel := 0;' in SRC
assert 'XChangeKeyboardMapping(D, Scratch, Width, @SavedSyms[0], 1)' in SRC


def bind(lib, name, args, result):
    f = getattr(lib, name)
    f.argtypes, f.restype = args, result
    return f


def main():
    if not all(shutil.which(n) for n in ('Xvfb', 'setxkbmap')):
        print('SKIP: Xvfb/setxkbmap unavailable')
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
    code_range = bind(x, 'XDisplayKeycodes', [P, C.POINTER(I), C.POINTER(I)], I)
    group_sym = bind(x, 'XkbKeycodeToKeysym', [P, B, I, I], UL)
    get = bind(x, 'XGetKeyboardMapping', [P, B, I, C.POINTER(I)], C.POINTER(UL))
    change = bind(x, 'XChangeKeyboardMapping', [P, I, I, C.POINTER(UL), I], I)
    free = bind(x, 'XFree', [P], I)
    fake = bind(xt, 'XTestFakeKeyEvent', [P, U, I, UL], I)
    sync = bind(x, 'XSync', [P, I], I)
    xquery = bind(x, 'XQueryKeymap', [P, P], I)
    focus = bind(x, 'XSetInputFocus', [P, UL, I, UL], I)
    proc = subprocess.Popen(['Xvfb', '-displayfd', '1', '-screen', '0',
                             '640x360x24', '-nolisten', 'tcp'],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    display = None
    app = None
    try:
        sel = selectors.DefaultSelector()
        sel.register(proc.stdout, selectors.EVENT_READ)
        assert sel.select(10), 'Xvfb startup timeout'
        name = ':' + proc.stdout.readline().decode().strip()
        result = subprocess.run(['setxkbmap', '-display', name, '-layout', 'us'],
                                capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        env = dict(os.environ, DISPLAY=name)
        env.pop('XAUTHORITY', None)
        tk_program = '''import tkinter as tk
root = tk.Tk()
entry = tk.Entry(root)
entry.pack()
root.update()
entry.focus_force()
root.update()
print('READY', root.winfo_id(), flush=True)
root.after(1500, lambda: (print('CONTENT', repr(entry.get()), flush=True), root.destroy()))
root.mainloop()
'''
        app = subprocess.Popen([sys.executable, '-c', tk_program],
                               env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True)
        app_select = selectors.DefaultSelector()
        app_select.register(app.stdout, selectors.EVENT_READ)
        assert app_select.select(10), 'Tk window startup timeout'
        ready = app.stdout.readline().split()
        assert ready and ready[0] == 'READY', ready
        display = op(name.encode())
        assert display
        focus(display, int(ready[1]), 1, 0)
        sync(display, 0)
        lo, hi, width = I(), I(), I()
        assert code_range(display, C.byref(lo), C.byref(hi))
        # Xvfb initially exposes a second | on Shift+backslash. Remove only
        # that alias in this throwaway display to reproduce the user's XKB
        # diagnostic (pipe: keycode 94, level 2 / AltGr).
        alias_width = I()
        alias_syms = get(display, 51, 1, C.byref(alias_width))
        assert alias_syms
        alias_original = [alias_syms[i] for i in range(alias_width.value)]
        free(alias_syms)
        assert ord('|') in alias_original
        alias_without_pipe = [ord('\\') if val == ord('|') else val
                              for val in alias_original]
        change(display, 51, alias_width.value,
               (UL*alias_width.value)(*alias_without_pipe), 1)
        sync(display, 0)
        matches = [(c, lev) for lev in range(4)
                   for c in range(lo.value, hi.value + 1)
                   if group_sym(display, c, 0, lev) == ord('|')]
        assert matches, 'pipe missing from simulated XKB layout'
        first_code, first_level = matches[0]
        assert first_level & 2, ('test requires pipe at AltGr level', matches)
        mapping = get(display, lo.value, hi.value-lo.value+1, C.byref(width))
        assert mapping and 0 < width.value <= 64
        try:
            scratch = next(c for c in range(hi.value, lo.value-1, -1)
                           if all(mapping[(c-lo.value)*width.value+j] == 0
                                  for j in range(width.value))
                           and all(group_sym(display, c, group, level) == 0
                                   for group in range(4) for level in range(8)))
            original = [mapping[(scratch-lo.value)*width.value+j]
                        for j in range(width.value)]
            real_key_before = [mapping[(first_code-lo.value)*width.value+j]
                               for j in range(width.value)]
        finally:
            free(mapping)
        assert first_code != scratch
        keys_before = C.create_string_buffer(32)
        assert xquery(display, keys_before)
        try:
            syms = (UL*width.value)(*([ord('|')]*width.value))
            change(display, scratch, width.value, syms, 1)
            sync(display, 0)
            assert fake(display, scratch, 1, 0)
            assert fake(display, scratch, 0, 0)
            sync(display, 0)
            time.sleep(.025)
        finally:
            change(display, scratch, width.value,
                   (UL*width.value)(*original), 1)
            sync(display, 0)
        message = app.stdout.readline().rstrip()
        assert message == "CONTENT '|'", (message, app.stderr.read())
        after = get(display, lo.value, hi.value-lo.value+1, C.byref(width))
        try:
            assert [after[(scratch-lo.value)*width.value+j]
                    for j in range(width.value)] == original
            assert [after[(first_code-lo.value)*width.value+j]
                    for j in range(width.value)] == real_key_before
        finally:
            free(after)
        keys_after = C.create_string_buffer(32)
        assert xquery(display, keys_after)
        assert keys_after.raw == keys_before.raw, 'stuck key after injection'
        change(display, 51, alias_width.value,
               (UL*alias_width.value)(*alias_original), 1)
        sync(display, 0)
        print(f'PASS: pipe at XKB code={first_code}, level={first_level}; '
              f'typed through unused keycode={scratch}, original key restored')
    finally:
        if display:
            close(display)
        if app:
            try:
                app.wait(timeout=3)
            except subprocess.TimeoutExpired:
                app.terminate()
                app.wait(timeout=3)
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


if __name__ == '__main__':
    main()

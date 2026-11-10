#!/usr/bin/env python3
"""Read-only X11/XKB keyboard diagnosis for Windows -> Linux text problems.

Run inside the SAME X11 environment (DISPLAY / XAUTHORITY) as the LazDesk
server. Does not press keys, log user input, or change the layout.
"""
from __future__ import annotations

import ctypes as C
import os
import sys


class XkbState(C.Structure):
    _fields_ = [
        ('group', C.c_ubyte), ('locked_group', C.c_ubyte),
        ('base_group', C.c_ushort), ('latched_group', C.c_ushort),
        ('mods', C.c_ubyte), ('base_mods', C.c_ubyte),
        ('latched_mods', C.c_ubyte), ('locked_mods', C.c_ubyte),
        ('compat_state', C.c_ubyte), ('grab_mods', C.c_ubyte),
        ('compat_grab_mods', C.c_ubyte), ('lookup_mods', C.c_ubyte),
        ('compat_lookup_mods', C.c_ubyte), ('ptr_buttons', C.c_ushort),
    ]


def main() -> int:
    print('XDG_SESSION_TYPE:', os.environ.get('XDG_SESSION_TYPE', '(absent)'))
    print('DISPLAY:', os.environ.get('DISPLAY', '(absent)'))
    print('XAUTHORITY defined:', bool(os.environ.get('XAUTHORITY')))
    try:
        x = C.CDLL('libX11.so.6')
        xt = C.CDLL('libXtst.so.6')
    except OSError as exc:
        print('ERROR: X11/XTest library missing:', exc, file=sys.stderr)
        return 2

    def bind(lib, name, args, result):
        f = getattr(lib, name)
        f.argtypes, f.restype = args, result
        return f

    P, I, U, UL = C.c_void_p, C.c_int, C.c_uint, C.c_ulong
    op = bind(x, 'XOpenDisplay', [C.c_char_p], P)
    close = bind(x, 'XCloseDisplay', [P], I)
    state_fn = bind(x, 'XkbGetState', [P, U, C.POINTER(XkbState)], I)
    sym_fn = bind(x, 'XkbKeycodeToKeysym', [P, C.c_ubyte, I, I], UL)
    code_fn = bind(x, 'XKeysymToKeycode', [P, UL], C.c_ubyte)
    ranges_fn = bind(x, 'XDisplayKeycodes', [P, C.POINTER(I), C.POINTER(I)], I)
    xtest_fn = bind(xt, 'XTestQueryExtension', [P, C.POINTER(I), C.POINTER(I),
                                                 C.POINTER(I), C.POINTER(I)], I)
    d = op(None)
    if not d:
        print('ERROR: cannot open X11 display. Run as the same desktop '
              'user as LazDesk or set DISPLAY/XAUTHORITY for that session.', file=sys.stderr)
        return 2
    try:
        state = XkbState()
        if state_fn(d, 0x100, C.byref(state)) != 0:
            print('ERROR: XkbGetState failed', file=sys.stderr)
            return 2
        lo, hi = I(), I()
        ranges_fn(d, C.byref(lo), C.byref(hi))
        xeb, er, ma, mi = I(), I(), I(), I()
        xtest_ok = bool(xtest_fn(d, C.byref(xeb), C.byref(er),
                                 C.byref(ma), C.byref(mi)))
        print('XTest:', 'available' if xtest_ok else 'NOT AVAILABLE')
        print('XKB effective group:', state.group)
        print('XKB modifiers mask:', hex(state.mods),
              '(Ctrl active:' + ('yes' if state.mods & 4 else 'no') + ', '
              'Alt/Mod1 active:' + ('yes' if state.mods & 8 else 'no') + ', '
              'AltGr/Mod5 active:' + ('yes' if state.mods & 128 else 'no') + ')')
        print('ISO_Level3_Shift keycode:', code_fn(d, 0xfe03))
        missing = []
        for ch in ('@', '#', '|', '!'):
            sym = ord(ch)
            match = next(((code, level) for level in range(4)
                          for code in range(lo.value, hi.value + 1)
                          if sym_fn(d, code, state.group, level) == sym), None)
            if match is None:
                print(f'{ch}: NOT IN active XKB group')
                missing.append(ch)
            else:
                code, level = match
                mod = ['none', 'Shift', 'AltGr', 'Shift+AltGr'][level]
                print(f'{ch}: keycode={code}, XKB level={level}, modifier={mod}')
        if missing:
            print('Warning: symbols missing from the active XKB group:',
                  ''.join(missing))
            return 1
        if not xtest_ok:
            return 1
        print('OK: all four symbols can be resolved in the active XKB group.')
        return 0
    finally:
        close(d)


if __name__ == '__main__':
    sys.exit(main())

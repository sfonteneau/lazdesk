#!/usr/bin/env python3
"""X11-only regression for Unicode text while modifiers are held.

Exercises XKB/XTest requests matching kvm_inject_x11.pas in a private Xvfb
server. The test observes actual KeyPress events using XLookupString and checks
that pressed modifier keycodes are exactly restored. This is not a Pascal
compile nor a test in the user's real desktop session.
"""
from __future__ import annotations

import ctypes as C
import os
import sys
from pathlib import Path
import selectors
import shutil
import subprocess

SRC = (Path(__file__).resolve().parents[1] / 'server/kvm_inject_x11.pas').read_text()
assert 'TextModifierSyms:' in SRC
assert 'XQueryKeymap(D, @PressedMap[0])' in SRC
assert 'XTestFakeKeyEvent(D, ModCode, 0, 0)' in SRC
assert 'XTestFakeKeyEvent(D, ReleasedMods[I], 1, 0)' in SRC
assert 'if XTestFakeKeyEvent(D, FoundCode, 1, 0) = 0' in SRC
assert 'XkbLockModifiers(D, $100, 2, State.locked_mods and 2)' in SRC

if not all(shutil.which(tool) for tool in ('Xvfb', 'setxkbmap')):
    print('PASS: X11 isolation source guards, SKIP: no Xvfb / setxkbmap')
    raise SystemExit(0)

I, U, UL, P = C.c_int, C.c_uint, C.c_ulong, C.c_void_p
x = C.CDLL('libX11.so.6')
xt = C.CDLL('libXtst.so.6')


def bind(lib, symbol, args, result):
    f = getattr(lib, symbol)
    f.argtypes, f.restype = args, result
    return f


op = bind(x, 'XOpenDisplay', [C.c_char_p], P)
close = bind(x, 'XCloseDisplay', [P], I)
screen = bind(x, 'XDefaultScreen', [P], I)
root = bind(x, 'XRootWindow', [P, I], UL)
create = bind(x, 'XCreateSimpleWindow', [P, UL, I, I, U, U, U, UL, UL], UL)
destroy = bind(x, 'XDestroyWindow', [P, UL], I)
select = bind(x, 'XSelectInput', [P, UL, C.c_long], I)
map_win = bind(x, 'XMapWindow', [P, UL], I)
focus = bind(x, 'XSetInputFocus', [P, UL, I, UL], I)
sync = bind(x, 'XSync', [P, I], I)
flush = bind(x, 'XFlush', [P], I)
pending = bind(x, 'XPending', [P], I)
next_ev = bind(x, 'XNextEvent', [P, P], I)
keycode = bind(x, 'XKeysymToKeycode', [P, UL], C.c_ubyte)
xkb_sym = bind(x, 'XkbKeycodeToKeysym', [P, C.c_ubyte, I, I], UL)
xkb_lock = bind(x, 'XkbLockModifiers', [P, U, U, U], I)
xkb_state = bind(x, 'XkbGetState', [P, U, P], I)
keymap = bind(x, 'XQueryKeymap', [P, P], I)
fake = bind(xt, 'XTestFakeKeyEvent', [P, U, I, UL], I)
lookup = bind(x, 'XLookupString', [P, P, I, C.POINTER(UL), P], I)


class XkbState(C.Structure):
    _fields_ = [('group', C.c_ubyte), ('locked_group', C.c_ubyte),
                ('base_group', C.c_ushort), ('latched_group', C.c_ushort),
                ('mods', C.c_ubyte), ('base_mods', C.c_ubyte),
                ('latched_mods', C.c_ubyte), ('locked_mods', C.c_ubyte),
                ('compat_state', C.c_ubyte), ('grab_mods', C.c_ubyte),
                ('compat_grab_mods', C.c_ubyte), ('lookup_mods', C.c_ubyte),
                ('compat_lookup_mods', C.c_ubyte), ('ptr_buttons', C.c_ushort)]


class KeyEvent(C.Structure):
    _fields_ = [('type', I), ('serial', UL), ('send_event', I),
                ('display', P), ('window', UL), ('root', UL), ('subwindow', UL),
                ('time', UL), ('x', I), ('y', I), ('x_root', I), ('y_root', I),
                ('state', U), ('keycode', U), ('same_screen', I)]

MODSYMS = [0xffe1, 0xffe2, 0xffe3, 0xffe4, 0xffe7, 0xffe8,
           0xffe9, 0xffea, 0xffeb, 0xffec, 0xffed, 0xffee,
           0xfe03, 0xfe11, 0xff7e]


def read_chars(d):
    out = []
    while pending(d):
        event = C.create_string_buffer(24 * C.sizeof(C.c_long))
        next_ev(d, event)
        e = C.cast(event, C.POINTER(KeyEvent)).contents
        if e.type != 2:
            continue
        result = C.create_string_buffer(32)
        symbol = UL()
        length = lookup(event, result, len(result), C.byref(symbol), None)
        if length:
            out.append(result.raw[:length])
    return out


def pressed(d):
    buf = C.create_string_buffer(32)
    assert keymap(d, buf)
    return buf.raw


def tap(d, code, down):
    assert code and fake(d, code, int(down), 0)


def inject_isolated(d, ch):
    state = XkbState()
    assert xkb_state(d, 0x100, C.byref(state)) == 0
    sym = ord(ch)
    codes = [(c, level) for level in range(4) for c in range(8, 255)
             if xkb_sym(d, c, state.group, level) == sym]
    assert codes, ('not in layout', ch, state.group)
    code, level = codes[0]
    shift = keycode(d, 0xffe1)
    level3 = keycode(d, 0xfe03)
    snapshot = pressed(d)
    released = []
    shift_added = altgr_added = locked = False
    try:
        assert xkb_lock(d, 0x100, 2, 0)
        locked = True
        for keysym in MODSYMS:
            mod = keycode(d, keysym)
            if (mod and snapshot[mod // 8] & (1 << (mod % 8))
                    and mod not in released):
                tap(d, mod, False)
                released.append(mod)
        if level & 1:
            tap(d, shift, True)
            shift_added = True
        if level & 2:
            tap(d, level3, True)
            altgr_added = True
        tap(d, code, True)
        tap(d, code, False)
    finally:
        if altgr_added:
            tap(d, level3, False)
        if shift_added:
            tap(d, shift, False)
        for mod in reversed(released):
            tap(d, mod, True)
        if locked:
            assert xkb_lock(d, 0x100, 2, state.locked_mods & 2)
        flush(d)


proc = subprocess.Popen(['Xvfb', '-displayfd', '1', '-screen', '0', '480x320x24',
                         '-nolisten', 'tcp'], stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE)
d = window = None
try:
    sel = selectors.DefaultSelector()
    sel.register(proc.stdout, selectors.EVENT_READ)
    assert sel.select(10), 'Xvfb start timeout'
    number = proc.stdout.readline().strip()
    assert number.isdigit(), 'Xvfb did not provide a display number'
    display = ':' + number.decode('ascii')
    d = op(display.encode('ascii'))
    assert d, 'failed to connect to Xvfb'
    window = create(d, root(d, screen(d)), 0, 0, 240, 160, 0, 0, 0)
    select(d, window, 3)
    map_win(d, window)
    focus(d, window, 1, 0)
    sync(d, 0)
    total = 0
    for layout in ('fr', 'us'):
        p = subprocess.run(['setxkbmap', '-display', display, '-layout', layout],
                           capture_output=True, text=True)
        assert p.returncode == 0, p.stderr
        sync(d, 0)
        env = os.environ.copy()
        env['DISPLAY'] = display
        env.pop('XAUTHORITY', None)
        diag = subprocess.run(
            [sys.executable, str(Path(__file__).resolve().parents[1] /
                                'tools/diagnose_keyboard_x11.py')],
            env=env, capture_output=True, text=True)
        assert diag.returncode == 0, (layout, diag.stdout, diag.stderr)
        assert 'all four symbols' in diag.stdout
        code_ctrl = keycode(d, 0xffe3)
        code_alt = keycode(d, 0xffe9)
        code_shift = keycode(d, 0xffe1)
        code_altgr = keycode(d, 0xfe03)
        code_super = keycode(d, 0xffeb)
        modifiers = [('none', []), ('ctrl', [code_ctrl]),
                     ('ctrl-alt', [code_ctrl, code_alt]),
                     ('shift-ctrl', [code_shift, code_ctrl]),
                     ('altgr', [code_altgr]),
                     ('ctrl-altgr', [code_ctrl, code_altgr]),
                     ('super', [code_super])]
        for combo, keys in modifiers:
            if any(not key for key in keys):
                continue
            for key in keys:
                tap(d, key, True)
            sync(d, 0)
            before = pressed(d)
            read_chars(d)
            for char in '@#|!':
                inject_isolated(d, char)
                sync(d, 0)
                got = read_chars(d)
                assert char.encode() in got, (layout, combo, char, got)
                assert pressed(d) == before, (layout, combo, char, 'modifier stuck')
                total += 1
            for key in reversed(keys):
                tap(d, key, False)
            sync(d, 0)
            read_chars(d)
            assert pressed(d) == b'\0' * 32, (layout, combo, 'not released')
    print(f'PASS: {total} X11 Unicode injections (@ # | !), layouts fr/us,')
    print('      with Ctrl, Alt, AltGr, Shift and Super held; exact key state restored')
finally:
    if d:
        if window:
            destroy(d, window)
        close(d)
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()

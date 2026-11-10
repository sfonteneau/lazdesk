#!/usr/bin/env python3
"""X11 character-injection regression (isolated Xvfb, US + French layouts).

Exercises the native XKB/XTest calls used by kvm_inject_x11.pas and verifies
*delivered* symbols via XLookupString, not just keysym lookup. It does not
compile Pascal or test the Windows LCL client. No live desktop is touched.
"""
import ctypes as C
from pathlib import Path
import selectors
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
INJECT = (ROOT / 'server/kvm_inject_x11.pas').read_text()
CLIENT = (ROOT / 'client/kvm_view_form.pas').read_text()
KEYS = (ROOT / 'shared/kvm_keysym.pas').read_text()

# Guard that the production source retains the native algorithm under test.
assert 'FindXkbSymbol(D, State.group, Sym, FoundCode, FoundLevel)' in INJECT
assert 'XkbKeycodeToKeysym(D, Byte(Code), Group, Level) = Symbol' in INJECT
assert 'FoundLevel and 1' in INJECT and 'FoundLevel and 2' in INJECT
assert 'XTestFakeKeyEvent(D,Level3Key,1,0)' in INJECT
assert 'CodePoint <> $20ac' in INJECT and 'FindXkbSymbol(D, State.group, $20ac' in INJECT
assert 'InjectExtraOemKey(D, Pressed, VKey)' in INJECT
assert 'HeldOemShift[VKey] := AddedShift' in INJECT
assert 'HeldOemLevel3[VKey] := AddedLevel3' in INJECT
assert 'XQueryKeymap(D, @PressedMap[0])' in INJECT
assert 'KvmWinGetKeyState($a5) < 0' in CLIENT
assert 'KvmIsTextShortcut(FLastShift)' in CLIENT
assert 'Shortcut := KvmIsTextShortcut(Shift)' in CLIENT
for vk in ('$df', '$e2'):
    assert vk in CLIENT[CLIENT.index('function IsPrintableVirtualKey'):]
    assert vk+':' in KEYS

I, U, UL, P = C.c_int, C.c_uint, C.c_ulong, C.c_void_p

class XkbState(C.Structure):
    _fields_ = [('group', C.c_ubyte), ('locked_group', C.c_ubyte),
                ('base_group', C.c_ushort), ('latched_group', C.c_ushort)] + [
                    (name, C.c_ubyte) for name in (
                        'mods', 'base_mods', 'latched_mods', 'locked_mods',
                        'compat_state', 'grab_mods', 'compat_grab_mods',
                        'lookup_mods', 'compat_lookup_mods')
                ] + [('ptr_buttons', C.c_ushort)]

class XKeyEvent(C.Structure):
    _fields_ = [('type', I), ('serial', UL), ('send_event', I),
                ('display', P), ('window', UL), ('root', UL), ('subwindow', UL),
                ('time', UL), ('x', I), ('y', I), ('x_root', I), ('y_root', I),
                ('state', U), ('keycode', U), ('same_screen', I)]


def bind(lib, name, args, result):
    fn = getattr(lib, name)
    fn.argtypes, fn.restype = args, result
    return fn


def run():
    for tool in ('Xvfb', 'setxkbmap'):
        if shutil.which(tool) is None:
            print('SKIP: {} unavailable'.format(tool))
            return
    x = C.CDLL('libX11.so.6')
    xt = C.CDLL('libXtst.so.6')
    op = bind(x, 'XOpenDisplay', [C.c_char_p], P)
    close = bind(x, 'XCloseDisplay', [P], I)
    codes = bind(x, 'XDisplayKeycodes', [P, C.POINTER(I), C.POINTER(I)], I)
    key_sym = bind(x, 'XkbKeycodeToKeysym', [P, C.c_ubyte, I, I], UL)
    to_code = bind(x, 'XKeysymToKeycode', [P, UL], C.c_ubyte)
    state = bind(x, 'XkbGetState', [P, U, C.POINTER(XkbState)], I)
    lock = bind(x, 'XkbLockModifiers', [P, U, U, U], I)
    query_keymap = bind(x, 'XQueryKeymap', [P, P], I)
    fake = bind(xt, 'XTestFakeKeyEvent', [P, U, I, UL], I)
    flush = bind(x, 'XFlush', [P], I)
    sync = bind(x, 'XSync', [P, I], I)
    screen = bind(x, 'XDefaultScreen', [P], I)
    root = bind(x, 'XRootWindow', [P, I], UL)
    create = bind(x, 'XCreateSimpleWindow', [P, UL, I, I, U, U, U, UL, UL], UL)
    select = bind(x, 'XSelectInput', [P, UL, C.c_long], I)
    map_ = bind(x, 'XMapWindow', [P, UL], I)
    focus = bind(x, 'XSetInputFocus', [P, UL, I, UL], I)
    pending = bind(x, 'XPending', [P], I)
    next_event = bind(x, 'XNextEvent', [P, P], I)
    lookup = bind(x, 'XLookupString', [C.POINTER(XKeyEvent), C.c_void_p, I,
                                      C.POINTER(UL), P], I)
    destroy = bind(x, 'XDestroyWindow', [P, UL], I)
    proc = subprocess.Popen(['Xvfb', '-displayfd', '1', '-screen', '0', '640x360x24',
                             '-nolisten', 'tcp'], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)
    d = None
    win = None
    try:
        poll = selectors.DefaultSelector()
        poll.register(proc.stdout, selectors.EVENT_READ)
        assert poll.select(10), 'Xvfb did not start'
        number = proc.stdout.readline().strip()
        assert number.isdigit(), 'Xvfb display number unavailable'
        display = ':' + number.decode('ascii')
        d = op(display.encode('ascii'))
        assert d, 'failed to connect to the isolated Xvfb display'
        win = create(d, root(d, screen(d)), 0, 0, 300, 200, 0, 0, 0)
        select(d, win, 1 << 0 | 1 << 1)  # KeyPress, KeyRelease
        map_(d, win)
        focus(d, win, 1, 0)  # RevertToPointerRoot, CurrentTime
        sync(d, 0)
        tested = 0
        for layout in ('us', 'fr'):
            result = subprocess.run(['setxkbmap', '-display', display, '-layout', layout],
                                    capture_output=True, text=True)
            assert result.returncode == 0, 'setxkbmap {}: {}'.format(layout, result.stderr)
            sync(d, 0)
            for ch in ('!@|#[]{}\\<>€' if layout == 'fr' else '!@|#[]{}\\<>'):
                before = XkbState()
                assert state(d, 0x100, C.byref(before)) == 0
                lo, hi = I(), I()
                codes(d, C.byref(lo), C.byref(hi))
                expected = ord(ch)
                candidates = [expected] if expected <= 255 else [0x1000000 | expected, expected]
                found = None
                # Match the server's group-first, level 0..3 search order.
                for sym in candidates:
                    for level in range(4):
                        for code in range(lo.value, hi.value+1):
                            if key_sym(d, code, before.group, level) == sym:
                                found = (code, level)
                                break
                        if found is not None:
                            break
                    if found is not None:
                        break
                assert found is not None, (layout, ch, 'missing keysym')
                code, level = found
                sh = to_code(d, 0xffe1)
                altgr = to_code(d, 0xfe03)
                assert not(level & 1) or sh, (layout, ch, 'missing Shift')
                assert not(level & 2) or altgr, (layout, ch, 'missing AltGr')
                keys_before = C.create_string_buffer(32)
                assert query_keymap(d, keys_before)
                assert lock(d, 0x100, 2, 0)
                try:
                    if level & 1:
                        assert fake(d, sh, 1, 0)
                    if level & 2:
                        assert fake(d, altgr, 1, 0)
                    assert fake(d, code, 1, 0)
                    assert fake(d, code, 0, 0)
                finally:
                    if level & 2:
                        assert fake(d, altgr, 0, 0)
                    if level & 1:
                        assert fake(d, sh, 0, 0)
                    assert lock(d, 0x100, 2, before.locked_mods & 2)
                    flush(d)
                sync(d, 0)
                keys_after = C.create_string_buffer(32)
                assert query_keymap(d, keys_after)
                assert keys_after.raw == keys_before.raw, (layout, ch, 'stuck key/modifier')
                symbols = []
                while pending(d):
                    event = C.create_string_buffer(24 * C.sizeof(C.c_long))
                    next_event(d, event)
                    event_key = C.cast(event, C.POINTER(XKeyEvent))
                    if event_key.contents.type != 2:
                        continue
                    sym = UL()
                    chars = C.create_string_buffer(64)
                    lookup(event_key, chars, len(chars), C.byref(sym), None)
                    symbols.append(sym.value)
                assert expected in symbols, (layout, ch, 'got', symbols, 'level', level)
                tested += 1
            print('PASS: Xvfb XKB/XTest typed ! @ | # and punctuation on {} layout'.format(layout))
        # A French layout has the legacy EuroSign keysym ($20ac), not U20AC.
        euro = XkbState()
        assert state(d, 0x100, C.byref(euro)) == 0
        assert euro.group == 0
        lo, hi = I(), I(); codes(d, C.byref(lo), C.byref(hi))
        assert any(key_sym(d, code, euro.group, level) == 0x20ac
                   for level in range(4) for code in range(lo.value, hi.value+1))
        assert not any(key_sym(d, code, euro.group, level) == 0x10020ac
                       for level in range(4) for code in range(lo.value, hi.value+1))
        print('PASS: French XKB legacy EuroSign fallback required and available')
        print('PASS: {} native symbol injections tested'.format(tested))
    finally:
        if d:
            if win: destroy(d, win)
            close(d)
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()

if __name__ == '__main__':
    run()

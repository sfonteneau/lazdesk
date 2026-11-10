#!/usr/bin/env python3
"""X11 regression: missing characters must reach an X11 client without layout changes.

Uses ctypes to exercise X11's mapping/XTest operations in a private Xvfb;
the test watches KeyPress events while the temporary mapping is still active,
and verifies the exact original key map and pressed keys are restored.
The code is an independent native integration test, not compiled Pascal.
"""
from __future__ import annotations
import ctypes as C
import os
import sys
import selectors
import shutil
import subprocess
import threading
import time
from pathlib import Path

SRC = (Path(__file__).resolve().parents[1] / 'server/kvm_inject_x11.pas').read_text()
for required in (
    'FindUnusedXkbKey(D, PressedMap, Scratch, Width, SavedSyms)',
    'XChangeKeyboardMapping(D, Scratch, Width, @TemporarySyms[0], 1)',
    'XChangeKeyboardMapping(D, Scratch, Width, @SavedSyms[0], 1)',
    'if MappedScratch then',
    'Sleep(25);',
    'XSync(D, 0);',
    'if Scratch <> 0 then ScratchSubmitted := True;',
):
    assert required in SRC, f'production Pascal path missing: {required}'

I, UL, U, P, B = C.c_int, C.c_ulong, C.c_uint, C.c_void_p, C.c_ubyte


def bind(lib, name, args, result):
    f = getattr(lib, name)
    f.argtypes, f.restype = args, result
    return f


class KeyEvent(C.Structure):
    _fields_ = [
        ('type', I), ('serial', UL), ('send_event', I), ('display', P),
        ('window', UL), ('root', UL), ('subwindow', UL), ('time', UL),
        ('x', I), ('y', I), ('x_root', I), ('y_root', I), ('state', U),
        ('keycode', U), ('same_screen', I),
    ]


def main():
    for binary in ('Xvfb', 'setxkbmap'):
        if not shutil.which(binary):
            print('SKIP:', binary, 'not available')
            return
    x, xt = C.CDLL('libX11.so.6'), C.CDLL('libXtst.so.6')
    assert bind(x, 'XInitThreads', [], I)(), 'Xlib thread support unavailable'
    op = bind(x, 'XOpenDisplay', [C.c_char_p], P)
    close = bind(x, 'XCloseDisplay', [P], I)
    codes = bind(x, 'XDisplayKeycodes', [P, C.POINTER(I), C.POINTER(I)], I)
    get = bind(x, 'XGetKeyboardMapping', [P, B, I, C.POINTER(I)], C.POINTER(UL))
    change = bind(x, 'XChangeKeyboardMapping', [P, I, I, C.POINTER(UL), I], I)
    free = bind(x, 'XFree', [P], I)
    key = bind(x, 'XkbKeycodeToKeysym', [P, B, I, I], UL)
    tocode = bind(x, 'XKeysymToKeycode', [P, UL], B)
    xquery = bind(x, 'XQueryKeymap', [P, P], I)
    fake = bind(xt, 'XTestFakeKeyEvent', [P, U, I, UL], I)
    sync = bind(x, 'XSync', [P, I], I)
    screen = bind(x, 'XDefaultScreen', [P], I)
    root = bind(x, 'XRootWindow', [P, I], UL)
    create = bind(x, 'XCreateSimpleWindow', [P, UL, I, I, U, U, U, UL, UL], UL)
    select = bind(x, 'XSelectInput', [P, UL, C.c_long], I)
    mapwin = bind(x, 'XMapWindow', [P, UL], I)
    focus = bind(x, 'XSetInputFocus', [P, UL, I, UL], I)
    pending = bind(x, 'XPending', [P], I)
    nextev = bind(x, 'XNextEvent', [P, P], I)
    lookup = bind(x, 'XLookupString', [P, P, I, C.POINTER(UL), P], I)
    lockgroup = bind(x, 'XkbLockGroup', [P, U, U], I)
    destroy = bind(x, 'XDestroyWindow', [P, UL], I)
    proc = subprocess.Popen(['Xvfb', '-displayfd', '1', '-screen', '0',
                             '640x360x24', '-nolisten', 'tcp'],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    sel = selectors.DefaultSelector()
    sel.register(proc.stdout, selectors.EVENT_READ)
    d1 = d2 = None
    window = None
    stop = threading.Event()
    seen = []
    seen_guard = threading.Lock()
    reader = None
    try:
        assert sel.select(10), 'Xvfb failed to start'
        name = ':' + proc.stdout.readline().decode().strip()
        d1, d2 = op(name.encode()), op(name.encode())
        assert d1 and d2
        window = create(d2, root(d2, screen(d2)), 0, 0, 400, 250, 0, 0, 0)
        select(d2, window, 3)  # KeyPress + KeyRelease
        mapwin(d2, window)
        focus(d2, window, 1, 0)
        sync(d2, 0)

        def receive():
            while not stop.is_set():
                if not pending(d2):
                    time.sleep(.001)
                    continue
                ev = C.create_string_buffer(24 * C.sizeof(C.c_long))
                nextev(d2, ev)
                item = C.cast(ev, C.POINTER(KeyEvent)).contents
                if item.type == 2:
                    sym = UL()
                    chars = C.create_string_buffer(64)
                    lookup(ev, chars, len(chars), C.byref(sym), None)
                    with seen_guard:
                        seen.append(sym.value)

        reader = threading.Thread(target=receive, daemon=True)
        reader.start()
        total = 0
        # The Russian group intentionally lacks most of these punctuation
        # symbols; one run uses group 1 to exercise a multi-group desktop.
        for layout, active_group in [('ru', 0), ('us,ru', 1)]:
            assert subprocess.run(['setxkbmap', '-display', name, '-layout', layout],
                                  capture_output=True).returncode == 0
            assert lockgroup(d1, 0x100, active_group)
            sync(d1, 0)
            environment = dict(os.environ, DISPLAY=name)
            environment.pop('XAUTHORITY', None)
            diagnosis = subprocess.run(
                [sys.executable, str(Path(__file__).resolve().parents[1] /
                                       'tools/diagnose_keyboard_x11.py')],
                env=environment, capture_output=True, text=True)
            assert diagnosis.returncode == 0, (diagnosis.stdout, diagnosis.stderr)
            assert 'Unicode fallback: available' in diagnosis.stdout, diagnosis.stdout
            lo, hi, width = I(), I(), I()
            assert codes(d1, C.byref(lo), C.byref(hi))
            pmap = get(d1, lo.value, hi.value - lo.value + 1, C.byref(width))
            assert pmap and 0 < width.value <= 64
            try:
                scratch = next(c for c in range(hi.value, lo.value - 1, -1)
                               if all(pmap[(c-lo.value) * width.value+j] == 0
                                      for j in range(width.value))
                               and all(key(d1, c, group, level) == 0
                                       for group in range(4) for level in range(8)))
                saved = [pmap[(scratch-lo.value)*width.value+j]
                         for j in range(width.value)]
            finally:
                free(pmap)
            assert saved == [0] * width.value
            assert sum(key(d1, c, active_group, l) == ord('@')
                       for c in range(lo.value, hi.value+1) for l in range(4)) == 0
            keymap_before = C.create_string_buffer(32)
            assert xquery(d1, keymap_before)
            for char in '#{[|`\\^@]}€中':
                unicode_keysym = ord(char) if ord(char) <= 255 else (0x1000000 | ord(char))
                syms = (UL*width.value)(*([unicode_keysym]*width.value))
                with seen_guard:
                    last_index = len(seen)
                try:
                    change(d1, scratch, width.value, syms, 1)
                    sync(d1, 0)
                    check_width = I()
                    mapped = get(d1, scratch, 1, C.byref(check_width))
                    assert mapped and mapped[0] == unicode_keysym
                    free(mapped)
                    assert fake(d1, scratch, 1, 0)
                    assert fake(d1, scratch, 0, 0)
                    sync(d1, 0)
                    # The real X11 application consumes the symbol while the
                    # temporary binding exists, not after restoring NoSymbol.
                    time.sleep(.025)
                finally:
                    change(d1, scratch, width.value, (UL*width.value)(*saved), 1)
                    sync(d1, 0)
                observed = []
                with seen_guard:
                    observed = seen[last_index:]
                assert unicode_keysym in observed, (layout, char, observed)
                after_width = I()
                after = get(d1, scratch, 1, C.byref(after_width))
                try:
                    assert after_width.value == width.value
                    assert list(after[:width.value]) == saved, 'keyboard mapping not restored'
                finally:
                    free(after)
                after_keymap = C.create_string_buffer(32)
                assert xquery(d1, after_keymap)
                assert after_keymap.raw == keymap_before.raw, 'stuck or missing key release'
                total += 1

            # Repeat with a Windows-style synthetic Ctrl+AltGr held remotely.
            # The Pascal path releases these modifiers for the Unicode commit
            # and restores exactly the starting state after inserting text.
            mod_codes = [tocode(d1, 0xffe3), tocode(d1, 0xfe03)]
            if all(mod_codes):
                for mod in mod_codes:
                    assert fake(d1, mod, 1, 0)
                sync(d1, 0)
                held = C.create_string_buffer(32)
                assert xquery(d1, held)
                for char in ('@', '#', '|'):
                    for mod in mod_codes:
                        assert fake(d1, mod, 0, 0)
                    with seen_guard:
                        last_index = len(seen)
                    try:
                        symbol = ord(char)
                        temporary = (UL*width.value)(*([symbol]*width.value))
                        change(d1, scratch, width.value, temporary, 1)
                        sync(d1, 0)
                        assert fake(d1, scratch, 1, 0)
                        assert fake(d1, scratch, 0, 0)
                        sync(d1, 0)
                        time.sleep(.025)
                    finally:
                        change(d1, scratch, width.value,
                               (UL*width.value)(*saved), 1)
                        sync(d1, 0)
                        for mod in reversed(mod_codes):
                            assert fake(d1, mod, 1, 0)
                        sync(d1, 0)
                    after_mods = C.create_string_buffer(32)
                    assert xquery(d1, after_mods)
                    assert after_mods.raw == held.raw, 'Ctrl/AltGr state changed'
                    with seen_guard:
                        assert ord(char) in seen[last_index:], (layout, 'Ctrl+AltGr', char)
                    total += 1
                for mod in reversed(mod_codes):
                    assert fake(d1, mod, 0, 0)
                sync(d1, 0)
                finally_free = C.create_string_buffer(32)
                assert xquery(d1, finally_free)
                assert finally_free.raw == keymap_before.raw
            print('PASS:', layout, 'group', active_group,
                  '12 Unicode characters and Ctrl+AltGr, exact map restored')
        print('PASS:', total, 'native X11 missing-symbol injections observed')
    finally:
        stop.set()
        if reader:
            reader.join(timeout=2)
        if d2:
            if window:
                destroy(d2, window)
            close(d2)
        if d1:
            close(d1)
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == '__main__':
    main()

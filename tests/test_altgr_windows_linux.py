#!/usr/bin/env python3
"""Regression for Windows AltGr -> Linux (X11 and portal source guards).

The native test runs in a private Xvfb display with a French XKB layout.
It validates the X11 input event sequence; it is not a Windows/LCL runtime test.
"""
import ctypes as c
from pathlib import Path
import selectors
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
client = (ROOT / 'client/kvm_view_form.pas').read_text(encoding='utf-8')
desktop = (ROOT / 'server/kvm_desktop.pas').read_text(encoding='utf-8')
xinject = (ROOT / 'server/kvm_inject_x11.pas').read_text(encoding='utf-8')
wayland = (ROOT / 'server/kvm_wayland.pas').read_text(encoding='utf-8')

# Assert the change exists on the full client -> Linux backend path, and is
# restricted to the Linux implementation (Win32 SendInput is unmodified).
assert 'FForwardedVirtualKeys[Key] := Byte(ForwardKey)' in client
assert 'SendPacket(MakeKey(False, FForwardedVirtualKeys[Key]))' in client
assert '(Key in [$12,$a5]) and (KvmWinGetKeyState($a5) < 0)' in client
assert 'LinuxCtrlHeld: array[0..2] of Boolean;' in desktop
assert 'if VKey = $a5 then' in desktop
assert 'LinuxRawKey(False,CtrlVK[I]);' in desktop
assert 'LinuxRawKey(True,$a5);' in desktop
assert 'if not LinuxAltGrHeld then LinuxRawKey(Pressed,VKey);' in desktop
assert 'if VKey=$a5 then KeyCode:=XKeysymToKeycode(D,$fe03)' in xinject
assert 'if VKey = $a5 then Sym := $fe03' in wayland

if shutil.which('Xvfb') is None or shutil.which('setxkbmap') is None:
    print('PASS: AltGr code guards; SKIP: native test (Xvfb/setxkbmap missing)')
    raise SystemExit(0)

I = c.c_int
U = c.c_uint
UL = c.c_ulong
P = c.c_void_p
x = c.CDLL('libX11.so.6')
xtst = c.CDLL('libXtst.so.6')


def bind(lib, name, argtypes, restype):
    fn = getattr(lib, name)
    fn.argtypes = argtypes
    fn.restype = restype
    return fn


open_display = bind(x, 'XOpenDisplay', [c.c_char_p], P)
close_display = bind(x, 'XCloseDisplay', [P], I)
screen = bind(x, 'XDefaultScreen', [P], I)
root = bind(x, 'XRootWindow', [P, I], UL)
create = bind(x, 'XCreateSimpleWindow', [P, UL, I, I, U, U, U, UL, UL], UL)
destroy = bind(x, 'XDestroyWindow', [P, UL], I)
select = bind(x, 'XSelectInput', [P, UL, c.c_long], I)
map_window = bind(x, 'XMapWindow', [P, UL], I)
focus = bind(x, 'XSetInputFocus', [P, UL, I, UL], I)
sync = bind(x, 'XSync', [P, I], I)
pending = bind(x, 'XPending', [P], I)
next_event = bind(x, 'XNextEvent', [P, P], I)
keycode = bind(x, 'XKeysymToKeycode', [P, UL], c.c_ubyte)
key_to_symbol = bind(x, 'XkbKeycodeToKeysym', [P, c.c_ubyte, I, I], UL)
lookup = bind(x, 'XLookupString', [P, P, I, c.POINTER(UL), P], I)
fake = bind(xtst, 'XTestFakeKeyEvent', [P, U, I, UL], I)
keymap = bind(x, 'XQueryKeymap', [P, P], I)


class KeyEvent(c.Structure):
    _fields_ = [('type', I), ('serial', UL), ('send_event', I),
                ('display', P), ('window', UL), ('root', UL), ('subwindow', UL),
                ('time', UL), ('x', I), ('y', I), ('x_root', I), ('y_root', I),
                ('state', U), ('keycode', U), ('same_screen', I)]


def key_state(d):
    result = c.create_string_buffer(32)
    assert keymap(d, result)
    return result.raw


def press(d, code, down):
    assert fake(d, code, int(down), 0)


def read_keypresses(d):
    result = []
    while pending(d):
        event = c.create_string_buffer(24 * c.sizeof(c.c_long))
        next_event(d, event)
        parsed = c.cast(event, c.POINTER(KeyEvent)).contents
        if parsed.type != 2:
            continue
        keysym = UL()
        chars = c.create_string_buffer(32)
        length = lookup(event, chars, len(chars), c.byref(keysym), None)
        result.append((parsed.keycode, chars.raw[:length], parsed.state))
    return result


proc = subprocess.Popen(['Xvfb', '-displayfd', '1', '-screen', '0', '640x360x24',
                         '-nolisten', 'tcp'], stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE)
d = None
window = None
try:
    poll = selectors.DefaultSelector()
    poll.register(proc.stdout, selectors.EVENT_READ)
    assert poll.select(10), 'Xvfb startup timed out'
    display_number = proc.stdout.readline().strip()
    assert display_number.isdigit(), 'Xvfb did not report an isolated display'
    display = ':' + display_number.decode('ascii')
    d = open_display(display.encode('ascii'))
    assert d, 'could not connect to private display'
    window = create(d, root(d, screen(d)), 0, 0, 300, 180, 0, 0, 0)
    select(d, window, 3)  # KeyPress | KeyRelease
    map_window(d, window)
    focus(d, window, 1, 0)
    sync(d, 0)
    set_layout = subprocess.run(['setxkbmap', '-display', display,
                                 '-layout', 'fr'], capture_output=True, text=True)
    assert set_layout.returncode == 0, set_layout.stderr
    sync(d, 0)

    ctrl = keycode(d, 0xffe3)
    level3 = keycode(d, 0xfe03)
    assert ctrl != 0 and level3 != 0
    assert keycode(d, 0xffea) == 0, 'FR XKB unexpectedly has an Alt_R keysym'

    count = 0
    for ch in '@#|':
        target = ord(ch)
        # All three symbols live at XKB level 2 on the isolated French layout.
        codes = [code for code in range(8, 255)
                 if key_to_symbol(d, code, 0, 2) == target]
        assert codes, 'AltGr symbol absent from FR layout: ' + ch
        char_code = codes[0]
        prior = key_state(d)
        # The original raw Windows event sequence leaves Control held while
        # AltGr and the printable key are being injected.
        for code, down in ((ctrl, 1), (level3, 1), (char_code, 1),
                           (char_code, 0), (level3, 0), (ctrl, 0)):
            press(d, code, down)
        sync(d, 0)
        broken = [(chars, state) for code, chars, state in read_keypresses(d)
                  if code == char_code]
        # Some XLookupString implementations still emit '#' under Control,
        # but the ControlMask makes it a Ctrl+AltGr shortcut to applications.
        assert broken and all(state & 4 for _, state in broken), ('baseline missing Ctrl', ch, broken)
        if ch == '@':
            assert ch.encode('utf-8') not in [chars for chars, _ in broken], ('baseline did not reproduce @', broken)
        assert key_state(d) == prior, ('baseline stuck keys', ch)

        # Fixed Linux sequence: suspend the synthetic Ctrl before AltGr,
        # restore Ctrl after releasing AltGr, and release it on Windows Ctrl-up.
        for code, down in ((ctrl, 1), (ctrl, 0), (level3, 1),
                           (char_code, 1), (char_code, 0), (level3, 0),
                           (ctrl, 1), (ctrl, 0)):
            press(d, code, down)
        sync(d, 0)
        typed = [(chars, state) for code, chars, state in read_keypresses(d)
                 if code == char_code]
        assert (ch.encode('utf-8'), 128) in typed, ('corrected injection failed', ch, typed)
        assert key_state(d) == prior, ('patched path left a stuck key', ch)
        count += 1
    print(f'PASS: {count}/3 AltGr symbols (@ # |), broken Ctrl+AltGr reproduced,')
    print('      Linux Ctrl suspension fixed in native XKB/XTest test, no stuck keys')
    print('PASS: Windows virtual-key mapping and both Linux backends source guards')
finally:
    if d:
        if window:
            destroy(d, window)
        close_display(d)
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()

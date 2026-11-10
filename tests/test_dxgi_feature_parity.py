#!/usr/bin/env python3
"""Windows DXGI/GDI integration and native scaling regression guards.

No Windows GPU runtime is available here. These tests compile the actual
portable pixel routines, not a reimplementation of the interpolator.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load(path):
    return (ROOT / path).read_text(encoding='utf-8')


class DxgiFeatureParity(unittest.TestCase):
    def test_native_scaler(self):
        cc = shutil.which('cc') or shutil.which('gcc')
        if not cc:
            self.skipTest('C compiler not found')
        with tempfile.TemporaryDirectory(prefix='dxgi_filter_') as tmp:
            result = Path(tmp) / 'test_filter'
            compile_result = subprocess.run([
                cc, '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                str(ROOT / 'tests/test_dxgi_filter.c'), '-o', str(result)
            ], text=True, capture_output=True)
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            execution = subprocess.run([str(result)], text=True, capture_output=True)
            self.assertEqual(execution.returncode, 0, execution.stderr)
            self.assertIn('PASS:', execution.stdout)

    def test_dxgi_reuses_gdi_cursor_injection_and_layout(self):
        desktop = load('server/kvm_desktop.pas')
        win = load('server/kvm_inject_win.pas')
        dxgi = load('server/kvm_capture_dxgi.pas')
        cpp = load('native/windows/kvm_dxgi.cpp')
        self.assertIn('Result:=kvm_inject_win.GetCursorState(NX,NY,Shape)', desktop)
        self.assertIn('kvm_inject_win.InjectMouse(Action,Button,NX,NY)', desktop)
        self.assertIn('kvm_inject_win.InjectKey(Pressed,VKey)', desktop)
        self.assertIn('kvm_inject_win.InjectText(CodePoint)', desktop)
        self.assertIn('kvm_inject_win.InjectWheel(Notches)', desktop)
        self.assertIn('CaptureMonitorLayoutText', load('server/kvm_server.pas'))
        self.assertIn('LastCaptureCursorEmbedded := Result and DxgiCursorEmbedded', desktop)
        self.assertIn('info.PointerPosition.Visible!=FALSE', cpp)
        self.assertIn('LAZDESK_DXGI_FORCE_SEPARATE_CURSOR', cpp)
        self.assertIn('if (!c || c->force_separate_cursor) return 0;', cpp)
        self.assertIn('GetCursorInfo(&ci)', cpp)
        self.assertIn('KVM_CURSOR_HIDE_DEBOUNCE_MS', win)
        self.assertIn('M := CaptureMonitor;', dxgi)

    def test_incremental_virtual_composition_and_filtered_downscale(self):
        native = load('native/windows/kvm_dxgi.cpp')
        gdi = load('server/kvm_capture_win.pas')
        self.assertIn('SetStretchBltMode(MemDC, HALFTONE)', gdi)
        self.assertIn('LAZDESK_DXGI_FAST_SCALE', native)
        self.assertIn('kvm_rgb_bilinear_bgra(', native)
        self.assertIn('if (resized || out->rgb_changed)', native)
        self.assertIn('kvm_merge_rgb24_damage(', native)
        self.assertIn('c->rgb_changed=desktop_changed || full_conversion', native)
        self.assertNotIn('std::fill(c->assembled.begin()', native)
        self.assertIn('if (!virtual_layout_valid(c))', native)
        self.assertIn('API int kvm_dxgi_abi() { return 3; }', native)
        self.assertIn('if Abi() <> 3 then', load('server/kvm_capture_dxgi.pas'))
        self.assertIn('if (monitor!=0) return open_output', native)
        self.assertIn('if not Result and not RequireDxgi', load('server/kvm_desktop.pas'))


if __name__ == '__main__':
    unittest.main()

#!/usr/bin/env python3
"""Regression guard: GDI host cursor must not flicker from CAPTUREBLT by default.

Source-level tests only: a real Windows GDI/desktop test is still required.
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GDI = (ROOT / 'server/kvm_capture_win.pas').read_text(encoding='utf-8')


class GdiCaptureBltDefaultTests(unittest.TestCase):
    def test_captureblt_is_opt_in_only(self):
        config = GDI.split('procedure ReadCaptureSettings;', 1)[1].split('procedure CloseCapture;', 1)[0]
        self.assertIn("UseCaptureBlt := GetEnvironmentVariable('LAZDESK_GDI_CAPTUREBLT') = '1';", config)
        self.assertNotIn("GetEnvironmentVariable('LAZDESK_GDI_CAPTUREBLT') <> '0'", config)

    def test_default_rop_starts_from_srccopy_for_both_capture_paths(self):
        capture = GDI.split('function CaptureDesktopRgb(MaxW, MaxH: Integer; var Frame: TRgbFrame): Boolean;', 2)[2]
        self.assertIn('Rop := SRCCOPY;', capture)
        self.assertIn('if UseCaptureBlt then Rop := Rop or CAPTUREBLT_FLAG;', capture)
        self.assertLess(capture.index('Rop := SRCCOPY;'), capture.index('if UseCaptureBlt then'))
        self.assertIn('BitBlt(', capture)
        self.assertIn('StretchBlt(', capture)
        self.assertIn('Rop)', capture)

    def test_cursor_capture_remains_separate(self):
        self.assertNotIn('DrawIconEx', GDI)
        desktop=(ROOT / 'server/kvm_desktop.pas').read_text(encoding='utf-8')
        self.assertIn('kvm_inject_win.GetCursorState(NX,NY,Shape)', desktop)


if __name__ == '__main__':
    unittest.main()

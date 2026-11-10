#!/usr/bin/env python3
"""Regression for the Windows GDI cursor fix (source guards + coordinate model).

These tests run on non-Windows hosts. They do not exercise SendInput or the GDI
API, so a live Windows/Lazarus smoke test is still required.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
INJECTION = (ROOT / 'server/kvm_inject_win.pas').read_text(encoding='utf-8')
GDI = (ROOT / 'server/kvm_capture_win.pas').read_text(encoding='utf-8')
DESKTOP = (ROOT / 'server/kvm_desktop.pas').read_text(encoding='utf-8')


def pixel_center_absolute(pixel, origin, width):
    """Mirror the Int64 expression used by SendAbsoluteMouseMove."""
    return min(65535, max(0, ((2 * (pixel - origin) + 1) * 65536) // (2 * width)))


def windows_pixel_from_absolute(absol, origin, width):
    # Windows mouse input distributes the normalized span over screen pixels.
    return origin + (absol * width // 65536)


class GdiCursorStabilityTests(unittest.TestCase):
    def test_uses_pixel_center_not_legacy_endpoint_conversion(self):
        inject = INJECTION.split('function SendAbsoluteMouseMove', 1)[1].split('procedure InjectMouse', 1)[0]
        self.assertIn('AX:=((2*(Int64(X)-Int64(VX))+1)*65536) div (2*Int64(VW));', inject)
        self.assertIn('AY:=((2*(Int64(Y)-Int64(VY))+1)*65536) div (2*Int64(VH));', inject)
        self.assertNotIn('*65535) div (VW-1)', inject)
        self.assertNotIn('*65535) div (VH-1)', inject)
        self.assertIn('KVM_MOUSEEVENTF_VIRTUALDESK', inject)
        self.assertIn('KVM_MOUSEEVENTF_ABSOLUTE', inject)
        self.assertIn('KVM_MOUSEEVENTF_MOVE', inject)

    def test_absolute_math_hits_physical_pixel(self):
        # The old formula sends absolute=34 for pixel 1 on 1920px,
        # which lands on pixel 0 and triggers pointless WM_MOUSEMOVE.
        old = 65535 // (1920 - 1)
        self.assertEqual(windows_pixel_from_absolute(old, 0, 1920), 0)
        self.assertEqual(windows_pixel_from_absolute(pixel_center_absolute(1, 0, 1920), 0, 1920), 1)

        for width in (1, 2, 3, 640, 1366, 1920, 2560, 3840,
                      7680, 15360, 30720, 32768, 65536):
            for origin in (-1920, -1, 0, 1024):
                xs = range(width) if width <= 3840 else set(
                    [0, 1, 2, 3, width // 2, width - 4, width - 3, width - 2, width - 1] +
                    [(i * (width - 1)) // 509 for i in range(510)])
                for delta in xs:
                    pixel = origin + delta
                    ab = pixel_center_absolute(pixel, origin, width)
                    self.assertEqual(windows_pixel_from_absolute(ab, origin, width), pixel,
                                     (origin, width, delta, ab))

    def test_repeated_requested_pixel_is_quiet_but_real_moves_preserved(self):
        inject = INJECTION.split('function SendAbsoluteMouseMove', 1)[1].split('procedure InjectMouse', 1)[0]
        self.assertIn('(Current.X=X) and (Current.Y=Y) then', inject)
        self.assertIn('LastAbsoluteTargetValid and', inject)
        self.assertIn('(LastAbsoluteTargetX=X) and (LastAbsoluteTargetY=Y)', inject)
        self.assertIn('(Abs(Int64(Current.X)-Int64(X))<=1)', inject)
        self.assertIn('(Abs(Int64(Current.Y)-Int64(Y))<=1)', inject)
        self.assertLess(inject.index('GetCursorPos(Current)'),
                        inject.index('KvmSendInput(1,@TI,SizeOf(TI))'))
        self.assertIn('if Result then', inject.split('KvmSendInput(1,@TI,SizeOf(TI))=1;', 1)[1])

        mouse = INJECTION.split('procedure InjectMouse(Action, Button: Byte; NX, NY: Word);', 2)[2].split('procedure InjectText', 1)[0]
        self.assertIn('if Action = 0 then Exit;', mouse)
        self.assertIn('KvmSendInput(1,@TI,SizeOf(TI))', mouse, 'Button-down/up must not be filtered')

    def test_gdi_cursor_visibility_and_bitmap_stability(self):
        state = INJECTION.split('function GetCursorState(out NX, NY: Word; out Shape: TKvmCursorShape): Boolean;', 2)[2].split('function GetCursorNormalized', 1)[0]
        self.assertIn('KVM_CURSOR_HIDE_DEBOUNCE_MS = 300;', INJECTION)
        self.assertIn('PositionKnown:=GetCursorPos(P)', state)
        self.assertIn('if PositionKnown and not PositionValid then Exit(False)', state)
        self.assertIn('if Shape.Revision=0 then Exit(False)', state)
        self.assertIn('if (LastCursorShape.Revision<>0) and (LastCursorSeenTick<>0)', state)
        self.assertIn('NowTick-LastCursorSeenTick<=KVM_CURSOR_HIDE_DEBOUNCE_MS', state)
        self.assertIn('Shape:=LastCursorShape', state)
        self.assertIn('GetCursorInfo(C)', state)

        self.assertIn('Result := kvm_capture_win.CaptureDesktopRgb(MaxW,MaxH,Frame)', DESKTOP)
        self.assertIn('Result:=kvm_inject_win.GetCursorState(NX,NY,Shape)', DESKTOP)
        self.assertIn('if not DesktopCursorEmbedded then', (ROOT/'server/kvm_server.pas').read_text())
        self.assertNotIn('DrawIconEx', GDI, 'GDI should not burn pointer into captured desktop')


if __name__ == '__main__':
    unittest.main()

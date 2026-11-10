#!/usr/bin/env python3
"""Non-Windows source guards. These do NOT simulate a Windows desktop."""
import unittest
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

class CursorFlickerTests(unittest.TestCase):
    def test_windows_identical_mouse_position_is_not_reinjected(self):
        source=(ROOT/'server/kvm_inject_win.pas').read_text()
        move=source.split('function SendAbsoluteMouseMove', 1)[1].split('procedure InjectMouse', 1)[0]
        self.assertIn('GetCursorPos(Current)',move)
        self.assertIn('(Current.X=X) and (Current.Y=Y) then',move)
        self.assertIn('Exit(True);',move)
        self.assertLess(move.index('GetCursorPos(Current)'),move.index('KvmSendInput(1,@TI,SizeOf(TI))'))
        self.assertIn('KVM_MOUSEEVENTF_MOVE', move)
        self.assertIn('KVM_MOUSEEVENTF_ABSOLUTE', move)
        self.assertIn('KVM_MOUSEEVENTF_VIRTUALDESK', move)
        inject=source.split('procedure InjectMouse(Action, Button: Byte; NX, NY: Word);',2)[2].split('procedure InjectText',1)[0]
        self.assertIn('if not SendAbsoluteMouseMove(X,Y)',inject)
        self.assertIn('if Action = 0 then Exit;',inject)
        self.assertIn('KvmSendInput(1,@TI,SizeOf(TI))',inject, 'Button events must still be injected')

    def test_dxgi_uses_same_stable_cursor_as_gdi(self):
        native=(ROOT/'native/windows/kvm_dxgi.cpp').read_text()
        desktop=(ROOT/'server/kvm_desktop.pas').read_text()
        inject=(ROOT/'server/kvm_inject_win.pas').read_text()
        server=(ROOT/'server/kvm_server.pas').read_text()
        # Since DXGI's multi-screen update, cursor shapes are NOT burned into
        # each video frame. The proven GDI publisher handles hide debounce,
        # hotspot, XOR/monochrome cursors and remote pointer movement.
        self.assertNotIn('draw_cursor(', native)
        self.assertIn('kvm_dxgi_cursor_embedded(void *handle)', native)
        self.assertIn('Result:=kvm_inject_win.GetCursorState(NX,NY,Shape)', desktop)
        self.assertIn('if not DesktopCursorEmbedded then', server)
        self.assertIn('KVM_CURSOR_HIDE_DEBOUNCE_MS = 300;',inject)
        self.assertIn('CaptureCursorShape(', inject)
        self.assertIn('if (DeltaB+DeltaG+DeltaR)<-192 then',inject)
        self.assertIn('LastCursorHandle',inject)

if __name__=='__main__':
    unittest.main()

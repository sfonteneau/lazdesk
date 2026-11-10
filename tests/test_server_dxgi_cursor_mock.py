#!/usr/bin/env python3
"""Guard that DXGI delegates cursor shapes to the proven GDI sender.

DXGI may sometimes contain the pointer in the driver frame: in that case,
only the separate cursor message is suppressed to avoid double pointers.
"""
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]
CPP=(ROOT/'native/windows/kvm_dxgi.cpp').read_text(encoding='utf8')
DESKTOP=(ROOT/'server/kvm_desktop.pas').read_text(encoding='utf8')
INJECT=(ROOT/'server/kvm_inject_win.pas').read_text(encoding='utf8')

class DxgiCursorTest(unittest.TestCase):
    def test_shared_cursor_path(self):
        self.assertNotIn('draw_cursor(', CPP)
        self.assertIn('kvm_dxgi_cursor_embedded(void *handle)',CPP)
        self.assertIn('info.PointerPosition.Visible!=FALSE',CPP)
        self.assertIn('LastCaptureCursorEmbedded := Result and DxgiCursorEmbedded;',DESKTOP)
        self.assertIn('Result:=kvm_inject_win.GetCursorState(NX,NY,Shape)',DESKTOP)
        self.assertIn('KVM_CURSOR_HIDE_DEBOUNCE_MS = 300;',INJECT)
        self.assertIn('CaptureCursorShape(',INJECT)
        self.assertIn('NormalizePoint(M.Bounds,P.X,P.Y,NX,NY)',INJECT)

if __name__=='__main__':
    unittest.main()

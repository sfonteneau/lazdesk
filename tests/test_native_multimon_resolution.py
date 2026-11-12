"""Guard against regression to implicit 1080p and broken multi-monitor bounds.

Structural checks only; Pascal/Lazarus integration must be run on Windows.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def text(path):
    return (ROOT / path).read_text(encoding='utf-8')

class NativeMultimonTests(unittest.TestCase):
    def test_no_1080p_default_and_optin_adaptive(self):
        cli = text('shared/kvm_cli.pas')
        self.assertNotIn('Options.MaxWidth := 1920', cli)
        self.assertNotIn('Options.MaxHeight := 1080', cli)
        self.assertIn('Options.MaxWidth := KVM_MAX_FRAME_SIDE;', cli)
        self.assertIn('Options.MaxHeight := KVM_MAX_FRAME_SIDE;', cli)
        self.assertIn('Options.Adaptive := False;', cli)
        self.assertIn("A = '--adaptive'", cli)
        self.assertIn("A = '--native-resolution'", cli)
        self.assertNotIn('Int64(Options.MaxWidth) * Options.MaxHeight >', cli)

    def test_shared_bound_kept_identical_in_c_and_pascal(self):
        wire=text('shared/kvm_wire.pas')
        header=text('native/common/kvm_pixels.h')
        self.assertIn('KVM_MAX_FRAME_SIDE = 32768', wire)
        self.assertIn('KVM_MAX_FRAME_PIXELS = 67108864', wire)
        self.assertIn('KVM_MAX_SIDE 32768u', header)
        self.assertIn('KVM_MAX_PIXELS 67108864u', header)
        for name in ('shared/kvm_frame.pas', 'shared/kvm_surface.pas',
                     'shared/kvm_damage.pas', 'shared/kvm_rgb_bitmap.pas'):
            src=text(name)
            self.assertIn('KVM_MAX_FRAME_PIXELS', src, name)
        self.assertIn('Int64(W) * H <= KVM_MAX_FRAME_PIXELS', text('shared/kvm_frame.pas'))

    def test_native_rejects_oversize_without_implicit_downscale(self):
        frame=text('shared/kvm_frame.pas')
        self.assertIn('if (MaxW = KVM_MAX_FRAME_SIDE) and (MaxH = KVM_MAX_FRAME_SIDE)', frame)
        self.assertIn('(Int64(SourceW) * SourceH > KVM_MAX_FRAME_PIXELS)', frame)
        self.assertIn('then Exit(False);', frame)

    def test_dynamic_wayland_allocation(self):
        src = text('server/kvm_wayland.pas')
        portal = text('native/linux/kvm_portal.c')
        self.assertNotIn('Int64(MaxW) * MaxH * 3', src)
        self.assertIn('Status = -2', src)
        self.assertIn('return -2;', portal)
        self.assertIn('*width=(int)w; *height=(int)h;', portal)

    def test_wire_still_bounded(self):
        wire=text('shared/kvm_wire.pas')
        self.assertIn('W <= KVM_MAX_FRAME_SIDE',wire)
        self.assertIn('Int64(W) * H <= KVM_MAX_FRAME_PIXELS',wire)
        self.assertIn("KVM_SUBPROTOCOL = 'lazdesk9'",wire)

if __name__=='__main__': unittest.main()

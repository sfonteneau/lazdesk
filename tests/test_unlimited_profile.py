#!/usr/bin/env python3
"""Static regression checks for the optional unpaced LAN profile.

These checks inspect sources; they do not compile Pascal or measure FPS.
The Pascal runtime tests are in run_cli_tests.sh, test_p123_core.lpr,
test_v7_core.lpr and test_turbo.lpr.
"""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]

class UnlimitedProfileSources(unittest.TestCase):
    def source(self, rel):
        return (ROOT/rel).read_text(encoding='utf-8')

    def test_cli_allows_explicit_unpaced_fps(self):
        s = self.source('shared/kvm_cli.pas')
        self.assertIn('--fps 0|1..1000', s)
        self.assertIn('if not IsUnsignedDecimal(V, N) or (N > 1000)', s)
        self.assertNotIn('(N < 1) or (N > 30)', s)

    def test_quality_accepts_turbojpeg_range(self):
        s = self.source('shared/kvm_cli.pas')
        t = self.source('server/kvm_turbojpeg.pas')
        self.assertIn('--quality 1..100', s)
        self.assertIn('(N < 1) or (N > 100)', s)
        self.assertIn('(Quality < 1) or (Quality > 100)', t)
        self.assertIn('TJSAMP_444, Quality', t)

    def test_unpaced_schedule_has_no_deadline(self):
        s = self.source('shared/kvm_schedule.pas')
        self.assertIn('if FPS<=0 then Exit(Finished)', s)
        self.assertNotIn('FPS:=120', s)
        self.assertIn('if FPS>=1000 then Interval:=1', s)

    def test_adaptive_profiles_keep_bounded_fps_when_base_is_unpaced(self):
        s = self.source('shared/kvm_adaptive.pas')
        self.assertIn('if BaseFps=0 then FPS:=30', s)
        self.assertIn('if BaseFps=0 then FPS:=10', s)

    def test_native_backends_not_passed_zero(self):
        s = self.source('server/kvm_desktop.pas')
        self.assertIn('if FPS<=0 then Exit(30)', s)
        self.assertIn('OpenWayland(AllowControl,NativeCaptureFPS(RequestedFPS)', s)
        self.assertIn('SetMacCaptureFPS(NativeCaptureFPS(FPS))', s)

    def test_h264_keeps_legal_nominal_time_base(self):
        s = self.source('server/kvm_video.pas')
        self.assertIn('if FPS<=0 then FFPS:=60 else FFPS:=Min(FPS,60)', s)

    def test_no_unbounded_queue_or_protocol_changes(self):
        s = self.source('shared/kvm_flow.pas')
        self.assertIn('KVM_BATCH_MAX_TILES = 20', s)
        self.assertIn('WaitingAck', s)
        t = self.source('server/kvm_server.pas')
        self.assertIn('FOwner.FWakeCapture.WaitFor(WaitMs)', t)
        self.assertIn('if CaptureRate=0 then Sleep(0)', t)
        self.assertIn('if CaptureW>0 then ConfigureCaptureFPS(CaptureRate)', t)

    def test_upstream_mormot_is_not_modified_by_builder(self):
        s = self.source('build/build_standalone.py')
        self.assertNotIn('fix_mormot_msi_import.py', s)
        self.assertFalse((ROOT/'tools/fix_mormot_msi_import.py').exists())

if __name__=='__main__':
    unittest.main()

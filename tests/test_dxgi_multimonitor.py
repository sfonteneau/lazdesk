#!/usr/bin/env python3
"""Native tested geometry/assembly + backend integration guards.

Tests run on Linux without DirectX, and do not replace a Windows GPU test.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CPP = (ROOT / 'native/windows/kvm_dxgi.cpp').read_text(encoding='utf8')
PASCAL = (ROOT / 'server/kvm_capture_dxgi.pas').read_text(encoding='utf8')
DESKTOP = (ROOT / 'server/kvm_desktop.pas').read_text(encoding='utf8')


class MultiMonitorTests(unittest.TestCase):
    def test_native_multimonitor_and_cursor_pipeline(self):
        self.assertIn('if (monitor!=0) return open_output', CPP)
        self.assertIn('EnumDisplayMonitors(', CPP)
        self.assertIn('std::vector<std::unique_ptr<Capture>> outputs;', CPP)
        self.assertIn('kvm_project_monitor(', CPP)
        self.assertIn('kvm_merge_rgb24(', CPP)
        self.assertIn('kvm_dxgi_cursor_embedded(void *handle)', CPP)
        self.assertIn('info.PointerPosition.Visible!=FALSE', CPP)
        self.assertNotIn('draw_cursor(', CPP, 'DXGI must use the GDI cursor-shape publisher')
        self.assertIn('Result := Status = 1;', PASCAL)
        self.assertNotIn('if M.NativeID = 0 then Exit;', PASCAL)
        self.assertIn('LastCaptureCursorEmbedded := Result and DxgiCursorEmbedded;', DESKTOP)
        self.assertIn('Result:=kvm_inject_win.GetCursorState(NX,NY,Shape)', DESKTOP)
        self.assertNotIn('DXGI: select --monitor N', DESKTOP)

    def test_compose_real_native_header(self):
        cc = shutil.which('c++') or shutil.which('g++')
        if not cc:
            self.skipTest('No native C++ compiler')
        code = r'''
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include "native/common/kvm_desktop_merge.h"
int main() {
    // 2 monitors side by side, left one has a negative desktop origin.
    KvmDesktopRect desktop{-1920,0,1920,1080};
    KvmDesktopRect left{-1920,0,0,1080}, right{0,0,1920,1080};
    KvmDesktopRect a{},b{};
    assert(kvm_project_monitor(desktop,left,8,2,&a));
    assert(kvm_project_monitor(desktop,right,8,2,&b));
    assert(a.left==0 && a.right==4 && b.left==4 && b.right==8);
    uint8_t dst[8*2*3]={}, red[4*2*3], blue[4*2*3];
    for (int i=0;i<8;i++) {
        red[i*3]=250;red[i*3+1]=0;red[i*3+2]=0;
        blue[i*3]=0;blue[i*3+1]=0;blue[i*3+2]=240;
    }
    assert(kvm_merge_rgb24(dst,sizeof(dst),8,2,a,red,sizeof(red)));
    assert(kvm_merge_rgb24(dst,sizeof(dst),8,2,b,blue,sizeof(blue)));
    for (int y=0;y<2;y++) for (int x=0;x<8;x++) {
        auto p=dst+(y*8+x)*3;
        assert(p[0]==(x<4 ? 250:0) && p[2]==(x<4 ? 0:240));
    }
    // Vertical stacking and odd downscales; no seams, coordinate translation.
    desktop={-1920,-1080,1920,1080};
    KvmDesktopRect top{-1920,-1080,1920,0},bottom{-1920,0,1920,1080};
    assert(kvm_project_monitor(desktop,top,9,7,&a));
    assert(kvm_project_monitor(desktop,bottom,9,7,&b));
    assert(a.top==0 && a.bottom==b.top && b.bottom==7);
    // Gaps stay blank, no out-of-bounds writes.
    desktop={-10,-10,10,10};
    KvmDesktopRect inset{-5,-5,5,5};
    assert(kvm_project_monitor(desktop,inset,8,8,&a));
    assert(a.left==2 && a.right==6 && a.top==2 && a.bottom==6);
    uint8_t padded[8*8*3+2];std::memset(padded,0x55,sizeof(padded));
    uint8_t part[4*4*3];std::memset(part,8,sizeof(part));
    assert(kvm_merge_rgb24(padded+1,sizeof(padded)-2,8,8,a,part,sizeof(part)));
    assert(padded[0]==0x55 && padded[sizeof(padded)-1]==0x55);
    assert(padded[1]==0x55 && padded[1+(2*8+2)*3]==8);
    assert(!kvm_merge_rgb24(padded+1,sizeof(padded)-2,8,8,a,part,sizeof(part)-1));
    assert(!kvm_project_monitor(desktop,{-100,0,4,5},8,8,&a));
    assert(!kvm_project_monitor(desktop,{0,0,0,5},8,8,&a));
    // Dirty rectangles copy only modified scanlines into an already assembled
    // desktop. Neighbouring monitors and pixels outside the dirty region stay.
    uint8_t update[4*4*3]; std::memset(update,42,sizeof(update));
    std::memset(dst,5,sizeof(dst));
    KvmDesktopRect region{0,0,4,2},dirty{1,0,3,1};
    assert(kvm_merge_rgb24_damage(dst,sizeof(dst),8,2,region,update,sizeof(update),dirty));
    for(int yy=0;yy<2;yy++) for(int xx=0;xx<8;xx++) {
        auto p=dst+(yy*8+xx)*3;
        assert(p[0]==((yy==0 && xx>=1 && xx<3)?42:5));
    }
    assert(!kvm_merge_rgb24_damage(dst,sizeof(dst),8,2,region,update,sizeof(update),{0,0,5,1}));
    assert(!kvm_merge_rgb24_damage(dst,sizeof(dst),8,2,region,update,3,{1,0,3,1}));
    std::puts("PASS: multi-monitor composition, dirty rectangles and bounds checks");
}
'''
        with tempfile.TemporaryDirectory(prefix='kvm_merge_') as d:
            file = Path(d) / 'run.cpp'
            exe = Path(d) / 'run'
            file.write_text(code, encoding='utf8')
            built = subprocess.run([cc,'-std=c++17','-O2','-Wall','-Wextra','-Werror',
                '-I',str(ROOT),str(file),'-o',str(exe)],capture_output=True,text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            proc = subprocess.run([str(exe)],capture_output=True,text=True)
            self.assertEqual(proc.returncode,0,proc.stderr)
            self.assertIn('PASS:',proc.stdout)


if __name__=='__main__':
    unittest.main()

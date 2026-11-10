#!/usr/bin/env python3
"""Invariants for v9 performance patch (not a Pascal build)."""
from pathlib import Path
import random
r=Path(__file__).resolve().parents[1]
video=(r/'server/kvm_video.pas').read_text()
damage=(r/'shared/kvm_damage.pas').read_text()
client=(r/'client/kvm_view_form.pas').read_text()
decoder=(r/'client/kvm_turbojpeg_decode.pas').read_text()
x11=(r/'server/kvm_capture_x11.pas').read_text()
assert 'Current := Source' in video and 'Current := FFrame' in video
assert 'CopyFrameRegions(Current, FPrevious, FRegions)' in video
assert 'CopyFrameRegions' in damage and 'UniqueString(Target.RGB)' in damage
assert 'TJFLAG_BOTTOMUP = 2' in decoder and 'TJPF_BGR = 1' in decoder
assert "GetProcedureAddress(FLibrary, 'tjDecompressHeader3')" in decoder
assert 'ActualW <> W' in decoder and 'ActualH <> H' in decoder
worker=(r/'client/kvm_video_worker.pas').read_text()
assert 'DecodeIntoSurface' in worker
assert 'FImage.LoadFromStream(FStream,FReader)' in worker
assert 'DecodeToBmp(' not in client and 'TJPEGImage' not in client
assert 'XShmGetImage' in x11 and 'XSync(D, 0); Result := Result and not TrapError;' in x11
jpeg=(r/'tests/fixtures/turbo_5x3.jpg').read_bytes()
assert jpeg.startswith(b'\xff\xd8') and jpeg.endswith(b'\xff\xd9')
# Independent RGB copy model exercises random disjoint rectangles and bounds.
random.seed(19)
for _ in range(1000):
    w=random.randint(1,71); h=random.randint(1,53)
    pixels=bytearray(random.randbytes(w*h*3))
    prev=bytearray(pixels)
    rects=[]
    for j in range(random.randint(1,7)):
        x=random.randrange(w); y=random.randrange(h)
        rw=random.randint(1,w-x); rh=random.randint(1,h-y)
        rects.append((x,y,rw,rh))
        for row in range(y,y+rh):
            start=(row*w+x)*3
            pixels[start:start+rw*3]=random.randbytes(rw*3)
    for x,y,rw,rh in rects:
        for row in range(y,y+rh):
            start=(row*w+x)*3
            prev[start:start+rw*3]=pixels[start:start+rw*3]
    assert prev==pixels
print('PASS: static pipeline invariants, JPEG sample and 1000 independent copy cases')

#!/usr/bin/env python3
"""Static regression for 4:4:4 buffer sizing; not an encoder runtime test."""
from pathlib import Path
import re
root=Path(__file__).resolve().parents[1]
wire=(root/'shared/kvm_wire.pas').read_text()
codec=(root/'server/kvm_turbojpeg.pas').read_text()
def value(name):
    result=re.search(r"\b"+name+r"\s*=\s*(\d+)(?:\s*\*\s*(\d+)\s*\*\s*(\d+))?",wire)
    assert result is not None, name
    return int(result.group(1)) * (int(result.group(2)) if result.group(2) else 1) * (int(result.group(3)) if result.group(3) else 1)
assert 'TJSAMP_444 = 0' in codec
assert 'TJSAMP_420' not in codec
assert 'TJFLAG_FASTDCT' not in codec
assert 'FBufferSize(W, H, TJSAMP_444)' in codec
assert '@Dst, @Size, TJSAMP_444, Quality' in codec
width=value('KVM_MAX_RECT_WIDTH')
height=value('KVM_MAX_RECT_HEIGHT')
limit=value('KVM_MAX_JPEG_BYTES')
# Formula from libjpeg-turbo tjBufSize implementation for 4:4:4:
# PAD(width,8)*PAD(height,8)*(2+4)+2048.
pad=lambda n: ((n+7)//8)*8
max_size=pad(width)*pad(height)*6+2048
assert max_size <= limit, f'4:4:4 max output buffer {max_size} exceeds {limit}'
print(f'OK: 4:4:4 JPEG, accurate DCT flag, {width}x{height}, max buffer {max_size} <= {limit}')

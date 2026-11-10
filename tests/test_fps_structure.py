#!/usr/bin/env python3
"""Source-level invariants only; NOT a Pascal compiler or FPS benchmark."""
from pathlib import Path
root=Path(__file__).resolve().parents[1]
flow=(root/'shared/kvm_flow.pas').read_text()
transport=(root/'server/kvm_transport.pas').read_text()
client=(root/'client/kvm_view_form.pas').read_text()
x11=(root/'server/kvm_capture_x11.pas').read_text()
adaptive=(root/'shared/kvm_adaptive.pas').read_text()
assert 'KVM_BATCH_MAX_TILES = 20;' in flow
assert 'KVM_OUTGOING_MAX_FRAMES = 64' in transport
assert 'KVM_OUTGOING_MAX_BYTES = 4 * 1024 * 1024' in transport
assert 'KVM_BATCH_MAX_BYTES = 3 * 1024 * 1024' in flow
worker=(root/'client/kvm_video_worker.pas').read_text()
assert 'FDecoder.DrainUI' in client
assert 'FImage.LoadFromStream(FStream,FReader)' in worker
assert 'DecodeTile(' not in client
assert 'KVM_DECODE_QUEUE_PACKETS = 128' in worker
assert 'SrcLine[2]' in x11 and '(W = M.Bounds.W)' in x11
assert 'if S.BytesPerSecond = 0 then Exit(1024 * 1024);' in adaptive
print('PASS: static bounds and optimized code paths (no runtime / FPS measurement)')

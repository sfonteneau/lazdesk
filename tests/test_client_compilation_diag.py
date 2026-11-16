#!/usr/bin/env python3
"""Client fix regressions (static checks, no Pascal compilation)."""
from pathlib import Path
root=Path(__file__).resolve().parents[1]
c=(root/'client/kvm_view_form.pas').read_text()
w=(root/'client/kvm_video_worker.pas').read_text()
ws=(root/'shared/kvm_wire.pas').read_text()
s=(root/'server/kvm_server.pas').read_text()
assert 'procedure TKvmViewForm.SetStatus(const TextA: string);' in c
assert 'FStatus.Caption := TextA;' in c
assert 'FStatus.Caption := Text;' not in c
assert 'Visible1,Available,StateChanged: Boolean;' in w
assert 'ReadCursor(Packet,CX,CY,Visible1)' in w
assert 'SetCaptureControl(AView)' in c
assert 'THttpClientWebSockets.WebSocketsConnect(' in c
assert 'RawUtf8(FHost.Text), RawUtf8(FPort.Text), Proto,' in c
assert "nil, '', KVM_WS_PATH, '', FTls.Checked, TLSContextRef" in c
assert 'TLSContextRef := @TLSContext' in c
assert 'TargetURI, ConnectOptions, Proto' not in c
assert 'AUTH ' in c and "' '+Capability" in c
assert "KVM_WS_ROUTE = 'kvm';" in ws
assert 'Protocol.UpgradeUri <> KVM_WS_ROUTE' in s
print('PASS: user client v9 + legacy mORMot2 overload + internal route handling')

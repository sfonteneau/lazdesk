#!/usr/bin/env python3
"""Regressions de la correction client (statique, sans compilation Pascal)."""
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
assert 'SetCaptureControl(FView)' in c
assert 'THttpRequestExtendedOptions' in c
assert 'TargetURI.FromScheme(WS_SCHEME[FTls.Checked]' in c
assert 'TargetURI, ConnectOptions, Proto' in c and '@ConnectError' in c
assert 'AUTH ' in c and "' '+Capability" in c
assert "KVM_WS_ROUTE = 'kvm';" in ws
assert 'Protocol.UpgradeUri<>KVM_WS_ROUTE' in s
print('PASS: client v9 de l utilisateur + diagnostic WebSocket + chemin interne de route')

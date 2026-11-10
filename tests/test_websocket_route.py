#!/usr/bin/env python3
"""Static regression check for mORMot2 WebSocket routing (not a Pascal build)."""
from pathlib import Path
import re
root = Path(__file__).resolve().parents[1]
wire = (root / "shared/kvm_wire.pas").read_text()
server = (root / "server/kvm_server.pas").read_text()
client = (root / "client/kvm_view_form.pas").read_text()
worker = (root / "client/kvm_video_worker.pas").read_text()
constants = dict(re.findall(r"\b(KVM_WS_(?:PATH|ROUTE))\s*=\s*'([^']+)'", wire))
assert constants == {"KVM_WS_PATH": "/kvm", "KVM_WS_ROUTE": "kvm"}, constants
assert constants["KVM_WS_PATH"].lstrip("/") == constants["KVM_WS_ROUTE"]
assert "KVM_WS_ROUTE, @HandleFrame" in server
assert "Protocol.UpgradeUri <> KVM_WS_ROUTE" in server
assert 'TargetURI, ConnectOptions, Proto' in client and '@ConnectError' in client
assert 'KVM_WS_PATH) then' in client
assert 'FStatus.Caption := TextA;' in client
assert 'mormot.net.client' in client
assert "Frame.payload := 'AUTH ' + RawByteString(AnsiString(FToken.Text))+' '+Capability;" in client
assert "ReadDesktopState(Events[I]" in client
assert "ReadDesktopState(Packet" in worker
assert "FInputs.Receipt" in client
assert "FView.MouseCapture" not in client
assert "GetCaptureControl" in client and "SetCaptureControl" in client
assert "LazDesk v9" in client
print("PASS: WS routes, client v9/auth capabilities, mouse capture (lexical checks)")

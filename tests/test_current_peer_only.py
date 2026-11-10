"""Current client/server speak one protocol; internal input-queue U is kept."""
from pathlib import Path
root=Path(__file__).resolve().parents[1]
server=(root/'server/kvm_server.pas').read_text()
client=(root/'client/kvm_view_form.pas').read_text()
wire=(root/'shared/kvm_extwire.pas').read_text()
queue=(root/'shared/kvm_input_queue.pas').read_text()
assert "'U': Valid:=ReadTextRequest" not in server
assert "'U','X':" not in server
assert "if Packet[1]='U'" not in server
assert "'U','X':" not in client
assert "FRemoteMonitorCount" not in client
assert "MONITORS '" not in client
assert "SendText(Sender,'MONITORS '" not in server
assert "SendText(Sender,CaptureMonitorLayoutText)" in server
assert "Packet[1]<>'X'" in wire
assert "ReadTextCommit('U'+Copy(Packet,9,N),Points)" in wire
assert "MakeTextRequest(Next,Copy(Packet,2,MaxInt))" in queue
assert 'dxgi' in (root/'server/kvm_desktop.pas').read_text().lower()
assert 'gdi' in (root/'server/kvm_desktop.pas').read_text().lower()
print('PASS: one peer protocol; DXGI and GDI kept')

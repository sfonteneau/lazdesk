#!/usr/bin/env python3
"""Static guards for direct server-side X Unicode decoding and recoverable failures."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
server = (root / 'server' / 'kvm_server.pas').read_text(encoding='utf-8')
assert 'function DecodeTextUtf8Server' in server
assert 'function ReadTextRequestServer' in server
assert "'X': Valid:=ReadTextRequestServer(Frame.payload,Serial,Points);" in server
assert "'U': Valid:=ReadTextRequest" not in server
assert "'U','X':" not in server
assert 'DeclaredBytes:=KvmServerGet16LE(Packet,7);' in server
assert 'ActualBytes:=Length(Packet)-KVM_TEXT_REQUEST_HEADER;' in server
assert '(DeclaredBytes<>ActualBytes)' in server
assert 'Result:=DecodeTextUtf8Server(Packet,KVM_TEXT_REQUEST_HEADER+1,ActualBytes,Points);' in server
# The Win32 server must decode protocol bytes directly, without rebuilding U+UTF-8.
helper = server[server.index('function ReadTextRequestServer'):server.index('\nconst\n', server.index('function ReadTextRequestServer'))]
assert "ReadTextCommit('U'+" not in helper
assert "if Packet[1]='U'" not in helper
# Malformed X text is recoverable: return a receipt so the client never times out/disconnects.
assert 'function TKvmServer.RejectText' in server
assert "Result:=MakeInputReceipt(Serial,KVM_INPUT_FAILED,0);" in server
assert "Receipt:=RejectText(ID,Serial,Frame.payload);" in server
assert "first_byte=" in server
assert "BadPacket(Sender); Exit;" in server  # still used for non-X malformed packets
print('PASS: server decodes X bytes directly and malformed X receives a failure receipt')

#!/usr/bin/env python3
"""Source guards for local UTF-8 keyboard commits. Not a Windows/LCL runtime test."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
view = (root / 'client' / 'kvm_view_form.pas').read_text(encoding='utf-8')
queue = (root / 'shared' / 'kvm_input_queue.pas').read_text(encoding='utf-8')
assert 'function TKvmViewForm.OutgoingInputPacketValid' in view
assert "'X': Result:=ReadTextRequest(Payload,Serial,Points);" in view
assert "'U','X': Result:=ReadTextRequest" not in view
assert "if not OutgoingInputPacketValid(Payload) then" in view
assert "if Payload[1]='X' then FInputs.Reset;" in view
assert 'Move(UTF8Key[1],Utf8Bytes[1],Length(UTF8Key));' in view
assert 'MakeTextUtf8(Utf8Bytes)' in view
# Receipt state must be armed only after the exact versioned on-wire X packet validates.
validate_pos = queue.index('not ReadTextRequest(Built,CheckSerial,CheckPoints)')
pending_pos = queue.index('FPending:=Next')
assert validate_pos < pending_pos
assert 'Built:=MakeTextRequest(Next,Copy(Packet,2,MaxInt));' in queue
assert "Result[1]:='X'" in (root / 'shared' / 'kvm_extwire.pas').read_text(encoding='utf-8')

# A recoverable failed text receipt must not release control or reset the whole session.
receipt_block = view[view.index('if InputStatus<>KVM_INPUT_OK then'):view.index('DrainInputs;', view.index('if InputStatus<>KVM_INPUT_OK then'))]
assert "if InputStatus=KVM_INPUT_PARTIAL then" in receipt_block
assert "TransmitPacket('Z')" in receipt_block
assert receipt_block.count("TransmitPacket('Z')") == 1

print('PASS: local UTF-8 input uses versioned X framing and validates before WebSocket')

unit kvm_direct_wire;

{$mode objfpc}{$H+}

// A direct tunnel preserves a whole KVM message in one mORMot SendData call.
// The single leading byte carries the WebSocket text/binary distinction.
// No JPEG fragmentation or reassembly is performed by LazDesk.

interface

uses SysUtils;

const
  KVM_DIRECT_FRAME_MAX_BYTES = 3 * 1024 * 1024;

function KvmDirectPack(Kind: AnsiChar;
  const Payload: RawByteString): RawByteString;
function KvmDirectUnpack(const Frame: RawByteString;
  out Kind: AnsiChar; out Payload: RawByteString): Boolean;

implementation

function KvmDirectPack(Kind: AnsiChar;
  const Payload: RawByteString): RawByteString;
var
  N: Integer;
begin
  N := Length(Payload);
  if not (Kind in ['B','T']) or (N<1) or
     (N>KVM_DIRECT_FRAME_MAX_BYTES) then
    raise ERangeError.Create('Invalid KVM direct frame');
  SetLength(Result,N+1);
  Result[1] := Kind;
  Move(Payload[1],Result[2],N);
end;

function KvmDirectUnpack(const Frame: RawByteString;
  out Kind: AnsiChar; out Payload: RawByteString): Boolean;
var
  N: Integer;
begin
  Kind := #0;
  Payload := '';
  N := Length(Frame)-1;
  Result := (N>=1) and (N<=KVM_DIRECT_FRAME_MAX_BYTES);
  if not Result then Exit;
  if not (Frame[1] in ['B','T']) then Exit(False);
  Kind := Frame[1];
  SetLength(Payload,N);
  Move(Frame[2],Payload[1],N);
end;

end.

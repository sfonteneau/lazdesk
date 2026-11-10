unit kvm_extwire;
{$mode objfpc}{$H+}
interface
uses SysUtils, kvm_wire;
const
  KVM_CODEC_H264 = 1;
  KVM_VIDEO_HEADER = 10;
  KVM_MAX_VIDEO_BYTES = 2*1024*1024;
  KVM_SESSION_UNKNOWN = 0;
  KVM_SESSION_ACTIVE = 1;
  KVM_SESSION_LOCKED = 2;
  KVM_SESSION_INACTIVE = 3;
  KVM_SESSION_CHANGED = 4;
  KVM_SESSION_CAPTURE_LOST = 5;
  KVM_INPUT_OK = 0;
  KVM_INPUT_DENIED = 1;
  KVM_INPUT_PARTIAL = 2;
  KVM_INPUT_FAILED = 3;
  KVM_INPUT_STALE = 4;
  KVM_TEXT_REQUEST_VERSION = 1;
  KVM_TEXT_REQUEST_HEADER = 8; // X + version:u8 + serial:u32 + utf8-bytes:u16
function MakeVideo(W,H: Word; const AccessUnit: RawByteString): RawByteString;
function ReadVideo(const Packet: RawByteString; out W,H: Word; out AccessUnit: RawByteString): Boolean;
function MakeDesktopState(Available: Boolean; Reason: Byte; Epoch: Cardinal): RawByteString;
function ReadDesktopState(const Packet: RawByteString; out Available: Boolean;
  out Reason: Byte; out Epoch: Cardinal): Boolean;
function DesktopStateText(Reason: Byte): string;
function MakeTextRequest(Serial: Cardinal; const Utf8: RawByteString): RawByteString;
function ReadTextRequest(const Packet: RawByteString; out Serial: Cardinal;
  out Points: TKvmCodePoints): Boolean;
function MakeInputReceipt(Serial: Cardinal; Status: Byte; Applied: Word): RawByteString;
function ReadInputReceipt(const Packet: RawByteString; out Serial: Cardinal;
  out Status: Byte; out Applied: Word): Boolean;
function NextSerial(Serial: Cardinal): Cardinal;
implementation
procedure Put16(var S: RawByteString; I: Integer; N: Word);
begin S[I]:=AnsiChar(N and 255); S[I+1]:=AnsiChar(N shr 8); end;
function Get16(const S: RawByteString; I: Integer): Word;
begin Result:=Word(Ord(S[I])) or (Word(Ord(S[I+1])) shl 8); end;
procedure Put32(var S: RawByteString; I: Integer; N: Cardinal);
var J: Integer;
begin for J:=0 to 3 do S[I+J]:=AnsiChar((N shr (J*8)) and 255); end;
function Get32(const S: RawByteString; I: Integer): Cardinal;
var J: Integer;
begin Result:=0; for J:=0 to 3 do Result:=Result or (Cardinal(Ord(S[I+J])) shl (J*8)); end;
function NextSerial(Serial: Cardinal): Cardinal;
begin if Serial=High(Cardinal) then Result:=1 else Result:=Serial+1; end;
function MakeVideo(W,H: Word; const AccessUnit: RawByteString): RawByteString;
begin
  Result:='';
  if (W<2) or (H<2) or Odd(W) or Odd(H) or (W>KVM_MAX_FRAME_SIDE) or
     (H>KVM_MAX_FRAME_SIDE) or (Int64(W)*H>KVM_MAX_FRAME_PIXELS) or
     (Length(AccessUnit)<5) or (Length(AccessUnit)>KVM_MAX_VIDEO_BYTES) then Exit;
  SetLength(Result,KVM_VIDEO_HEADER+Length(AccessUnit)); Result[1]:='V'; Result[2]:=#1;
  Put16(Result,3,W); Put16(Result,5,H); Put32(Result,7,Length(AccessUnit));
  Move(AccessUnit[1],Result[11],Length(AccessUnit));
end;
function ReadVideo(const Packet: RawByteString; out W,H: Word; out AccessUnit: RawByteString): Boolean;
begin
  Result:=False; W:=0; H:=0; AccessUnit:='';
  if (Length(Packet)<15) or (Length(Packet)>KVM_MAX_VIDEO_BYTES+KVM_VIDEO_HEADER) then Exit;
  if (Packet[1]<>'V') or (Packet[2]<>#1) or (Get32(Packet,7)<>Cardinal(Length(Packet)-10)) then Exit;
  W:=Get16(Packet,3); H:=Get16(Packet,5);
  if (W<2) or (H<2) or Odd(W) or Odd(H) or (W>KVM_MAX_FRAME_SIDE) or
     (H>KVM_MAX_FRAME_SIDE) or (Int64(W)*H>KVM_MAX_FRAME_PIXELS) then Exit;
  AccessUnit:=Copy(Packet,11,MaxInt); Result:=True;
end;
function MakeDesktopState(Available: Boolean; Reason: Byte; Epoch: Cardinal): RawByteString;
begin
  SetLength(Result,7); Result[1]:='D'; Result[2]:=AnsiChar(Ord(Available));
  Result[3]:=AnsiChar(Reason); Put32(Result,4,Epoch);
end;
function ReadDesktopState(const Packet: RawByteString; out Available: Boolean;
  out Reason: Byte; out Epoch: Cardinal): Boolean;
begin
  Result:=False; Available:=False; Reason:=0; Epoch:=0;
  if (Length(Packet)<>7) or (Packet[1]<>'D') or not (Packet[2] in [#0,#1]) then Exit;
  Reason:=Ord(Packet[3]); Epoch:=Get32(Packet,4);
  if (Reason>KVM_SESSION_CAPTURE_LOST) or (Epoch=0) then Exit;
  Available:=Packet[2]=#1;
  Result:=(not Available) or (Reason=KVM_SESSION_ACTIVE);
end;
function DesktopStateText(Reason: Byte): string;
begin
  case Reason of
    1: Result:='Session active'; 2: Result:='Session verrouillee';
    3: Result:='Session inactive/deconnectee';
    4: Result:='Session changed: restart the server in the intended session';
    5: Result:='Capture unavailable';
    else Result:='Unknown session state (sharing suspended)';
  end;
end;
function MakeTextRequest(Serial: Cardinal; const Utf8: RawByteString): RawByteString;
var Points: TKvmCodePoints; N: Integer;
begin
  // X is the on-wire, versioned Unicode-text request. The local input queue
  // still uses U+UTF-8 as a transient commit before assigning a serial.
  Result:='';
  N:=Length(Utf8);
  if (Serial=0) or (N<1) or (N>KVM_MAX_TEXT_BYTES) or
     not ReadTextCommit('U'+Utf8,Points) then Exit;
  SetLength(Result,KVM_TEXT_REQUEST_HEADER+N);
  Result[1]:='X'; Result[2]:=AnsiChar(KVM_TEXT_REQUEST_VERSION);
  Put32(Result,3,Serial); Put16(Result,7,Word(N));
  Move(Utf8[1],Result[9],N);
end;
function ReadTextRequest(const Packet: RawByteString; out Serial: Cardinal;
  out Points: TKvmCodePoints): Boolean;
var N: Integer;
begin
  Result:=False; Serial:=0; SetLength(Points,0);
  // The only network text request is the versioned X frame.
  if (Length(Packet)<KVM_TEXT_REQUEST_HEADER+1) or
     (Length(Packet)>KVM_TEXT_REQUEST_HEADER+KVM_MAX_TEXT_BYTES) or
     (Packet[1]<>'X') or (Ord(Packet[2])<>KVM_TEXT_REQUEST_VERSION) then Exit;
  Serial:=Get32(Packet,3); N:=Get16(Packet,7);
  if (Serial=0) or (N<1) or
     (Length(Packet)<>KVM_TEXT_REQUEST_HEADER+N) then Exit;
  Result:=ReadTextCommit('U'+Copy(Packet,9,N),Points);
end;
function MakeInputReceipt(Serial: Cardinal; Status: Byte; Applied: Word): RawByteString;
begin
  SetLength(Result,8); Result[1]:='I'; Put32(Result,2,Serial);
  Result[6]:=AnsiChar(Status); Put16(Result,7,Applied);
end;
function ReadInputReceipt(const Packet: RawByteString; out Serial: Cardinal;
  out Status: Byte; out Applied: Word): Boolean;
begin
  Result:=False; Serial:=0; Status:=0; Applied:=0;
  if (Length(Packet)<>8) or (Packet[1]<>'I') then Exit;
  Serial:=Get32(Packet,2); Status:=Ord(Packet[6]); Applied:=Get16(Packet,7);
  Result:=(Serial<>0) and (Status<=KVM_INPUT_STALE) and (Applied<=KVM_MAX_TEXT_SCALARS);
end;
end.

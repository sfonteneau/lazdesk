unit kvm_input_queue;
{$mode objfpc}{$H+}
interface
uses SysUtils, kvm_wire, kvm_extwire;
const KVM_INPUT_QUEUE_BYTES=65536; KVM_INPUT_QUEUE_ITEMS=512;
      KVM_TEXT_RECEIPT_TIMEOUT_MS=4000;
type
  { UI-thread owned. No automatic replay after an uncertain remote injection. }
  TKvmInputQueue=class
  private
    FItems: array of RawByteString;
    FBytes: Integer;
    FSerial, FPending: Cardinal;
    FPendingPoints: Integer;
    FSent: QWord;
  public
    function Push(const Packet: RawByteString): Boolean;
    function Take(NowTick: QWord; out Packet: RawByteString): Boolean;
    function Receipt(const Packet: RawByteString; out Status: Byte; out Applied: Word): Boolean;
    function TimedOut(NowTick: QWord): Boolean;
    procedure CancelQueued;
    procedure Reset;
    property Pending: Cardinal read FPending;
  end;
implementation
function TKvmInputQueue.Push(const Packet: RawByteString): Boolean;
var N: Integer; Points: TKvmCodePoints;
begin
  Result:=False;
  if (Packet='') or not (Packet[1] in ['K','M','W','U']) then Exit;
  if (Packet[1]='U') and not ReadTextCommit(Packet,Points) then Exit;
  N:=Length(FItems);
  // Replace only the last *unsent* pure mouse move. Never cross a key,
  // button, wheel or text event: their ordering must remain intact.
  // This prevents old pointer positions piling up behind a text receipt.
  if (Packet[1]='M') and (Length(Packet)=7) and
     (Packet[2]=#0) and (Packet[3]=#0) and (N>0) and
     (Length(FItems[N-1])=7) and (FItems[N-1][1]='M') and
     (FItems[N-1][2]=#0) and (FItems[N-1][3]=#0) then
  begin
    FItems[N-1]:=Packet;
    Exit(True);
  end;
  if (N>=KVM_INPUT_QUEUE_ITEMS) or (Length(Packet)>KVM_INPUT_QUEUE_BYTES-FBytes) then Exit;
  SetLength(FItems,N+1); FItems[N]:=Packet; Inc(FBytes,Length(Packet)); Result:=True;
end;
function TKvmInputQueue.Take(NowTick: QWord; out Packet: RawByteString): Boolean;
var
  I: Integer;
  Points,CheckPoints: TKvmCodePoints;
  Next,CheckSerial: Cardinal;
  Built: RawByteString;
begin
  Packet:=''; Result:=False;
  if (FPending<>0) or (Length(FItems)=0) then Exit;
  Packet:=FItems[0]; Dec(FBytes,Length(Packet));
  for I:=1 to High(FItems) do FItems[I-1]:=FItems[I];
  SetLength(FItems,Length(FItems)-1);
  if Packet[1]='U' then
  begin
    if not ReadTextCommit(Packet,Points) then begin Packet:=''; Exit; end;
    Next:=NextSerial(FSerial);
    Built:=MakeTextRequest(Next,Copy(Packet,2,MaxInt));
    // Arm the receipt only after the exact on-wire X packet has passed the same
    // parser used by the server. A construction failure can therefore never
    // leave FPending stuck or emit a malformed Unicode-text frame.
    if (Built='') or not ReadTextRequest(Built,CheckSerial,CheckPoints) or
       (CheckSerial<>Next) or (Length(CheckPoints)<>Length(Points)) then
    begin Packet:=''; Exit; end;
    FSerial:=Next; FPending:=Next;
    FPendingPoints:=Length(Points); FSent:=NowTick;
    Packet:=Built;
  end;
  Result:=Packet<>'';
end;
function TKvmInputQueue.Receipt(const Packet: RawByteString; out Status: Byte; out Applied: Word): Boolean;
var Serial: Cardinal;
begin
  Result:=ReadInputReceipt(Packet,Serial,Status,Applied);
  if Result then Result:=(FPending<>0) and (Serial=FPending) and (Applied<=FPendingPoints);
  if Result and (Status=KVM_INPUT_OK) then Result:=Applied=FPendingPoints;
  if Result then begin FPending:=0; FSent:=0; end;
end;
function TKvmInputQueue.TimedOut(NowTick: QWord): Boolean;
begin Result:=(FPending<>0) and (NowTick>=FSent) and (NowTick-FSent>=KVM_TEXT_RECEIPT_TIMEOUT_MS); end;
procedure TKvmInputQueue.CancelQueued;
begin SetLength(FItems,0); FBytes:=0; end;
procedure TKvmInputQueue.Reset;
begin CancelQueued; FSerial:=0; FPending:=0; FPendingPoints:=0; FSent:=0; end;
end.

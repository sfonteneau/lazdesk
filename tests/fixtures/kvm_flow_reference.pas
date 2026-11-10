unit kvm_flow_reference;

{$mode objfpc}{$H+}

// Stop-and-wait, per-viewer tile flow control.  The network writer must
// send only a single PrepareFlowBatch result and wait for AcknowledgeFlowBatch
// before preparing another batch for that viewer.

interface

uses SysUtils, kvm_wire, kvm_extwire;

const
  KVM_BATCH_MAX_TILES = 20;  // <= 24 messages incl. D, S, C and B
  KVM_BATCH_MAX_BYTES = 3 * 1024 * 1024;
  KVM_FLOW_ACK_TIMEOUT_MS = 20000;
  KVM_FLOW_RESYNC_INTERVAL_MS = 2000;


type
  TKvmFlowBatch = record
    Serial: Cardinal;
    PayloadBytes: Integer;
    SendScreen: Boolean;
    SendCursor, CursorVisible: Boolean;
    CursorX, CursorY: Word;
    Indices: array of Integer;
  end;

  TKvmFlowState = record
    NeedScreen: Boolean;
    WaitingAck: Boolean;
    NextTile: Integer;
    Serial: Cardinal;
    FlightSerial: Cardinal;
    LastSentTick, LastResyncTick: QWord;

    AckedVersions: array of Cardinal;
    FlightVersions: array of Cardinal;
    CursorKnown, CursorVisible: Boolean;
    CursorX, CursorY: Word;
    FlightCursor, FlightCursorVisible: Boolean;
    FlightCursorX, FlightCursorY: Word;
  end;

procedure InitFlow(var State: TKvmFlowState);
// Geometry change must not bypass an outstanding unacknowledged batch.
procedure InvalidateFlowGeometry(var State: TKvmFlowState);
function RequestFlowReset(var State: TKvmFlowState; NowTick: QWord): Boolean;
function PrepareFlowBatch(var State: TKvmFlowState;
  const Cache: array of RawByteString; const Versions: array of Cardinal;
  const Groups: array of Integer; CursorValid: Boolean; CursorX, CursorY: Word; NowTick: QWord;
  out Batch: TKvmFlowBatch; ByteBudget: Integer = KVM_BATCH_MAX_BYTES): Boolean;
function AcknowledgeFlowBatch(var State: TKvmFlowState; Serial: Cardinal): Boolean;
function RejectFlowBatch(var State: TKvmFlowState; Serial: Cardinal): Boolean;
function FlowTimedOut(const State: TKvmFlowState; NowTick: QWord): Boolean;

implementation

procedure ResetToScreen(var State: TKvmFlowState);
begin
  State.NeedScreen := True;
  State.NextTile := 0;
  State.CursorKnown := False;
  State.CursorVisible := False;
  SetLength(State.AckedVersions, 0);
end;

procedure InitFlow(var State: TKvmFlowState);
begin
  State.Serial := 0;
  State.FlightSerial := 0;
  State.WaitingAck := False;
  State.LastSentTick := 0;
  State.LastResyncTick := 0;

  State.FlightCursor := False;
  SetLength(State.FlightVersions, 0);
  ResetToScreen(State);
end;

procedure InvalidateFlowGeometry(var State: TKvmFlowState);
begin
  // Do not queue another snapshot over an unacknowledged batch.
  State.NeedScreen := True;
end;

function RequestFlowReset(var State: TKvmFlowState; NowTick: QWord): Boolean;
begin
  Result := False;
  if (State.LastResyncTick <> 0) and
     (NowTick - State.LastResyncTick < KVM_FLOW_RESYNC_INTERVAL_MS) then Exit;
  // Never abandon an in-flight batch. The receiver must ACK or NACK its
  // serial. Refresh floods cannot queue additional JPEGs behind a slow peer.
  State.NeedScreen := True;
  if not State.WaitingAck then ResetToScreen(State);
  State.LastResyncTick := NowTick;
  Result := True;
end;

function PrepareFlowBatch(var State: TKvmFlowState;
  const Cache: array of RawByteString; const Versions: array of Cardinal;
  const Groups: array of Integer; CursorValid: Boolean; CursorX, CursorY: Word; NowTick: QWord;
  out Batch: TKvmFlowBatch; ByteBudget: Integer): Boolean;
var
  N, J, I, K, Added, Bytes, StartTile, Candidate: Integer;
  Outdated: Boolean;
begin
  Result := False;
  Batch.Serial := 0;
  Batch.PayloadBytes := 0;
  if ByteBudget < 1 then ByteBudget := 1;
  if ByteBudget > KVM_BATCH_MAX_BYTES then ByteBudget := KVM_BATCH_MAX_BYTES;
  Batch.SendScreen := False;
  Batch.SendCursor := False;
  SetLength(Batch.Indices, 0);
  N := Length(Cache);
  if State.WaitingAck or (N = 0) or (N <> Length(Versions)) or
     (N <> Length(Groups)) then Exit;

  if Length(State.AckedVersions) <> N then
    State.NeedScreen := True;
  if State.NeedScreen then
  begin
    SetLength(State.AckedVersions, N);
    for J := 0 to N - 1 do State.AckedVersions[J] := 0;
    State.NextTile := 0;
    State.CursorKnown := False;
    State.CursorVisible := False;
    Batch.SendScreen := True;
    State.NeedScreen := False;
  end;

  SetLength(State.FlightVersions, N);
  for J := 0 to N - 1 do State.FlightVersions[J] := 0;
  Added := 0;
  Bytes := 0;
  if (State.NextTile < 0) or (State.NextTile >= N) then State.NextTile := 0;
  StartTile := State.NextTile;
  for J := 0 to N - 1 do
  begin
    I := (StartTile + J) mod N;
    // Only the leader owns the JPEG packet. All tiles in its rectangle
    // share the same latest JPEG bytes, but are ACKed as one atomic image.
    if (Groups[I] <> I) or (Versions[I] = 0) or (Cache[I] = '') then Continue;
    Outdated := False;
    for K := 0 to N - 1 do
      if (Groups[K] = I) and
         (State.AckedVersions[K] <> Versions[K]) then
        Outdated := True;
    if not Outdated then Continue;
    Candidate := Length(Cache[I]);
    if (Candidate > KVM_MAX_VIDEO_BYTES + KVM_VIDEO_HEADER) or (Candidate < 13) or
       not (Cache[I][1] in ['T','V']) then Continue;
    if (Added >= KVM_BATCH_MAX_TILES) or
       ((Added > 0) and (Bytes + Candidate > ByteBudget)) then Break;
    SetLength(Batch.Indices, Added + 1);
    Batch.Indices[Added] := I;
    for K := 0 to N - 1 do
      if Groups[K] = I then State.FlightVersions[K] := Versions[K];
    Inc(Added);
    Inc(Bytes, Candidate);
    State.NextTile := (I + 1) mod N;
  end;

  Batch.SendCursor := (not State.CursorKnown) or (CursorValid <> State.CursorVisible) or
    (CursorValid and ((CursorX <> State.CursorX) or (CursorY <> State.CursorY)));
  Batch.CursorVisible := CursorValid;
  if Batch.SendCursor then
  begin
    Batch.CursorX := CursorX;
    Batch.CursorY := CursorY;
    State.FlightCursorVisible := CursorValid;
    State.FlightCursorX := CursorX;
    State.FlightCursorY := CursorY;
  end;
  State.FlightCursor := Batch.SendCursor;

  // A no-change frame does not create any unacknowledged data.
  if (Added = 0) and not Batch.SendScreen and not Batch.SendCursor then Exit;

  // Explicit wrap also works with FPC overflow checking enabled (-Co).
  if State.Serial = High(Cardinal) then State.Serial := 1
  else Inc(State.Serial);
  State.FlightSerial := State.Serial;
  State.WaitingAck := True;
  State.LastSentTick := NowTick;
  Batch.Serial := State.FlightSerial;
  Batch.PayloadBytes := Bytes + 5;
  if Batch.SendScreen then Inc(Batch.PayloadBytes, 5);
  if Batch.SendCursor then Inc(Batch.PayloadBytes, 6);
  Result := True;
end;

function AcknowledgeFlowBatch(var State: TKvmFlowState;
  Serial: Cardinal): Boolean;
var
  I: Integer;
begin
  Result := State.WaitingAck and (Serial <> 0) and
    (Serial = State.FlightSerial);
  if not Result then Exit;
  for I := 0 to High(State.FlightVersions) do
    if State.FlightVersions[I] <> 0 then
      State.AckedVersions[I] := State.FlightVersions[I];
  if State.FlightCursor then
  begin
    State.CursorKnown := True;
    State.CursorVisible := State.FlightCursorVisible;
    State.CursorX := State.FlightCursorX;
    State.CursorY := State.FlightCursorY;
  end;
  State.FlightCursor := False;
  State.WaitingAck := False;

  SetLength(State.FlightVersions, 0);
end;

function RejectFlowBatch(var State: TKvmFlowState; Serial: Cardinal): Boolean;
begin
  Result := State.WaitingAck and (Serial <> 0) and (Serial = State.FlightSerial);
  if not Result then Exit;
  State.WaitingAck := False; State.FlightCursor := False;
  SetLength(State.FlightVersions, 0);
  ResetToScreen(State);
end;

function FlowTimedOut(const State: TKvmFlowState; NowTick: QWord): Boolean;
begin
  Result := State.WaitingAck and
    (NowTick - State.LastSentTick > KVM_FLOW_ACK_TIMEOUT_MS);
end;

end.

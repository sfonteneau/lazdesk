unit kvm_flow;

{$mode objfpc}{$H+}

// Small per-viewer sliding window. Up to KVM_FLOW_MAX_IN_FLIGHT batches may
// be queued before ACKs arrive. Each flight keeps the exact tile versions and
// cursor state it carries, so newer changes can follow older unacknowledged
// ones without resending the same version or losing an update.

interface

uses SysUtils, kvm_wire, kvm_extwire;

const
  KVM_BATCH_MAX_TILES = 20;  // <= 25 messages incl. D, S, H, C and B
  KVM_BATCH_MAX_BYTES = 3 * 1024 * 1024;
  // 3 * (D + 20 tiles + S/C/B) stays comfortably below the client FIFO of
  // 128 packets while hiding one or two ACK round trips on a LAN.
  KVM_FLOW_MAX_IN_FLIGHT = 3;
  KVM_FLOW_ACK_TIMEOUT_MS = 20000;
  KVM_FLOW_RESYNC_INTERVAL_MS = 2000;


type
  TKvmFlowBatch = record
    Serial: Cardinal;
    PayloadBytes: Integer;
    SendScreen: Boolean;
    SendCursor, SendCursorShape, CursorVisible: Boolean;
    CursorX, CursorY: Word;
    CursorShapeRevision: Cardinal;
    Indices: array of Integer;
  end;

  TKvmFlowFlight = record
    Serial: Cardinal;
    SentTick: QWord;
    PayloadBytes: Integer;
    Versions: array of Cardinal;
    Cursor, CursorShape, CursorVisible: Boolean;
    CursorX, CursorY: Word;
    CursorShapeRevision: Cardinal;
  end;

  TKvmFlowState = record
    NeedScreen: Boolean;
    // Compatibility fields expose the oldest outstanding flight. New code
    // should prefer FlightCount/FlowCanQueue and the per-flight ring below.
    WaitingAck: Boolean;
    NextTile: Integer;
    Serial: Cardinal;
    FlightSerial: Cardinal;
    LastSentTick, LastResyncTick: QWord;
    FlightCount: Integer;
    Flights: array[0..KVM_FLOW_MAX_IN_FLIGHT-1] of TKvmFlowFlight;
    LastAckElapsedMs: QWord;
    LastAckBytes: Integer;

    AckedVersions: array of Cardinal;
    FlightVersions: array of Cardinal;
    // Per-viewer reusable scratch: bit 0 = outdated, bit 1 = selected.
    GroupFlags: array of Byte;
    CursorKnown, CursorVisible: Boolean;
    CursorX, CursorY: Word;
    CursorShapeKnown: Boolean;
    CursorShapeRevision: Cardinal;
    FlightCursor, FlightCursorVisible: Boolean;
    FlightCursorX, FlightCursorY: Word;
  end;

procedure InitFlow(var State: TKvmFlowState);
// Geometry change waits for the current window to drain before sending S.
procedure InvalidateFlowGeometry(var State: TKvmFlowState);
function RequestFlowReset(var State: TKvmFlowState; NowTick: QWord): Boolean;
function FlowCanQueue(const State: TKvmFlowState): Boolean;
function PrepareFlowBatch(var State: TKvmFlowState;
  const Cache: array of RawByteString; const Versions: array of Cardinal;
  const Groups: array of Integer; CursorValid: Boolean; CursorX, CursorY: Word;
  CursorShapeRevision: Cardinal; CursorShapeBytes: Integer; NowTick: QWord;
  out Batch: TKvmFlowBatch; ByteBudget: Integer = KVM_BATCH_MAX_BYTES): Boolean; overload;
function PrepareFlowBatch(var State: TKvmFlowState;
  const Cache: array of RawByteString; const Versions: array of Cardinal;
  const Groups: array of Integer; CursorValid: Boolean; CursorX, CursorY: Word; NowTick: QWord;
  out Batch: TKvmFlowBatch; ByteBudget: Integer = KVM_BATCH_MAX_BYTES): Boolean; overload;
function AcknowledgeFlowBatch(var State: TKvmFlowState; Serial: Cardinal;
  NowTick: QWord = 0): Boolean;
function CancelPreparedFlowBatch(var State: TKvmFlowState; Serial: Cardinal;
  SentScreen: Boolean): Boolean;
function RejectFlowBatch(var State: TKvmFlowState; Serial: Cardinal): Boolean;
function FlowTimedOut(const State: TKvmFlowState; NowTick: QWord): Boolean;

implementation

procedure ClearFlight(var Flight: TKvmFlowFlight);
begin
  Flight.Serial := 0;
  Flight.SentTick := 0;
  Flight.PayloadBytes := 0;
  SetLength(Flight.Versions, 0);
  Flight.Cursor := False;
  Flight.CursorShape := False;
  Flight.CursorVisible := False;
  Flight.CursorX := 0;
  Flight.CursorY := 0;
  Flight.CursorShapeRevision := 0;
end;

procedure SyncOldestFlight(var State: TKvmFlowState);
begin
  State.WaitingAck := State.FlightCount > 0;
  if State.FlightCount > 0 then
  begin
    State.FlightSerial := State.Flights[0].Serial;
    State.LastSentTick := State.Flights[0].SentTick;
    State.FlightVersions := State.Flights[0].Versions;
    State.FlightCursor := State.Flights[0].Cursor;
    State.FlightCursorVisible := State.Flights[0].CursorVisible;
    State.FlightCursorX := State.Flights[0].CursorX;
    State.FlightCursorY := State.Flights[0].CursorY;
  end
  else
  begin
    State.FlightSerial := 0;
    State.LastSentTick := 0;
    SetLength(State.FlightVersions, 0);
    State.FlightCursor := False;
    State.FlightCursorVisible := False;
    State.FlightCursorX := 0;
    State.FlightCursorY := 0;
  end;
end;

procedure ClearFlights(var State: TKvmFlowState);
var I: Integer;
begin
  for I := 0 to KVM_FLOW_MAX_IN_FLIGHT - 1 do ClearFlight(State.Flights[I]);
  State.FlightCount := 0;
  SyncOldestFlight(State);
end;

procedure ResetToScreen(var State: TKvmFlowState);
begin
  State.NeedScreen := True;
  State.NextTile := 0;
  State.CursorKnown := False;
  State.CursorVisible := False;
  State.CursorShapeKnown := False;
  State.CursorShapeRevision := 0;
  SetLength(State.AckedVersions, 0);
end;

procedure InitFlow(var State: TKvmFlowState);
begin
  State.Serial := 0;
  State.LastResyncTick := 0;
  State.LastAckElapsedMs := 0;
  State.LastAckBytes := 0;
  SetLength(State.GroupFlags, 0);
  ClearFlights(State);
  ResetToScreen(State);
end;

procedure InvalidateFlowGeometry(var State: TKvmFlowState);
begin
  // Ordered old batches may still be decoded safely. Do not put a new screen
  // geometry in front of them; PrepareFlowBatch resumes once they are ACKed.
  State.NeedScreen := True;
end;

function RequestFlowReset(var State: TKvmFlowState; NowTick: QWord): Boolean;
begin
  Result := False;
  if (State.LastResyncTick <> 0) and
     (NowTick - State.LastResyncTick < KVM_FLOW_RESYNC_INTERVAL_MS) then Exit;
  State.NeedScreen := True;
  if State.FlightCount = 0 then ResetToScreen(State);
  State.LastResyncTick := NowTick;
  Result := True;
end;

function FlowCanQueue(const State: TKvmFlowState): Boolean;
begin
  Result := (State.FlightCount < KVM_FLOW_MAX_IN_FLIGHT) and
    not (State.NeedScreen and (State.FlightCount > 0));
end;

function VersionPending(const State: TKvmFlowState; Index: Integer;
  Version: Cardinal): Boolean;
var I: Integer;
begin
  Result := False;
  if Version = 0 then Exit;
  for I := 0 to State.FlightCount - 1 do
    if (Index >= 0) and (Index < Length(State.Flights[I].Versions)) and
       (State.Flights[I].Versions[Index] = Version) then Exit(True);
end;

function PrepareFlowBatch(var State: TKvmFlowState;
  const Cache: array of RawByteString; const Versions: array of Cardinal;
  const Groups: array of Integer; CursorValid: Boolean; CursorX, CursorY: Word;
  CursorShapeRevision: Cardinal; CursorShapeBytes: Integer; NowTick: QWord;
  out Batch: TKvmFlowBatch; ByteBudget: Integer): Boolean;
var
  N, J, I, F, Leader, Added, Bytes, StartTile, Candidate: Integer;
  EffectiveKnown, EffectiveVisible: Boolean;
  EffectiveShapeKnown, ShapeChanged: Boolean;
  EffectiveX, EffectiveY: Word;
  EffectiveShapeRevision: Cardinal;
  Flight: TKvmFlowFlight;
begin
  Result := False;
  Batch.Serial := 0;
  Batch.PayloadBytes := 0;
  if ByteBudget < 1 then ByteBudget := 1;
  if ByteBudget > KVM_BATCH_MAX_BYTES then ByteBudget := KVM_BATCH_MAX_BYTES;
  Batch.SendScreen := False;
  Batch.SendCursor := False;
  Batch.SendCursorShape := False;
  Batch.CursorShapeRevision := 0;
  SetLength(Batch.Indices, 0);
  Flight.Serial := 0;
  Flight.SentTick := 0;
  Flight.PayloadBytes := 0;
  Flight.Cursor := False;
  Flight.CursorShape := False;
  Flight.CursorVisible := False;
  Flight.CursorX := 0;
  Flight.CursorY := 0;
  Flight.CursorShapeRevision := 0;
  N := Length(Cache);
  if (N = 0) or (N <> Length(Versions)) or (N <> Length(Groups)) or
     not FlowCanQueue(State) then Exit;

  if Length(State.AckedVersions) <> N then State.NeedScreen := True;
  // A geometry/profile reset is ordered after every already queued batch.
  if State.NeedScreen and (State.FlightCount > 0) then Exit;
  if State.NeedScreen then
  begin
    SetLength(State.AckedVersions, N);
    for J := 0 to N - 1 do State.AckedVersions[J] := 0;
    State.NextTile := 0;
    State.CursorKnown := False;
    State.CursorVisible := False;
    State.CursorShapeKnown := False;
    State.CursorShapeRevision := 0;
    Batch.SendScreen := True;
    State.NeedScreen := False;
  end;

  SetLength(Flight.Versions, N);
  SetLength(State.GroupFlags, N);
  for J := 0 to N - 1 do
  begin
    Flight.Versions[J] := 0;
    State.GroupFlags[J] := 0;
  end;
  // A current version is stale only if it is neither ACKed nor already in
  // one of the at-most-three outstanding flights. This remains O(N).
  for J := 0 to N - 1 do
  begin
    Leader := Groups[J];
    if (Leader >= 0) and (Leader < N) and
       (State.AckedVersions[J] <> Versions[J]) and
       not VersionPending(State, J, Versions[J]) then
      State.GroupFlags[Leader] := 1;
  end;
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
    if State.GroupFlags[I] = 0 then Continue;
    Candidate := Length(Cache[I]);
    if (Candidate > KVM_MAX_VIDEO_BYTES + KVM_VIDEO_HEADER) or (Candidate < 13) or
       not (Cache[I][1] in ['T','V']) then Continue;
    if (Added >= KVM_BATCH_MAX_TILES) or
       ((Added > 0) and (Bytes + Candidate > ByteBudget)) then Break;
    if Added = 0 then
    begin
      if N < KVM_BATCH_MAX_TILES then SetLength(Batch.Indices, N)
      else SetLength(Batch.Indices, KVM_BATCH_MAX_TILES);
    end;
    Batch.Indices[Added] := I;
    State.GroupFlags[I] := State.GroupFlags[I] or 2;
    Inc(Added);
    Inc(Bytes, Candidate);
    State.NextTile := (I + 1) mod N;
  end;

  SetLength(Batch.Indices, Added);
  // Snapshot exactly the versions sent, including non-leader members.
  for J := 0 to N - 1 do
  begin
    Leader := Groups[J];
    if (Leader >= 0) and (Leader < N) and
       ((State.GroupFlags[Leader] and 2) <> 0) then
      Flight.Versions[J] := Versions[J];
  end;

  // Compare the pointer against the state that will exist after all queued
  // flights ahead of this one have been composited, not only against ACKed C.
  EffectiveKnown := State.CursorKnown;
  EffectiveVisible := State.CursorVisible;
  EffectiveX := State.CursorX;
  EffectiveY := State.CursorY;
  EffectiveShapeKnown := State.CursorShapeKnown;
  EffectiveShapeRevision := State.CursorShapeRevision;
  for F := 0 to State.FlightCount - 1 do
  begin
    if State.Flights[F].Cursor then
    begin
      EffectiveKnown := True;
      EffectiveVisible := State.Flights[F].CursorVisible;
      EffectiveX := State.Flights[F].CursorX;
      EffectiveY := State.Flights[F].CursorY;
    end;
    if State.Flights[F].CursorShape then
    begin
      EffectiveShapeKnown := True;
      EffectiveShapeRevision := State.Flights[F].CursorShapeRevision;
    end;
  end;
  ShapeChanged := CursorValid and (CursorShapeRevision<>0) and
    ((not EffectiveShapeKnown) or (CursorShapeRevision<>EffectiveShapeRevision));
  Batch.SendCursorShape := ShapeChanged and (CursorShapeBytes>KVM_CURSOR_SHAPE_HEADER);
  if Batch.SendCursorShape then Batch.CursorShapeRevision:=CursorShapeRevision;
  Batch.SendCursor := (not EffectiveKnown) or (CursorValid <> EffectiveVisible) or
    (CursorValid and ((CursorX <> EffectiveX) or (CursorY <> EffectiveY))) or
    Batch.SendCursorShape;
  Batch.CursorVisible := CursorValid;
  if Batch.SendCursor then
  begin
    Batch.CursorX := CursorX;
    Batch.CursorY := CursorY;
    Flight.CursorVisible := CursorValid;
    Flight.CursorX := CursorX;
    Flight.CursorY := CursorY;
  end;
  Flight.Cursor := Batch.SendCursor;
  Flight.CursorShape := Batch.SendCursorShape;
  Flight.CursorShapeRevision := Batch.CursorShapeRevision;

  // A no-change frame does not consume a slot in the ACK window.
  if (Added = 0) and not Batch.SendScreen and not Batch.SendCursor then Exit;

  // Explicit wrap also works with FPC overflow checking enabled (-Co).
  if State.Serial = High(Cardinal) then State.Serial := 1
  else Inc(State.Serial);
  Flight.Serial := State.Serial;
  Flight.SentTick := NowTick;
  Batch.Serial := Flight.Serial;
  Batch.PayloadBytes := Bytes + 5;
  if Batch.SendScreen then Inc(Batch.PayloadBytes, 5);
  if Batch.SendCursor then Inc(Batch.PayloadBytes, 6);
  if Batch.SendCursorShape then Inc(Batch.PayloadBytes, CursorShapeBytes);
  Flight.PayloadBytes := Batch.PayloadBytes;

  // FlowCanQueue guaranteed a free slot above.
  State.Flights[State.FlightCount] := Flight;
  Inc(State.FlightCount);
  SyncOldestFlight(State);
  Result := True;
end;

function PrepareFlowBatch(var State: TKvmFlowState;
  const Cache: array of RawByteString; const Versions: array of Cardinal;
  const Groups: array of Integer; CursorValid: Boolean; CursorX, CursorY: Word; NowTick: QWord;
  out Batch: TKvmFlowBatch; ByteBudget: Integer): Boolean;
begin
  Result:=PrepareFlowBatch(State,Cache,Versions,Groups,CursorValid,CursorX,CursorY,
    0,0,NowTick,Batch,ByteBudget);
end;

function AcknowledgeFlowBatch(var State: TKvmFlowState; Serial: Cardinal;
  NowTick: QWord): Boolean;
var
  I, J, Match, OldCount, Remaining, Limit: Integer;
begin
  Result := False;
  if Serial = 0 then Exit;
  Match := -1;
  for I := 0 to State.FlightCount - 1 do
    if State.Flights[I].Serial = Serial then
    begin Match := I; Break; end;
  if Match < 0 then Exit;

  State.LastAckBytes := State.Flights[Match].PayloadBytes;
  if (NowTick <> 0) and (NowTick >= State.Flights[Match].SentTick) then
    State.LastAckElapsedMs := NowTick - State.Flights[Match].SentTick
  else State.LastAckElapsedMs := 0;

  // WebSocket ordering means ACKing a later serial also proves every earlier
  // batch was received and composited. Apply them in order so versions never
  // regress if an ACK is coalesced or an earlier ACK is delayed.
  for J := 0 to Match do
  begin
    Limit := Length(State.Flights[J].Versions);
    if Limit > Length(State.AckedVersions) then Limit := Length(State.AckedVersions);
    for I := 0 to Limit - 1 do
      if State.Flights[J].Versions[I] <> 0 then
        State.AckedVersions[I] := State.Flights[J].Versions[I];
    if State.Flights[J].Cursor then
    begin
      State.CursorKnown := True;
      State.CursorVisible := State.Flights[J].CursorVisible;
      State.CursorX := State.Flights[J].CursorX;
      State.CursorY := State.Flights[J].CursorY;
    end;
    if State.Flights[J].CursorShape then
    begin
      State.CursorShapeKnown:=True;
      State.CursorShapeRevision:=State.Flights[J].CursorShapeRevision;
    end;
  end;

  OldCount := State.FlightCount;
  Remaining := OldCount - Match - 1;
  for I := 0 to Remaining - 1 do
    State.Flights[I] := State.Flights[Match + 1 + I];
  for I := Remaining to OldCount - 1 do ClearFlight(State.Flights[I]);
  State.FlightCount := Remaining;
  SyncOldestFlight(State);
  Result := True;
end;

function CancelPreparedFlowBatch(var State: TKvmFlowState; Serial: Cardinal;
  SentScreen: Boolean): Boolean;
var Last: Integer;
begin
  Result := False;
  if (Serial = 0) or (State.FlightCount < 1) then Exit;
  Last := State.FlightCount - 1;
  // Only a batch that has just been prepared but not queued may be rolled
  // back. Earlier flights may already be on the wire and must remain intact.
  if State.Flights[Last].Serial <> Serial then Exit;
  ClearFlight(State.Flights[Last]);
  Dec(State.FlightCount);
  SyncOldestFlight(State);
  if SentScreen then
  begin
    // PrepareFlowBatch consumed NeedScreen before the transport enqueue. If
    // nothing was queued, restore the initial-screen requirement for retry.
    ResetToScreen(State);
  end;
  Result := True;
end;

function RejectFlowBatch(var State: TKvmFlowState; Serial: Cardinal): Boolean;
var I: Integer;
begin
  Result := False;
  if Serial = 0 then Exit;
  for I := 0 to State.FlightCount - 1 do
    if State.Flights[I].Serial = Serial then
    begin Result := True; Break; end;
  if not Result then Exit;
  // A failed batch invalidates any later deltas already queued after it.
  // Their eventual ACK/NACK is stale and ignored; the next valid batch starts
  // with S and a complete version baseline.
  ClearFlights(State);
  ResetToScreen(State);
end;

function FlowTimedOut(const State: TKvmFlowState; NowTick: QWord): Boolean;
begin
  Result := (State.FlightCount > 0) and
    (NowTick >= State.Flights[0].SentTick) and
    (NowTick - State.Flights[0].SentTick > KVM_FLOW_ACK_TIMEOUT_MS);
end;

end.

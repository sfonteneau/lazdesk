program test_flow;

{$mode objfpc}{$H+}

uses SysUtils, kvm_wire, kvm_flow;

procedure Check(Condition: Boolean; const Msg: string);
begin
  if not Condition then
  begin
    WriteLn('FAIL: ', Msg);
    Halt(1);
  end;
end;

var
  State: TKvmFlowState;
  Batch: TKvmFlowBatch;
  Cache: array of RawByteString;
  Versions: array of Cardinal;
  Groups: array of Integer;
  Seen: array of Boolean;
  I, J, Received: Integer;
  S1, S2, S3, S4, OldVersion: Cardinal;
begin
  SetLength(Cache, 70);
  SetLength(Versions, 70);
  SetLength(Groups, 70);
  SetLength(Seen, 70);
  for I := 0 to 69 do
  begin
    Cache[I] := MakeTile(0, 0, 1, 1, #$ff + #$d8 + #$ff + #$d9);
    Versions[I] := 1;
    Groups[I] := I;
    Seen[I] := False;
  end;

  InitFlow(State);
  Check(FlowCanQueue(State), 'fresh flow can queue');
  Check(PrepareFlowBatch(State, Cache, Versions, Groups, True, 17, 23, 1000, Batch),
    'first window batch');
  S1 := Batch.Serial;
  Check(Batch.SendScreen and Batch.SendCursor, 'first batch carries S and C');
  Check(Length(Batch.Indices) = KVM_BATCH_MAX_TILES, 'first tile cap');
  for J := 0 to High(Batch.Indices) do
  begin Check(not Seen[Batch.Indices[J]], 'no duplicate in batch 1'); Seen[Batch.Indices[J]] := True; end;

  Check(PrepareFlowBatch(State, Cache, Versions, Groups, True, 17, 23, 1001, Batch),
    'second batch before ACK');
  S2 := Batch.Serial;
  Check(not Batch.SendScreen and not Batch.SendCursor, 'S/C not duplicated while pending');
  for J := 0 to High(Batch.Indices) do
  begin Check(not Seen[Batch.Indices[J]], 'no duplicate in batch 2'); Seen[Batch.Indices[J]] := True; end;

  Check(PrepareFlowBatch(State, Cache, Versions, Groups, True, 17, 23, 1002, Batch),
    'third batch before ACK');
  S3 := Batch.Serial;
  for J := 0 to High(Batch.Indices) do
  begin Check(not Seen[Batch.Indices[J]], 'no duplicate in batch 3'); Seen[Batch.Indices[J]] := True; end;
  Check(State.FlightCount = KVM_FLOW_MAX_IN_FLIGHT, 'window reaches three flights');
  Check(not FlowCanQueue(State), 'full window applies backpressure');
  Check(not PrepareFlowBatch(State, Cache, Versions, Groups, True, 17, 23, 1003, Batch),
    'fourth flight blocked by window');
  Check(FlowTimedOut(State, 21001), 'timeout uses oldest flight');
  Check(not AcknowledgeFlowBatch(State, 999, 1010), 'unknown ACK rejected');

  Check(AcknowledgeFlowBatch(State, S1, 1010), 'ACK oldest flight');
  Check((State.LastAckElapsedMs = 10) and (State.FlightCount = 2), 'ACK metrics and window release');
  Check(PrepareFlowBatch(State, Cache, Versions, Groups, True, 17, 23, 1011, Batch),
    'released slot sends remaining tiles');
  S4 := Batch.Serial;
  for J := 0 to High(Batch.Indices) do
  begin Check(not Seen[Batch.Indices[J]], 'no duplicate in batch 4'); Seen[Batch.Indices[J]] := True; end;
  Received := 0;
  for I := 0 to 69 do if Seen[I] then Inc(Received);
  Check(Received = 70, 'all initial tiles queued exactly once');

  Check(AcknowledgeFlowBatch(State, S2, 1020), 'ACK second flight');
  // ACKing the newest outstanding serial cumulatively proves S3 then S4,
  // because both WebSocket directions preserve message order.
  Check(AcknowledgeFlowBatch(State, S4, 1030), 'later ACK cumulatively drains prior flight');
  Check(State.FlightCount = 0, 'window fully drained');
  Check(not AcknowledgeFlowBatch(State, S3, 1031), 'coalesced older ACK is stale');
  for I := 0 to High(State.AckedVersions) do
    Check(State.AckedVersions[I] = Versions[I], 'initial version ACKed');

  // A newer version may follow an older unacknowledged version in another
  // window slot, but the exact same current version is never duplicated.
  Inc(Versions[0]); OldVersion := Versions[0];
  Check(PrepareFlowBatch(State, Cache, Versions, Groups, True, 17, 23, 2000, Batch),
    'old changed version queued');
  S1 := Batch.Serial;
  Check((Length(Batch.Indices) = 1) and (Batch.Indices[0] = 0), 'single changed tile');
  Inc(Versions[0]);
  Check(PrepareFlowBatch(State, Cache, Versions, Groups, True, 17, 23, 2001, Batch),
    'newer version follows before ACK');
  S2 := Batch.Serial;
  Check((Length(Batch.Indices) = 1) and (Batch.Indices[0] = 0), 'newer same tile queued');
  Check(not PrepareFlowBatch(State, Cache, Versions, Groups, True, 17, 23, 2002, Batch),
    'current version not duplicated while pending');
  Check(AcknowledgeFlowBatch(State, S1, 2010), 'ACK old changed version');
  Check(State.AckedVersions[0] = OldVersion, 'old version committed first');
  Check(AcknowledgeFlowBatch(State, S2, 2011), 'ACK newest version');
  Check(State.AckedVersions[0] = Versions[0], 'newest version committed');

  // Cursor updates are pipelined using the effective pending state.
  Check(PrepareFlowBatch(State, Cache, Versions, Groups, True, 44, 55, 3000, Batch),
    'cursor flight');
  S1 := Batch.Serial;
  Check(Batch.SendCursor and (Length(Batch.Indices) = 0), 'cursor-only batch');
  Check(not PrepareFlowBatch(State, Cache, Versions, Groups, True, 44, 55, 3001, Batch),
    'same pending cursor not duplicated');
  Check(PrepareFlowBatch(State, Cache, Versions, Groups, True, 45, 55, 3002, Batch),
    'new cursor follows before ACK');
  S2 := Batch.Serial;
  Check(AcknowledgeFlowBatch(State, S2, 3010), 'new cursor ACK also covers prior cursor');
  Check((State.CursorX = 45) and (State.CursorY = 55), 'latest cursor committed');
  Check(not AcknowledgeFlowBatch(State, S1, 3011), 'prior cursor ACK now stale');

  // Geometry reset never interleaves a new S ahead of old-geometry flights.
  InvalidateFlowGeometry(State);
  Check(PrepareFlowBatch(State, Cache, Versions, Groups, True, 45, 55, 4000, Batch),
    'geometry reset starts after empty window');
  Check(Batch.SendScreen, 'geometry reset sends S');
  S1 := Batch.Serial;
  InvalidateFlowGeometry(State);
  Check(not FlowCanQueue(State), 'second geometry reset waits for in-flight data');
  Check(not PrepareFlowBatch(State, Cache, Versions, Groups, True, 45, 55, 4001, Batch),
    'no geometry mixing');
  Check(AcknowledgeFlowBatch(State, S1, 4010), 'ACK old geometry flight');
  Check(PrepareFlowBatch(State, Cache, Versions, Groups, True, 45, 55, 4011, Batch),
    'queued geometry reset resumes');
  Check(Batch.SendScreen, 'resumed reset sends S');
  S1 := Batch.Serial;

  // A real client NACK flushes the complete delta window and forces the next
  // accepted packet sequence to restart with S. Local transport backpressure
  // is tested separately below and must not cause this reset.
  Check(AcknowledgeFlowBatch(State, S1, 4020), 'ACK reset');
  Inc(Versions[1]);
  Check(PrepareFlowBatch(State, Cache, Versions, Groups, True, 45, 55, 5000, Batch),
    'flight before NACK');
  S1 := Batch.Serial;
  Inc(Versions[2]);
  Check(PrepareFlowBatch(State, Cache, Versions, Groups, True, 45, 55, 5001, Batch),
    'later flight before NACK');
  S2 := Batch.Serial;
  Check(RejectFlowBatch(State, S1), 'NACK flushes matching window');
  Check((State.FlightCount = 0) and State.NeedScreen, 'NACK requests full reset');
  Check(not AcknowledgeFlowBatch(State, S2, 5010), 'later ACK is stale after NACK');
  Check(PrepareFlowBatch(State, Cache, Versions, Groups, True, 45, 55, 5011, Batch, 1),
    'resync after NACK');
  Check(Batch.SendScreen and (Length(Batch.Indices) = 1), 'resync starts with bounded S batch');
  S1 := Batch.Serial;
  Check(AcknowledgeFlowBatch(State,S1,5020),'ACK bounded resync');

  // A prepared batch which never reaches the socket is only rolled back. It
  // must be rebuilt later from the current cache without losing earlier ACKs.
  Inc(Versions[3]);
  Check(PrepareFlowBatch(State,Cache,Versions,Groups,True,45,55,6000,Batch),
    'batch prepared before local queue backpressure');
  S1:=Batch.Serial;
  Check(not Batch.SendScreen,'ordinary backpressure batch is delta-only');
  Check(CancelPreparedFlowBatch(State,S1,False),'cancel newest unqueued delta');
  Check((State.FlightCount=0) and not State.NeedScreen,
    'local backpressure preserves acknowledged screen state');
  Check(PrepareFlowBatch(State,Cache,Versions,Groups,True,45,55,6001,Batch),
    'canceled delta can be rebuilt immediately');
  Check((not Batch.SendScreen) and (Length(Batch.Indices)>=1),
    'rebuilt delta does not force full resync');
  S1:=Batch.Serial;
  Check(AcknowledgeFlowBatch(State,S1,6010),'ACK rebuilt delta');

  InitFlow(State);
  Check(PrepareFlowBatch(State,Cache,Versions,Groups,True,45,55,7000,Batch,1),
    'initial screen prepared before local queue backpressure');
  S1:=Batch.Serial;
  Check(Batch.SendScreen,'initial prepared batch contains screen');
  Check(CancelPreparedFlowBatch(State,S1,True),'cancel newest unqueued screen batch');
  Check((State.FlightCount=0) and State.NeedScreen,
    'canceled screen batch restores screen requirement');
  Check(PrepareFlowBatch(State,Cache,Versions,Groups,True,45,55,7001,Batch,1),
    'screen batch retries after backpressure');
  Check(Batch.SendScreen,'retry still carries screen');

  WriteLn('OK: three-flight ACK window, local backpressure rollback, cursor pipeline, timeout, NACK and geometry resync');
end.

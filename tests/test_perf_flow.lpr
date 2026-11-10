program test_perf_flow;
{$mode objfpc}{$H+}

// Randomized invariants for the sliding ACK window. This replaces the old
// differential test against stop-and-wait, whose behavior is intentionally no
// longer equivalent.

uses SysUtils, kvm_wire, kvm_flow;

procedure Check(OK: Boolean; const Msg: string);
begin if not OK then raise Exception.Create(Msg); end;

var
  State: TKvmFlowState;
  Batch: TKvmFlowBatch;
  Cache: array of RawByteString;
  Versions: array of Cardinal;
  Groups: array of Integer;
  Step, I, N, Op: Integer;
  NowTick: QWord;
  CX, CY: Word;
  Visible: Boolean;
  Serial: Cardinal;
begin
  RandSeed := 19372;
  N := 257;
  SetLength(Cache,N); SetLength(Versions,N); SetLength(Groups,N);
  for I := 0 to N-1 do
  begin
    Cache[I] := MakeTile(0,0,1,1,StringOfChar('x',4+Random(512)));
    Versions[I] := 1;
    Groups[I] := I;
  end;
  InitFlow(State);
  NowTick := 1000; CX := 0; CY := 0; Visible := False;
  for Step := 1 to 30000 do
  begin
    Inc(NowTick, 1 + Random(4));
    for I := 1 to Random(4) do
    begin
      Op := Random(N);
      if Versions[Op] = High(Cardinal) then Versions[Op] := 1 else Inc(Versions[Op]);
    end;
    if Random(25)=0 then
    begin CX:=Random(65536); CY:=Random(65536); Visible:=not Visible; end;
    if Random(500)=0 then InvalidateFlowGeometry(State);

    if FlowCanQueue(State) and (Random(3)<>0) then
      PrepareFlowBatch(State,Cache,Versions,Groups,Visible,CX,CY,NowTick,Batch,
        1+Random(KVM_BATCH_MAX_BYTES));

    Check((State.FlightCount >= 0) and
      (State.FlightCount <= KVM_FLOW_MAX_IN_FLIGHT), 'window bounds');
    Check(State.WaitingAck = (State.FlightCount > 0), 'legacy waiting flag');
    if State.FlightCount > 0 then
    begin
      Check(State.FlightSerial = State.Flights[0].Serial, 'oldest serial mirror');
      Check(State.LastSentTick = State.Flights[0].SentTick, 'oldest tick mirror');
    end;

    Op := Random(10);
    if (State.FlightCount > 0) and (Op < 4) then
    begin
      // Usually ACK the head, occasionally a later flight to exercise the
      // cumulative ordered-transport path.
      I := 0;
      if (State.FlightCount > 1) and (Random(5)=0) then I := Random(State.FlightCount);
      Serial := State.Flights[I].Serial;
      Check(AcknowledgeFlowBatch(State,Serial,NowTick), 'valid ACK');
    end
    else if (State.FlightCount > 0) and (Op = 4) then
    begin
      Serial := State.Flights[Random(State.FlightCount)].Serial;
      Check(RejectFlowBatch(State,Serial), 'valid NACK');
    end
    else if Op = 5 then
      Check(not AcknowledgeFlowBatch(State,0,NowTick), 'zero ACK rejected');
  end;
  WriteLn('PASS: 30000 randomized sliding-window flow steps and invariants');
end.

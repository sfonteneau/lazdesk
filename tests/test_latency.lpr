program test_latency;
{$mode objfpc}{$H+}
uses SysUtils, kvm_wire, kvm_input_queue, kvm_adaptive;
var
  Q: TKvmInputQueue;
  P: RawByteString;
  Action, Button: Byte;
  X, Y: Word;
  A: TKvmAdaptiveState;
  I, Count: Integer;
procedure Check(Value: Boolean; const Msg: string);
begin
  Inc(Count);
  if not Value then raise Exception.Create(Msg);
end;
procedure CheckMove(const Packet: RawByteString; WantX: Word);
begin
  Check(ReadMouse(Packet,Action,Button,X,Y),'mouse packet valid');
  Check((Action=0) and (Button=0) and (X=WantX),'latest mouse move');
end;
begin
  Count:=0;
  Q:=TKvmInputQueue.Create;
  try
    Check(Q.Push(MakeMouse(0,0,1,20)),'first move');
    Check(Q.Push(MakeMouse(0,0,2,20)),'second move');
    Check(Q.Push(MakeKey(True,$41)),'key down');
    Check(Q.Push(MakeMouse(0,0,3,20)),'third move');
    Check(Q.Push(MakeMouse(0,0,4,20)),'fourth move');
    Check(Q.Take(1,P),'take first move'); CheckMove(P,2);
    Check(Q.Take(1,P) and (P=MakeKey(True,$41)),'key preserved');
    Check(Q.Take(1,P),'take last move'); CheckMove(P,4);
    Check(not Q.Take(1,P),'no stale moves');

    Check(Q.Push(MakeMouse(1,1,10,20)),'mouse button down');
    Check(Q.Push(MakeMouse(0,0,11,20)),'drag 1');
    Check(Q.Push(MakeMouse(0,0,12,20)),'drag 2');
    Check(Q.Push(MakeMouse(2,1,12,20)),'mouse button up');
    Check(Q.Take(2,P) and (P=MakeMouse(1,1,10,20)),'down preserved');
    Check(Q.Take(2,P),'latest drag'); CheckMove(P,12);
    Check(Q.Take(2,P) and (P=MakeMouse(2,1,12,20)),'up preserved');
    Check(not Q.Take(2,P),'no leftovers');

    for I:=1 to 1000 do
      Check(Q.Push(MakeMouse(0,0,Word(I),20)),'burst coalescing');
    Check(Q.Take(3,P),'burst last move'); CheckMove(P,1000);
    Check(not Q.Take(3,P),'burst must not overflow queue');
  finally
    Q.Free;
  end;
  InitAdaptive(A);
  Check(AdaptiveBudget(A)=1024*1024,'initial LAN budget');
  A.BytesPerSecond:=1024*1024;
  Check(AdaptiveBudget(A)=512*1024,'minimum burst budget');
  A.BytesPerSecond:=80*1024*1024;
  Check(AdaptiveBudget(A)=2*1024*1024,'fast-link budget cap');
  WriteLn('PASS ',Count,' latency/input assertions');
end.

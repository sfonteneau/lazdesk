unit kvm_schedule;
{$mode objfpc}{$H+}
// Capture cadence is independent from draining already encoded rectangles.
interface
function CaptureIsDue(NowTick, DueTick: QWord): Boolean;
function NextCaptureTick(Started, Finished: QWord; FPS: Integer): QWord;
function CaptureWaitMs(NowTick, DueTick: QWord; Maximum: Cardinal): Cardinal;
implementation
function CaptureIsDue(NowTick, DueTick: QWord): Boolean;
begin Result:=(DueTick=0) or (NowTick>=DueTick); end;
function NextCaptureTick(Started, Finished: QWord; FPS: Integer): QWord;
var Interval: Cardinal;
begin
  // 0 = no frame-rate deadline. The capture loop still yields and retains
  // one acknowledged batch per client, so this is not an unbounded queue.
  if FPS<=0 then Exit(Finished);
  // GetTickCount64 has millisecond granularity. Requested rates >= 1000
  // therefore share the minimum 1 ms scheduling interval.
  if FPS>=1000 then Interval:=1
  else Interval:=(1000+Cardinal(FPS)-1) div Cardinal(FPS);
  Result:=Started+Interval;
  // A late capture must not add a full frame period to its processing time,
  // and must not run a burst of old deadlines to "catch up" either.
  if Result<Finished then Result:=Finished;
end;
function CaptureWaitMs(NowTick, DueTick: QWord; Maximum: Cardinal): Cardinal;
begin
  if CaptureIsDue(NowTick,DueTick) then Exit(0);
  if DueTick-NowTick>Maximum then Exit(Maximum);
  Result:=DueTick-NowTick;
end;
end.

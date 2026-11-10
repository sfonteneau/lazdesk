unit kvm_adaptive;
{$mode objfpc}{$H+}
// Per-client ACK feedback. Three shared encoding profiles, not one global
// quality dragged down by the slowest viewer. No wall-clock time involved.
interface
const KVM_PROFILE_COUNT = 3;
type
  TKvmAdaptiveState = record
    Profile: Integer; // 0=full, 1=balanced, 2=low bandwidth
    SlowCount, FastCount: Integer;
    SmoothedAckMs: QWord;
    BytesPerSecond: QWord;
    LastChangeTick, NextSendTick: QWord;
    FlightBytes: Integer;
  end;
procedure InitAdaptive(var S: TKvmAdaptiveState);
procedure ProfileSettings(Profile, BaseW, BaseH, BaseQuality, BaseFps: Integer;
  out W, H, Quality, FPS: Integer);
function ObserveAck(var S: TKvmAdaptiveState; NowTick, ElapsedMs: QWord;
  Bytes: Integer; Enabled: Boolean): Boolean;
function AdaptiveBudget(const S: TKvmAdaptiveState): Integer;
implementation
uses Math;
procedure InitAdaptive(var S: TKvmAdaptiveState);
begin FillChar(S, SizeOf(S), 0); end;
procedure ProfileSettings(Profile, BaseW, BaseH, BaseQuality, BaseFps: Integer;
  out W, H, Quality, FPS: Integer);
begin
  W := BaseW; H := BaseH; Quality := BaseQuality; FPS := BaseFps;
  case Profile of
    1: begin W := Max(1, BaseW * 3 div 4); H := Max(1, BaseH * 3 div 4);
         Quality := Min(BaseQuality, 55);
         if BaseFps=0 then FPS:=30 else FPS:=Max(1, BaseFps div 2); end;
    2: begin W := Max(1, BaseW div 2); H := Max(1, BaseH div 2);
         Quality := Min(BaseQuality, 35);
         if BaseFps=0 then FPS:=10 else FPS:=Min(BaseFps, 3); end;
  end;
end;
function ObserveAck(var S: TKvmAdaptiveState; NowTick, ElapsedMs: QWord;
  Bytes: Integer; Enabled: Boolean): Boolean;
var Rate: QWord;
begin
  Result := False;
  // Cursor-only batches do not provide useful bandwidth measurements.
  if Bytes < 4096 then Exit;
  if ElapsedMs < 1 then ElapsedMs := 1;
  if ElapsedMs > 20000 then ElapsedMs := 20000;
  if S.SmoothedAckMs = 0 then S.SmoothedAckMs := ElapsedMs
  else S.SmoothedAckMs := (S.SmoothedAckMs * 3 + ElapsedMs) div 4;
  Rate := QWord(Bytes) * 1000 div ElapsedMs;
  if S.BytesPerSecond = 0 then S.BytesPerSecond := Rate
  else S.BytesPerSecond := (S.BytesPerSecond * 3 + Rate) div 4;
  if not Enabled then Exit;
  if S.SmoothedAckMs > 650 then
  begin Inc(S.SlowCount); S.FastCount := 0; end
  else if S.SmoothedAckMs < 220 then
  begin Inc(S.FastCount); S.SlowCount := 0; end
  else begin S.SlowCount := 0; S.FastCount := 0; end;
  // Hysteresis: one step at a time, no rapid resolution oscillation.
  if (S.LastChangeTick <> 0) and (NowTick - S.LastChangeTick < 5000) then Exit;
  if (S.SlowCount >= 3) and (S.Profile < KVM_PROFILE_COUNT - 1) then
  begin Inc(S.Profile); Result := True; end
  else if (S.FastCount >= 12) and (S.Profile > 0) then
  begin Dec(S.Profile); Result := True; end;
  if Result then
  begin S.LastChangeTick := NowTick; S.FastCount := 0; S.SlowCount := 0; end;
end;
function AdaptiveBudget(const S: TKvmAdaptiveState): Integer;
var B: QWord;
begin
  // Favor shorter in-flight batches so an updated desktop is visible sooner.
  // Preserve a nonzero floor to avoid RTT-bound one-tile traffic on WAN.
  if S.BytesPerSecond = 0 then Exit(1024 * 1024);
  // Up to three bounded batches may be in flight. Keep each batch large
  // enough for throughput, while the window hides ACK latency on a LAN.
  B := S.BytesPerSecond div 4; // about 250 ms of measured throughput
  if B < 512 * 1024 then B := 512 * 1024;
  if B > 2 * 1024 * 1024 then B := 2 * 1024 * 1024;
  Result := Integer(B);
end;
end.

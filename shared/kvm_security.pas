unit kvm_security;
{$mode objfpc}{$H+}
interface
uses SysUtils;
type
  TKvmRate = record
    Credits, Capacity, PerSecond: QWord;
    LastTick: QWord;
  end;
procedure InitRate(var R: TKvmRate; Capacity, PerSecond: Cardinal; NowTick: QWord);
function SpendRate(var R: TKvmRate; Cost: Cardinal; NowTick: QWord): Boolean;
function SecureTokenEqual(const A, B: RawByteString): Boolean;
function KvmLoopbackHost(const Host: string): Boolean;
implementation
procedure InitRate(var R: TKvmRate; Capacity, PerSecond: Cardinal; NowTick: QWord);
begin
  R.Capacity := QWord(Capacity)*1000; R.Credits := R.Capacity;
  R.PerSecond := PerSecond; R.LastTick := NowTick;
end;
function SpendRate(var R: TKvmRate; Cost: Cardinal; NowTick: QWord): Boolean;
var Delta, Added, Needed: QWord;
begin
  Delta := 0;
  if NowTick >= R.LastTick then Delta := NowTick-R.LastTick;
  R.LastTick := NowTick;
  if Delta > 60000 then Delta := 60000;
  Added := Delta * R.PerSecond;
  if (R.Credits > R.Capacity) or (Added >= R.Capacity-R.Credits) then R.Credits := R.Capacity
  else Inc(R.Credits, Added);
  Needed := QWord(Cost)*1000; Result := Needed <= R.Credits;
  if Result then Dec(R.Credits, Needed);
end;
function SecureTokenEqual(const A, B: RawByteString): Boolean;
var I: Integer; X,Y: Byte; Diff: Cardinal;
begin
  if (Length(A)>256) or (Length(B)>256) then Exit(False);
  Diff := Cardinal(Length(A)) xor Cardinal(Length(B));
  for I := 1 to 256 do
  begin
    X := 0; Y := 0;
    if I<=Length(A) then X := Ord(A[I]);
    if I<=Length(B) then Y := Ord(B[I]);
    Diff := Diff or (X xor Y);
  end;
  Result := (Diff=0) and (Length(A)>0);
end;
function KvmLoopbackHost(const Host: string): Boolean;
var S: string;
begin
  S := LowerCase(Trim(Host));
  // Deliberately only literal loopback; a DNS name can be rebound.
  Result := (S='127.0.0.1') or (S='::1') or (S='[::1]');
end;
end.

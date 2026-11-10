unit kvm_geometry;
{$mode objfpc}{$H+}
interface
type
  TKvmBounds = record X, Y, W, H: Integer; end;
function BoundsValid(const B: TKvmBounds): Boolean;
function NormalizePoint(const B: TKvmBounds; X, Y: Integer;
  out NX, NY: Word): Boolean;
function DenormalizePoint(const B: TKvmBounds; NX, NY: Word;
  out X, Y: Integer): Boolean;
implementation
uses Math;
function BoundsValid(const B: TKvmBounds): Boolean;
begin Result := (B.W > 0) and (B.H > 0); end;
function NormalizePoint(const B: TKvmBounds; X, Y: Integer;
  out NX, NY: Word): Boolean;
begin
  NX := 0; NY := 0;
  Result := BoundsValid(B) and (X >= B.X) and (Y >= B.Y) and
    (Int64(X) < Int64(B.X) + B.W) and (Int64(Y) < Int64(B.Y) + B.H);
  if not Result then Exit;
  if B.W > 1 then NX := Word((Int64(X - B.X) * 65535) div (B.W - 1));
  if B.H > 1 then NY := Word((Int64(Y - B.Y) * 65535) div (B.H - 1));
end;
function DenormalizePoint(const B: TKvmBounds; NX, NY: Word;
  out X, Y: Integer): Boolean;
begin
  Result := BoundsValid(B); X := 0; Y := 0;
  if not Result then Exit;
  X := B.X + Integer((Int64(NX) * (B.W - 1)) div 65535);
  Y := B.Y + Integer((Int64(NY) * (B.H - 1)) div 65535);
end;
end.

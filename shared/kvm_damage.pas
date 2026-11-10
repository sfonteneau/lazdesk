unit kvm_damage;

{$mode objfpc}{$H+}

// Exact RGB difference and bounded contiguous dirty-rectangle grouping.
// Tiles belonging to an old cached rectangle always change as a UNIT: this
// prevents old overlapping JPEG rectangles overwriting newer pixels during
// a viewer resynchronization or an incomplete ACK round.

interface

uses SysUtils, kvm_frame, kvm_wire;

type
  TKvmDirtyMap = array of Boolean;
  TKvmGroupMap = array of Integer;
  TKvmRegion = record
    Col, Row, Cols, Rows: Integer;
    X, Y, W, H: Integer;
    Leader: Integer;
  end;
  TKvmRegions = array of TKvmRegion;

function RegionTileChanged(const Current, Previous: TRgbFrame;
  X, Y, W, H: Integer): Boolean;
procedure CopyFrameReuse(const Source: TRgbFrame; var Target: TRgbFrame);
procedure CopyFrameRegions(const Source: TRgbFrame; var Target: TRgbFrame;
  const Regions: TKvmRegions);
procedure ExpandDirtyCacheGroups(var Dirty: TKvmDirtyMap;
  const OldGroups: TKvmGroupMap);
function MakeDirtyRegions(const Dirty: TKvmDirtyMap;
  Columns, Rows, Width, Height: Integer; out Regions: TKvmRegions;
  MaxTilesPerSide: Integer = 2): Boolean;
procedure AssignRegionGroups(const Regions: TKvmRegions;
  Columns: Integer; var Groups: TKvmGroupMap);

implementation

uses Math;

function RegionTileChanged(const Current, Previous: TRgbFrame;
  X, Y, W, H: Integer): Boolean;
var
  Row, Offset, ByteCount: Integer;
begin
  Result := True;
  if (Current.Order <> Previous.Order) or
     (Current.Width <> Previous.Width) or
     (Current.Height <> Previous.Height) or
     (Length(Current.RGB) <> Length(Previous.RGB)) or
     (Current.Width < 1) or (Current.Height < 1) or
     (Current.Width > KVM_MAX_FRAME_SIDE) or (Current.Height > KVM_MAX_FRAME_SIDE) or
     (Int64(Current.Width) * Current.Height > KVM_MAX_FRAME_PIXELS) or
     (Length(Current.RGB) <> Int64(Current.Width) * Current.Height * 3) or
     (X < 0) or (Y < 0) or (W <= 0) or (H <= 0) or
     (Int64(X) + W > Current.Width) or (Int64(Y) + H > Current.Height) then Exit;
  ByteCount := W * 3;
  for Row := Y to Y + H - 1 do
  begin
    Offset := (Row * Current.Width + X) * 3 + 1;
    if not CompareMem(@Current.RGB[Offset], @Previous.RGB[Offset], ByteCount) then
      Exit;
  end;
  Result := False;
end;

procedure CopyFrameReuse(const Source: TRgbFrame; var Target: TRgbFrame);
begin
  if Length(Source.RGB) <> Int64(Source.Width) * Source.Height * 3 then
    raise Exception.Create('Tampon source RGB incomplet.');
  if not AllocateFrame(Target, Source.Width, Source.Height) then
    raise Exception.Create('Invalid capture dimensions.');
  Target.Order := Source.Order;
  if Length(Source.RGB) > 0 then
    Move(Source.RGB[1], Target.RGB[1], Length(Source.RGB));
end;

procedure CopyFrameRegions(const Source: TRgbFrame; var Target: TRgbFrame;
  const Regions: TKvmRegions);
var
  I, Y, Offset, Count: Integer;
begin
  if (Source.Width < 1) or (Source.Height < 1) or
     (Length(Source.RGB) <> Int64(Source.Width) * Source.Height * 3) then
    raise Exception.Create('Invalid RGB source for the partial cache.');
  // First capture / resolution change must populate every pixel.
  if (Target.Order <> Source.Order) or
     (Target.Width <> Source.Width) or (Target.Height <> Source.Height) or
     (Length(Target.RGB) <> Length(Source.RGB)) then
  begin
    CopyFrameReuse(Source, Target);
    Exit;
  end;
  // Validate the whole region list BEFORE changing any reference pixel.
  for I := 0 to High(Regions) do
    if (Regions[I].X < 0) or (Regions[I].Y < 0) or
       (Regions[I].W < 1) or (Regions[I].H < 1) or
       (Int64(Regions[I].X) + Regions[I].W > Source.Width) or
       (Int64(Regions[I].Y) + Regions[I].H > Source.Height) then
      raise Exception.Create('Region RGB hors limites.');
  UniqueString(Target.RGB);
  for I := 0 to High(Regions) do
  begin
    Count := Regions[I].W * 3;
    for Y := Regions[I].Y to Regions[I].Y + Regions[I].H - 1 do
    begin
      Offset := (Y * Source.Width + Regions[I].X) * 3 + 1;
      Move(Source.RGB[Offset], Target.RGB[Offset], Count);
    end;
  end;
end;

procedure ExpandDirtyCacheGroups(var Dirty: TKvmDirtyMap;
  const OldGroups: TKvmGroupMap);
var
  T, I, Leader: Integer;
  Affected: TKvmDirtyMap;
begin
  if (Length(Dirty) <> Length(OldGroups)) then Exit;
  SetLength(Affected, Length(Dirty));
  for I := 0 to High(Dirty) do
    if Dirty[I] then
    begin
      Leader := OldGroups[I];
      if (Leader >= 0) and (Leader < Length(Dirty)) then
        Affected[Leader] := True;
    end;
  for T := 0 to High(Dirty) do
  begin
    Leader := OldGroups[T];
    if (Leader >= 0) and (Leader < Length(Affected)) then
      if Affected[Leader] then Dirty[T] := True;
  end;
end;

function MakeDirtyRegions(const Dirty: TKvmDirtyMap;
  Columns, Rows, Width, Height: Integer; out Regions: TKvmRegions;
  MaxTilesPerSide: Integer): Boolean;
var
  Used: TKvmDirtyMap;
  Row, Col, C, R, CW, RH, I, N, MaxCols, MaxRows: Integer;
  Ok: Boolean;
  Rect: TKvmRegion;
begin
  SetLength(Regions, 0);
  Result := (Width > 0) and (Height > 0) and
    (Width <= KVM_MAX_FRAME_SIDE) and (Height <= KVM_MAX_FRAME_SIDE) and
    (Columns > 0) and (Rows > 0) and
    (Columns = (Width + KVM_TILE_SIZE - 1) div KVM_TILE_SIZE) and
    (Rows = (Height + KVM_TILE_SIZE - 1) div KVM_TILE_SIZE) and
    (Length(Dirty) = Columns * Rows) and
    (Int64(Width) * Height <= KVM_MAX_FRAME_PIXELS);
  if not Result then Exit;
  // Allow a previously merged JPEG cache group to be safely split into
  // independent tiles on sparse updates. The caller already expanded all
  // old groups, so this rewrite always replaces *every* old group member.
  MaxCols := Min(Max(1, MaxTilesPerSide),
    KVM_MAX_RECT_WIDTH div KVM_TILE_SIZE);
  MaxRows := Min(Max(1, MaxTilesPerSide),
    KVM_MAX_RECT_HEIGHT div KVM_TILE_SIZE);
  N := 0;
  for I := 0 to High(Dirty) do if Dirty[I] then Inc(N);
  if N = 0 then Exit;
  SetLength(Used, Length(Dirty));
  SetLength(Regions, N); // at most one rectangle per dirty tile
  N := 0;
  for Row := 0 to Rows - 1 do
    for Col := 0 to Columns - 1 do
    begin
      I := Row * Columns + Col;
      if (not Dirty[I]) or Used[I] then Continue;
      CW := 1;
      while (CW < MaxCols) and
            (Col + CW < Columns) and
            Dirty[I + CW] and (not Used[I + CW]) do Inc(CW);
      RH := 1;
      while (RH < MaxRows) and
            (Row + RH < Rows) do
      begin
        Ok := True;
        for C := Col to Col + CW - 1 do
          if (not Dirty[(Row + RH) * Columns + C]) or
             Used[(Row + RH) * Columns + C] then
             Ok := False;
        if not Ok then Break;
        Inc(RH);
      end;
      for R := Row to Row + RH - 1 do
        for C := Col to Col + CW - 1 do
          Used[R * Columns + C] := True;
      Rect.Col := Col;
      Rect.Row := Row;
      Rect.Cols := CW;
      Rect.Rows := RH;
      Rect.X := Col * KVM_TILE_SIZE;
      Rect.Y := Row * KVM_TILE_SIZE;
      Rect.W := Min(Width - Rect.X, CW * KVM_TILE_SIZE);
      Rect.H := Min(Height - Rect.Y, RH * KVM_TILE_SIZE);
      Rect.Leader := I;
      Regions[N] := Rect;
      Inc(N);
    end;
  SetLength(Regions, N);
end;

procedure AssignRegionGroups(const Regions: TKvmRegions;
  Columns: Integer; var Groups: TKvmGroupMap);
var
  I, R, C, T: Integer;
begin
  for I := 0 to High(Regions) do
    for R := Regions[I].Row to Regions[I].Row + Regions[I].Rows - 1 do
      for C := Regions[I].Col to Regions[I].Col + Regions[I].Cols - 1 do
      begin
        T := R * Columns + C;
        if (T >= 0) and (T < Length(Groups)) then
          Groups[T] := Regions[I].Leader;
      end;
end;

end.

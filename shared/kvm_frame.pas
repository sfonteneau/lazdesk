unit kvm_frame;

{$mode objfpc}{$H+}

interface

uses SysUtils;

type
  // Packed 24-bit pixels, top-left origin. GDI can keep its native BGR
  // ordering through damage detection and TurboJPEG without a channel swap.
  TKvmPixelOrder = (kpoRGB, kpoBGR);
  // Exact nearest-neighbour coordinates, reusable while geometry is stable.
  TKvmScaleMap = record
    SourceW, SourceH, Width, Height: Integer;
    X, Y: array of Integer;
  end;
  TRgbFrame = record
    Width, Height: Integer;
    Order: TKvmPixelOrder;
    RGB: RawByteString;
  end;

function AllocateFrame(var Frame: TRgbFrame; W, H: Integer): Boolean;
// DIB is top-down BGR24 with DWORD row padding. Caller retains the source
// allocation during this call; it must not overlap the destination frame.
function CopyBgrDib24(Source: Pointer; Capacity: SizeUInt; Stride,W,H: Integer;
  var Dest: TRgbFrame): Boolean;
// Optional 32-bit top-down GDI DIB (B,G,R,unused alpha), converted to the
// existing packed BGR24 wire format. The alpha byte is never transmitted.
function CopyBgraDib32(Source: Pointer; Capacity: SizeUInt; Stride,W,H: Integer;
  var Dest: TRgbFrame): Boolean;
function ScaledSize(SourceW, SourceH, MaxW, MaxH: Integer;
  out W, H: Integer): Boolean;

function PrepareScaleMap(SourceW, SourceH, W, H: Integer;
  var Map: TKvmScaleMap): Boolean;
function ResizeFrameExact(const Source: TRgbFrame; W, H: Integer;
  var Dest: TRgbFrame; var Map: TKvmScaleMap): Boolean;
function ResizeFrameCached(const Source: TRgbFrame; MaxW, MaxH: Integer;
  var Dest: TRgbFrame; var Map: TKvmScaleMap): Boolean;

function ResizeFrame(const Source: TRgbFrame; MaxW, MaxH: Integer;
  var Dest: TRgbFrame): Boolean;

implementation

uses Math, kvm_wire;

function AllocateFrame(var Frame: TRgbFrame; W, H: Integer): Boolean;
begin
  Result := (W >= 1) and (H >= 1) and (W <= KVM_MAX_FRAME_SIDE) and (H <= KVM_MAX_FRAME_SIDE) and
    (Int64(W) * H <= KVM_MAX_FRAME_PIXELS);
  if not Result then Exit;
  if (Frame.Width <> W) or (Frame.Height <> H) or
     (Length(Frame.RGB) <> W * H * 3) then
    SetLength(Frame.RGB, W * H * 3);
  UniqueString(Frame.RGB); // a reused frame must never mutate an alias
  Frame.Width := W;
  Frame.Height := H;
  Frame.Order := kpoRGB;
end;

function CopyBgrDib24(Source: Pointer; Capacity: SizeUInt; Stride,W,H: Integer;
  var Dest: TRgbFrame): Boolean;
var Y,RowBytes: Integer; Required: QWord;
begin
  Result:=False;
  if (Source=nil) or (W<1) or (H<1) or (W>KVM_MAX_FRAME_SIDE) or
     (H>KVM_MAX_FRAME_SIDE) or (Int64(W)*H>KVM_MAX_FRAME_PIXELS) or
     (Stride<1) then Exit;
  RowBytes:=W*3;
  if Stride<RowBytes then Exit;
  Required:=QWord(H-1)*QWord(Stride)+QWord(RowBytes);
  if Required>QWord(Capacity) then Exit;
  if not AllocateFrame(Dest,W,H) then Exit;
  Dest.Order:=kpoBGR;
  if Stride=RowBytes then Move(Source^,Dest.RGB[1],RowBytes*H)
  else for Y:=0 to H-1 do
    Move(PByte(PtrUInt(Source)+PtrUInt(Y)*PtrUInt(Stride))^,
      Dest.RGB[Y*RowBytes+1],RowBytes);
  Result:=True;
end;

function CopyBgraDib32(Source: Pointer; Capacity: SizeUInt; Stride,W,H: Integer;
  var Dest: TRgbFrame): Boolean;
var
  X, Y: Integer;
  Required: QWord;
  Src, Dst: PByte;
begin
  Result := False;
  if (Source = nil) or (W < 1) or (H < 1) or
     (W > KVM_MAX_FRAME_SIDE) or (H > KVM_MAX_FRAME_SIDE) or
     (Int64(W) * H > KVM_MAX_FRAME_PIXELS) or (Stride < 1) or
     (Int64(Stride) < Int64(W) * 4) then Exit;
  Required := QWord(H - 1) * QWord(Stride) + QWord(W) * 4;
  if Required > QWord(Capacity) then Exit;
  if not AllocateFrame(Dest, W, H) then Exit;
  Dest.Order := kpoBGR;
  for Y := 0 to H - 1 do
  begin
    Src := PByte(PtrUInt(Source) + SizeUInt(Y) * SizeUInt(Stride));
    Dst := @Dest.RGB[Y * W * 3 + 1];
    for X := 0 to W - 1 do
    begin
      Dst^ := Src^; Inc(Dst); Inc(Src);  // blue
      Dst^ := Src^; Inc(Dst); Inc(Src);  // green
      Dst^ := Src^; Inc(Dst); Inc(Src);  // red
      Inc(Src);                         // GDI unused alpha
    end;
  end;
  Result := True;
end;

function ScaledSize(SourceW, SourceH, MaxW, MaxH: Integer;
  out W, H: Integer): Boolean;
var
  Factor: Double;
begin
  W := 0;
  H := 0;
  Result := (SourceW > 0) and (SourceH > 0) and (MaxW > 0) and (MaxH > 0);
  if not Result then Exit;
  // With the native defaults, a desktop exceeding the memory/protocol
  // envelope must FAIL (not be silently resized to 32768 pixels).
  if (MaxW = KVM_MAX_FRAME_SIDE) and (MaxH = KVM_MAX_FRAME_SIDE) and
     ((SourceW > KVM_MAX_FRAME_SIDE) or (SourceH > KVM_MAX_FRAME_SIDE) or
      (Int64(SourceW) * SourceH > KVM_MAX_FRAME_PIXELS)) then Exit(False);
  Factor := Min(1.0, Min(MaxW / SourceW, MaxH / SourceH));
  W := Max(1, Round(SourceW * Factor));
  H := Max(1, Round(SourceH * Factor));
  // Reject rather than silently shrink an otherwise native desktop beyond
  // the protocol/memory safety envelope. Explicit smaller --max-* remains a
  // deliberate downscale when requested by the administrator.
  Result := (W > 0) and (H > 0) and
    (W <= KVM_MAX_FRAME_SIDE) and (H <= KVM_MAX_FRAME_SIDE) and
    (Int64(W) * H <= KVM_MAX_FRAME_PIXELS);
end;

function PrepareScaleMap(SourceW, SourceH, W, H: Integer;
  var Map: TKvmScaleMap): Boolean;
var I: Integer;
begin
  Result := (SourceW > 0) and (SourceH > 0) and (W > 0) and (H > 0) and
    (SourceW <= KVM_MAX_FRAME_SIDE) and (SourceH <= KVM_MAX_FRAME_SIDE) and
    (W <= KVM_MAX_FRAME_SIDE) and (H <= KVM_MAX_FRAME_SIDE) and
    (Int64(SourceW) * SourceH <= KVM_MAX_FRAME_PIXELS) and
    (Int64(W) * H <= KVM_MAX_FRAME_PIXELS);
  if not Result then Exit;
  if (Map.SourceW = SourceW) and (Map.SourceH = SourceH) and
     (Map.Width = W) and (Map.Height = H) and
     (Length(Map.X) = W) and (Length(Map.Y) = H) then Exit;
  SetLength(Map.X, W); SetLength(Map.Y, H);
  for I := 0 to W - 1 do Map.X[I] := (Int64(I) * SourceW) div W;
  for I := 0 to H - 1 do Map.Y[I] := (Int64(I) * SourceH) div H;
  Map.SourceW := SourceW; Map.SourceH := SourceH;
  Map.Width := W; Map.Height := H;
end;

function ResizeFrameExact(const Source: TRgbFrame; W, H: Integer;
  var Dest: TRgbFrame; var Map: TKvmScaleMap): Boolean;
var X, Y, A, B, SourceRow: Integer; Input: TRgbFrame;
begin
  Result := False;
  if Length(Source.RGB) <> Int64(Source.Width) * Source.Height * 3 then Exit;
  if not PrepareScaleMap(Source.Width, Source.Height, W, H, Map) then Exit;
  // Preserve input even if a caller passes the same record for both arguments.
  Input := Source;
  if not AllocateFrame(Dest, W, H) then Exit;
  Dest.Order := Input.Order;
  if (W = Input.Width) and (H = Input.Height) then
    Move(Input.RGB[1], Dest.RGB[1], Length(Input.RGB))
  else for Y := 0 to H - 1 do
  begin
    SourceRow := Map.Y[Y] * Input.Width * 3;
    B := Y * W * 3 + 1;
    for X := 0 to W - 1 do
    begin
      A := SourceRow + Map.X[X] * 3 + 1;
      Dest.RGB[B] := Input.RGB[A]; Dest.RGB[B+1] := Input.RGB[A+1];
      Dest.RGB[B+2] := Input.RGB[A+2];
      Inc(B, 3);
    end;
  end;
  Result := True;
end;

function ResizeFrameCached(const Source: TRgbFrame; MaxW, MaxH: Integer;
  var Dest: TRgbFrame; var Map: TKvmScaleMap): Boolean;
var W, H: Integer;
begin
  Result := ScaledSize(Source.Width, Source.Height, MaxW, MaxH, W, H);
  if Result then Result := ResizeFrameExact(Source, W, H, Dest, Map);
end;

function ResizeFrame(const Source: TRgbFrame; MaxW, MaxH: Integer;
  var Dest: TRgbFrame): Boolean;
var Map: TKvmScaleMap;
begin
  Result := ResizeFrameCached(Source, MaxW, MaxH, Dest, Map);
end;

end.

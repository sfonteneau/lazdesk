unit kvm_cursor;
{$mode objfpc}{$H+}
interface
uses kvm_frame;
type TKvmArgbPixels = array of Cardinal;
// Cursor pixels are premultiplied ARGB, matching XFixes/Render.
function CompositeCursor(var Frame: TRgbFrame; SourceW, SourceH, Left, Top,
  CursorW, CursorH: Integer; const Pixels: TKvmArgbPixels): Boolean;
implementation
uses Math;
function CompositeCursor(var Frame: TRgbFrame; SourceW, SourceH, Left, Top,
  CursorW, CursorH: Integer; const Pixels: TKvmArgbPixels): Boolean;
var X,Y,SX,SY,L,T,R,B,At,Alpha,I,Value: Integer; Pixel: Cardinal;
begin
  Result := False;
  if (SourceW < 1) or (SourceH < 1) or (Frame.Width < 1) or (Frame.Height < 1) or
     (Length(Frame.RGB) <> Int64(Frame.Width)*Frame.Height*3) or
     (CursorW < 1) or (CursorH < 1) or (CursorW > 512) or (CursorH > 512) or
     (Length(Pixels) <> CursorW*CursorH) then Exit;
  UniqueString(Frame.RGB);
  L := Max(0,Floor(Double(Left)*Frame.Width/SourceW));
  T := Max(0,Floor(Double(Top)*Frame.Height/SourceH));
  R := Min(Frame.Width,Ceil((Double(Left)+CursorW)*Frame.Width/SourceW));
  B := Min(Frame.Height,Ceil((Double(Top)+CursorH)*Frame.Height/SourceH));
  for Y := T to B-1 do
    for X := L to R-1 do
    begin
      SX := (Int64(X)*SourceW) div Frame.Width - Left;
      SY := (Int64(Y)*SourceH) div Frame.Height - Top;
      if (SX < 0) or (SY < 0) or (SX >= CursorW) or (SY >= CursorH) then Continue;
      Pixel := Pixels[SY*CursorW+SX]; Alpha := Pixel shr 24;
      if Alpha = 0 then Continue;
      At := (Y*Frame.Width+X)*3+1;
      for I := 0 to 2 do
      begin
        Value := ((Pixel shr (16-I*8)) and $ff) +
          (Ord(Frame.RGB[At+I])*(255-Alpha)+127) div 255;
        Frame.RGB[At+I] := AnsiChar(Min(255,Value));
      end;
    end;
  Result := True;
end;
end.

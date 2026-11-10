unit kvm_rgb_bitmap;
{$mode objfpc}{$H+}
interface
uses kvm_frame;
function RgbBitmapBytes(const Frame: TRgbFrame): RawByteString;
implementation
uses kvm_wire;
procedure Put16(var S: RawByteString; At: Integer; V: Word);
begin S[At]:=AnsiChar(V and 255); S[At+1]:=AnsiChar(V shr 8); end;
procedure Put32(var S: RawByteString; At: Integer; V: Cardinal);
var I: Integer;
begin for I:=0 to 3 do S[At+I]:=AnsiChar((V shr (8*I)) and 255); end;
function RgbBitmapBytes(const Frame: TRgbFrame): RawByteString;
var Stride,Size,X,Y,Src,Dst: Integer;
begin
  Result:='';
  if (Frame.Width<1) or (Frame.Height<1) or (Frame.Width>KVM_MAX_FRAME_SIDE) or (Frame.Height>KVM_MAX_FRAME_SIDE) or
     (Int64(Frame.Width)*Frame.Height>KVM_MAX_FRAME_PIXELS) or
     (Length(Frame.RGB)<>Int64(Frame.Width)*Frame.Height*3) then Exit;
  Stride:=(Frame.Width*3+3) and not 3; Size:=54+Stride*Frame.Height;
  SetLength(Result,Size); FillChar(Result[1],Size,0);
  Result[1]:='B'; Result[2]:='M'; Put32(Result,3,Size); Put32(Result,11,54);
  Put32(Result,15,40); Put32(Result,19,Frame.Width); Put32(Result,23,Frame.Height);
  Put16(Result,27,1); Put16(Result,29,24); Put32(Result,35,Stride*Frame.Height);
  for Y:=0 to Frame.Height-1 do
  begin
    Src:=1+Y*Frame.Width*3; Dst:=55+(Frame.Height-1-Y)*Stride;
    for X:=0 to Frame.Width-1 do
    begin
      if Frame.Order=kpoBGR then
      begin Result[Dst]:=Frame.RGB[Src]; Result[Dst+2]:=Frame.RGB[Src+2]; end
      else begin Result[Dst]:=Frame.RGB[Src+2]; Result[Dst+2]:=Frame.RGB[Src]; end;
      Result[Dst+1]:=Frame.RGB[Src+1];
      Inc(Src,3); Inc(Dst,3);
    end;
  end;
end;
end.

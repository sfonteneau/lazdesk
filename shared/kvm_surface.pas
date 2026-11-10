unit kvm_surface;
{$mode objfpc}{$H+}{$pointermath on}
// CPU-only top-down BGRX32 surface. No LCL object crosses a thread boundary.
interface
uses SysUtils, kvm_frame;
type
  TKvmSurface = record
    Width, Height: Integer;
    Pixels: RawByteString;
  end;
function AllocateSurface(var S: TKvmSurface; W, H: Integer): Boolean;
procedure ClearSurface(var S: TKvmSurface);
function SurfaceValid(const S: TKvmSurface): Boolean;
function FrameToSurface(const F: TRgbFrame; var S: TKvmSurface): Boolean;
implementation
uses kvm_wire;
function SurfaceValid(const S: TKvmSurface): Boolean;
begin
  Result := (S.Width>0) and (S.Height>0) and
    (S.Width<=KVM_MAX_FRAME_SIDE) and (S.Height<=KVM_MAX_FRAME_SIDE) and
    (Int64(S.Width)*S.Height<=KVM_MAX_FRAME_PIXELS) and
    (Length(S.Pixels)=Int64(S.Width)*S.Height*4);
end;
function AllocateSurface(var S: TKvmSurface; W, H: Integer): Boolean;
begin
  Result := (W>0) and (H>0) and (W<=KVM_MAX_FRAME_SIDE) and
    (H<=KVM_MAX_FRAME_SIDE) and (Int64(W)*H<=KVM_MAX_FRAME_PIXELS);
  if not Result then Exit;
  SetLength(S.Pixels,W*H*4);
  UniqueString(S.Pixels);
  S.Width:=W; S.Height:=H;
end;
procedure ClearSurface(var S: TKvmSurface);
begin S.Pixels:=''; S.Width:=0; S.Height:=0; end;
function FrameToSurface(const F: TRgbFrame; var S: TKvmSurface): Boolean;
var Src,Dst: PByte; I,N: Integer;
begin
  Result:=False;
  if (F.Width<1) or (F.Height<1) or
    (Length(F.RGB)<>Int64(F.Width)*F.Height*3) then Exit;
  if not AllocateSurface(S,F.Width,F.Height) then Exit;
  Src:=PByte(Pointer(F.RGB)); Dst:=PByte(Pointer(S.Pixels)); N:=F.Width*F.Height;
  if F.Order=kpoBGR then
    for I:=1 to N do
    begin Dst[0]:=Src[0]; Dst[1]:=Src[1]; Dst[2]:=Src[2]; Dst[3]:=255; Inc(Src,3); Inc(Dst,4); end
  else
    for I:=1 to N do
    begin Dst[0]:=Src[2]; Dst[1]:=Src[1]; Dst[2]:=Src[0]; Dst[3]:=255; Inc(Src,3); Inc(Dst,4); end;
  Result:=True;
end;
end.

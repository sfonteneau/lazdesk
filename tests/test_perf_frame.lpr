program test_perf_frame;
{$mode objfpc}{$H+}
uses SysUtils, kvm_frame;
procedure Check(OK: Boolean; const Msg: string);
begin if not OK then raise Exception.Create(Msg); end;
var Source,Dest,Expected,Saved: TRgbFrame; Map: TKvmScaleMap;
    Trial,W,H,X,Y,A,B,I: Integer; XP,YP: Pointer;
begin
  RandSeed:=73521;
  for Trial:=1 to 500 do
  begin
    Check(AllocateFrame(Source,1+Random(97),1+Random(83)),'source');
    if Odd(Trial) then Source.Order:=kpoBGR;
    for I:=1 to Length(Source.RGB) do Source.RGB[I]:=AnsiChar(Random(256));
    W:=1+Random(Source.Width); H:=1+Random(Source.Height);
    Check(AllocateFrame(Expected,W,H),'expected');
    Expected.Order:=Source.Order;
    for Y:=0 to H-1 do for X:=0 to W-1 do
    begin
      A:=((Int64(Y)*Source.Height div H)*Source.Width+
        Int64(X)*Source.Width div W)*3+1;
      B:=(Y*W+X)*3+1;
      Move(Source.RGB[A],Expected.RGB[B],3);
    end;
    Saved:=Source;
    Check(ResizeFrameExact(Source,W,H,Dest,Map),'resize');
    Check((Dest.RGB=Expected.RGB) and (Dest.Order=Source.Order),'exact mapping/channels');
    XP:=Pointer(Map.X); YP:=Pointer(Map.Y);
    Check(ResizeFrameExact(Source,W,H,Dest,Map),'repeat resize');
    Check((Pointer(Map.X)=XP) and (Pointer(Map.Y)=YP),'coordinate maps not reused');
    Check(Source.RGB=Saved.RGB,'source mutated');
    Check(ResizeFrameExact(Source,W,H,Source,Map),'self resize');
    Check(Source.RGB=Expected.RGB,'self resize corrupted source coordinates');
  end;
  Check(not PrepareScaleMap(32768,32768,1,1,Map),'source cap');
  Check(not PrepareScaleMap(10,10,0,10,Map),'zero target');
  Check(not PrepareScaleMap(10,10,32768,32768,Map),'destination cap');
  WriteLn('PASS: 500 exact RGB/BGR resizes, reusable maps, self-alias and bounds');
end.

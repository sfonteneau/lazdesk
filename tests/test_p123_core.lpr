program test_p123_core;
{$mode objfpc}{$H+}
uses SysUtils, kvm_frame, kvm_surface, kvm_damage, kvm_schedule,
  kvm_wire, kvm_flow;
procedure Check(Value: Boolean; const MessageText: string);
begin if not Value then raise Exception.Create(MessageText); end;
var Src: array[0..47] of Byte; F,G,Saved: TRgbFrame; Surface,Held: TKvmSurface;
  I,Y,X,At: Integer; State: TKvmFlowState; Batch: TKvmFlowBatch;
  Cache: array[0..29] of RawByteString; Versions: array[0..29] of Cardinal;
  Groups: array[0..29] of Integer; Due: QWord;
begin
  FillChar(Src,SizeOf(Src),$ef);
  for Y:=0 to 2 do for X:=0 to 4 do
  begin At:=Y*16+X*3; Src[At]:=30; Src[At+1]:=110; Src[At+2]:=210; end;
  Check(CopyBgrDib24(@Src[0],SizeOf(Src),16,5,3,F),'BGR padded DIB copy');
  Check((F.Order=kpoBGR) and (Length(F.RGB)=45),'BGR format/size');
  for I:=0 to 14 do
    Check((Ord(F.RGB[I*3+1])=30) and (Ord(F.RGB[I*3+3])=210),'BGR row padding');
  Saved:=F;
  Src[0]:=90;
  Check(CopyBgrDib24(@Src[0],SizeOf(Src),16,5,3,F),'Second copy');
  Check(Ord(Saved.RGB[1])=30,'Capture buffer alias mutated');
  Check(not CopyBgrDib24(@Src[0],46,16,5,3,F),'Truncated DIB accepted');
  Check(not CopyBgrDib24(@Src[0],48,14,5,3,F),'Small stride accepted');
  Check(not CopyBgrDib24(nil,48,16,5,3,F),'Nil DIB accepted');
  Check(ResizeFrame(Saved,3,2,G) and (G.Order=kpoBGR),'Resize lost BGR format');
  CopyFrameReuse(G,F);
  Check((F.Order=kpoBGR) and (F.RGB=G.RGB),'Damage copy lost BGR format');
  G.Order:=kpoRGB;
  Check(RegionTileChanged(F,G,0,0,F.Width,F.Height),'Format change not dirty');
  Check(FrameToSurface(Saved,Surface),'BGR -> BGRX');
  Check((Ord(Surface.Pixels[1])=30) and (Ord(Surface.Pixels[3])=210),'Surface channels');
  Held:=Surface;
  Check(AllocateSurface(Surface,5,3),'Surface allocation');
  Surface.Pixels[1]:=#99;
  Check(Ord(Held.Pixels[1])=30,'Surface is not copy-on-write');
  Check(not AllocateSurface(Surface,32768,32768),'Surface memory cap');
  Check(CaptureIsDue(100,0),'Initial capture');
  Check(NextCaptureTick(100,130,20)=150,'Capture deadline includes elapsed work');
  Check(NextCaptureTick(100,180,20)=180,'No catch-up burst');
  Check(NextCaptureTick(100,130,0)=130,'Unpaced captures have no deadline');
  Check(NextCaptureTick(100,105,144)=107,'144 FPS has no 120 FPS clamp');
  Check(NextCaptureTick(100,105,240)=105,'Late high-FPS captures do not catch up');
  Check(NextCaptureTick(100,100,1000)=101,'1ms resolution at 1000 FPS');
  Check(CaptureWaitMs(130,150,50)=20,'Deadline wait');
  Check(CaptureWaitMs(160,150,50)=0,'Overdue wait');
  InitFlow(State);
  for I:=0 to 29 do
  begin Cache[I]:=MakeTile(0,0,1,1,'fakejpeg'); Versions[I]:=1; Groups[I]:=I; end;
  Due:=NextCaptureTick(100,105,20);
  Check(PrepareFlowBatch(State,Cache,Versions,Groups,False,0,0,105,Batch),'First cached batch');
  I:=Batch.Serial;
  Check(not PrepareFlowBatch(State,Cache,Versions,Groups,False,0,0,106,Batch),'Inflight limit');
  Check(AcknowledgeFlowBatch(State,I),'ACK');
  Check(not CaptureIsDue(110,Due),'Capture must wait until deadline');
  Check(PrepareFlowBatch(State,Cache,Versions,Groups,False,0,0,110,Batch),
    'Cached continuation must NOT wait for capture deadline');
  WriteLn('PASS: padded BGR, COW, format propagation, scheduler and cached flow');
end.

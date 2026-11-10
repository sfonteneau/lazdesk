program test_jpeg_batch;
{$mode objfpc}{$H+}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, kvm_frame, kvm_damage, kvm_wire, kvm_turbojpeg, kvm_jpeg_batch;

procedure Check(Condition: Boolean; const Msg: string);
begin
  if not Condition then
  begin
    WriteLn('ERROR: ', Msg);
    Halt(1);
  end;
end;

var
  Frame: TRgbFrame;
  Regions: TKvmRegions;
  Dirty: TKvmDirtyMap;
  Packets: TKvmJpegPackets;
  Encoder: TTurboJpegEncoder;
  Batch: TParallelJpegEncoder;
  Jpeg, Expected, Decoded: RawByteString;
  X,Y,W,H,I: Integer;
  RX,RY,RW,RH: Word;
begin
  Check(AllocateFrame(Frame,768,768),'allocate frame');
  for I:=1 to Length(Frame.RGB) do
    Frame.RGB[I]:=AnsiChar((I*17+I div 113) and 255);
  SetLength(Dirty,9);
  for I:=0 to High(Dirty) do Dirty[I]:=True;
  Check(MakeDirtyRegions(Dirty,3,3,768,768,Regions),'make batch');
  Check(Length(Regions)=4,'enough rectangles to use two JPEG threads');
  SetLength(Packets,Length(Regions));
  Encoder:=TTurboJpegEncoder.Create;
  Batch:=TParallelJpegEncoder.Create;
  try
    Check(Batch.Encode(Frame,Regions,78,Packets),'parallel JPEG encode');
    for I:=0 to High(Regions) do
    begin
      X:=Regions[I].X; Y:=Regions[I].Y;
      W:=Regions[I].W; H:=Regions[I].H;
      Check(Encoder.EncodeRect(Frame,X,Y,W,H,78,Jpeg),'sequential encode');
      Expected:=MakeTile(X,Y,W,H,Jpeg);
      Check(Packets[I]=Expected,'parallel JPEG must match serial output');
      Check(ReadTile(Packets[I],RX,RY,RW,RH,Decoded),'wire packet');
      Check((RX=X) and (RY=Y) and (RW=W) and (RH=H), 'rectangle coords');
      Check(Decoded=Jpeg,'JPEG body');
    end;
    Check(Batch.Encode(Frame,Regions,78,Packets),'reused workers');
    Frame.RGB:='';
    Check(not Batch.Encode(Frame,Regions,78,Packets),'invalid input fails atomically');
  finally
    Batch.Free;
    Encoder.Free;
  end;
  WriteLn('OK: parallel JPEG is byte-for-byte identical to serial JPEG');
end.

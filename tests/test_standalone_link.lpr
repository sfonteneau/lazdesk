program test_standalone_link;
{$mode objfpc}{$H+}
{$IFNDEF KVM_STANDALONE}{$FATAL This test requires -dKVM_STANDALONE}{$ENDIF}
{$I kvm_build.inc}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, kvm_frame, kvm_turbojpeg, kvm_turbojpeg_decode, kvm_jpeg_guard,
  {$IFDEF LINUX}{$IFNDEF KVM_TEST_CLIENT_ONLY}kvm_session_static,{$ENDIF}{$ENDIF}
  {$IFDEF KVM_STATIC_DXGI}kvm_dxgi_static,{$ENDIF}
  kvm_build_info;
var
  Encoder: TTurboJpegEncoder;
  Decoder: TKvmTurboJpegDecoder;
  Frame: TRgbFrame;
  JPEG,BGR: RawByteString;
  I: Integer;
  {$IFDEF LINUX}{$IFNDEF KVM_TEST_CLIENT_ONLY}
  Guard: Pointer;
  Error,Identity: array[0..511] of AnsiChar;
  S: Integer;
  {$ENDIF}{$ENDIF}
procedure Require(Ok: Boolean; const MessageText: string);
begin
  if not Ok then raise Exception.Create(MessageText);
end;
begin
  WriteLn(KvmBuildDescription);
  {$IFDEF KVM_STATIC_DXGI}
  // Smoke-link DXGI through FPC itself, not just through g++'s startup.
  // Catches unresolved atexit, WinPthreads, SDK libraries before Lazarus.
  Require(KvmDxgiAbi=3,'Static DXGI ABI mismatch');
  WriteLn('PASS: DXGI static bridge linked with the FPC runtime');
  {$ENDIF}
  Encoder:=nil; Decoder:=nil;
  try
    Encoder:=TTurboJpegEncoder.Create;
    Decoder:=TKvmTurboJpegDecoder.Create;
    Require(Decoder.Available,'Static decoder unavailable');
    Require(AllocateFrame(Frame,64,48),'Frame allocation failed');
    // Uniform color: test channel order and the actual codec round-trip.
    for I:=0 to 64*48-1 do
    begin
      Frame.RGB[I*3+1]:=AnsiChar(210);
      Frame.RGB[I*3+2]:=AnsiChar(110);
      Frame.RGB[I*3+3]:=AnsiChar(30);
    end;
    Require(Encoder.EncodeRect(Frame,0,0,64,48,90,JPEG),'Static JPEG encode failed');
    Require(JpegMatchesSize(JPEG,64,48),'JPEG dimensions mismatch');
    Require(Decoder.DecodeToBgr(JPEG,64,48,BGR),'Static JPEG decode failed');
    Require(Length(BGR)=64*48*3,'BGR length mismatch');
    Require(Abs(Ord(BGR[1])-30)<=5,'Blue channel mismatch');
    Require(Abs(Ord(BGR[2])-110)<=5,'Green channel mismatch');
    Require(Abs(Ord(BGR[3])-210)<=5,'Red channel mismatch');
    Require(not Decoder.DecodeToBgr(JPEG,63,48,BGR),'Malformed geometry accepted');
    WriteLn('PASS: actual TurboJPEG static encode/decode and malformed geometry');
  finally
    Decoder.Free; Encoder.Free;
  end;
  {$IFDEF LINUX}{$IFNDEF KVM_TEST_CLIENT_ONLY}
  Require(KvmSessionAbi=$00090001,'Session ABI mismatch');
  FillChar(Error,SizeOf(Error),0);
  Guard:=KvmSessionOpenEx(@Error[0],SizeOf(Error));
  if Guard=nil then
    WriteLn('NOTE: session code linked; system runtime unavailable: ',PAnsiChar(@Error[0]))
  else
    try
      FillChar(Identity,SizeOf(Identity),0);
      S:=KvmSessionPoll(Guard,@Identity[0],SizeOf(Identity));
      Require((S>=0) and (S<=4),'Invalid session state');
      WriteLn('PASS: integrated session ABI, open/poll/close; state=',S,
        ' (not a locked-desktop qualification)');
    finally KvmSessionClose(Guard); end;
  {$ENDIF}{$ENDIF}
end.

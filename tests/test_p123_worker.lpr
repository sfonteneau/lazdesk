program test_p123_worker;
{$mode objfpc}{$H+}
uses {$IFDEF UNIX}cthreads,{$ENDIF} Classes, SysUtils,
  kvm_frame, kvm_surface, kvm_wire, kvm_extwire,
  kvm_turbojpeg, kvm_video_worker;
procedure Check(Value: Boolean; const MessageText: string);
begin if not Value then raise Exception.Create(MessageText); end;
type
  TReplies = class
  private
    Lock: TRTLCriticalSection;
    Items: TKvmPacketList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Reply(const Payload: RawByteString);
    function Count: Integer;
    function Item(I: Integer): RawByteString;
  end;
constructor TReplies.Create;
begin inherited Create; InitCriticalSection(Lock); end;
destructor TReplies.Destroy;
begin DoneCriticalSection(Lock); inherited Destroy; end;
procedure TReplies.Reply(const Payload: RawByteString);
var N: Integer;
begin
  EnterCriticalSection(Lock);
  try N:=Length(Items); SetLength(Items,N+1); Items[N]:=Payload;
  finally LeaveCriticalSection(Lock); end;
end;
function TReplies.Count: Integer;
begin EnterCriticalSection(Lock); try Result:=Length(Items); finally LeaveCriticalSection(Lock); end; end;
function TReplies.Item(I: Integer): RawByteString;
begin EnterCriticalSection(Lock); try Result:=Items[I]; finally LeaveCriticalSection(Lock); end; end;
procedure WaitCount(R: TReplies; N: Integer);
var UntilTick: QWord;
begin
  UntilTick:=GetTickCount64+5000;
  while (R.Count<N) and (GetTickCount64<UntilTick) do Sleep(1);
  Check(R.Count=N,'Expected reply '+IntToStr(N)+' without GUI polling');
end;
procedure Put(W: TKvmVideoWorker; const Packet: RawByteString);
begin Check(W.Enqueue(Packet),'Enqueue refused'); end;
function SolidJPEG(Encoder: TTurboJpegEncoder; B,G,R: Byte): RawByteString;
var Frame: TRgbFrame; I: Integer;
begin
  Check(AllocateFrame(Frame,16,16),'Test frame'); Frame.Order:=kpoBGR;
  for I:=0 to 255 do
  begin Frame.RGB[I*3+1]:=AnsiChar(B); Frame.RGB[I*3+2]:=AnsiChar(G); Frame.RGB[I*3+3]:=AnsiChar(R); end;
  Check(Encoder.EncodeRect(Frame,0,0,16,16,90,Result),'Test JPEG encode');
end;
procedure PixelNear(const S: TKvmSurface; X,Y,B,G,R: Integer);
var At: Integer;
begin
  Check(SurfaceValid(S),'Invalid surface'); At:=(Y*S.Width+X)*4+1;
  Check((Abs(Ord(S.Pixels[At])-B)<12) and
    (Abs(Ord(S.Pixels[At+1])-G)<12) and (Abs(Ord(S.Pixels[At+2])-R)<12),'Pixel/color mismatch');
end;
procedure RunMode(UseNative: Boolean; const Red,Blue: RawByteString);
var W: TKvmVideoWorker; R: TReplies; Events: TKvmPacketList;
  Snap,Held: TKvmPresentation; HasSnap: Boolean; FatalText: string;
  Stats: TKvmDecodeStats; I: Integer;
begin
  R:=TReplies.Create; W:=nil;
  try
    W:=TKvmVideoWorker.Create(False,@R.Reply,UseNative);
    if UseNative then Check(W.NativeAvailable,'TurboJPEG required by this test');
    Put(W,MakeDesktopState(True,KVM_SESSION_ACTIVE,2));
    Put(W,MakeScreen(32,16));
    Put(W,MakeTile(0,0,16,16,Red)); Put(W,MakeBatchEnd(1)); WaitCount(R,1);
    Check(R.Item(0)=MakeBatchAck(1),'First ACK');
    // GUI has NEVER been polled. Next delta must decode/ACK independently.
    Put(W,MakeTile(16,0,16,16,Blue)); Put(W,MakeBatchEnd(2)); WaitCount(R,2);
    W.DrainUI(Events,Snap,HasSnap,FatalText);
    Check((FatalText='') and HasSnap and (Snap.Serial=2),'Latest coherent snapshot');
    Check((Length(Events)=1) and (Events[0][1]='D'),'State event retained');
    PixelNear(Snap.Surface,3,3,0,0,220); PixelNear(Snap.Surface,22,3,220,0,0);
    Held:=Snap;
    Put(W,MakeTile(0,0,16,16,Blue)); Put(W,MakeBatchEnd(3)); WaitCount(R,3);
    W.DrainUI(Events,Snap,HasSnap,FatalText);
    PixelNear(Held.Surface,3,3,0,0,220); PixelNear(Snap.Surface,3,3,220,0,0);
    // A failed tile after a valid tile must not publish a partial batch.
    Put(W,MakeTile(0,0,16,16,Red)); Put(W,MakeTile(16,0,16,16,'badjpeg'));
    Put(W,MakeBatchEnd(4)); WaitCount(R,4);
    Check(R.Item(3)=MakeBatchNack(4),'Malformed tile must NACK');
    W.DrainUI(Events,Snap,HasSnap,FatalText);
    Check(not HasSnap,'Partial failed batch published');
    Put(W,MakeScreen(32,16)); Put(W,MakeTile(0,0,16,16,Red));
    Put(W,MakeTile(16,0,16,16,Blue)); Put(W,MakeBatchEnd(5)); WaitCount(R,5);
    Check(R.Item(4)=MakeBatchAck(5),'Resync ACK');
    W.DrainUI(Events,Snap,HasSnap,FatalText); PixelNear(Snap.Surface,3,3,0,0,220);
    // No UI polling for fifty full batches: bounded latest-frame mailbox,
    // cumulative CPU state and ACK progress, not a queue of raw bitmaps.
    for I:=6 to 55 do
    begin Put(W,MakeTile(0,0,16,16,Red)); Put(W,MakeBatchEnd(I)); WaitCount(R,I); end;
    W.DrainUI(Events,Snap,HasSnap,FatalText);
    Check(HasSnap and (Snap.Serial=55),'Slow GUI sees most recent snapshot');
    W.TakeStats(Stats);
    Check((Stats.AckCount=54) and (Stats.NackCount=1),'ACK/NACK stats');
    Check(Stats.Coalesced>=49,'Presentations not coalesced');
    // Ordered pause/new epoch and receipts survive presentation coalescing.
    Put(W,MakeDesktopState(False,KVM_SESSION_LOCKED,3));
    Put(W,MakeInputReceipt(1,KVM_INPUT_DENIED,0));
    Put(W,MakeDesktopState(True,KVM_SESSION_ACTIVE,4));
    Put(W,MakeScreen(16,16)); Put(W,MakeTile(0,0,16,16,Blue));
    Put(W,MakeBatchEnd(56)); WaitCount(R,56);
    W.DrainUI(Events,Snap,HasSnap,FatalText);
    Check((Length(Events)=3) and (Events[0][1]='D') and
      (Events[1][1]='I') and (Events[2][1]='D'),'Ordered control events');
    Check(HasSnap and (Snap.Epoch=4) and (Snap.Surface.Width=16),'New epoch/resolution');
    PixelNear(Snap.Surface,3,3,220,0,0);
    Put(W,MakeDesktopState(False,KVM_SESSION_LOCKED,5));
    Put(W,MakeBatchEnd(57)); WaitCount(R,57);
    Check(R.Item(56)=MakeBatchNack(57),'Paused desktop ACKed');
    W.DrainUI(Events,Snap,HasSnap,FatalText);
    Check(HasSnap and not Snap.Available and (Snap.Surface.Width=0),
      'Paused desktop kept old pixels');
    Check(not W.Enqueue(StringOfChar('T',KVM_DECODE_QUEUE_BYTES+1)),'Oversized input accepted');
    W.DrainUI(Events,Snap,HasSnap,FatalText); Check(FatalText<>'','Missing queue error');
  finally W.Free; R.Free; end;
end;
procedure RunCursorMode(UseNative: Boolean; const Red,Blue: RawByteString);
var W: TKvmVideoWorker; R: TReplies; Events: TKvmPacketList;
  Snap,Held: TKvmPresentation; HasSnap: Boolean; FatalText: string;
  Stats: TKvmDecodeStats;
begin
  R:=TReplies.Create; W:=nil;
  try
    W:=TKvmVideoWorker.Create(False,@R.Reply,UseNative);
    Put(W,MakeDesktopState(True,KVM_SESSION_ACTIVE,10));
    Put(W,MakeScreen(16,16)); Put(W,MakeTile(0,0,16,16,Red));
    Put(W,MakeBatchEnd(1)); WaitCount(R,1);
    W.DrainUI(Events,Snap,HasSnap,FatalText);
    Check(HasSnap and (FatalText=''),'Initial cursor-test frame'); Held:=Snap;
    W.TakeStats(Stats);
    Put(W,MakeCursor(100,200,True)); Put(W,MakeBatchEnd(2)); WaitCount(R,2);
    W.DrainUI(Events,Snap,HasSnap,FatalText); W.TakeStats(Stats);
    Check(HasSnap and (Snap.ImageRevision=Held.ImageRevision),'Cursor changes pixel revision');
    Check(Pointer(Snap.Surface.Pixels)=Pointer(Held.Surface.Pixels),'Cursor clones pixels');
    Check((Stats.CopiedBytes=0) and (Stats.JpegCount=0),'Cursor performs pixel work');
    Check(Snap.CursorVisible and (Snap.CursorX=100) and (Snap.CursorY=200),'Cursor state lost');
    // A later cursor-only publish must not hide an unseen image update.
    Put(W,MakeTile(0,0,16,16,Blue)); Put(W,MakeBatchEnd(3)); WaitCount(R,3);
    Put(W,MakeCursor(300,400,False)); Put(W,MakeBatchEnd(4)); WaitCount(R,4);
    W.DrainUI(Events,Snap,HasSnap,FatalText);
    Check(HasSnap and (Snap.Serial=4) and (Snap.ImageRevision<>Held.ImageRevision),
      'Coalesced cursor lost image revision');
    PixelNear(Snap.Surface,3,3,220,0,0); PixelNear(Held.Surface,3,3,0,0,220);
    Check(not Snap.CursorVisible,'Hide cursor lost');
  finally W.Free; R.Free; end;
end;
var Encoder: TTurboJpegEncoder; Red,Blue: RawByteString; W: TKvmVideoWorker; I: Integer;
begin
  Encoder:=TTurboJpegEncoder.Create;
  try Red:=SolidJPEG(Encoder,0,0,220); Blue:=SolidJPEG(Encoder,220,0,0);
  finally Encoder.Free; end;
  RunMode(True,Red,Blue); RunMode(False,Red,Blue);
  RunCursorMode(True,Red,Blue); RunCursorMode(False,Red,Blue);
  for I:=1 to 20 do begin W:=TKvmVideoWorker.Create(False,nil); W.Stop; W.Free; end;
  WriteLn('PASS: actual worker native/FCL, no GUI ACK dependency, immutable pool, cursor-only, NACK/resync, events and shutdown');
end.

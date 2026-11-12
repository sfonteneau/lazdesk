program test_v9_core;
{$mode objfpc}{$H+}
uses SysUtils, kvm_wire, kvm_extwire, kvm_input_queue, kvm_security,
  kvm_frame, kvm_rgb_bitmap, kvm_keysym;
var Count: Integer;
procedure Check(Value: Boolean; const Name: string);
begin Inc(Count); if not Value then raise Exception.Create(Name); end;
var
  R: TKvmRate; Q: TKvmInputQueue; P,S: RawByteString;
  Serial,Epoch: Cardinal; W,H,Applied: Word; Status,Reason: Byte;
  Available: Boolean; Points: TKvmCodePoints; Shortcut: TKvmShortcutKeys; F: TRgbFrame;
  I: Integer;
begin
  Check(KVM_SUBPROTOCOL='lazdesk9','protocol');
  P:=MakeShortcut([$11,$1b]);
  Check((P='Y'+#2+#$11+#$1b) and ReadShortcut(P,Shortcut) and
    (Length(Shortcut)=2) and (Shortcut[0]=$11) and (Shortcut[1]=$1b),
    'ctrl-esc roundtrip');
  Check(ReadShortcut(MakeShortcut([$11,$10,$1b]),Shortcut) and
    (Length(Shortcut)=3) and (Shortcut[2]=$1b),'three-key chord');
  Check(MakeShortcut([$11])='','one-key shortcut rejected');
  Check(MakeShortcut([$11,0])='','null virtual key rejected');
  Check(not ReadShortcut('Y'+#2+#$11,Shortcut),'truncated shortcut rejected');
  Check(not ReadShortcut('Y'+#3+#$11+#$1b,Shortcut),'bad count rejected');
  Check(not ReadShortcut('Y'+#2+#$11+#0,Shortcut),'zero key rejected');
  Check(not ReadKey(MakeKey(True,0),Available,W),'zero virtual key rejected');
  Check(SecureTokenEqual('abcdefghijklmnop','abcdefghijklmnop'),'equal');
  Check(not SecureTokenEqual('abcdefghijklmnop','bbcdefghijklmnop'),'unequal');
  Check(not SecureTokenEqual('',''),'empty token');
  Check(not SecureTokenEqual(StringOfChar('a',257),StringOfChar('a',257)),'long token');
  Check(not KvmLoopbackHost('localhost'),'DNS not trusted as loopback');
  Check(KvmLoopbackHost('127.0.0.1'),'literal loopback');
  InitRate(R,10,5,100); Check(SpendRate(R,10,100),'burst');
  Check(not SpendRate(R,1,100),'exhausted'); Check(SpendRate(R,1,300),'refill');
  Check(not SpendRate(R,1,300),'refill consumed'); Check(not SpendRate(R,11,100000),'cap');
  for Reason:=0 to KVM_SESSION_CAPTURE_LOST do
  begin
    P:=MakeDesktopState(Reason=KVM_SESSION_ACTIVE,Reason,123);
    Check(ReadDesktopState(P,Available,Status,Epoch),'D valid');
    Check((Status=Reason) and (Epoch=123),'D values');
  end;
  Check(not ReadDesktopState('D'+#1,Available,Reason,Epoch),'legacy D rejected');
  P:=MakeTextRequest(1,'caf'+#$c3#$a9);
  Check((P<>'') and (P[1]='X'),'Unicode request uses versioned X');
  Check(ReadTextRequest(P,Serial,Points) and (Serial=1) and (Length(Points)=4),'Unicode request');
  Check(not ReadTextRequest('U'+#1#0#0#0+'x',Serial,Points),'old Unicode network frame rejected');
  Check(not ReadTextRequest('U'+#1#0#0#0+#$c0#$80,Serial,Points),'old malformed Unicode frame rejected');
  Check(not ReadTextRequest('X'+#2+#1#0#0#0+#1#0+'x',Serial,Points),'unknown X text version rejected');
  Check(MakeTextRequest(0,'x')='','zero serial');
  Check(NextSerial(High(Cardinal))=1,'serial rollover');
  P:=MakeVideo(640,360,#0#0#0#1#$65);
  Check(ReadVideo(P,W,H,S) and (W=640) and (H=360),'V header');
  Check(MakeVideo(641,360,'12345')='','odd size');
  P[7]:=#6; Check(not ReadVideo(P,W,H,S),'V length mismatch');
  Q:=TKvmInputQueue.Create;
  try
    Check(Q.Push(MakeTextUtf8('abc')),'queue text');
    Check(Q.Push(MakeKey(True,$41)),'queue key');
    Check(Q.Take(1000,P),'take text'); Check(ReadTextRequest(P,Serial,Points) and (Serial=1),'request serial');
    Check(not Q.Take(1000,P),'wait receipt');
    Check(not Q.Receipt(MakeInputReceipt(2,0,3),Status,Applied),'wrong serial');
    Check(not Q.Receipt(MakeInputReceipt(1,0,4),Status,Applied),'wrong count');
    Check(Q.Receipt(MakeInputReceipt(1,0,3),Status,Applied),'good receipt');
    Check(Q.Take(1001,P) and (P[1]='K'),'preserve input order');
    Check(Q.Push(MakeTextUtf8('x')) and Q.Take(1002,P),'second text');
    Q.CancelQueued; Check(Q.Pending=2,'cancel does not forget inflight commit');
    Check(not Q.TimedOut(5001),'receipt timer before limit');
    Check(Q.TimedOut(5002),'receipt timeout');
    Q.Reset; for I:=1 to KVM_INPUT_QUEUE_ITEMS do Check(Q.Push(MakeKey(True,$41)),'bounded enqueue');
    Check(not Q.Push(MakeKey(True,$41)),'queue cap');
  finally Q.Free; end;
  Check(AllocateFrame(F,2,1),'RGB allocate'); F.RGB:=#255#0#0#0#255#0;
  S:=RgbBitmapBytes(F); Check((Length(S)=62) and (Copy(S,1,2)='BM'),'BMP padded length');
  Check(Copy(S,55,6)=#0#0#255#0#255#0,'BMP BGR ordering');
  Check(KvmKeysym($15)=$ff27,'Kana'); Check(KvmKeysym($1d)=$ff22,'Muhenkan');
  Check(KvmKeysym($87)=$ffd5,'F24');
  WriteLn('PASS ',Count,' v9 core assertions (actual Pascal execution)');
end.

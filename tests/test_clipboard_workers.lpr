program test_clipboard_workers;
{$mode objfpc}{$H+}{$B-}{$R+}{$Q+}
// Actual worker classes with fake OS clipboards; never reads the real clipboard.
uses {$IFDEF UNIX}cthreads,{$ENDIF} Classes,SysUtils,SyncObjs,
  kvm_clipboard_wire,kvm_clipboard_base,kvm_clipboard_server_worker,kvm_clipboard_client_worker;
type
  TStore = class
    Lock: TRTLCriticalSection;
    Value: RawByteString;
    Reads,Writes: Integer;
    Stamp: QWord;
    constructor Create;
    destructor Destroy; override;
    procedure SetValue(const S: RawByteString);
    function GetValue: RawByteString;
    function GetWrites: Integer;
  end;
  TFakeClipboard = class(TKvmClipboardBackend)
    Store: TStore;
    constructor Create(S: TStore);
    function Ready: Boolean; override;
    function ChangeStamp: QWord; override;
    function ReadText(out Text: RawByteString): TKvmClipResult; override;
    function WriteText(const Text: RawByteString): TKvmClipResult; override;
  end;
  THarness = class
    Local,Remote: TStore;
    Server: TKvmClipboardServerWorker;
    Client: TKvmClipboardClientWorker;
    Enabled: LongInt;
    function Allowed(ID: QWord; Epoch: Cardinal): Boolean;
    function Reply(ID: QWord; const R: TKvmClipReply): Boolean;
    procedure Send(const Packet: RawByteString);
  end;
var H: THarness; Count: Integer;
procedure Check(B: Boolean; const Msg: string);
begin if not B then raise Exception.Create('FAIL: '+Msg); end;
constructor TStore.Create;
begin inherited Create; InitCriticalSection(Lock); Stamp:=1; end;
destructor TStore.Destroy;
begin DoneCriticalSection(Lock); inherited Destroy; end;
procedure TStore.SetValue(const S: RawByteString);
begin EnterCriticalSection(Lock); try Value:=S; Inc(Stamp); finally LeaveCriticalSection(Lock); end; end;
function TStore.GetValue: RawByteString;
begin EnterCriticalSection(Lock); try Result:=Value; finally LeaveCriticalSection(Lock); end; end;
function TStore.GetWrites: Integer;
begin EnterCriticalSection(Lock); try Result:=Writes; finally LeaveCriticalSection(Lock); end; end;
constructor TFakeClipboard.Create(S: TStore);
begin inherited Create; Store:=S; end;
function TFakeClipboard.Ready: Boolean; begin Result:=True; end;
function TFakeClipboard.ChangeStamp: QWord;
begin EnterCriticalSection(Store.Lock); try Result:=Store.Stamp; finally LeaveCriticalSection(Store.Lock); end; end;
function TFakeClipboard.ReadText(out Text: RawByteString): TKvmClipResult;
begin
  EnterCriticalSection(Store.Lock);
  try Text:=Store.Value; Inc(Store.Reads); finally LeaveCriticalSection(Store.Lock); end;
  Result:=crOk;
end;
function TFakeClipboard.WriteText(const Text: RawByteString): TKvmClipResult;
begin
  EnterCriticalSection(Store.Lock);
  try Store.Value:=Text; Inc(Store.Writes); Inc(Store.Stamp); finally LeaveCriticalSection(Store.Lock); end;
  Result:=crOk;
end;
function LocalFactory: TKvmClipboardBackend; begin Result:=TFakeClipboard.Create(H.Local); end;
function RemoteFactory: TKvmClipboardBackend; begin Result:=TFakeClipboard.Create(H.Remote); end;
function THarness.Allowed(ID: QWord; Epoch: Cardinal): Boolean;
begin Result:=(InterlockedCompareExchange(Enabled,1,1)=1) and (ID=7) and (Epoch=3); end;
function THarness.Reply(ID: QWord; const R: TKvmClipReply): Boolean;
begin Result:=(ID=7) and Client.EnqueueReply(MakeClipReply(R)); end;
procedure THarness.Send(const Packet: RawByteString);
var R: TKvmClipRequest;
begin
  Check(ReadClipRequest(Packet,R),'wire sent by actual worker');
  Check(Server.Enqueue(7,R),'one outstanding transaction');
end;
procedure WaitValue(Store: TStore; const Value,Msg: RawByteString);
var UntilTick: QWord;
begin
  UntilTick:=GetTickCount64+4000;
  while (Store.GetValue<>Value) and (GetTickCount64<UntilTick) do Sleep(10);
  Check(Store.GetValue=Value,string(Msg));
end;
begin
  H:=THarness.Create; H.Local:=TStore.Create; H.Remote:=TStore.Create; H.Enabled:=1;
  H.Local.SetValue('local initial'); H.Remote.SetValue('remote initial');
  H.Server:=TKvmClipboardServerWorker.Create(@RemoteFactory,@H.Allowed,@H.Reply,True); H.Server.Start;
  H.Client:=TKvmClipboardClientWorker.Create(@LocalFactory,@H.Send);
  try
    Sleep(400);
    Check((H.Local.Reads=0) and (H.Remote.Reads=0),'no content read before consent');
    H.Client.Configure(KVM_CLIP_WRITE,3);
    WaitValue(H.Remote,'local initial','initial write'); Sleep(350);
    Check(H.Remote.Reads=0,'write-only does not read remote');
    H.Local.SetValue('local second'); WaitValue(H.Remote,'local second','changed local');
    Sleep(400); H.Client.Configure(0,3); Sleep(100);
    H.Local.SetValue('private not shared'); Sleep(500);
    Check(H.Remote.GetValue='local second','disabled direction');
    H.Client.Configure(KVM_CLIP_READ,3);
    WaitValue(H.Local,'local second','initial read');
    H.Remote.SetValue('remote second'); WaitValue(H.Local,'remote second','changed remote');
    Sleep(400); H.Local.SetValue('private receive-only'); Sleep(500);
    Check(H.Remote.GetValue='remote second','receive-only never writes remote');
    H.Client.Configure(3,3); WaitValue(H.Remote,'private receive-only','both initially local wins'); Sleep(500);
    Count:=H.Remote.GetWrites;
    H.Remote.SetValue('remote accent '+#$c3#$a9+#$f0#$9f#$98#$80);
    WaitValue(H.Local,'remote accent '+#$c3#$a9+#$f0#$9f#$98#$80,'remote Unicode');
    Sleep(900); Check(H.Remote.GetWrites=Count,'no echo of received text');
    H.Local.SetValue('local final'); WaitValue(H.Remote,'local final','local after remote'); Sleep(600);
    Count:=H.Remote.GetWrites; H.Local.SetValue('local final'); Sleep(600);
    Check(H.Remote.GetWrites=Count+1,'copy same text again uses native change stamp');
    Count:=H.Remote.GetWrites; InterlockedExchange(H.Enabled,0);
    H.Local.SetValue('must not reach locked session'); Sleep(900);
    Check(H.Remote.GetWrites=Count,'authorization checked on worker');
    H.Client.Configure(0,0); Sleep(100);
    Writeln('PASS: actual client/server clipboard workers with fake OS, consent, both directions, echo and revoke');
  finally
    // Stop client sends before removing the server; stop replies before freeing client.
    H.Client.Stop; H.Client.WaitFor; H.Server.Stop; H.Server.WaitFor;
    H.Server.Free; H.Client.Free; H.Local.Free; H.Remote.Free; H.Free;
  end;
end.

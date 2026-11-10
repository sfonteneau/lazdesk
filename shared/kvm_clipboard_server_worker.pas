unit kvm_clipboard_server_worker;
{$mode objfpc}{$H+}{$B-}
interface
uses Classes, SysUtils, SyncObjs, kvm_clipboard_base, kvm_clipboard_wire;
type
  TKvmClipAllowed = function(ID: QWord; Epoch: Cardinal): Boolean of object;
  TKvmClipReplyProc = function(ID: QWord; const Reply: TKvmClipReply): Boolean of object;
  TKvmClipboardServerWorker = class(TThread)
  private
    FLock: TRTLCriticalSection;
    FWake: TEvent;
    FFactory: TKvmClipboardFactory;
    FAllowed: TKvmClipAllowed;
    FReply: TKvmClipReplyProc;
    FQueued, FBusy, FNativeAllowed, FLockReady: Boolean;
    FID: QWord;
    FRequest: TKvmClipRequest;
    procedure Process(B: TKvmClipboardBackend; ID: QWord; const Request: TKvmClipRequest;
      var SentID,SentStamp: QWord; var SentEpoch,SentSerial: Cardinal; var SentText: RawByteString);
  protected
    procedure Execute; override;
  public
    constructor Create(Factory: TKvmClipboardFactory; Allowed: TKvmClipAllowed;
      Reply: TKvmClipReplyProc; NativeAllowed: Boolean);
    destructor Destroy; override;
    function Enqueue(ID: QWord; const Request: TKvmClipRequest): Boolean;
    procedure Stop;
  end;
implementation
constructor TKvmClipboardServerWorker.Create(Factory: TKvmClipboardFactory;
  Allowed: TKvmClipAllowed; Reply: TKvmClipReplyProc; NativeAllowed: Boolean);
begin
  inherited Create(True); FreeOnTerminate:=False; InitCriticalSection(FLock); FLockReady:=True;
  FWake:=TEvent.Create(nil,False,False,''); FFactory:=Factory;
  FAllowed:=Allowed; FReply:=Reply; FNativeAllowed:=NativeAllowed;
end;
procedure TKvmClipboardServerWorker.Stop;
begin Terminate; if FWake<>nil then FWake.SetEvent; end;
destructor TKvmClipboardServerWorker.Destroy;
begin
  Stop; inherited Destroy; // joins while locks/events/callbacks still exist
  FWake.Free; if FLockReady then DoneCriticalSection(FLock);
end;
function TKvmClipboardServerWorker.Enqueue(ID: QWord; const Request: TKvmClipRequest): Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Result:=not Terminated and not FBusy;
    if Result then begin FBusy:=True; FQueued:=True; FID:=ID; FRequest:=Request; end;
  finally LeaveCriticalSection(FLock); end;
  if Result then FWake.SetEvent;
end;
procedure TKvmClipboardServerWorker.Process(B: TKvmClipboardBackend; ID: QWord;
  const Request: TKvmClipRequest; var SentID,SentStamp: QWord; var SentEpoch,SentSerial: Cardinal;
  var SentText: RawByteString);
var R: TKvmClipReply; Deadline,ReadStamp: QWord; Text: RawByteString;
  procedure Deny;
  begin
    R.HasText:=False; R.Text:='';
    if (Request.Flags and KVM_CLIP_WRITE)<>0 then R.WriteResult:=crDenied;
    if (Request.Flags and KVM_CLIP_READ)<>0 then R.ReadResult:=crDenied;
  end;
  function CanProceed: Boolean;
  begin Result:=not Terminated and FAllowed(ID,Request.Epoch); end;
  procedure Pause;
  begin B.Pump; FWake.WaitFor(20); end;
begin
  R.Epoch:=Request.Epoch; R.Serial:=Request.Serial;
  R.WriteResult:=crSkip; R.ReadResult:=crSkip; R.HasText:=False; R.Text:=''; ReadStamp:=0;
  if (SentID<>ID) or (SentEpoch<>Request.Epoch) then
  begin SentID:=ID; SentEpoch:=Request.Epoch; SentSerial:=0; SentStamp:=0; SentText:=''; end;
  try
    if not CanProceed then Deny
    else if (B=nil) or not B.Ready then
    begin
      if (Request.Flags and KVM_CLIP_WRITE)<>0 then R.WriteResult:=crUnsupported;
      if (Request.Flags and KVM_CLIP_READ)<>0 then R.ReadResult:=crUnsupported;
    end
    else
    begin
      // One write at most after success; never replay it while waiting for a
      // read. Only explicit "busy, no write performed" is retried locally.
      if (Request.Flags and KVM_CLIP_WRITE)<>0 then
      begin
        Deadline:=GetTickCount64+1000;
        repeat
          if not CanProceed then begin Deny; Break; end;
          R.WriteResult:=B.WriteText(Request.Text);
          if R.WriteResult<>crBusy then Break;
          Pause;
        until GetTickCount64>=Deadline;
      end;
      if ((Request.Flags and KVM_CLIP_READ)<>0) and
         (((Request.Flags and KVM_CLIP_WRITE)=0) or (R.WriteResult=crOk)) and CanProceed then
      begin
        Deadline:=GetTickCount64+2500;
        repeat
          if not CanProceed then begin Deny; Break; end;
          R.ReadResult:=B.ReadText(Text);
          if R.ReadResult<>crBusy then Break;
          Pause;
        until GetTickCount64>=Deadline;
        B.CancelRead;
        if R.ReadResult<>crOk then begin SentSerial:=0; SentStamp:=0; SentText:=''; end;
        if (R.ReadResult=crOk) and CanProceed then
        begin
          ReadStamp:=B.ChangeStamp;
          if (SentSerial<>0) and (Request.KnownReadSerial=SentSerial) and (Text=SentText)
             and ((ReadStamp=0) or (ReadStamp=SentStamp)) then
            R.ReadResult:=crUnchanged
          else begin R.HasText:=True; R.Text:=Text; end;
        end;
      end;
    end;
  except
    // Never expose clipboard text via an exception message or a log.
    R.HasText:=False; R.Text:='';
    if R.WriteResult=crSkip then R.WriteResult:=crFailed;
    if (Request.Flags and KVM_CLIP_READ)<>0 then R.ReadResult:=crFailed;
  end;
  if Terminated then Exit;
  if not CanProceed then Deny; // revoke/lock/disconnect during native operation
  if FReply(ID,R) and R.HasText then
  begin SentSerial:=R.Serial; SentStamp:=ReadStamp; SentText:=R.Text; end;
end;
procedure TKvmClipboardServerWorker.Execute;
var B: TKvmClipboardBackend; ID,SentID,SentStamp: QWord; Request: TKvmClipRequest;
  SentEpoch,SentSerial: Cardinal; SentText: RawByteString; Have: Boolean;
begin
  B:=nil; SentStamp:=0; SentID:=0; SentEpoch:=0; SentSerial:=0; SentText:='';
  try
    if FNativeAllowed and not Terminated then
      try B:=FFactory(); except B:=nil; end;
    while not Terminated do
    begin
      if B<>nil then try B.Pump; except end;
      EnterCriticalSection(FLock);
      try
        Have:=FQueued;
        if Have then begin ID:=FID; Request:=FRequest; FRequest.Text:=''; FQueued:=False; end;
      finally LeaveCriticalSection(FLock); end;
      if Have then
      begin
        try Process(B,ID,Request,SentID,SentStamp,SentEpoch,SentSerial,SentText);
        finally
          Request.Text:='';
          EnterCriticalSection(FLock); try FBusy:=False; finally LeaveCriticalSection(FLock); end;
        end;
      end
      else
      begin
        if (SentID<>0) and not FAllowed(SentID,SentEpoch) then
        begin SentID:=0; SentSerial:=0; SentStamp:=0; SentText:=''; end;
        FWake.WaitFor(20); // continue serving an owned X11 selection
      end;
    end;
  finally
    B.Free; SentText:=''; FRequest.Text:='';
  end;
end;
end.

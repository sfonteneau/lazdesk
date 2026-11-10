unit kvm_clipboard_client_worker;
{$mode objfpc}{$H+}{$B-}
interface
uses Classes, SysUtils, SyncObjs, kvm_clipboard_wire, kvm_clipboard_base;
type
  TKvmClipSend = procedure(const Packet: RawByteString) of object;
  TKvmClipboardClientWorker = class(TThread)
  private
    FLock: TRTLCriticalSection;
    FWake: TEvent;
    FFactory: TKvmClipboardFactory;
    FSend: TKvmClipSend;
    FMask,FDisabled: Byte;
    FEpoch,FGeneration: Cardinal;
    FMailbox: TKvmClipReply;
    FHaveReply: Boolean;
    FNotice: string;
    FLockReady: Boolean;
    procedure Notice(DisableMask: Byte; const Text: string);
    procedure GetConfig(out Mask: Byte; out Epoch,Generation: Cardinal);
    function TakeReply(out Reply: TKvmClipReply): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(Factory: TKvmClipboardFactory; Sender: TKvmClipSend);
    destructor Destroy; override;
    procedure Stop;
    procedure Configure(Mask: Byte; Epoch: Cardinal);
    function EnqueueReply(const Packet: RawByteString): Boolean;
    function TakeNotice(out DisableMask: Byte; out Text: string): Boolean;
  end;
implementation
constructor TKvmClipboardClientWorker.Create(Factory: TKvmClipboardFactory; Sender: TKvmClipSend);
begin
  inherited Create(True); FreeOnTerminate:=False;
  InitCriticalSection(FLock); FLockReady:=True;
  FWake:=TEvent.Create(nil,False,False,''); FFactory:=Factory; FSend:=Sender;
  FGeneration:=1; Start;
end;
procedure TKvmClipboardClientWorker.Stop;
begin Terminate; if FWake<>nil then FWake.SetEvent; end;
destructor TKvmClipboardClientWorker.Destroy;
begin
  Stop; inherited Destroy; // joins before the owner can destroy its WebSocket
  FWake.Free; if FLockReady then DoneCriticalSection(FLock);
end;
procedure TKvmClipboardClientWorker.Configure(Mask: Byte; Epoch: Cardinal);
begin
  Mask:=Mask and 3; if Epoch=0 then Mask:=0;
  EnterCriticalSection(FLock);
  try
    if (FMask=Mask) and (FEpoch=Epoch) then Exit;
    FMask:=Mask; FEpoch:=Epoch; FGeneration:=ClipNextSerial(FGeneration);
  finally LeaveCriticalSection(FLock); end;
  FWake.SetEvent;
end;
procedure TKvmClipboardClientWorker.GetConfig(out Mask: Byte; out Epoch,Generation: Cardinal);
begin
  EnterCriticalSection(FLock);
  try Mask:=FMask; Epoch:=FEpoch; Generation:=FGeneration;
  finally LeaveCriticalSection(FLock); end;
end;
procedure TKvmClipboardClientWorker.Notice(DisableMask: Byte; const Text: string);
begin
  EnterCriticalSection(FLock);
  try FDisabled:=FDisabled or DisableMask; FNotice:=Text;
  finally LeaveCriticalSection(FLock); end;
end;
function TKvmClipboardClientWorker.TakeNotice(out DisableMask: Byte; out Text: string): Boolean;
begin
  EnterCriticalSection(FLock);
  try
    DisableMask:=FDisabled; Text:=FNotice;
    Result:=(DisableMask<>0) or (Text<>''); FDisabled:=0; FNotice:='';
  finally LeaveCriticalSection(FLock); end;
end;
function TKvmClipboardClientWorker.EnqueueReply(const Packet: RawByteString): Boolean;
var R: TKvmClipReply;
begin
  Result:=False; if not ReadClipReply(Packet,R) then Exit;
  EnterCriticalSection(FLock);
  try
    if Terminated or FHaveReply then Exit;
    FMailbox:=R; FHaveReply:=True; Result:=True;
  finally LeaveCriticalSection(FLock); end;
  FWake.SetEvent;
end;
function TKvmClipboardClientWorker.TakeReply(out Reply: TKvmClipReply): Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Result:=FHaveReply;
    if Result then begin Reply:=FMailbox; FMailbox.Text:=''; FHaveReply:=False; end;
  finally LeaveCriticalSection(FLock); end;
end;
procedure TKvmClipboardClientWorker.Execute;
var B: TKvmClipboardBackend; Mask,OldMask,Blocked: Byte;
  Epoch,Gen,LastGen,LastEpoch,Serial,KnownRead,RequestGen: Cardinal;
  PollAt,SentAt,LocalReadAt,ApplyAt,LocalStamp,AtSendStamp,ReadStamp: QWord;
  Pending,HaveResponse,LocalValid,AtSendValid,CompareDone,SkipApply,LocalMatches: Boolean;
  LocalText,AtSendText,Text: RawByteString;
  Request: TKvmClipRequest; Response,Incoming: TKvmClipReply;
  Status: TKvmClipResult;
  procedure Disable(Which: Byte; const Msg: string);
  begin Blocked:=Blocked or Which; Notice(Which,Msg); end;
  procedure Finish;
  begin
    Pending:=False; HaveResponse:=False; Request.Text:=''; Response.Text:='';
    PollAt:=GetTickCount64+KVM_CLIP_POLL_MS; CompareDone:=False; ApplyAt:=0;
    if B<>nil then B.CancelRead;
  end;
  function StillCurrent: Boolean;
  var M: Byte; E,G: Cardinal;
  begin
    GetConfig(M,E,G);
    Result:=not Terminated and (G=RequestGen) and (E=Request.Epoch) and (M<>0);
  end;
begin
  B:=nil; Mask:=0; OldMask:=0; Blocked:=0; LastGen:=0; LastEpoch:=0;
  Serial:=0; KnownRead:=0; LocalStamp:=0; AtSendStamp:=0; ReadStamp:=0; PollAt:=0; SentAt:=0; LocalReadAt:=0; ApplyAt:=0;
  Pending:=False; HaveResponse:=False; LocalValid:=False; AtSendValid:=False;
  CompareDone:=False; LocalMatches:=False; Request.Text:=''; Response.Text:='';
  LocalText:=''; AtSendText:=''; Text:='';
  try
    if not Terminated then try B:=FFactory(); except B:=nil; end;
    while not Terminated do
    begin
      try
        if B<>nil then B.Pump;
        GetConfig(Mask,Epoch,Gen);
        if Gen<>LastGen then
        begin
          if (Epoch<>LastEpoch) or ((Mask and 1)<>0) and ((OldMask and 1)=0) then
          begin LocalValid:=False; LocalText:=''; end;
          if (Epoch<>LastEpoch) or ((Mask and 2)<>0) and ((OldMask and 2)=0) then KnownRead:=0;
          if Mask=0 then begin LocalValid:=False; LocalText:=''; KnownRead:=0; end;
          LastGen:=Gen; LastEpoch:=Epoch; OldMask:=Mask; Blocked:=0; PollAt:=0; LocalReadAt:=0;
          if B<>nil then B.CancelRead;
        end;
        Mask:=Mask and not Blocked;
        if TakeReply(Incoming) then
        begin
          if not Pending or HaveResponse or (Incoming.Serial<>Request.Serial) or
             (Incoming.Epoch<>Request.Epoch) then
          begin Disable(3,'Presse-papiers : reponse inattendue, synchronisation arretee.'); Finish; end
          else
          begin Response:=Incoming; HaveResponse:=True; CompareDone:=False; LocalMatches:=False; ApplyAt:=0; end;
          Incoming.Text:='';
        end;
        if Pending then
        begin
          if HaveResponse then
          begin
            if not StillCurrent then begin Finish; Continue; end;
            if ((Request.Flags and KVM_CLIP_WRITE)<>0) then
            begin
              if Response.WriteResult=crOk then
              begin LocalText:=Request.Text; LocalStamp:=AtSendStamp; LocalValid:=True; end
              else if Response.WriteResult=crBusy then
                Notice(0,'Presse-papiers distant occupe : nouvel essai apres liberation.')
              else Disable(1,'Presse-papiers local -> distant : '+ClipResultText(Response.WriteResult));
              // Process receipt only once, including if local clipboard is busy.
              Request.Flags:=Request.Flags and not KVM_CLIP_WRITE;
            end;
            if Response.HasText and ((Mask and KVM_CLIP_READ)<>0) then
            begin
              if ApplyAt=0 then ApplyAt:=GetTickCount64;
              SkipApply:=False;
              // Do not overwrite a newer local copy made while this RPC was
              // in flight. In bidirectional mode that newer local value wins.
              if not CompareDone then
              begin
                Status:=B.ReadText(Text);
                if (Status=crBusy) and (GetTickCount64-ApplyAt<2500) then
                begin FWake.WaitFor(20); Continue; end;
                B.CancelRead;
                ReadStamp:=B.ChangeStamp;
                LocalMatches:=(Status=crOk) and (Text=Response.Text);
                if (Status=crOk) and ((Mask and KVM_CLIP_WRITE)<>0) and AtSendValid and ((Text<>AtSendText) or
                  ((ReadStamp<>0) and (AtSendStamp<>0) and (ReadStamp<>AtSendStamp))) then SkipApply:=True;
              end;
              CompareDone:=True;
              if not StillCurrent then begin Finish; Continue; end;
              if SkipApply then begin KnownRead:=0; Finish; PollAt:=0; Continue; end;
              if LocalMatches then Status:=crOk // preserve richer local formats when text is identical
              else Status:=B.WriteText(Response.Text);
              if (Status=crBusy) and (GetTickCount64-ApplyAt<3000) then
              begin CompareDone:=False; FWake.WaitFor(20); Continue; end;
              if Status=crOk then
              begin
                // Suppression of echo: received text becomes the local baseline.
                LocalText:=Response.Text; LocalStamp:=B.ChangeStamp; LocalValid:=True; KnownRead:=Response.Serial;
                Notice(0,'Presse-papiers distant -> local : texte recu.');
              end
              else Disable(2,'Presse-papiers local : '+ClipResultText(Status));
            end
            else if (Response.ReadResult in [crDenied,crUnsupported,crFailed,crInvalid]) and
              ((Mask and KVM_CLIP_READ)<>0) then
              Disable(2,'Presse-papiers distant -> local : '+ClipResultText(Response.ReadResult))
            else if Response.ReadResult=crTooLarge then
              Notice(0,'Presse-papiers distant : texte superieur a 64 Kio, non copie.');
            Finish;
          end
          else if GetTickCount64-SentAt>KVM_CLIP_TIMEOUT_MS then
          begin
            Disable(3,'Presse-papiers : reponse absente. Aucun renvoi automatique du texte.');
            Finish;
          end;
          FWake.WaitFor(20); Continue;
        end;
        if (Mask=0) or (Epoch=0) or (GetTickCount64<PollAt) then
        begin FWake.WaitFor(20); Continue; end;
        if (B=nil) or not B.Ready then
        begin Disable(3,'Presse-papiers local indisponible (Wayland natif non pris en charge).'); Continue; end;
        Request.Text:=''; Request.Flags:=Mask and KVM_CLIP_READ;
        AtSendValid:=False; AtSendText:='';
        if (Mask and KVM_CLIP_WRITE)<>0 then
        begin
          if LocalReadAt=0 then LocalReadAt:=GetTickCount64;
          Status:=B.ReadText(Text);
          if (Status=crBusy) and (GetTickCount64-LocalReadAt<2500) then
          begin FWake.WaitFor(20); Continue; end;
          B.CancelRead; LocalReadAt:=0;
          if Status=crOk then
          begin
            AtSendText:=Text; AtSendValid:=True; AtSendStamp:=B.ChangeStamp;
            if not LocalValid or (LocalText<>Text) or
              ((AtSendStamp<>0) and (LocalStamp<>0) and (AtSendStamp<>LocalStamp)) then
            begin Request.Flags:=Request.Flags or KVM_CLIP_WRITE; Request.Text:=Text; end;
          end
          else if Status=crNoText then LocalValid:=False
          else if Status=crTooLarge then Notice(0,'Presse-papiers local : texte superieur a 64 Kio, non envoye.')
          else if Status<>crBusy then Disable(1,'Presse-papiers local : '+ClipResultText(Status));
        end;
        if Request.Flags=0 then begin PollAt:=GetTickCount64+KVM_CLIP_POLL_MS; Continue; end;
        // UI may have disabled a direction while ReadText waited on the OS.
        GetConfig(Mask,Epoch,Gen);
        if (Gen<>LastGen) or (Mask=0) then Continue;
        Serial:=ClipNextSerial(Serial); Request.Serial:=Serial; Request.Epoch:=Epoch;
        Request.KnownReadSerial:=KnownRead; RequestGen:=Gen;
        Pending:=True; HaveResponse:=False; SentAt:=GetTickCount64;
        FSend(MakeClipRequest(Request));
      except
        Disable(3,'Presse-papiers : erreur native, synchronisation arretee (contenu non journalise).');
        Finish;
      end;
      FWake.WaitFor(20);
    end;
  finally
    B.Free; LocalText:=''; AtSendText:=''; Request.Text:=''; Response.Text:='';
    FMailbox.Text:='';
  end;
end;
end.

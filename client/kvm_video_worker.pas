unit kvm_video_worker;
{$mode objfpc}{$H+}{$pointermath on}
// P1/P2: receive -> bounded FIFO -> decode -> CPU framebuffer commit -> ACK.
// Presentation is an independent, latest-complete-snapshot mailbox. Dropping
// a presentation does NOT drop a tile: every accepted delta is composited.
// No TBitmap, TCanvas, Synchronize or GUI callback is used on this thread.
interface
uses Classes, SysUtils, SyncObjs, Types, FPImage, FPReadJPEG, kvm_surface,
  kvm_frame, kvm_codec, kvm_turbojpeg_decode, kvm_surface_pool, kvm_wire;
const
  KVM_DECODE_QUEUE_PACKETS = 128;
  KVM_DECODE_QUEUE_BYTES = 16*1024*1024;
  KVM_DECODE_UI_EVENTS = 128;
type
  TKvmPacketList = array of RawByteString;
  TKvmDecodeReply = procedure(const Payload: RawByteString) of object;
  TKvmPresentation = record
    Surface: TKvmSurface;
    Epoch, Serial: Cardinal;
    ImageRevision: QWord; // unchanged for cursor-only presentations
    Available, CursorVisible: Boolean;
    Reason: Byte;
    CursorX, CursorY: Word;
    CursorShape: TKvmCursorShape;
    Damage: TRect; // source-pixel region changed since the last UI snapshot
  end;
  TKvmDecodeStats = record
    DecodeMs, CommitMs, CopyMs, CopiedBytes, QueueHighBytes: QWord;
    JpegCount, H264Count, NativeCount, FallbackCount: QWord;
    AckCount, NackCount, Coalesced: QWord;
  end;
  TKvmVideoWorker = class(TThread)
  private
    FLock: TRTLCriticalSection;
    FLockReady, FAccepting: Boolean;
    FWake: TEvent;
    FQueue: array[0..KVM_DECODE_QUEUE_PACKETS-1] of RawByteString;
    FHead, FCount: Integer;
    FBytes: Int64;
    FEvents: array[0..KVM_DECODE_UI_EVENTS-1] of RawByteString;
    FEventCount: Integer;
    FFatal, FLastDecodeError: string;
    FReply: TKvmDecodeReply;
    FTurbo: TKvmTurboJpegDecoder;
    FH264: TKvmH264Decoder;
    FImage: TFPMemoryImage;
    FReader: TFPReaderJPEG;
    FStream: TMemoryStream;
    FWork: TKvmPresentation;
    FSurfaces: TKvmSurfacePool;
    FPublished: TKvmPresentation;
    FHasPublished, FInvalid, FStateKnown, FBatchTouched: Boolean;
    FBatchDamage: TRect;
    FStats: TKvmDecodeStats;
    FPendingDecodeMs, FPendingCopyMs: QWord;
    function TakePacket(out Packet: RawByteString): Boolean;
    procedure Fail(const Reason: string);
    procedure PushUIEvent(const Packet: RawByteString);
    procedure Publish;
    procedure PixelsChanged(X,Y,W,H: Integer);
    function DecodeTile(const Packet: RawByteString): Boolean;
    function DecodeVideo(const Packet: RawByteString): Boolean;
    procedure Process(const Packet: RawByteString);
  protected
    procedure Execute; override;
  public
    constructor Create(EnableH264: Boolean; Reply: TKvmDecodeReply; PreferNative: Boolean = True);
    destructor Destroy; override;
    function NativeAvailable: Boolean;
    function H264Available: Boolean;
    // FLock in the owner protects the POINTER lifetime during Enqueue/Stop.
    function Enqueue(const Packet: RawByteString): Boolean;
    procedure Stop;
    procedure DrainUI(out Events: TKvmPacketList; out Snapshot: TKvmPresentation;
      out HasSnapshot: Boolean; out FatalError: string);
    procedure TakeStats(out Stats: TKvmDecodeStats);
  end;
implementation
uses kvm_extwire, kvm_jpeg_guard, kvm_client_log;

constructor TKvmVideoWorker.Create(EnableH264: Boolean; Reply: TKvmDecodeReply; PreferNative: Boolean);
begin
  inherited Create(True);
  FreeOnTerminate:=False;
  InitCriticalSection(FLock); FLockReady:=True;
  FWake:=TEvent.Create(nil,False,False,'');
  FReply:=Reply; FInvalid:=True;
  FSurfaces:=TKvmSurfacePool.Create;
  if PreferNative then FTurbo:=TKvmTurboJpegDecoder.Create;
  if not NativeAvailable then
  begin
    FImage:=TFPMemoryImage.Create(0,0);
    FReader:=TFPReaderJPEG.Create;
    FStream:=TMemoryStream.Create;
  end;
  if EnableH264 then
    try FH264:=TKvmH264Decoder.Create;
    except on E: Exception do FH264:=nil; end;
  FAccepting:=True;
  Start;
end;

destructor TKvmVideoWorker.Destroy;
begin
  Stop;
  // No Synchronize/Queue to the GUI: waiting cannot require a GUI callback.
  // TThread.Destroy also handles a constructor that failed before Start.
  inherited Destroy;
  FSurfaces.Free; FH264.Free; FTurbo.Free; FImage.Free; FReader.Free; FStream.Free;
  FWake.Free;
  if FLockReady then DoneCriticalSection(FLock);
end;

procedure TKvmVideoWorker.Stop;
begin
  if FLockReady then
  begin
    EnterCriticalSection(FLock);
    try FAccepting:=False; finally LeaveCriticalSection(FLock); end;
  end;
  Terminate;
  if FWake<>nil then FWake.SetEvent;
end;
function TKvmVideoWorker.NativeAvailable: Boolean;
begin Result:=(FTurbo<>nil) and FTurbo.Available; end;
function TKvmVideoWorker.H264Available: Boolean;
begin Result:=FH264<>nil; end;

procedure TKvmVideoWorker.Fail(const Reason: string);
begin
  EnterCriticalSection(FLock);
  try
    if FFatal='' then FFatal:=Reason;
    FAccepting:=False;
  finally LeaveCriticalSection(FLock); end;
end;

function TKvmVideoWorker.Enqueue(const Packet: RawByteString): Boolean;
var I: Integer;
begin
  Result:=False;
  EnterCriticalSection(FLock);
  try
    if not FAccepting then Exit;
    if (Length(Packet)<1) or
       (Length(Packet)>KVM_MAX_VIDEO_BYTES+KVM_VIDEO_HEADER) or
       (FCount>=KVM_DECODE_QUEUE_PACKETS) or
       (FBytes+Length(Packet)>KVM_DECODE_QUEUE_BYTES) then
    begin
      FFatal:='File decode pleine ou trame hors limite';
      FAccepting:=False; Exit;
    end;
    I:=(FHead+FCount) mod KVM_DECODE_QUEUE_PACKETS;
    FQueue[I]:=Packet; Inc(FCount); Inc(FBytes,Length(Packet));
    if QWord(FBytes)>FStats.QueueHighBytes then FStats.QueueHighBytes:=FBytes;
    Result:=True;
  finally LeaveCriticalSection(FLock); end;
  FWake.SetEvent;
end;

function TKvmVideoWorker.TakePacket(out Packet: RawByteString): Boolean;
begin
  Packet:='';
  EnterCriticalSection(FLock);
  try
    Result:=(FCount>0) and FAccepting;
    if not Result then Exit;
    Packet:=FQueue[FHead]; FQueue[FHead]:='';
    FHead:=(FHead+1) mod KVM_DECODE_QUEUE_PACKETS;
    Dec(FCount); Dec(FBytes,Length(Packet));
  finally LeaveCriticalSection(FLock); end;
end;

procedure TKvmVideoWorker.PushUIEvent(const Packet: RawByteString);
var N: Integer;
begin
  EnterCriticalSection(FLock);
  try
    N:=FEventCount;
    if N>=KVM_DECODE_UI_EVENTS then
      raise Exception.Create('File evenements de controle pleine');
    FEvents[N]:=Packet; Inc(FEventCount);
  finally LeaveCriticalSection(FLock); end;
end;

procedure AddDamage(var R: TRect; X,Y,W,H: Integer);
var N: TRect;
begin
  N:=Rect(X,Y,X+W,Y+H);
  if (R.Right<=R.Left) or (R.Bottom<=R.Top) then R:=N
  else
  begin
    if N.Left<R.Left then R.Left:=N.Left;
    if N.Top<R.Top then R.Top:=N.Top;
    if N.Right>R.Right then R.Right:=N.Right;
    if N.Bottom>R.Bottom then R.Bottom:=N.Bottom;
  end;
end;

procedure TKvmVideoWorker.PixelsChanged(X,Y,W,H: Integer);
begin
  FSurfaces.MarkDirty(X,Y,W,H);
  AddDamage(FBatchDamage,X,Y,W,H);
  if FWork.ImageRevision=High(QWord) then FWork.ImageRevision:=1
  else Inc(FWork.ImageRevision);
end;

procedure TKvmVideoWorker.Publish;
var Image: TKvmSurface; Tick, Bytes: QWord;
    OldDamage: TRect; OldW,OldH: Integer; HadPublished: Boolean;
begin
  OldDamage:=Rect(0,0,0,0); OldW:=0; OldH:=0; HadPublished:=False;
  EnterCriticalSection(FLock);
  try
    HadPublished:=FHasPublished;
    if HadPublished then
    begin
      Inc(FStats.Coalesced);
      OldDamage:=FPublished.Damage; OldW:=FPublished.Surface.Width; OldH:=FPublished.Surface.Height;
    end;
    // Release a superseded mailbox before looking for a reusable buffer.
    // A concurrent DrainUI sees no frame, never a half-built presentation.
    FHasPublished:=False; ClearSurface(FPublished.Surface);
  finally LeaveCriticalSection(FLock); end;
  // Pixel copies do not hold the queue/UI lock. Only the worker owns the
  // pool; external snapshots are immutable and protected by their refcounts.
  Tick:=GetTickCount64; Bytes:=0;
  if FWork.Available and SurfaceValid(FWork.Surface) then
  begin
    if not FSurfaces.Snapshot(FWork.Surface,Image,Bytes) then
      raise Exception.Create('Cannot publish CPU surface');
  end
  else ClearSurface(Image);
  Inc(FPendingCopyMs,GetTickCount64-Tick);
  EnterCriticalSection(FLock);
  try
    Inc(FStats.CopiedBytes,Bytes);
    FPublished:=FWork;
    FPublished.Surface:=Image;
    if HadPublished then
    begin
      if (OldW=FPublished.Surface.Width) and (OldH=FPublished.Surface.Height) then
      begin
        if (OldDamage.Right>OldDamage.Left) and (OldDamage.Bottom>OldDamage.Top) then
          AddDamage(FPublished.Damage,OldDamage.Left,OldDamage.Top,
            OldDamage.Right-OldDamage.Left,OldDamage.Bottom-OldDamage.Top);
      end
      else if SurfaceValid(FPublished.Surface) then
        FPublished.Damage:=Rect(0,0,FPublished.Surface.Width,FPublished.Surface.Height);
    end;
    FHasPublished:=True;
  finally LeaveCriticalSection(FLock); end;
end;

procedure TKvmVideoWorker.DrainUI(out Events: TKvmPacketList;
  out Snapshot: TKvmPresentation; out HasSnapshot: Boolean; out FatalError: string);
var I: Integer;
begin
  EnterCriticalSection(FLock);
  try
    SetLength(Events,FEventCount);
    for I:=0 to FEventCount-1 do
    begin Events[I]:=FEvents[I]; FEvents[I]:=''; end;
    FEventCount:=0;
    FatalError:=FFatal;
    HasSnapshot:=FHasPublished;
    if HasSnapshot then
    begin
      Snapshot:=FPublished; FHasPublished:=False;
      ClearSurface(FPublished.Surface);
    end;
  finally LeaveCriticalSection(FLock); end;
end;

procedure TKvmVideoWorker.TakeStats(out Stats: TKvmDecodeStats);
begin
  EnterCriticalSection(FLock);
  try Stats:=FStats; FillChar(FStats,SizeOf(FStats),0);
  finally LeaveCriticalSection(FLock); end;
end;

function TKvmVideoWorker.DecodeTile(const Packet: RawByteString): Boolean;
var X,Y,W,H: Word; JPEG: RawByteString; Tick: QWord;
    Row,Col: Integer; P: PByte; Color: TFPColor;
begin
  Result:=False;
  if not ReadTile(Packet,X,Y,W,H,JPEG) or not SurfaceValid(FWork.Surface) then Exit;
  if (Integer(X)+W>FWork.Surface.Width) or
     (Integer(Y)+H>FWork.Surface.Height) or not JpegMatchesSize(JPEG,W,H) then Exit;
  Tick:=GetTickCount64;
  UniqueString(FWork.Surface.Pixels);
  Inc(FPendingCopyMs,GetTickCount64-Tick);
  Tick:=GetTickCount64;
  try
    if NativeAvailable then
      Result:=FTurbo.DecodeIntoSurface(JPEG,X,Y,W,H,FWork.Surface)
    else
    begin
      // Pure FCL fallback, not TJPEGImage/TBitmap. It owns its reader/image
      // and stream and never accesses widgetset or GUI resources.
      FStream.Size:=0; FStream.Position:=0; FStream.WriteBuffer(JPEG[1],Length(JPEG)); FStream.Position:=0;
      FImage.LoadFromStream(FStream,FReader);
      if (FImage.Width<>W) or (FImage.Height<>H) then Exit;
      for Row:=0 to H-1 do
      begin
        P:=PByte(PtrUInt(Pointer(FWork.Surface.Pixels))+
          PtrUInt((Y+Row)*FWork.Surface.Width+X)*4);
        for Col:=0 to W-1 do
        begin
          Color:=FImage.Colors[Col,Row];
          P[0]:=Color.Blue shr 8; P[1]:=Color.Green shr 8;
          P[2]:=Color.Red shr 8; P[3]:=255; Inc(P,4);
        end;
      end;
      Result:=True;
    end;
  except on E: Exception do begin FLastDecodeError:=E.Message; Result:=False; end; end;
  Inc(FPendingDecodeMs,GetTickCount64-Tick);
  if Result then
  begin
    PixelsChanged(X,Y,W,H);
    EnterCriticalSection(FLock);
    try
      Inc(FStats.JpegCount);
      if NativeAvailable then Inc(FStats.NativeCount) else Inc(FStats.FallbackCount);
    finally LeaveCriticalSection(FLock); end;
  end;
end;

function TKvmVideoWorker.DecodeVideo(const Packet: RawByteString): Boolean;
var W,H: Word; AU: RawByteString; Error: string; Tick: QWord;
begin
  Result:=False;
  if (FH264=nil) or not ReadVideo(Packet,W,H,AU) then Exit;
  if (W<>FWork.Surface.Width) or (H<>FWork.Surface.Height) then Exit;
  Tick:=GetTickCount64;
  try
    Result:=FH264.DecodeIntoSurface(AU,W,H,FWork.Surface,Error);
    if not Result then FLastDecodeError:=Error;
  except on E: Exception do begin FLastDecodeError:=E.Message; Result:=False; end; end;
  Inc(FPendingDecodeMs,GetTickCount64-Tick);
  if Result then
  begin
    PixelsChanged(0,0,W,H);
    EnterCriticalSection(FLock);
    try Inc(FStats.H264Count); finally LeaveCriticalSection(FLock); end;
  end;
end;

procedure TKvmVideoWorker.Process(const Packet: RawByteString);
var W,H,CX,CY: Word; Visible1,Available,StateChanged: Boolean;
    Reason: Byte; Epoch,Serial: Cardinal; Tick: QWord; Shape: TKvmCursorShape;
begin
  case Packet[1] of
    'D':
      begin
        if not ReadDesktopState(Packet,Available,Reason,Epoch) then
          raise Exception.Create('Etat de session invalide');
        StateChanged:=not FStateKnown or (FWork.Available<>Available) or
          (FWork.Epoch<>Epoch) or (FWork.Reason<>Reason);
        if StateChanged then
        begin
          FStateKnown:=True;
          // Never keep pixels/control across a different desktop generation.
          if (FWork.Epoch<>Epoch) or not Available then
          begin
            ClearSurface(FWork.Surface); FSurfaces.Reset;
            FWork.CursorVisible:=False; ClearCursorShape(FWork.CursorShape); FInvalid:=True;
          end;
          FWork.Available:=Available; FWork.Reason:=Reason; FWork.Epoch:=Epoch;
          PushUIEvent(Packet);
          if not Available then
          begin FWork.Damage:=Rect(0,0,0,0); Publish; end;
        end;
      end;
    'S':
      begin
        if not FWork.Available or not ReadScreen(Packet,W,H) then
        begin FInvalid:=True; Exit; end;
        StateChanged:=FInvalid or (FWork.Surface.Width<>W) or (FWork.Surface.Height<>H);
        if not AllocateSurface(FWork.Surface,W,H) then
          raise Exception.Create('Dimensions ecran invalides');
        if StateChanged then
        begin
          FillChar(FWork.Surface.Pixels[1],Length(FWork.Surface.Pixels),0);
          FSurfaces.Reset; ClearCursorShape(FWork.CursorShape); PixelsChanged(0,0,W,H);
        end;
        FInvalid:=False; FBatchTouched:=True; FLastDecodeError:='';
      end;
    'T','V':
      if FWork.Available and not FInvalid then
      begin
        FLastDecodeError:='Image invalide ou geometry incoherente';
        if Packet[1]='T' then FInvalid:=not DecodeTile(Packet)
        else FInvalid:=not DecodeVideo(Packet);
        FBatchTouched:=True;
      end;
    'C':
      begin
        if not ReadCursor(Packet,CX,CY,Visible1) then
          raise Exception.Create('Curseur invalide');
        FWork.CursorX:=CX; FWork.CursorY:=CY;
        FWork.CursorVisible:=Visible1 and FWork.Available; FBatchTouched:=True;
      end;
    'H':
      begin
        if not ReadCursorShape(Packet,Shape) then
          raise Exception.Create('Forme de curseur invalide');
        FWork.CursorShape:=Shape;
        FBatchTouched:=True;
      end;
    'I':
      begin
        if Length(Packet)<>8 then raise Exception.Create('Accuse saisie invalide');
        PushUIEvent(Packet);
      end;
    'B':
      begin
        if not ReadBatchEnd(Packet,Serial) then raise Exception.Create('Fin de lot invalide');
        Tick:=GetTickCount64;
        FWork.Serial:=Serial;
        if FInvalid or not FWork.Available or not SurfaceValid(FWork.Surface) then
        begin
          EnterCriticalSection(FLock);
          try Inc(FStats.NackCount); finally LeaveCriticalSection(FLock); end;
          KvmClientLog('[client-video] NACK '+IntToStr(Serial)+': '+FLastDecodeError);
          // The server discards this flight and sends a new S. No ACK of
          // partially decoded data and no unbounded retry/refresh queue.
          if not Terminated and Assigned(FReply) then FReply(MakeBatchNack(Serial));
        end
        else
        begin
          FWork.Damage:=FBatchDamage;
          if FBatchTouched then Publish;
          EnterCriticalSection(FLock);
          try Inc(FStats.AckCount); finally LeaveCriticalSection(FLock); end;
          // ACK means decoded+composited, NOT painted. GUI can skip whole
          // presentations, never raw deltas, while CPU state stays current.
          if not Terminated and Assigned(FReply) then FReply(MakeBatchAck(Serial));
        end;
        EnterCriticalSection(FLock);
        try
          Inc(FStats.CommitMs,GetTickCount64-Tick);
          Inc(FStats.DecodeMs,FPendingDecodeMs); Inc(FStats.CopyMs,FPendingCopyMs);
        finally LeaveCriticalSection(FLock); end;
        FPendingDecodeMs:=0; FPendingCopyMs:=0; FBatchTouched:=False;
        FBatchDamage:=Rect(0,0,0,0);
      end;
  else raise Exception.Create('Type de trame binaire inconnu');
  end;
end;

procedure TKvmVideoWorker.Execute;
var Packet: RawByteString;
begin
  try
    while not Terminated do
      if TakePacket(Packet) then Process(Packet)
      else FWake.WaitFor(100);
  except on E: Exception do Fail(E.ClassName+': '+E.Message); end;
end;
end.

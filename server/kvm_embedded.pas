unit kvm_embedded;

{$mode objfpc}{$H+}

// Import this unit from any Free Pascal/Lazarus application to run LazDesk in
// that application's process. No separate LazDeskServer.exe is started.
// StartDirect() uses TTunnelLocal.OpenDirect() and has NO local listening socket.

interface

uses
  SysUtils, mormot.core.base, mormot.net.tunnel, mormot.net.ws.core,
  kvm_cli, kvm_server, kvm_direct_endpoint, kvm_direct_wire;

type
  EKvmEmbedded = class(Exception);

  TKvmEmbedded = class
  private
    FOptions: TKvmServerOptions;
    FServer: TKvmServer;
    FTunnel: TTunnelLocalServer;
    FEndpoint: TKvmDirectEndpoint;
    FEndpointRef: ITunnelTransmit; // reference-counted lifetime
    FSender: IKvmDirectSender;
    FDesktopConfigured: Boolean;
    procedure InitDesktop;
    procedure DirectInvalid;
  public
    constructor Create(const Options: TKvmServerOptions);
    destructor Destroy; override;
    // Still listens for regular LazDeskClient WebSockets, but inside the host
    // process rather than a standalone server executable.
    procedure StartWebSocket;
    // In-process capture/control + mORMot2 tunnel, with NO local HTTP/WS/TCP.
    // Transmit is the relay-side ITunnelTransmit supplied by the host application.
    // The other end must use TTunnelLocalClient.OpenDirect() and the same
    // single-byte text/binary tag (TKvmDirectEndpoint), then AUTH/KVM messages.
    // OpenDirect waits for the other end's handshake: call off the UI thread.
    procedure StartDirect(Session: TTunnelSession;
      const Transmit: ITunnelTransmit; const AppSecret: RawUtf8;
      TimeOutMS: Integer = 10000);
    procedure Stop;
    property Running: Boolean read FDesktopConfigured;
  end;

// Set defaults without reading command-line parameters (which belong to the
// host application). Always assign Options.Token before Start*() is called.
function DefaultEmbeddedKvmOptions: TKvmServerOptions;

implementation

uses kvm_security, kvm_desktop, kvm_monitors, kvm_wire, kvm_transport;

var
  ActiveEmbeddedInstance: LongInt = 0;

type
  TKvmDirectServerSender = class(TInterfacedObject, IKvmDirectSender)
  private
    FLock: TRTLCriticalSection;
    FEndpoint: TKvmDirectEndpoint; // valid until TKvmServer destroys sender
  public
    constructor Create(Endpoint: TKvmDirectEndpoint);
    destructor Destroy; override;
    function TrySend(const Frames: TWebSocketFrameDynArray): TKvmQueueResult;
  end;

constructor TKvmDirectServerSender.Create(Endpoint: TKvmDirectEndpoint);
begin
  inherited Create;
  InitCriticalSection(FLock);
  FEndpoint := Endpoint;
end;

destructor TKvmDirectServerSender.Destroy;
begin
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TKvmDirectServerSender.TrySend(
  const Frames: TWebSocketFrameDynArray): TKvmQueueResult;
var
  I: Integer;
  Bytes: Int64;
  Opcode: AnsiChar;
begin
  Result := kqrInvalid;
  if Length(Frames)=0 then Exit;
  if Length(Frames)>KVM_OUTGOING_MAX_FRAMES then Exit(kqrFull);
  Bytes := 0;
  for I:=0 to High(Frames) do
  begin
    if not (Frames[I].opcode in [focBinary,focText]) or
       (Length(Frames[I].payload)<1) then Exit;
    Inc(Bytes,Length(Frames[I].payload));
    if Length(Frames[I].payload)>KVM_DIRECT_FRAME_MAX_BYTES then Exit(kqrFull);
  end;
  if Bytes>KVM_OUTGOING_MAX_BYTES then Exit(kqrFull);
  EnterCriticalSection(FLock);
  try
    for I:=0 to High(Frames) do
    begin
      if Frames[I].opcode=focText then Opcode:='T' else Opcode:='B';
      if not FEndpoint.Send(Opcode,Frames[I].payload) then Exit(kqrClosed);
    end;
    Result := kqrQueued;
  finally LeaveCriticalSection(FLock); end;
end;

function DefaultEmbeddedKvmOptions: TKvmServerOptions;
begin
  Result := Default(TKvmServerOptions);
  Result.Listen := '127.0.0.1';
  Result.Port := 7900;
  Result.Encoder := 'turbojpeg';
  Result.BitrateKbps := 8000;
  Result.Backend := 'auto';
  Result.SessionPolicy := 'strict';
  Result.FPS := 3;
  Result.Quality := 65;
  Result.MaxWidth := KVM_MAX_FRAME_SIDE;
  Result.MaxHeight := KVM_MAX_FRAME_SIDE;
  Result.Monitor := 0;
end;

constructor TKvmEmbedded.Create(const Options: TKvmServerOptions);
begin
  inherited Create;
  FOptions:=Options;
end;

destructor TKvmEmbedded.Destroy;
begin
  Stop;
  inherited Destroy;
end;

procedure TKvmEmbedded.InitDesktop;
var
  Reason: string;
begin
  if FDesktopConfigured then raise EKvmEmbedded.Create('LazDesk already started');
  if not ValidKvmToken(FOptions.Token) then
    raise EKvmEmbedded.Create('A KVM control token of 16..256 ASCII characters is required');
  if (FOptions.ViewToken<>'') and
     ((not FOptions.AllowControl) or
      not ValidKvmToken(FOptions.ViewToken) or
      (FOptions.ViewToken=FOptions.Token)) then
    raise EKvmEmbedded.Create('Invalid view-only token');
  if (FOptions.Quality<1) or (FOptions.Quality>100) or
     (FOptions.FPS<0) or (FOptions.FPS>1000) or
     (FOptions.MaxWidth<64) or (FOptions.MaxWidth>KVM_MAX_FRAME_SIDE) or
     (FOptions.MaxHeight<64) or (FOptions.MaxHeight>KVM_MAX_FRAME_SIDE) then
    raise EKvmEmbedded.Create('Invalid capture dimensions, FPS or JPEG quality');
  if InterlockedCompareExchange(ActiveEmbeddedInstance,1,0)<>0 then
    raise EKvmEmbedded.Create('Only one embedded KVM server per process is supported');
  FDesktopConfigured := True;
  if not ConfigureDesktop(FOptions,Reason) then raise EKvmEmbedded.Create(Reason);
  if not DesktopBackendReady(FOptions.AllowControl,Reason) then
    raise EKvmEmbedded.Create('Capture/control unavailable: '+Reason);
  if not ConfigureDesktopMonitor(FOptions.Monitor,Reason) then
    raise EKvmEmbedded.Create('Monitor unavailable: '+Reason);
end;

procedure TKvmEmbedded.StartWebSocket;
begin
  if not KvmLoopbackHost(FOptions.Listen) and (FOptions.TLSCert='') and
     not FOptions.AllowInsecure then
    raise EKvmEmbedded.Create('Remote WebSocket binding without TLS denied');
  if (FOptions.TLSKey<>'') and (FOptions.TLSCert='') then
    raise EKvmEmbedded.Create('TLS key requires TLS certificate');
  if (FOptions.TLSCert<>'') and not FileExists(FOptions.TLSCert) then
    raise EKvmEmbedded.Create('TLS certificate not found');
  if (FOptions.TLSKey<>'') and not FileExists(FOptions.TLSKey) then
    raise EKvmEmbedded.Create('TLS private key not found');
  try
    InitDesktop;
    FServer := TKvmServer.Create(FOptions);
  except
    Stop;
    raise;
  end;
end;

procedure TKvmEmbedded.DirectInvalid;
begin
  if FServer<>nil then FServer.DirectClose;
end;

procedure TKvmEmbedded.StartDirect(Session: TTunnelSession;
  const Transmit: ITunnelTransmit; const AppSecret: RawUtf8;
  TimeOutMS: Integer);
begin
  // Requires upstream mORMot2 >= 2.4.17970 (commit 74cfe56d2), whose
  // OpenDirect() supports complete KVM frames up to 16 MiB.
  // The application itself enforces a stricter 3-MiB KVM frame bound.
  // Encryption is not optional for this hosted KVM API, even if the relay
  // happens to be on the same machine. The distinct KVM AUTH token still
  // provides protocol-level control/view-only permissions.
  if (Session=0) or (Transmit=nil) or (Length(AppSecret)<16) or
     (TimeOutMS<1) then
    raise EKvmEmbedded.Create('Invalid direct tunnel session, relay, or secret');
  if (FOptions.TLSCert<>'') or (FOptions.TLSKey<>'') then
    raise EKvmEmbedded.Create('TLS certificate is a WebSocket setting, not a direct tunnel setting');
  try
    InitDesktop;
    FServer := TKvmServer.Create(FOptions,True);
    FTunnel := TTunnelLocalServer.Create;
    FEndpoint := TKvmDirectEndpoint.Create;
    FEndpointRef := FEndpoint as ITunnelTransmit;
    FEndpoint.Attach(FTunnel,@FServer.DirectInput,@DirectInvalid);
    FSender := TKvmDirectServerSender.Create(FEndpoint);
    FServer.SetDirectSender(FSender);
    // Authenticated ECDHE handshake; blocks until opposite peer starts its
    // TTunnelLocalClient.OpenDirect call. No local TCP socket is opened.
    if not FTunnel.OpenDirect(Session,Transmit,FEndpointRef,[toEcdhe],
      TimeOutMS,AppSecret,[]) then
      raise EKvmEmbedded.Create('Direct tunnel handshake failed');
  except
    Stop;
    raise;
  end;
end;

procedure TKvmEmbedded.Stop;
begin
  if FEndpoint<>nil then FEndpoint.Detach;
  // Stop capture/encoder/clipboard threads while the tunnel still exists.
  FreeAndNil(FServer);
  FSender:=nil;
  if FTunnel<>nil then
  begin
    FTunnel.ClosePort;
    FreeAndNil(FTunnel);
  end;
  FEndpointRef:=nil;
  FEndpoint:=nil;
  if FDesktopConfigured then
  begin
    CloseDesktopCapture;
    ReleaseDesktop;
    FDesktopConfigured:=False;
    InterlockedCompareExchange(ActiveEmbeddedInstance,0,1);
  end;
end;

end.

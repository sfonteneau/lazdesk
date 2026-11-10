unit kvm_direct_endpoint;

{$mode objfpc}{$H+}

// ITunnelTransmit bridge for LazDesk's existing text/binary KVM messages.
// OpenDirect sends entire JPEG frames: no 64-KiB fragmentation layer.
// Both peers require upstream mORMot2 2.4.17970+ (16-MiB direct frames).

interface

uses SysUtils, mormot.core.base, mormot.net.tunnel, kvm_direct_wire;

type
  TKvmDirectMessageEvent = procedure(Opcode: AnsiChar;
    const Payload: RawByteString) of object;
  TKvmDirectErrorEvent = procedure of object;

  TKvmDirectEndpoint = class(TInterfacedObject, ITunnelTransmit)
  private
    FLock, FSendLock: TRTLCriticalSection;
    FTunnel: TTunnelLocal; // owned by the host, never by this class
    FClosed: Boolean;
    FOnMessage: TKvmDirectMessageEvent;
    FOnInvalid: TKvmDirectErrorEvent;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Attach(Tunnel: TTunnelLocal;
      OnMessage: TKvmDirectMessageEvent; OnInvalid: TKvmDirectErrorEvent);
    procedure Detach;
    // Send exactly one application frame per mORMot2 tunnel frame.
    function Send(Opcode: AnsiChar; const Payload: RawByteString): Boolean;
    // ITunnelTransmit: decrypted payload from TTunnelLocal.OpenDirect().
    procedure TunnelSend(const Frame: RawByteString);
    function TunnelInfo: variant;
  end;

implementation

uses Variants;

constructor TKvmDirectEndpoint.Create;
begin
  inherited Create;
  InitCriticalSection(FLock);
  InitCriticalSection(FSendLock);
end;

destructor TKvmDirectEndpoint.Destroy;
begin
  Detach;
  DoneCriticalSection(FSendLock);
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TKvmDirectEndpoint.Attach(Tunnel: TTunnelLocal;
  OnMessage: TKvmDirectMessageEvent; OnInvalid: TKvmDirectErrorEvent);
begin
  EnterCriticalSection(FLock);
  try
    if (FTunnel <> nil) or (Tunnel = nil) then
      raise Exception.Create('KVM direct endpoint already attached');
    FTunnel := Tunnel;
    FOnMessage := OnMessage;
    FOnInvalid := OnInvalid;
    FClosed := False;
  finally LeaveCriticalSection(FLock); end;
end;

procedure TKvmDirectEndpoint.Detach;
begin
  // Guard against in-flight synchronous receiver callbacks while the KVM
  // engine is being destroyed by its host application.
  EnterCriticalSection(FLock);
  try
    FClosed := True;
    FOnMessage := nil;
    FOnInvalid := nil;
  finally LeaveCriticalSection(FLock); end;
  EnterCriticalSection(FSendLock);
  try FTunnel := nil;
  finally LeaveCriticalSection(FSendLock); end;
end;

function TKvmDirectEndpoint.Send(Opcode: AnsiChar;
  const Payload: RawByteString): Boolean;
var
  Tunnel: TTunnelLocal;
begin
  Result := False;
  if not (Opcode in ['B','T']) or
     (Length(Payload)<1) or (Length(Payload)>KVM_DIRECT_FRAME_MAX_BYTES) then Exit;
  EnterCriticalSection(FSendLock);
  try
    Tunnel := FTunnel;
    if (Tunnel = nil) or (fClosed in Tunnel.Flags) then Exit;
    try
      // One mORMot GCM record per KVM message, preserving native ACK order.
      Tunnel.SendData(KvmDirectPack(Opcode,Payload));
      Result := True;
    except
      // Do not pretend a video batch was delivered if a send failed.
      Result := False;
    end;
  finally LeaveCriticalSection(FSendLock); end;
end;

procedure TKvmDirectEndpoint.TunnelSend(const Frame: RawByteString);
var
  Kind: AnsiChar;
  Payload: RawByteString;
begin
  EnterCriticalSection(FLock);
  try
    if FClosed then Exit;
    if KvmDirectUnpack(Frame,Kind,Payload) then
    begin
      if Assigned(FOnMessage) then FOnMessage(Kind,Payload);
    end
    else
    begin
      FClosed := True;
      if Assigned(FOnInvalid) then FOnInvalid;
    end;
  finally LeaveCriticalSection(FLock); end;
end;

function TKvmDirectEndpoint.TunnelInfo: variant;
begin
  Result := Null;
end;

end.

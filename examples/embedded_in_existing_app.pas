unit embedded_in_existing_app;

{$mode objfpc}{$H+}

// Example unit for inclusion in an existing Lazarus/FPC host application.
// The host controls lifecycle; no LazDeskServer.exe is started.
// DirectStart should be called from a host worker, not its UI event thread.

interface

uses SysUtils, mormot.core.base, mormot.net.tunnel, kvm_cli, kvm_embedded;

type
  TMyApplicationRemoteControl = class
  private
    FHost: TKvmEmbedded;
  public
    procedure StartRemoteDesktop(const Relay: ITunnelTransmit;
      Session: TTunnelSession; const TunnelSecret, KvmToken: RawUtf8);
    procedure StopRemoteDesktop;
    destructor Destroy; override;
  end;

implementation

procedure TMyApplicationRemoteControl.StartRemoteDesktop(
  const Relay: ITunnelTransmit; Session: TTunnelSession;
  const TunnelSecret, KvmToken: RawUtf8);
var
  Options: TKvmServerOptions;
begin
  if FHost <> nil then raise Exception.Create('Already running');
  Options := DefaultEmbeddedKvmOptions;
  Options.Token := string(KvmToken);
  Options.AllowControl := True;
  {$IFDEF WINDOWS}
  Options.Backend := 'gdi'; // Windows 7 compatible
  {$ENDIF}
  Options.FPS := 10;
  Options.Quality := 75;
  Options.Adaptive := True;
  FHost := TKvmEmbedded.Create(Options);
  try
    FHost.StartDirect(Session,Relay,TunnelSecret);
  except
    FreeAndNil(FHost);
    raise;
  end;
end;

procedure TMyApplicationRemoteControl.StopRemoteDesktop;
begin
  FreeAndNil(FHost);
end;

destructor TMyApplicationRemoteControl.Destroy;
begin
  StopRemoteDesktop;
  inherited Destroy;
end;

end.

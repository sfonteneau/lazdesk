program LazDeskServer;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, mormot.lib.openssl11, kvm_server, kvm_desktop, kvm_cli, kvm_monitors,
  {$IFDEF UNIX}BaseUnix, ctypes,{$ENDIF}
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  kvm_build_info, kvm_wire, Classes;

var
  Server: TKvmServer;
  Options: TKvmServerOptions;
  BindAddress, Reason, ErrorText: string;
  ShowHelp: Boolean;
  StopRequested: LongInt = 0;

{$IFDEF UNIX}
procedure SignalStop(Sig: cint); cdecl;
begin
  // Async-signal-safe: set a flag only (no RTL calls in a signal handler).
  StopRequested := 1;
end;
{$ENDIF}

{$IFDEF WINDOWS}
function ConsoleStop(Ctrl: DWORD): LongBool; stdcall;
begin
  Result := Ctrl in [CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT,
    CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT];
  if Result then StopRequested := 1;
end;
{$ENDIF}

begin
  if not ParseServerOptions(Options, ErrorText, ShowHelp) then
  begin
    WriteLn('Error: ', ErrorText);
    WriteLn(ServerUsage);
    Halt(2);
  end;
  if ShowHelp then
  begin
    WriteLn(ServerUsage);
    Halt(0);
  end;

  if not ConfigureDesktop(Options, Reason) then
  begin WriteLn('Error: ',Reason); Halt(2); end;
  if Options.ListMonitors then begin ListDesktopMonitors; Halt(0); end;

  WriteLn('LazDesk v9 / Lazarus + mORMot2');
  WriteLn('Build : ',KvmBuildDescription);
  WriteLn('Desktop backend: ', DesktopBackendName);
  if not DesktopBackendReady(Options.AllowControl, Reason) then
  begin
    WriteLn('Capture/control unavailable: ', Reason);
    Halt(3);
  end;
  if not ConfigureDesktopMonitor(Options.Monitor, Reason) then
  begin WriteLn('Capture unavailable: ', Reason); Halt(3); end;
  if (Options.TLSCert <> '') and not FileExists(Options.TLSCert) then
  begin
    WriteLn('TLS certificate file not found.');
    Halt(4);
  end;
  if (Options.TLSKey <> '') and not FileExists(Options.TLSKey) then
  begin
    WriteLn('TLS key file not found.');
    Halt(4);
  end;
  BindAddress := Options.Listen + ':' + IntToStr(Options.Port);
  if Options.Listen = '0.0.0.0' then
    WriteLn('WARNING: listening on all network interfaces.');
  Server := nil;
  try
    Server := TKvmServer.Create(Options);
    if Options.TLSCert <> '' then
      WriteLn('Listening: wss://', BindAddress, '/kvm ; protocole lazdesk8')
    else
      WriteLn('Listening: ws://', BindAddress, '/kvm ; protocole lazdesk8');
    if Options.FPS=0 then
      WriteLn('JPEG streaming: unlimited frame rate (capture/CPU/ACK); JPEG quality ',
        Options.Quality)
    else
      WriteLn('Diffusion JPEG/H264 selon codec negocie ; ', Options.FPS,
        ' requested frames/s; JPEG quality ', Options.Quality);
    if (Options.MaxWidth = KVM_MAX_FRAME_SIDE) and
       (Options.MaxHeight = KVM_MAX_FRAME_SIDE) then
      WriteLn('Resolution: NATIVE (multi-monitor desktop, no forced scaling)')
    else
      WriteLn('Resolution: limites explicites ', Options.MaxWidth, 'x',
        Options.MaxHeight);
    WriteLn('Dimension safety limits: ', KVM_MAX_FRAME_SIDE, ' per side; ',
      KVM_MAX_FRAME_PIXELS, ' pixels ; JPEG 4:4:4');
    if Options.Adaptive then
      WriteLn('Adaptive mode: ON (reduce resolution/quality if ACKs are slow)')
    else
      WriteLn('Adaptive mode: OFF');
    if Options.AllowControl then WriteLn('Mouse + keyboard: ENABLED')
    else WriteLn('Mouse + keyboard: DISABLED');
    if Options.TLSCert = '' then
      WriteLn('SECURITY: ws:// is unencrypted; use SSH/VPN, not direct Internet exposure.')
    else
      WriteLn('TLS enabled: verify the certificate with --tls [--tls-ca] on the client.');
    WriteLn('Requested encoder: ',Options.Encoder,'; session guard: ',Options.SessionPolicy);
    if Options.SessionPolicy='backend' then WriteLn('WARNING: unknown session state accepted; protection is limited to backend checks.');
    WriteLn('Token configured; value not displayed.');
    if Options.ViewToken <> '' then
      WriteLn('Separate view-only token: ENABLED');
    {$IFDEF UNIX}
    fpSignal(SIGINT, SignalHandler(@SignalStop));
    fpSignal(SIGTERM, SignalHandler(@SignalStop));
    {$ENDIF}
    {$IFDEF WINDOWS}
    SetConsoleCtrlHandler(@ConsoleStop, True);
    {$ENDIF}
    WriteLn('Server running. Stop with Ctrl+C or SIGTERM (no stdin required).');
    while StopRequested = 0 do Sleep(250);
    WriteLn('Stopping server...');
  except
    on E: Exception do
    begin
      WriteLn('Error ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
  Server.Free;
  ReleaseDesktop;
end.

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
    WriteLn('Erreur : ', ErrorText);
    WriteLn(ServerUsage);
    Halt(2);
  end;
  if ShowHelp then
  begin
    WriteLn(ServerUsage);
    Halt(0);
  end;

  if not ConfigureDesktop(Options, Reason) then
  begin WriteLn('Erreur: ',Reason); Halt(2); end;
  if Options.ListMonitors then begin ListDesktopMonitors; Halt(0); end;

  WriteLn('LazDesk v9 / Lazarus + mORMot2');
  WriteLn('Build : ',KvmBuildDescription);
  WriteLn('Moteur de bureau : ', DesktopBackendName);
  if not DesktopBackendReady(Options.AllowControl, Reason) then
  begin
    WriteLn('Capture/controle indisponible : ', Reason);
    Halt(3);
  end;
  if not ConfigureDesktopMonitor(Options.Monitor, Reason) then
  begin WriteLn('Capture indisponible : ', Reason); Halt(3); end;
  if (Options.TLSCert <> '') and not FileExists(Options.TLSCert) then
  begin
    WriteLn('Fichier de certificat TLS introuvable.');
    Halt(4);
  end;
  if (Options.TLSKey <> '') and not FileExists(Options.TLSKey) then
  begin
    WriteLn('Fichier de cle TLS introuvable.');
    Halt(4);
  end;
  BindAddress := Options.Listen + ':' + IntToStr(Options.Port);
  if Options.Listen = '0.0.0.0' then
    WriteLn('AVERTISSEMENT : ecoute sur toutes les interfaces reseau.');
  Server := nil;
  try
    Server := TKvmServer.Create(Options);
    if Options.TLSCert <> '' then
      WriteLn('Ecoute : wss://', BindAddress, '/kvm ; protocole lazdesk8')
    else
      WriteLn('Ecoute : ws://', BindAddress, '/kvm ; protocole lazdesk8');
    if Options.FPS=0 then
      WriteLn('Diffusion JPEG : cadence libre (capture/CPU/ACK) ; qualite JPEG ',
        Options.Quality)
    else
      WriteLn('Diffusion JPEG/H264 selon codec negocie ; ', Options.FPS,
        ' images/s demandees ; qualite JPEG ', Options.Quality);
    if (Options.MaxWidth = KVM_MAX_FRAME_SIDE) and
       (Options.MaxHeight = KVM_MAX_FRAME_SIDE) then
      WriteLn('Resolution : NATIVE (bureau multi-ecrans, sans redimensionnement impose)')
    else
      WriteLn('Resolution : limites explicites ', Options.MaxWidth, 'x',
        Options.MaxHeight);
    WriteLn('Securite dimensions : ', KVM_MAX_FRAME_SIDE, ' par cote ; ',
      KVM_MAX_FRAME_PIXELS, ' pixels ; JPEG 4:4:4');
    if Options.Adaptive then
      WriteLn('Adaptation : ACTIVE (resolution/qualite reduites si ACK lents)')
    else
      WriteLn('Adaptation : DESACTIVEE');
    if Options.AllowControl then WriteLn('Souris + clavier : ACTIVES')
    else WriteLn('Souris + clavier : DESACTIVES');
    if Options.TLSCert = '' then
      WriteLn('SECURITE : ws:// est en clair ; utiliser SSH/VPN, pas Internet direct.')
    else
      WriteLn('TLS actif : verifier le certificat avec --tls [--tls-ca] au client.');
    WriteLn('Encodeur demande : ',Options.Encoder,' ; garde session : ',Options.SessionPolicy);
    if Options.SessionPolicy='backend' then WriteLn('AVERTISSEMENT : etat de session inconnu accepte, protection limitee aux backends.');
    WriteLn('Token configure, non affiche.');
    if Options.ViewToken <> '' then
      WriteLn('Jeton vision distinct : ACTIF');
    {$IFDEF UNIX}
    fpSignal(SIGINT, SignalHandler(@SignalStop));
    fpSignal(SIGTERM, SignalHandler(@SignalStop));
    {$ENDIF}
    {$IFDEF WINDOWS}
    SetConsoleCtrlHandler(@ConsoleStop, True);
    {$ENDIF}
    WriteLn('Serveur actif. Arret par Ctrl+C ou SIGTERM (sans stdin).');
    while StopRequested = 0 do Sleep(250);
    WriteLn('Arret du serveur...');
  except
    on E: Exception do
    begin
      WriteLn('Erreur ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
  Server.Free;
  ReleaseDesktop;
end.

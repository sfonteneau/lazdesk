unit kvm_cli;

{$mode objfpc}{$H+}

interface

uses SysUtils;

type
  TKvmServerOptions = record
    Listen: string;
    Encoder, GPUDevice, SessionPolicy, MetricsCSV: string;
    BitrateKbps: Integer;
    AllowInsecure: Boolean;
    Backend: string;
    Port: Word;
    Token: string;
    ViewToken: string;
    TLSCert: string;
    TLSKey: string;
    FPS: Integer;
    Quality: Integer;
    AllowControl: Boolean;
    MaxWidth, MaxHeight, Monitor: Integer;
    Adaptive, ListMonitors: Boolean;
  end;

  TKvmClientOptions = record
    Host: string;
    AllowInsecure, H264: Boolean;
    Keyboard: string;
    Port: Word;
    Token: string;
    AutoConnect: Boolean;
    AutoControl: Boolean; // Ask the server for exclusive control after AUTH + active desktop.
    Maximized: Boolean; // Maximize the application window on startup.
    TLS: Boolean;
    TLSCA: string;
  end;

function ParseServerOptions(out Options: TKvmServerOptions;
  out ErrorText: string; out ShowHelp: Boolean): Boolean;
function ParseClientOptions(out Options: TKvmClientOptions;
  out ErrorText: string; out ShowHelp: Boolean): Boolean;
function ServerUsage: string;
function ClientUsage: string;
function ValidKvmToken(const Value: string): Boolean;

implementation

uses kvm_security, kvm_wire;

function IsUnsignedDecimal(const Value: string; out N: Integer): Boolean;
var
  I: Integer;
begin
  N := 0;
  Result := Value <> '';
  if not Result then Exit;
  for I := 1 to Length(Value) do
    if not (Value[I] in ['0'..'9']) then Exit(False);
  Result := TryStrToInt(Value, N) and (N >= 0);
end;

function IsIPv4(const Value: string): Boolean;
var
  I, C, At, N: Integer;
  Part: string;
begin
  Result := False;
  if (Length(Value) < 7) or (Length(Value) > 15) then Exit;
  At := 1;
  for C := 1 to 4 do
  begin
    I := At;
    while (I <= Length(Value)) and (Value[I] <> '.') do Inc(I);
    Part := Copy(Value, At, I - At);
    if (Length(Part) < 1) or (Length(Part) > 3) or
       not IsUnsignedDecimal(Part, N) or (N > 255) then Exit;
    if C < 4 then
    begin
      if I > Length(Value) then Exit;
      At := I + 1;
    end
    else if I <= Length(Value) then Exit;
  end;
  Result := True;
end;

function IsClientHost(const Value: string): Boolean;
var
  I: Integer;
begin
  Result := (Value <> '') and (Length(Value) <= 253);
  if not Result then Exit;
  // IPv4 or DNS name; do not accept URIs, paths or host:port pairs.
  for I := 1 to Length(Value) do
    if not (Value[I] in ['a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_']) then
      Exit(False);
end;

function ValidKvmToken(const Value: string): Boolean;
var
  I: Integer;
begin
  // Tokens are ASCII, without whitespace, to avoid shell/encoding surprises.
  Result := (Length(Value) >= 16) and (Length(Value) <= 256);
  if not Result then Exit;
  for I := 1 to Length(Value) do
    if not (Value[I] in [#33..#126]) then Exit(False);
end;

function ReadValue(const Key: string; var Index: Integer;
  out Value, ErrorText: string): Boolean;
var
  Arg: string;
begin
  Result := False;
  Arg := ParamStr(Index);
  if Arg = Key then
  begin
    if Index = ParamCount then
    begin
      ErrorText := 'Argument manquant pour ' + Key;
      Exit;
    end;
    Inc(Index);
    Value := ParamStr(Index);
  end
  else if Copy(Arg, 1, Length(Key) + 1) = Key + '=' then
    Value := Copy(Arg, Length(Key) + 2, MaxInt)
  else
  begin
    ErrorText := 'Option inconnue : ' + Arg;
    Exit;
  end;
  if Value = '' then
  begin
    ErrorText := 'Valeur vide pour ' + Key;
    Exit;
  end;
  Result := True;
end;

function ServerUsage: string;
begin
  Result :=
    'LazDeskServer [--listen IP] [--port PORT] [--token SECRET]' + LineEnding +
    '              [--view-token SECRET] [--fps 0|1..1000]' + LineEnding +
    '              [--quality 1..100] [--control]' + LineEnding +
    '              [--tls-cert FILE] [--tls-key FILE]' + LineEnding +
    '              [--backend auto|x11|portal|gdi|dxgi|sck]' + LineEnding +
    '              [--monitor N] [--list-monitors]' + LineEnding +
    '              [--native-resolution] [--max-width N --max-height N]' + LineEnding +
    '              [--adaptive|--no-adaptive]' + LineEnding +
    '              [--encoder turbojpeg|auto|h264_nvenc|h264_qsv|' + LineEnding +
    '                         h264_amf|h264_vaapi|h264_videotoolbox]' + LineEnding +
    '              [--bitrate-kbps 128..100000] [--gpu-device DEVICE]' + LineEnding +
    '              [--session-policy strict|backend] [--metrics-csv FILE]' + LineEnding +
    '              [--allow-insecure] (explicite pour ws distant, VPN requis)' + LineEnding +
    '--fps 0 : cadence libre (limitee par la capture, le CPU et les ACK).' + LineEnding +
    'Resolution native par defaut, y compris le bureau multi-ecrans.' + LineEnding +
    '--max-width/--max-height : reduction optionnelle de resolution.' + LineEnding +
    '--adaptive : autorise la baisse de resolution/qualite si ACK lents.' + LineEnding +
    'Limite de securite : 32768 pixels par cote, 67 108 864 pixels en tout.' + LineEnding +
    'Par defaut : --listen 127.0.0.1 --port 7900 --fps 3 --quality 65' + LineEnding +
    'Token : --token SECRET ou LAZDESK_TOKEN (16+ caracteres).' + LineEnding +
    '--control + --token : controle. --view-token / LAZDESK_VIEW_TOKEN : vision.' + LineEnding +
    'Exemple TLS : --listen 0.0.0.0 --port 7900 --tls-cert server.pem --tls-key server.key' + LineEnding +
    'TLS : --tls-cert avec certificat/cle PEM (ou PFX sur Windows).' + LineEnding +
    'Sans TLS, ws:// est en clair : utiliser un VPN ou un tunnel SSH.';
end;

function ClientUsage: string;
begin
  Result :=
    'LazDeskClient [--host IP-ou-DNS] [--port PORT] [--token SECRET]' + LineEnding +
    '              [--tls] [--tls-ca CERTIFICAT-CA-PEM]' + LineEnding +
    '              [--allow-insecure] [--no-h264] [--keyboard text|remote]' + LineEnding +
    '              [--control] [--maximized|--windowed]' + LineEnding +
    'Par defaut : --host 127.0.0.1 --port 7900 ;' + LineEnding +
    'token depuis --token ou LAZDESK_TOKEN, ou saisi dans la fenetre.' + LineEnding +
    'Fenetre 1080x730 par defaut ; --maximized maximise la fenetre normale.' + LineEnding +
    'Le span multi-ecrans est automatique selon la selection ; plein ecran via F8.' + LineEnding +
    '--control : demande le controle exclusif apres autorisation serveur et bureau actif.' + LineEnding +
    'Avec --host, --port ou --token et un token present, le client se connecte' +
    LineEnding + 'automatiquement ; sinon la fenetre permet la saisie manuelle.';
end;

function ParseServerOptions(out Options: TKvmServerOptions;
  out ErrorText: string; out ShowHelp: Boolean): Boolean;
var
  I, N: Integer;
  A, V: string;
  ProvidedToken: Boolean;
begin
  Options.Encoder := 'turbojpeg'; Options.GPUDevice := '';
  Options.SessionPolicy := 'strict'; Options.MetricsCSV := '';
  Options.BitrateKbps := 8000; Options.AllowInsecure := False;
  Options.Backend := 'auto';
  Options.Listen := '';
  Options.Token := '';
  Options.ViewToken := '';
  Options.TLSCert := '';
  Options.TLSKey := '';
  Options.Port := 0;
  Options.FPS := 0;
  Options.Quality := 0;
  Options.AllowControl := False;
  // Native dimensions are the default. Limits below are protocol/memory
  // guards, not an automatic scale to 1080p. Adaptation is opt-in.
  Options.Adaptive := False; Options.ListMonitors := False;
  Options.MaxWidth := KVM_MAX_FRAME_SIDE;
  Options.MaxHeight := KVM_MAX_FRAME_SIDE; Options.Monitor := 0;
  Options.Listen := '127.0.0.1';
  Options.Port := 7900;
  Options.FPS := 3;
  Options.Quality := 65;
  ErrorText := '';
  ShowHelp := False;
  ProvidedToken := False;
  Result := False;
  I := 1;
  while I <= ParamCount do
  begin
    A := ParamStr(I);
    if (A = '--help') or (A = '-h') then
    begin
      ShowHelp := True;
      Exit(True);
    end;
    if A = '--allow-insecure' then Options.AllowInsecure := True
    else if (A = '--encoder') or (Copy(A,1,10) = '--encoder=') then
    begin
      if not ReadValue('--encoder',I,V,ErrorText) then Exit;
      V:=LowerCase(V);
      if (V<>'turbojpeg') and (V<>'auto') and (V<>'h264_nvenc') and (V<>'h264_qsv') and
         (V<>'h264_amf') and (V<>'h264_vaapi') and (V<>'h264_videotoolbox') then
      begin ErrorText:='Encodeur non pris en charge'; Exit; end;
      Options.Encoder:=V;
    end
    else if (A = '--bitrate-kbps') or (Copy(A,1,15) = '--bitrate-kbps=') then
    begin
      if not ReadValue('--bitrate-kbps',I,V,ErrorText) then Exit;
      if not IsUnsignedDecimal(V,N) or (N<128) or (N>100000) then
      begin ErrorText:='--bitrate-kbps attend 128..100000'; Exit; end;
      Options.BitrateKbps:=N;
    end
    else if (A = '--gpu-device') or (Copy(A,1,13) = '--gpu-device=') then
    begin if not ReadValue('--gpu-device',I,Options.GPUDevice,ErrorText) then Exit; end
    else if (A = '--metrics-csv') or (Copy(A,1,14) = '--metrics-csv=') then
    begin if not ReadValue('--metrics-csv',I,Options.MetricsCSV,ErrorText) then Exit; end
    else if (A = '--session-policy') or (Copy(A,1,17) = '--session-policy=') then
    begin
      if not ReadValue('--session-policy',I,V,ErrorText) then Exit;
      if (V<>'strict') and (V<>'backend') then
      begin ErrorText:='--session-policy attend strict ou backend'; Exit; end;
      Options.SessionPolicy:=V;
    end
    else if A = '--list-monitors' then Options.ListMonitors := True
    else if A = '--no-adaptive' then Options.Adaptive := False
    else if A = '--adaptive' then Options.Adaptive := True
    else if A = '--native-resolution' then
    begin
      Options.MaxWidth := KVM_MAX_FRAME_SIDE;
      Options.MaxHeight := KVM_MAX_FRAME_SIDE;
    end
    else if (A = '--backend') or (Copy(A, 1, 10) = '--backend=') then
    begin
      if not ReadValue('--backend', I, V, ErrorText) then Exit;
      V := LowerCase(V);
      if (V <> 'auto') and (V <> 'x11') and (V <> 'portal') and
         (V <> 'gdi') and (V <> 'dxgi') and (V <> 'sck') then
      begin ErrorText := '--backend: auto, x11, portal, gdi, dxgi ou sck'; Exit; end;
      Options.Backend := V;
    end
    else if A = '--control' then
      Options.AllowControl := True
    else if (A = '--listen') or (Copy(A, 1, 9) = '--listen=') then
    begin
      if not ReadValue('--listen', I, V, ErrorText) then Exit;
      if not IsIPv4(V) then
      begin
        ErrorText := '--listen attend une adresse IPv4 (ex. 127.0.0.1 ou 0.0.0.0)';
        Exit;
      end;
      Options.Listen := V;
    end
    else if (A = '--port') or (Copy(A, 1, 7) = '--port=') then
    begin
      if not ReadValue('--port', I, V, ErrorText) then Exit;
      if not IsUnsignedDecimal(V, N) or (N < 1) or (N > 65535) then
      begin
        ErrorText := '--port doit etre entre 1 et 65535';
        Exit;
      end;
      Options.Port := Word(N);
    end
    else if (A = '--token') or (Copy(A, 1, 8) = '--token=') then
    begin
      if not ReadValue('--token', I, V, ErrorText) then Exit;
      Options.Token := V;
      ProvidedToken := True;
    end
    else if (A = '--view-token') or (Copy(A, 1, 13) = '--view-token=') then
    begin
      if not ReadValue('--view-token', I, V, ErrorText) then Exit;
      Options.ViewToken := V;
    end
    else if (A = '--tls-cert') or (Copy(A, 1, 11) = '--tls-cert=') then
    begin
      if not ReadValue('--tls-cert', I, V, ErrorText) then Exit;
      Options.TLSCert := V;
    end
    else if (A = '--tls-key') or (Copy(A, 1, 10) = '--tls-key=') then
    begin
      if not ReadValue('--tls-key', I, V, ErrorText) then Exit;
      Options.TLSKey := V;
    end
    else if (A = '--monitor') or (Copy(A, 1, 10) = '--monitor=') then
    begin
      if not ReadValue('--monitor', I, V, ErrorText) then Exit;
      if not IsUnsignedDecimal(V, N) or (N > 64) then
      begin ErrorText := '--monitor doit etre entre 0 et 64'; Exit; end;
      Options.Monitor := N;
    end
    else if (A = '--max-width') or (Copy(A, 1, 12) = '--max-width=') then
    begin
      if not ReadValue('--max-width', I, V, ErrorText) then Exit;
      if not IsUnsignedDecimal(V, N) or (N < 64) or (N > KVM_MAX_FRAME_SIDE) then
      begin ErrorText := '--max-width doit etre entre 64 et 32768'; Exit; end;
      Options.MaxWidth := N;
    end
    else if (A = '--max-height') or (Copy(A, 1, 13) = '--max-height=') then
    begin
      if not ReadValue('--max-height', I, V, ErrorText) then Exit;
      if not IsUnsignedDecimal(V, N) or (N < 64) or (N > KVM_MAX_FRAME_SIDE) then
      begin ErrorText := '--max-height doit etre entre 64 et 32768'; Exit; end;
      Options.MaxHeight := N;
    end
    else if (A = '--fps') or (Copy(A, 1, 6) = '--fps=') then
    begin
      if not ReadValue('--fps', I, V, ErrorText) then Exit;
      if not IsUnsignedDecimal(V, N) or (N > 1000) then
      begin
        ErrorText := '--fps attend 0 (libre) ou 1..1000';
        Exit;
      end;
      Options.FPS := N;
    end
    else if (A = '--quality') or (Copy(A, 1, 10) = '--quality=') then
    begin
      if not ReadValue('--quality', I, V, ErrorText) then Exit;
      if not IsUnsignedDecimal(V, N) or (N < 1) or (N > 100) then
      begin
        ErrorText := '--quality doit etre entre 1 et 100';
        Exit;
      end;
      Options.Quality := N;
    end
    else
    begin
      ErrorText := 'Option inconnue : ' + A;
      Exit;
    end;
    Inc(I);
  end;
  // MaxWidth/MaxHeight are independent OPTIONAL downscale bounds; the
  // physical capture dimensions are validated against the pixel safety cap.
  // Rejecting the PRODUCT of these maxima breaks native multi-monitor mode.
  if Options.ListMonitors then Exit(True);
  if not KvmLoopbackHost(Options.Listen) and (Options.TLSCert='') and not Options.AllowInsecure then
  begin ErrorText:='Ecoute distante sans TLS refusee. Configurer TLS ou --allow-insecure derriere un VPN.'; Exit; end;
  if not ProvidedToken then
    Options.Token := GetEnvironmentVariable('LAZDESK_TOKEN');
  if not ValidKvmToken(Options.Token) then
  begin
    ErrorText := 'Token obligatoire : 16 a 256 caracteres ASCII sans espace.';
    Exit;
  end;
  if (Options.TLSKey <> '') and (Options.TLSCert = '') then
  begin
    ErrorText := '--tls-key necessite --tls-cert';
    Exit(False);
  end;
  if Options.ViewToken = '' then
    Options.ViewToken := GetEnvironmentVariable('LAZDESK_VIEW_TOKEN');
  if Options.ViewToken <> '' then
  begin
    if not Options.AllowControl then
    begin
      ErrorText := '--view-token necessite --control';
      Exit(False);
    end;
    if not ValidKvmToken(Options.ViewToken) then
    begin
      ErrorText := '--view-token invalide (16..256 ASCII)';
      Exit(False);
    end;
    if Options.Token = Options.ViewToken then
    begin
      ErrorText := '--view-token et --token doivent etre differents';
      Exit(False);
    end;
  end;
  Result := True;
end;

function ParseClientOptions(out Options: TKvmClientOptions;
  out ErrorText: string; out ShowHelp: Boolean): Boolean;
var
  I, N: Integer;
  A, V: string;
  AnyOption, ProvidedToken: Boolean;
begin
  Options.AllowInsecure := False; Options.H264 := True; Options.Keyboard := 'text';
  Options.Host := '';
  Options.Token := '';
  Options.Port := 0;
  Options.AutoConnect := False;
  Options.AutoControl := False;
  Options.Maximized := False;
  Options.TLS := False;
  Options.TLSCA := '';
  Options.Host := '127.0.0.1';
  Options.Port := 7900;
  ErrorText := '';
  ShowHelp := False;
  AnyOption := False;
  ProvidedToken := False;
  Result := False;
  I := 1;
  while I <= ParamCount do
  begin
    A := ParamStr(I);
    if (A = '--help') or (A = '-h') then
    begin
      ShowHelp := True;
      Exit(True);
    end;
    if A = '--allow-insecure' then Options.AllowInsecure := True
    else if A = '--control' then Options.AutoControl := True
    else if A = '--auto-control' then Options.AutoControl := True
    else if A = '--windowed' then Options.Maximized := False
    else if A = '--maximized' then Options.Maximized := True
    else if A = '--no-h264' then Options.H264 := False
    else if (A='--keyboard') or (Copy(A,1,11)='--keyboard=') then
    begin
      if not ReadValue('--keyboard',I,V,ErrorText) then Exit;
      if (V<>'text') and (V<>'remote') then
      begin ErrorText:='--keyboard attend text ou remote'; Exit; end;
      Options.Keyboard:=V;
    end
    else if A = '--tls' then
      Options.TLS := True
    else if (A = '--tls-ca') or (Copy(A, 1, 9) = '--tls-ca=') then
    begin
      if not ReadValue('--tls-ca', I, V, ErrorText) then Exit;
      Options.TLSCA := V;
      Options.TLS := True;
    end
    else if (A = '--host') or (Copy(A, 1, 7) = '--host=') then
    begin
      if not ReadValue('--host', I, V, ErrorText) then Exit;
      if not IsClientHost(V) then
      begin
        ErrorText := '--host attend une adresse IPv4 ou un nom DNS, sans schema ni port';
        Exit;
      end;
      Options.Host := V;
    end
    else if (A = '--port') or (Copy(A, 1, 7) = '--port=') then
    begin
      if not ReadValue('--port', I, V, ErrorText) then Exit;
      if not IsUnsignedDecimal(V, N) or (N < 1) or (N > 65535) then
      begin
        ErrorText := '--port doit etre entre 1 et 65535';
        Exit;
      end;
      Options.Port := Word(N);
    end
    else if (A = '--token') or (Copy(A, 1, 8) = '--token=') then
    begin
      if not ReadValue('--token', I, V, ErrorText) then Exit;
      Options.Token := V;
      ProvidedToken := True;
    end
    else
    begin
      ErrorText := 'Option inconnue : ' + A;
      Exit;
    end;
    AnyOption := True;
    Inc(I);
  end;
  if not ProvidedToken then
    Options.Token := GetEnvironmentVariable('LAZDESK_TOKEN');
  if (Options.Token <> '') and not ValidKvmToken(Options.Token) then
  begin
    ErrorText := 'Token invalide : 16 a 256 caracteres ASCII sans espace.';
    Exit;
  end;
  Options.AutoConnect := AnyOption and (Options.Token <> '');
  Result := True;
end;

end.

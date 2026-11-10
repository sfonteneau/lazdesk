program test_server_options;
{$mode objfpc}{$H+}
uses SysUtils, kvm_cli;
var
  O: TKvmServerOptions;
  Err: string;
  Help: Boolean;
begin
  if not ParseServerOptions(O, Err, Help) then
  begin
    WriteLn('ERROR=', Err);
    Halt(2);
  end;
  if Help then
  begin
    WriteLn('HELP');
    Halt(0);
  end;
  WriteLn('ENCODER=',O.Encoder);
  WriteLn('BITRATE=',O.BitrateKbps);
  WriteLn('SESSIONPOLICY=',O.SessionPolicy);
  WriteLn('ALLOWINSECURE=',Ord(O.AllowInsecure));
  WriteLn('BACKEND=', O.Backend);
  WriteLn('LISTEN=', O.Listen);
  WriteLn('PORT=', O.Port);
  WriteLn('FPS=', O.FPS);
  WriteLn('QUALITY=', O.Quality);
  WriteLn('CONTROL=', Ord(O.AllowControl));
  WriteLn('TOKENLEN=', Length(O.Token));
  WriteLn('VIEWTOKENLEN=', Length(O.ViewToken));
  WriteLn('TLS=', Ord(O.TLSCert <> ''));
  WriteLn('MAXWIDTH=', O.MaxWidth);
  WriteLn('MAXHEIGHT=', O.MaxHeight);
  WriteLn('MONITOR=', O.Monitor);
  WriteLn('LISTMONITORS=', Ord(O.ListMonitors));
  WriteLn('ADAPTIVE=', Ord(O.Adaptive));
end.

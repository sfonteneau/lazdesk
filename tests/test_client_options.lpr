program test_client_options;
{$mode objfpc}{$H+}
uses SysUtils, kvm_cli;
var
  O: TKvmClientOptions;
  Err: string;
  Help: Boolean;
begin
  if not ParseClientOptions(O, Err, Help) then
  begin
    WriteLn('ERROR=', Err);
    Halt(2);
  end;
  if Help then
  begin
    WriteLn('HELP');
    Halt(0);
  end;
  WriteLn('KEYBOARD=',O.Keyboard);
  WriteLn('H264=',Ord(O.H264));
  WriteLn('ALLOWINSECURE=',Ord(O.AllowInsecure));
  WriteLn('HOST=', O.Host);
  WriteLn('PORT=', O.Port);
  WriteLn('AUTOCONNECT=', Ord(O.AutoConnect));
  WriteLn('AUTOCONTROL=', Ord(O.AutoControl));
  WriteLn('MAXIMIZED=', Ord(O.Maximized));
  WriteLn('TOKENLEN=', Length(O.Token));
  WriteLn('TLS=', Ord(O.TLS));
end.

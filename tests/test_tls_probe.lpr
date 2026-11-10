program test_tls_probe;
{$mode objfpc}{$H+}
uses {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, mormot.core.base, mormot.net.sock, mormot.net.ws.core,
  mormot.net.ws.client, kvm_wire, kvm_tls_policy;
var C: THttpClientWebSockets; P: TWebSocketProtocolChat; TLS: TNetTlsContext;
begin
  if ParamCount<>3 then begin WriteLn('Usage: test_tls_probe HOST PORT CA_FILE'); Halt(2); end;
  C:=nil;
  try
    PrepareClientTls(ParamStr(3),TLS);
    P:=TWebSocketProtocolChat.Create(KVM_SUBPROTOCOL,KVM_WS_PATH,nil);
    C:=THttpClientWebSockets.WebSocketsConnect(RawUtf8(ParamStr(1)),RawUtf8(ParamStr(2)),P,
      nil,'',KVM_WS_PATH,'',True,@TLS);
    if C=nil then raise Exception.Create('TLS/upgrade refuse');
    WriteLn('TLS_ACCEPTED');
  except on E: Exception do begin WriteLn('TLS_REJECTED: ',E.Message); ExitCode:=1; end; end;
  C.Free;
end.

unit kvm_tls_policy;
{$mode objfpc}{$H+}
interface
uses SysUtils, mormot.core.base, mormot.net.sock;
procedure PrepareClientTls(const CAFile: string; var Context: TNetTlsContext);
implementation
uses mormot.lib.openssl11;
procedure PrepareClientTls(const CAFile: string; var Context: TNetTlsContext);
begin
  if (CAFile<>'') and not FileExists(CAFile) then raise Exception.Create('TLS CA file not found');
  InitNetTlsContext(Context);
  Context.IgnoreCertificateErrors:=False;
  if CAFile<>'' then Context.CACertificatesFile:=RawUtf8(CAFile);
end;
end.

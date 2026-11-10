unit viewer_separate_window;

{$mode objfpc}{$H+}

// Example of opening a separate LazDesk viewer window from an existing
// Lazarus form without launching LazDeskClient.exe.
// Include LazDeskViewer.lpk in the host project.

interface

uses
  Classes, SysUtils, kvm_cli, kvm_viewer_window;

function ShowRemoteDesktop(AOwner: TComponent;
  const AHost, AToken: string; UseTLS: Boolean): TKvmViewerWindow;

implementation

function ShowRemoteDesktop(AOwner: TComponent;
  const AHost, AToken: string; UseTLS: Boolean): TKvmViewerWindow;
var
  Options: TKvmClientOptions;
begin
  Options := DefaultViewerWindowOptions;
  Options.Host := AHost;
  Options.Port := 7900;
  Options.Token := AToken; // secrets remain in the host process
  Options.TLS := UseTLS;
  Options.AutoControl := False;
  Result := OpenLazDeskViewerWindow(AOwner, Options);
end;

end.

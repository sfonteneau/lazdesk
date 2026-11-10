unit viewer_in_existing_form;

{$mode objfpc}{$H+}

// Example integration into an EXISTING Lazarus form.
// Add LazDeskViewer.lpk and put this unit in the host project.
// In the host form, create a Panel named DesktopPanel and call
// AttachLazDeskViewer(DesktopPanel, 'host.example', token, True).
// The caller owns the returned frame and may call Disconnect/Free.

interface

uses
  Classes, Controls, SysUtils, kvm_cli, kvm_viewer_frame;

function AttachLazDeskViewer(AParent: TWinControl;
  const AHost, AToken: string; UseTLS: Boolean): TKvmViewerFrame;

implementation

function AttachLazDeskViewer(AParent: TWinControl;
  const AHost, AToken: string; UseTLS: Boolean): TKvmViewerFrame;
var
  Options: TKvmClientOptions;
begin
  Result := TKvmViewerFrame.Create(AParent);
  try
    Result.Parent := AParent;
    Result.Align := alClient;
    Options := DefaultViewerOptions;
    Options.Host := AHost;
    Options.Port := 7900;
    Options.Token := AToken;  // host is responsible for protecting the secret
    Options.TLS := UseTLS;
    Options.AutoControl := False; // read-only until TakeControl(True)
    Result.Configure(Options);
    Result.Connect; // an ordinary WebSocket connection, from the LCL main thread
  except
    Result.Free;
    raise;
  end;
end;

end.

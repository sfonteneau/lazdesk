unit kvm_viewer_window;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, kvm_cli, kvm_view_form;

type
  // A modeless, independent LCL window hosted in the caller's process.
  // No LazDeskClient process or separate viewer executable is started.
  // Create it on the LCL GUI thread, after Application.Initialize.
  TKvmViewerWindow = class(TKvmViewForm)
  private
    FOnWindowClosed: TNotifyEvent;
    procedure WindowClosing(Sender: TObject; var CloseAction: TCloseAction);
  public
    constructor Create(AOwner: TComponent); override;
    procedure Configure(const Options: TKvmClientOptions);
    procedure TakeControl(Enabled: Boolean);
    // Called when the user closes this viewer window, BEFORE it is freed.
    // The host can clear its stored reference here; it must not free Sender.
    property OnWindowClosed: TNotifyEvent read FOnWindowClosed write FOnWindowClosed;
  end;

// Defaults for a viewer created directly by an LCL host application.
function DefaultViewerWindowOptions: TKvmClientOptions;

// Create, configure, show, and (optionally) connect a modeless viewer.
// The returned pointer becomes invalid when the user closes the window.
// Set OnWindowClosed to clear any reference retained by the host.
function OpenLazDeskViewerWindow(AOwner: TComponent;
  const Options: TKvmClientOptions;
  ConnectNow: Boolean = True): TKvmViewerWindow;

implementation

function DefaultViewerWindowOptions: TKvmClientOptions;
begin
  Result.Host := '127.0.0.1';
  Result.Port := 7900;
  Result.Token := '';
  Result.AllowInsecure := False;
  Result.H264 := True;
  Result.Keyboard := 'text';
  Result.AutoConnect := False;
  Result.AutoControl := False;
  Result.Maximized := False;
  Result.TLS := False;
  Result.TLSCA := '';
end;

constructor TKvmViewerWindow.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  // A secondary window must not terminate the host when it is closed.
  // TForm defaults to hiding a modeless secondary form; use caFree instead
  // so the connection, timers and decoder workers are released.
  OnClose := @WindowClosing;
end;

procedure TKvmViewerWindow.WindowClosing(Sender: TObject;
  var CloseAction: TCloseAction);
begin
  CloseAction := caFree;
  // Notify before LCL schedules destruction, so the host can forget the
  // pointer. The base form's destructor closes the socket and its workers.
  if Assigned(FOnWindowClosed) then
    FOnWindowClosed(Self);
end;

procedure TKvmViewerWindow.Configure(const Options: TKvmClientOptions);
var
  Local: TKvmClientOptions;
begin
  if Connected then
    raise Exception.Create('Disconnect the viewer before changing connection options.');
  Local := Options;
  // The host chooses when to show and connect its separate window.
  // Prevent the legacy timer-based CLI auto-connect from racing the host.
  Local.AutoConnect := False;
  ApplyOptions(Local);
end;

procedure TKvmViewerWindow.TakeControl(Enabled: Boolean);
begin
  RequestControl(Enabled);
end;

function OpenLazDeskViewerWindow(AOwner: TComponent;
  const Options: TKvmClientOptions;
  ConnectNow: Boolean): TKvmViewerWindow;
begin
  Result := TKvmViewerWindow.Create(AOwner);
  try
    Result.Configure(Options);
    Result.Show; // creates a normal native top-level window (HWND on Windows)
    if ConnectNow then
      Result.Connect;
  except
    Result.Free;
    raise;
  end;
end;

end.

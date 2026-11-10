unit kvm_viewer_frame;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics,
  kvm_cli, kvm_view_form;

type
  // Drop-in viewer for an existing Lazarus LCL window (TPanel, TTabSheet,
  // or another TWinControl). The legacy TForm remains a private borderless
  // child for now; there is no separate client process or top-level window.
  TKvmViewerFrame = class(TFrame)
  private
    FViewer: TKvmViewForm;
    FOnStatusChange: TNotifyEvent;
    procedure ViewerStatusChanged(Sender: TObject);
    function GetStatusText: string;
    function GetConnected: Boolean;
    function GetAuthenticated: Boolean;
    function GetControlGranted: Boolean;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Configure(const Options: TKvmClientOptions);
    procedure Connect;
    procedure Disconnect;
    procedure TakeControl(Enabled: Boolean);
    procedure RefreshDesktop;
    procedure ReleaseLocalInputs;
    property StatusText: string read GetStatusText;
    property Connected: Boolean read GetConnected;
    property Authenticated: Boolean read GetAuthenticated;
    property HasControl: Boolean read GetControlGranted;
    property OnStatusChange: TNotifyEvent read FOnStatusChange write FOnStatusChange;
  end;

function DefaultViewerOptions: TKvmClientOptions;

implementation

{$R *.lfm}

function DefaultViewerOptions: TKvmClientOptions;
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

constructor TKvmViewerFrame.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Align := alClient;
  Color := clBlack;
  FViewer := TKvmViewForm.Create(Self);
  FViewer.EnableEmbeddedMode;
  FViewer.Parent := Self;
  FViewer.Align := alClient;
  FViewer.OnStatusChange := @ViewerStatusChanged;
  FViewer.Show;
end;

destructor TKvmViewerFrame.Destroy;
begin
  if FViewer <> nil then
  begin
    // The form's destructor joins decoder and clipboard workers, and closes
    // the socket before the parent frame and its controls are destroyed.
    FViewer.OnStatusChange := nil;
    FreeAndNil(FViewer);
  end;
  inherited Destroy;
end;

procedure TKvmViewerFrame.ViewerStatusChanged(Sender: TObject);
begin
  if Assigned(FOnStatusChange) then FOnStatusChange(Self);
end;

procedure TKvmViewerFrame.Configure(const Options: TKvmClientOptions);
var
  Local: TKvmClientOptions;
begin
  if FViewer.Connected then
    raise Exception.Create('Disconnect the viewer before changing connection options.');
  Local := Options;
  Local.Maximized := False;  // host controls window size
  Local.AutoConnect := False; // connect explicitly through the host API
  FViewer.ApplyOptions(Local);
end;

procedure TKvmViewerFrame.Connect;
begin
  FViewer.Connect;
end;

procedure TKvmViewerFrame.Disconnect;
begin
  FViewer.Disconnect;
end;

procedure TKvmViewerFrame.TakeControl(Enabled: Boolean);
begin
  FViewer.RequestControl(Enabled);
end;

procedure TKvmViewerFrame.RefreshDesktop;
begin
  FViewer.RefreshDesktop;
end;

procedure TKvmViewerFrame.ReleaseLocalInputs;
begin
  FViewer.ReleaseLocalInputs;
end;

function TKvmViewerFrame.GetStatusText: string;
begin
  Result := FViewer.StatusText;
end;

function TKvmViewerFrame.GetConnected: Boolean;
begin
  Result := FViewer.Connected;
end;

function TKvmViewerFrame.GetAuthenticated: Boolean;
begin
  Result := FViewer.Authenticated;
end;

function TKvmViewerFrame.GetControlGranted: Boolean;
begin
  Result := FViewer.ControlGranted;
end;

end.

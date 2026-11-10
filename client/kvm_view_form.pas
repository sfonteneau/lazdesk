unit kvm_view_form;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, ExtCtrls, StdCtrls, Menus,
  Dialogs, Types, LCLType, LCLIntf, Math, GraphType,
  mormot.core.base, mormot.net.sock, mormot.net.client,
  mormot.net.ws.core, mormot.net.ws.client,
  kvm_wire, kvm_cli, kvm_jpeg_guard, kvm_extwire, kvm_codec, kvm_frame,
  kvm_rgb_bitmap, kvm_input_queue, kvm_security, kvm_tls_policy,
  kvm_video_worker, kvm_surface, kvm_client_log,
  kvm_clipboard_wire, kvm_clipboard_native, kvm_clipboard_client_worker
  {$IFDEF WINDOWS}, kvm_present_win{$ENDIF};

type
  TKvmMouseEcho = record
    X, Y: Word;
    Tick: QWord;
  end;

  TKvmRemoteMonitor = record
    X, Y, W, H: Integer;
  end;
  TKvmRemoteMonitors = array of TKvmRemoteMonitor;
  TKvmDisplayItem = record
    RemoteIndex: Integer;
    SourceRect, DestRect: TRect;
  end;
  TKvmDisplayItems = array of TKvmDisplayItem;
  TKvmIntegerArray = array of Integer;

  TKvmViewForm = class(TForm)
  private
    FTop: TPanel; // Parent cache invisible pour l'etat des controles internes.
    FMainMenu: TMainMenu;
    FFileMenu, FViewMenu, FControlMenu: TMenuItem;
    FMenuConnectionSettings, FMenuConnect, FMenuDisconnect, FMenuQuit: TMenuItem;
    FMenuMonitors, FMenuFullscreen, FMenuRefresh: TMenuItem;
    FMenuControl, FMenuKeyboardMode, FMenuUnicodeKeys, FMenuRemoteKeys, FMenuText: TMenuItem;
    FMenuClipboard, FMenuClipToRemote, FMenuClipFromRemote: TMenuItem;
    FHost, FPort, FToken: TEdit;
    FConnect, FDisconnect, FRefresh, FText: TButton;
    FControl, FRemoteKeys: TCheckBox;
    FClipToRemote, FClipFromRemote: TCheckBox;
    FClipboardChanging: Boolean;
    FClipboardWorker: TKvmClipboardClientWorker;
    FAllowInsecure, FEnableH264, FTransportFault: Boolean;
    FInputs: TKvmInputQueue;
    FDesktopEpoch: Cardinal;
    FTls: TCheckBox;
    FTlsCaFile: string;
    FStatus: TLabel;
    FView: TPaintBox;
    FTimer: TTimer;
    FBitmap: TBitmap;
    {$IFDEF WINDOWS}FWinPresenter: TKvmWinPresenter;{$ENDIF}
    FDecoder: TKvmVideoWorker;
    FFront: TKvmPresentation;
    FUseRawImage, FWorkerFault, FPolling: Boolean;
    FRawImportMs, FPaintMs, FStatsTick: QWord;
    FPaintCount, FPresentCount: Cardinal;
    FSocket: THttpClientWebSockets;
    FLock: TRTLCriticalSection;
    FPendingTexts: array of string;
    FCursorVisible: Boolean;
    FCursorX, FCursorY: Word;
    FControlGranted: Boolean;
    FLastHeartbeat: QWord;
    FLastShift: TShiftState;
    FSuppressedKeys, FForwardedKeys: array[0..255] of Boolean;
    FMouseButtons: Byte;
    FWheelRemainder: Integer;
    FDesktopPaused: Boolean;
    FAuthorized, FRemoteControl, FKeyboardFocus, FClosing: Boolean;
    FLastMouseTick: QWord;
    FPendingMouseMove: Boolean;
    FPendingMouseX, FPendingMouseY: Word;
    FMouseEchoes: array[0..63] of TKvmMouseEcho;
    FMouseEchoNext: Integer;
    FRemoteCursorOverlay: Boolean;
    FRemoteLayoutW, FRemoteLayoutH: Integer;
    FRemoteMonitors: TKvmRemoteMonitors;
    FRemoteMonitorSelected: array of Boolean;
    FPreferMaximized, FFullScreenMode, FSpanningMonitors: Boolean;
    FRestoreBounds: TRect;
    FRestoreWindowState: TWindowState;
    FRestoreValid: Boolean;
    FAutoConnect: Boolean;
    FAutoControl, FAutoControlPending: Boolean;
    FEmbeddedMode: Boolean;
    FOnStatusChange: TNotifyEvent;

    procedure ClipboardClick(Sender: TObject);
    procedure SyncClipboardOptions;
    procedure StopClipboardWorker;
    procedure ConnectClick(Sender: TObject);
    procedure ConnectionSettingsClick(Sender: TObject);
    procedure ControlMenuClick(Sender: TObject);
    procedure KeyboardMenuClick(Sender: TObject);
    procedure ClipboardMenuClick(Sender: TObject);
    procedure MonitorMenuClick(Sender: TObject);
    procedure FullScreenMenuClick(Sender: TObject);
    procedure QuitClick(Sender: TObject);
    procedure ToggleFullScreen;
    procedure SyncMainMenu;
    procedure WindowResized(Sender: TObject);
    procedure LayoutOverlay;
    procedure ApplyMonitorLayout;
    procedure RebuildMonitorMenu;
    procedure SyncMonitorMenu;
    procedure UpdateMonitorSummary;
    procedure ParseMonitorLayout(const TextMsg: string);
    function SelectedRemoteMonitorCount: Integer;
    procedure GetOrderedLocalMonitors(out Indices: TKvmIntegerArray);
    function LocalMonitorWorkRect(Index: Integer): TRect;
    function GetLocalSpanRect(const Indices: TKvmIntegerArray; Count: Integer;
      AFullScreen: Boolean; out SpanRect: TRect): Boolean;
    function BuildDisplayLayout(out Items: TKvmDisplayItems): Boolean;
    function MapRemoteCursorToView(NX,NY: Word; out CX,CY: Integer; out Item: TKvmDisplayItem): Boolean;
    procedure DisconnectClick(Sender: TObject);
    procedure ControlClick(Sender: TObject);
    procedure TryAutoRequestControl;
    procedure WindowDeactivated(Sender: TObject);
    procedure RefreshClick(Sender: TObject);
    procedure TextClick(Sender: TObject);
    procedure ResetLocalInputs;
    procedure ApplyDesktopState(Available: Boolean; Reason: Byte; Epoch: Cardinal);
    procedure KeyboardModeClick(Sender: TObject);
    function OutgoingInputPacketValid(const Payload: RawByteString): Boolean;
    procedure TransmitPacket(const Payload: RawByteString);
    procedure DrainInputs;
    procedure StopVideoWorker;
    procedure DecodeReply(const Payload: RawByteString);
    procedure PresentSnapshot(const Snapshot: TKvmPresentation);
    procedure InvalidateCursor(X,Y: Word; AVisible: Boolean);
    procedure SyncViewCursor;
    procedure RecordLocalMouseEcho(X,Y: Word);
    function CursorMoveWasLocalEcho(X,Y: Word; NowTick: QWord): Boolean;
    procedure HideRemoteCursorOverlay;
    procedure InvalidateDamage(const Damage: TRect);
    procedure IncomingFrame(Sender: TWebSocketProcess;
      const Frame: TWebSocketFrame);
    procedure PollTimer(Sender: TObject);
    procedure PaintView(Sender: TObject);
    procedure ViewMouseMove(Sender: TObject; Shift: TShiftState;
      X, Y: Integer);
    procedure ViewMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure ViewMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure ViewMouseWheel(Sender: TObject; Shift: TShiftState;
      WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
    procedure RemoteUTF8KeyPress(Sender: TObject; var UTF8Key: TUTF8Char);
    procedure RemoteKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure RemoteKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);

    procedure SendPacket(const Payload: RawByteString);
    function ControlAllowed: Boolean;
    function GetVideoRect: TRect;
    function ToNormalized(X, Y: Integer; out NX, NY: Word): Boolean;
    function MouseButtonCode(Button: TMouseButton): Byte;
    procedure SetStatus(const TextA: string);
    procedure CloseSocket;
  public
    procedure ApplyOptions(const Options: TKvmClientOptions);
    // Host-facing methods for embedding this viewer into another LCL window.
    // Call EnableEmbeddedMode before showing the viewer or connecting.
    procedure EnableEmbeddedMode;
    procedure Connect;
    procedure Disconnect;
    procedure RequestControl(AEnabled: Boolean);
    procedure RefreshDesktop;
    procedure ReleaseLocalInputs;
    function Connected: Boolean;
    function Authenticated: Boolean;
    function ControlGranted: Boolean;
    function StatusText: string;
    property OnStatusChange: TNotifyEvent read FOnStatusChange write FOnStatusChange;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

implementation

const
  // 12 ms cap: mouse moves are coalesced by the UI instead of discarded.
  KVM_MOUSE_INTERVAL_MS = 12;
  KVM_MOUSE_ECHO_WINDOW_MS = 800;
  KVM_MOUSE_ECHO_TOLERANCE = 64;
  {$IFDEF WINDOWS}
  // Local pointer mirrors the exact native cursor shape selected by the remote app.
  KVM_LOCAL_NATIVE_CURSOR: TCursor = 1001;
  {$ENDIF}


constructor TKvmViewForm.Create(AOwner: TComponent);
var
  L: TLabel;
  Sep: TMenuItem;
begin
  inherited CreateNew(AOwner, 1);
  InitCriticalSection(FLock);
  Caption := 'LazDesk v9 | F11: Full screen';
  Width := 1080;
  Height := 730;
  Position := poScreenCenter;
  Color := clBlack;
  KeyPreview := True;
  OnUTF8KeyPress := @RemoteUTF8KeyPress;
  OnKeyDown := @RemoteKeyDown;
  OnKeyUp := @RemoteKeyUp;
  OnDeactivate := @WindowDeactivated;
  OnResize := @WindowResized;

  FBitmap := TBitmap.Create;
  FUseRawImage := GetEnvironmentVariable('LAZDESK_RAW_IMAGE') <> '0';
  {$IFDEF WINDOWS}FWinPresenter:=TKvmWinPresenter.Create;{$ENDIF}
  FStatsTick := GetTickCount64;
  FInputs := TKvmInputQueue.Create; FEnableH264:=True;
  FSocket := nil;
  FClosing := False;
  FAuthorized := False;
  FRemoteControl := False;
  FControlGranted := False;
  FLastHeartbeat := 0;
  FLastShift := [];
  FillChar(FSuppressedKeys, SizeOf(FSuppressedKeys), 0);
  FCursorVisible := False;
  FRemoteCursorOverlay := False;
  FRemoteLayoutW := 0; FRemoteLayoutH := 0;
  SetLength(FRemoteMonitors,0); SetLength(FRemoteMonitorSelected,0);
  FPreferMaximized := False;
  FFullScreenMode := False;
  FSpanningMonitors := False;
  FRestoreValid := False;
  FRestoreBounds := Rect(0,0,0,0);
  FRestoreWindowState := wsNormal;
  FMouseEchoNext := 0;
  FillChar(FMouseEchoes,SizeOf(FMouseEchoes),0);
  FKeyboardFocus := False;
  FAutoConnect := False;
  FAutoControl := False; FAutoControlPending := False;
  FEmbeddedMode := False;
  FDesktopPaused := True;
  WebSocketsMaxFrameMB := 4;

  // Standard Windows menu bar: all user settings
  // are available here; there is no floating control panel.
  FMainMenu:=TMainMenu.Create(Self);
  Menu:=FMainMenu;

  FFileMenu:=TMenuItem.Create(FMainMenu);
  FFileMenu.Caption:='File';
  FMainMenu.Items.Add(FFileMenu);
  FMenuConnectionSettings:=TMenuItem.Create(FMainMenu);
  FMenuConnectionSettings.Caption:='Connection settings...';
  FMenuConnectionSettings.OnClick:=@ConnectionSettingsClick; FFileMenu.Add(FMenuConnectionSettings);
  Sep:=TMenuItem.Create(FMainMenu); Sep.Caption:='-'; FFileMenu.Add(Sep);
  FMenuConnect:=TMenuItem.Create(FMainMenu);
  FMenuConnect.Caption:='Connect'; FMenuConnect.OnClick:=@ConnectClick;
  FFileMenu.Add(FMenuConnect);
  FMenuDisconnect:=TMenuItem.Create(FMainMenu);
  FMenuDisconnect.Caption:='Disconnect'; FMenuDisconnect.Enabled:=False;
  FMenuDisconnect.OnClick:=@DisconnectClick; FFileMenu.Add(FMenuDisconnect);
  Sep:=TMenuItem.Create(FMainMenu); Sep.Caption:='-'; FFileMenu.Add(Sep);
  FMenuQuit:=TMenuItem.Create(FMainMenu);
  FMenuQuit.Caption:='Exit'; FMenuQuit.OnClick:=@QuitClick; FFileMenu.Add(FMenuQuit);

  FViewMenu:=TMenuItem.Create(FMainMenu);
  FViewMenu.Caption:='View'; FMainMenu.Items.Add(FViewMenu);
  FMenuMonitors:=TMenuItem.Create(FMainMenu);
  FMenuMonitors.Caption:='Monitors'; FMenuMonitors.Enabled:=False;
  FViewMenu.Add(FMenuMonitors);
  FMenuRefresh:=TMenuItem.Create(FMainMenu);
  FMenuRefresh.Caption:='Refresh'; FMenuRefresh.Enabled:=False;
  FMenuRefresh.OnClick:=@RefreshClick; FViewMenu.Add(FMenuRefresh);
  Sep:=TMenuItem.Create(FMainMenu); Sep.Caption:='-'; FViewMenu.Add(Sep);
  FMenuFullscreen:=TMenuItem.Create(FMainMenu);
  FMenuFullscreen.Caption:='Full screen'+#9+'F11';
  FMenuFullscreen.OnClick:=@FullScreenMenuClick; FViewMenu.Add(FMenuFullscreen);

  FControlMenu:=TMenuItem.Create(FMainMenu);
  FControlMenu.Caption:='Control'; FMainMenu.Items.Add(FControlMenu);
  FMenuControl:=TMenuItem.Create(FMainMenu);
  FMenuControl.Caption:='Take control';
  FMenuControl.OnClick:=@ControlMenuClick; FControlMenu.Add(FMenuControl);
  FMenuKeyboardMode:=TMenuItem.Create(FMainMenu);
  FMenuKeyboardMode.Caption:='Keyboard mode'; FControlMenu.Add(FMenuKeyboardMode);
  FMenuUnicodeKeys:=TMenuItem.Create(FMainMenu);
  FMenuUnicodeKeys.Caption:='Automatic: Unicode text + shortcuts';
  FMenuUnicodeKeys.RadioItem:=True; FMenuUnicodeKeys.GroupIndex:=41;
  FMenuUnicodeKeys.OnClick:=@KeyboardMenuClick; FMenuKeyboardMode.Add(FMenuUnicodeKeys);
  FMenuRemoteKeys:=TMenuItem.Create(FMainMenu);
  FMenuRemoteKeys.Caption:='Physical keys: remote layout';
  FMenuRemoteKeys.RadioItem:=True; FMenuRemoteKeys.GroupIndex:=41;
  FMenuRemoteKeys.OnClick:=@KeyboardMenuClick; FMenuKeyboardMode.Add(FMenuRemoteKeys);
  FMenuText:=TMenuItem.Create(FMainMenu);
  FMenuText.Caption:='Type / paste Unicode text...'; FMenuText.Enabled:=False;
  FMenuText.OnClick:=@TextClick; FControlMenu.Add(FMenuText);
  Sep:=TMenuItem.Create(FMainMenu); Sep.Caption:='-'; FControlMenu.Add(Sep);
  FMenuClipboard:=TMenuItem.Create(FMainMenu);
  FMenuClipboard.Caption:='Clipboard'; FControlMenu.Add(FMenuClipboard);
  FMenuClipToRemote:=TMenuItem.Create(FMainMenu);
  FMenuClipToRemote.Caption:='My clipboard -> remote';
  FMenuClipToRemote.OnClick:=@ClipboardMenuClick; FMenuClipboard.Add(FMenuClipToRemote);
  FMenuClipFromRemote:=TMenuItem.Create(FMainMenu);
  FMenuClipFromRemote.Caption:='Remote -> my clipboard';
  FMenuClipFromRemote.OnClick:=@ClipboardMenuClick; FMenuClipboard.Add(FMenuClipFromRemote);
  RebuildMonitorMenu;

  FTop := TPanel.Create(Self);
  FTop.Parent := Self;
  // The panel must NOT change the remote desktop geometry.
  // alTop would shrink the desktop area instead of overlaying controls.
  FTop.Align := alNone;
  FTop.SetBounds(0, 0, 1020, 186);
  FTop.BevelOuter := bvNone;
  FTop.Color := clBtnFace;
  FTop.Visible := False;

  L := TLabel.Create(Self);
  L.Parent := FTop;
  L.SetBounds(12, 6, 95, 17);
  L.Caption := 'Host / IP';

  FHost := TEdit.Create(Self);
  FHost.Parent := FTop;
  FHost.SetBounds(12, 25, 170, 26);
  FHost.Text := '127.0.0.1';

  L := TLabel.Create(Self);
  L.Parent := FTop;
  L.SetBounds(194, 6, 70, 17);
  L.Caption := 'Port';

  FPort := TEdit.Create(Self);
  FPort.Parent := FTop;
  FPort.SetBounds(194, 25, 65, 26);
  FPort.Text := '7900';

  L := TLabel.Create(Self);
  L.Parent := FTop;
  L.SetBounds(271, 6, 140, 17);
  L.Caption := 'Connection token';

  FToken := TEdit.Create(Self);
  FToken.Parent := FTop;
  FToken.SetBounds(271, 25, 220, 26);
  FToken.PasswordChar := '*';

  FTls := TCheckBox.Create(Self);
  FTls.Parent := FTop;
  FTls.SetBounds(735, 6, 125, 18);
  FTls.Caption := 'WSS / TLS';
  FTls.Checked := False;

  FConnect := TButton.Create(Self);
  FConnect.Parent := FTop;
  FConnect.SetBounds(503, 23, 102, 29);
  FConnect.Caption := 'Connect';
  FConnect.OnClick := @ConnectClick;

  FDisconnect := TButton.Create(Self);
  FDisconnect.Parent := FTop;
  FDisconnect.SetBounds(613, 23, 110, 29);
  FDisconnect.Caption := 'Disconnect';
  FDisconnect.Enabled := False;
  FDisconnect.OnClick := @DisconnectClick;

  FControl := TCheckBox.Create(Self);
  FControl.Parent := FTop;
  FControl.SetBounds(735, 28, 240, 24);
  FControl.Caption := 'Take control';
  FControl.Enabled := False;
  FControl.Checked := False;

  FStatus := TLabel.Create(Self);
  FStatus.Parent := FTop;
  FStatus.SetBounds(12, 66, 730, 19);
  FStatus.Caption := 'Disconnected | fit to window';

  FRefresh := TButton.Create(Self);
  FRefresh.Parent := FTop;
  FRefresh.SetBounds(894, 61, 120, 28);
  FRefresh.Caption := 'Refresh';
  FRefresh.Enabled := False;
  FRefresh.OnClick := @RefreshClick;

  FText := TButton.Create(Self);
  FText.Parent := FTop; FText.SetBounds(756,61,130,28);
  FText.Caption := 'Text / IME'; FText.Enabled := False;
  FText.OnClick := @TextClick;

  FRemoteKeys:=TCheckBox.Create(Self);
  FRemoteKeys.Parent:=FTop; FRemoteKeys.SetBounds(12,96,600,22);
  FRemoteKeys.Caption:='Physical key mode (otherwise automatic Unicode)';

  FClipToRemote:=TCheckBox.Create(Self);
  FClipToRemote.Parent:=FTop; FClipToRemote.SetBounds(12,126,470,24);
  FClipToRemote.Caption:='My clipboard -> remote';
  FClipToRemote.Checked:=False; FClipToRemote.Enabled:=False;
  FClipToRemote.Hint:='Sync the current text and future copies (64 KiB max). Control required.';
  FClipToRemote.ShowHint:=True;
  FClipFromRemote:=TCheckBox.Create(Self);
  FClipFromRemote.Parent:=FTop; FClipFromRemote.SetBounds(510,126,490,24);
  FClipFromRemote.Caption:='Remote -> my clipboard';
  FClipFromRemote.Checked:=False; FClipFromRemote.Enabled:=False;
  FClipFromRemote.Hint:='Allow the remote desktop to replace my text clipboard. Control required.';
  FClipFromRemote.ShowHint:=True;
  L:=TLabel.Create(Self); L.Parent:=FTop; L.SetBounds(12,156,980,20);
  L.Caption:='Clipboard: Unicode text only. Both directions are independent and reset for each connection.';


  FView := TPaintBox.Create(Self);
  FView.Parent := Self;
  FView.Align := alClient;
  FView.Cursor := crDefault;
  FView.OnPaint := @PaintView;
  FView.OnMouseMove := @ViewMouseMove;
  FView.OnMouseDown := @ViewMouseDown;
  FView.OnMouseUp := @ViewMouseUp;
  FView.OnMouseWheel := @ViewMouseWheel;

  SyncMainMenu;
  ResetLocalInputs;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 10; // react sooner to complete batches and input ACKs
  FTimer.OnTimer := @PollTimer;
  FTimer.Enabled := True;
end;

procedure TKvmViewForm.EnableEmbeddedMode;
begin
  if FSocket <> nil then
    raise Exception.Create('EnableEmbeddedMode must be called before connecting.');
  if FEmbeddedMode then Exit;
  FEmbeddedMode := True;
  FAutoConnect := False;
  FPreferMaximized := False;
  FFullScreenMode := False;
  FSpanningMonitors := False;
  FRestoreValid := False;
  Menu := nil;
  BorderStyle := bsNone;
  Position := poDesigned;
  // The host owns the top-level window, menus and geometry.
  // Do not invoke ApplyMonitorLayout here: we may not be parented yet.
end;

procedure TKvmViewForm.Connect;
begin
  if not FClosing and (FSocket = nil) then ConnectClick(nil);
end;

procedure TKvmViewForm.Disconnect;
begin
  if not FClosing then DisconnectClick(nil);
end;

procedure TKvmViewForm.RequestControl(AEnabled: Boolean);
begin
  if FClosing or not FAuthorized then Exit;
  if AEnabled and not FControl.Enabled then Exit;
  if FControl.Checked = AEnabled then Exit;
  FControl.Checked := AEnabled;
  ControlClick(nil);
end;

procedure TKvmViewForm.RefreshDesktop;
begin
  if not FClosing then RefreshClick(nil);
end;

procedure TKvmViewForm.ReleaseLocalInputs;
begin
  if not FClosing then WindowDeactivated(nil);
end;

function TKvmViewForm.Connected: Boolean;
begin
  Result := FSocket <> nil;
end;

function TKvmViewForm.Authenticated: Boolean;
begin
  Result := FAuthorized;
end;

function TKvmViewForm.ControlGranted: Boolean;
begin
  Result := FAuthorized and FControlGranted and not FDesktopPaused;
end;

function TKvmViewForm.StatusText: string;
begin
  Result := FStatus.Caption;
end;

procedure TKvmViewForm.ApplyOptions(const Options: TKvmClientOptions);
begin
  FHost.Text := Options.Host;
  FPort.Text := IntToStr(Options.Port);
  FToken.Text := Options.Token;
  FAutoConnect := Options.AutoConnect;
  FAutoControl := Options.AutoControl;
  FAutoControlPending := False; // A fresh session arms this after ConnectClick.
  FPreferMaximized := Options.Maximized;
  if FEmbeddedMode then FPreferMaximized := False;
  ApplyMonitorLayout;
  FTls.Checked := Options.TLS;
  FTlsCaFile := Options.TLSCA;
  FAllowInsecure:=Options.AllowInsecure; FEnableH264:=Options.H264;
  FRemoteKeys.Checked:=Options.Keyboard='remote';
  SyncMainMenu;
end;

destructor TKvmViewForm.Destroy;
begin
  FClosing := True;
  if FTimer<>nil then FTimer.Enabled:=False;
  if FView<>nil then CloseSocket
  else begin StopClipboardWorker; StopVideoWorker; FreeAndNil(FSocket); end;
  {$IFDEF WINDOWS}FWinPresenter.Free;{$ENDIF}
  FBitmap.Free; FInputs.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TKvmViewForm.SetStatus(const TextA: string);
begin
  // Status remains readable in the title even when the menu is hidden in full screen.
  if FStatus.Caption <> TextA then
    KvmClientLog('[client-status] ' + TextA);
  Caption := 'LazDesk | ' + Copy(TextA, 1, 80) + ' | F11 full screen';
  FStatus.Caption := TextA;
  FStatus.Hint := TextA + LineEnding + 'Journal : ' + KvmClientLogPath;
  FStatus.ShowHint := True;
  if Assigned(FOnStatusChange) then FOnStatusChange(Self);
end;

procedure TKvmViewForm.LayoutOverlay;
begin
  // No floating panel: the entire interface lives in the menu bar.
end;

procedure TKvmViewForm.WindowResized(Sender: TObject);
begin
  LayoutOverlay;
end;

function TKvmViewForm.SelectedRemoteMonitorCount: Integer;
var I: Integer;
begin
  Result:=0;
  for I:=0 to High(FRemoteMonitorSelected) do
    if FRemoteMonitorSelected[I] then Inc(Result);
end;

procedure TKvmViewForm.UpdateMonitorSummary;
begin
  SyncMonitorMenu;
  SyncMainMenu;
end;

procedure TKvmViewForm.ParseMonitorLayout(const TextMsg: string);
var
  Parts: TStringList; Temp: TKvmRemoteMonitors; OldSelected: array of Boolean;
  Count,BasisW,BasisH,I,At,X,Y,W,H: Integer; Preserve: Boolean;
begin
  Parts:=TStringList.Create;
  try
    Parts.Delimiter:=' '; Parts.StrictDelimiter:=True; Parts.DelimitedText:=TextMsg;
    if (Parts.Count<4) or (Parts[0]<>'MONITOR_LAYOUT') then Exit;
    Count:=StrToIntDef(Parts[1],0);
    BasisW:=StrToIntDef(Parts[2],0); BasisH:=StrToIntDef(Parts[3],0);
    if (Count<1) or (Count>64) or (BasisW<1) or (BasisH<1) or
       (BasisW>262144) or (BasisH>262144) or (Parts.Count<>4+Count*4) then Exit;
    SetLength(Temp,Count); At:=4;
    for I:=0 to Count-1 do
    begin
      X:=StrToIntDef(Parts[At],Low(Integer)); Inc(At);
      Y:=StrToIntDef(Parts[At],Low(Integer)); Inc(At);
      W:=StrToIntDef(Parts[At],0); Inc(At);
      H:=StrToIntDef(Parts[At],0); Inc(At);
      if (X<0) or (Y<0) or (W<1) or (H<1) or
         (Int64(X)+W>BasisW) or (Int64(Y)+H>BasisH) then Exit;
      Temp[I].X:=X; Temp[I].Y:=Y; Temp[I].W:=W; Temp[I].H:=H;
    end;
    Preserve:=Length(FRemoteMonitorSelected)=Count;
    if Preserve then OldSelected:=Copy(FRemoteMonitorSelected,0,Count);
    FRemoteMonitors:=Temp; FRemoteLayoutW:=BasisW; FRemoteLayoutH:=BasisH;
    SetLength(FRemoteMonitorSelected,Count);
    for I:=0 to Count-1 do
      if Preserve then FRemoteMonitorSelected[I]:=OldSelected[I]
      else FRemoteMonitorSelected[I]:=True;
    if SelectedRemoteMonitorCount=0 then
      for I:=0 to Count-1 do FRemoteMonitorSelected[I]:=True;
    RebuildMonitorMenu;
    UpdateMonitorSummary;
    ApplyMonitorLayout;
    FView.Invalidate;
  finally
    Parts.Free;
  end;
end;

procedure TKvmViewForm.RebuildMonitorMenu;
var
  Item,Sep: TMenuItem;
  I: Integer;
begin
  if FMenuMonitors=nil then Exit;
  while FMenuMonitors.Count>0 do FMenuMonitors.Items[0].Free;
  if Length(FRemoteMonitors)=0 then
  begin
    Item:=TMenuItem.Create(FMainMenu);
    Item.Caption:='No remote monitors'; Item.Enabled:=False;
    FMenuMonitors.Add(Item);
    FMenuMonitors.Enabled:=False;
    Exit;
  end;
  Item:=TMenuItem.Create(FMainMenu);
  Item.Caption:='All monitors'; Item.Tag:=-1;
  Item.OnClick:=@MonitorMenuClick; FMenuMonitors.Add(Item);
  if Length(FRemoteMonitors)>1 then
  begin
    Sep:=TMenuItem.Create(FMainMenu); Sep.Caption:='-'; Sep.Tag:=-2;
    FMenuMonitors.Add(Sep);
  end;
  for I:=0 to High(FRemoteMonitors) do
  begin
    Item:=TMenuItem.Create(FMainMenu);
    Item.Caption:=Format('Monitor %d  -  %dx%d',[I+1,FRemoteMonitors[I].W,FRemoteMonitors[I].H]);
    Item.Tag:=I; Item.OnClick:=@MonitorMenuClick;
    FMenuMonitors.Add(Item);
  end;
  SyncMonitorMenu;
end;

procedure TKvmViewForm.SyncMonitorMenu;
var
  I,Index: Integer; Item: TMenuItem; AllSelected: Boolean;
begin
  if FMenuMonitors=nil then Exit;
  FMenuMonitors.Enabled:=FAuthorized and (Length(FRemoteMonitors)>0);
  AllSelected:=(Length(FRemoteMonitorSelected)>0) and
    (SelectedRemoteMonitorCount=Length(FRemoteMonitorSelected));
  for I:=0 to FMenuMonitors.Count-1 do
  begin
    Item:=FMenuMonitors.Items[I];
    if Item.Caption='-' then Continue;
    Index:=Item.Tag;
    if Index=-1 then Item.Checked:=AllSelected
    else if (Index>=0) and (Index<Length(FRemoteMonitorSelected)) then
      Item.Checked:=FRemoteMonitorSelected[Index];
  end;
end;

procedure TKvmViewForm.MonitorMenuClick(Sender: TObject);
var
  Item: TMenuItem; Index,I: Integer;
begin
  if not (Sender is TMenuItem) then Exit;
  Item:=TMenuItem(Sender); Index:=Item.Tag;
  if Index=-1 then
  begin
    for I:=0 to High(FRemoteMonitorSelected) do FRemoteMonitorSelected[I]:=True;
  end
  else if (Index>=0) and (Index<Length(FRemoteMonitorSelected)) then
  begin
    if FRemoteMonitorSelected[Index] and (SelectedRemoteMonitorCount<=1) then
    begin
      SetStatus('At least one remote monitor must remain visible.');
      SyncMonitorMenu;
      Exit;
    end;
    FRemoteMonitorSelected[Index]:=not FRemoteMonitorSelected[Index];
  end
  else Exit;
  HideRemoteCursorOverlay;
  SyncMonitorMenu;
  ApplyMonitorLayout;
  if FView<>nil then FView.Invalidate;
end;

procedure TKvmViewForm.ToggleFullScreen;
begin
  if FEmbeddedMode then Exit; // host owns top-level window and shortcuts
  FFullScreenMode:=not FFullScreenMode;
  SyncMainMenu;
  ApplyMonitorLayout;
  if FView<>nil then FView.Invalidate;
end;

procedure TKvmViewForm.FullScreenMenuClick(Sender: TObject);
begin
  ToggleFullScreen;
end;

procedure TKvmViewForm.ConnectionSettingsClick(Sender: TObject);
var
  Dlg: TForm; L: TLabel; HostEdit,PortEdit,TokenEdit: TEdit;
  TlsCheck: TCheckBox; OkBtn,CancelBtn: TButton;
begin
  if FSocket<>nil then Exit;
  Dlg:=TForm.CreateNew(Self,1);
  try
    Dlg.Caption:='Connection settings';
    Dlg.Width:=470; Dlg.Height:=270; Dlg.Position:=poOwnerFormCenter;
    Dlg.BorderStyle:=bsDialog;
    L:=TLabel.Create(Dlg); L.Parent:=Dlg; L.SetBounds(16,18,100,18); L.Caption:='Host / IP';
    HostEdit:=TEdit.Create(Dlg); HostEdit.Parent:=Dlg; HostEdit.SetBounds(145,14,290,26); HostEdit.Text:=FHost.Text;
    L:=TLabel.Create(Dlg); L.Parent:=Dlg; L.SetBounds(16,58,100,18); L.Caption:='Port';
    PortEdit:=TEdit.Create(Dlg); PortEdit.Parent:=Dlg; PortEdit.SetBounds(145,54,100,26); PortEdit.Text:=FPort.Text;
    L:=TLabel.Create(Dlg); L.Parent:=Dlg; L.SetBounds(16,98,120,18); L.Caption:='Token';
    TokenEdit:=TEdit.Create(Dlg); TokenEdit.Parent:=Dlg; TokenEdit.SetBounds(145,94,290,26);
    TokenEdit.Text:=FToken.Text; TokenEdit.PasswordChar:='*';
    TlsCheck:=TCheckBox.Create(Dlg); TlsCheck.Parent:=Dlg; TlsCheck.SetBounds(145,134,180,24);
    TlsCheck.Caption:='WSS / TLS'; TlsCheck.Checked:=FTls.Checked;
    OkBtn:=TButton.Create(Dlg); OkBtn.Parent:=Dlg; OkBtn.Caption:='Save'; OkBtn.ModalResult:=mrOk;
    OkBtn.SetBounds(235,188,96,30);
    CancelBtn:=TButton.Create(Dlg); CancelBtn.Parent:=Dlg; CancelBtn.Caption:='Cancel'; CancelBtn.ModalResult:=mrCancel;
    CancelBtn.SetBounds(339,188,96,30);
    if Dlg.ShowModal<>mrOk then Exit;
    FHost.Text:=Trim(HostEdit.Text); FPort.Text:=Trim(PortEdit.Text);
    FToken.Text:=TokenEdit.Text; FTls.Checked:=TlsCheck.Checked;
    SyncMainMenu;
  finally
    Dlg.Free;
  end;
end;

procedure TKvmViewForm.ControlMenuClick(Sender: TObject);
begin
  if not FControl.Enabled then Exit;
  FControl.Checked:=not FControl.Checked;
  ControlClick(nil);
  SyncMainMenu;
end;

procedure TKvmViewForm.KeyboardMenuClick(Sender: TObject);
begin
  if Sender=FMenuUnicodeKeys then FRemoteKeys.Checked:=False
  else if Sender=FMenuRemoteKeys then FRemoteKeys.Checked:=True
  else Exit;
  KeyboardModeClick(nil);
  SyncMainMenu;
end;

procedure TKvmViewForm.ClipboardMenuClick(Sender: TObject);
begin
  if Sender=FMenuClipToRemote then
  begin
    if not FClipToRemote.Enabled then Exit;
    FClipToRemote.Checked:=not FClipToRemote.Checked;
  end
  else if Sender=FMenuClipFromRemote then
  begin
    if not FClipFromRemote.Enabled then Exit;
    FClipFromRemote.Checked:=not FClipFromRemote.Checked;
  end
  else Exit;
  ClipboardClick(nil);
  SyncMainMenu;
end;

procedure TKvmViewForm.QuitClick(Sender: TObject);
begin
  Close;
end;

procedure TKvmViewForm.SyncMainMenu;
begin
  if FMenuConnectionSettings<>nil then FMenuConnectionSettings.Enabled:=(FSocket=nil);
  if FMenuConnect<>nil then FMenuConnect.Enabled:=(FConnect<>nil) and FConnect.Enabled;
  if FMenuDisconnect<>nil then FMenuDisconnect.Enabled:=(FDisconnect<>nil) and FDisconnect.Enabled;
  if FMenuRefresh<>nil then FMenuRefresh.Enabled:=(FRefresh<>nil) and FRefresh.Enabled;
  if FMenuFullscreen<>nil then FMenuFullscreen.Checked:=FFullScreenMode;
  if FMenuControl<>nil then
  begin FMenuControl.Enabled:=FControl.Enabled; FMenuControl.Checked:=FControl.Checked; end;
  if FMenuUnicodeKeys<>nil then FMenuUnicodeKeys.Checked:=not FRemoteKeys.Checked;
  if FMenuRemoteKeys<>nil then FMenuRemoteKeys.Checked:=FRemoteKeys.Checked;
  if FMenuText<>nil then FMenuText.Enabled:=FText.Enabled;
  if FMenuClipToRemote<>nil then
  begin FMenuClipToRemote.Enabled:=FClipToRemote.Enabled; FMenuClipToRemote.Checked:=FClipToRemote.Checked; end;
  if FMenuClipFromRemote<>nil then
  begin FMenuClipFromRemote.Enabled:=FClipFromRemote.Enabled; FMenuClipFromRemote.Checked:=FClipFromRemote.Checked; end;
  if FMenuClipboard<>nil then FMenuClipboard.Enabled:=FClipToRemote.Enabled or FClipFromRemote.Enabled;
  SyncMonitorMenu;
  // Never replace the host application's menu in embedded mode.
  if FEmbeddedMode then Menu := nil
  else if FMainMenu<>nil then
    if FFullScreenMode then Menu:=nil else Menu:=FMainMenu;
end;

procedure TKvmViewForm.GetOrderedLocalMonitors(out Indices: TKvmIntegerArray);
var I,J,T: Integer; A,B: TRect;
begin
  SetLength(Indices,0);
  if Screen=nil then Exit;
  SetLength(Indices,Screen.MonitorCount);
  for I:=0 to High(Indices) do Indices[I]:=I;
  for I:=0 to High(Indices)-1 do
    for J:=I+1 to High(Indices) do
    begin
      A:=Screen.Monitors[Indices[I]].BoundsRect;
      B:=Screen.Monitors[Indices[J]].BoundsRect;
      if (B.Left<A.Left) or ((B.Left=A.Left) and (B.Top<A.Top)) then
      begin T:=Indices[I]; Indices[I]:=Indices[J]; Indices[J]:=T; end;
    end;
end;

function TKvmViewForm.LocalMonitorWorkRect(Index: Integer): TRect;
begin
  Result:=Screen.Monitors[Index].WorkareaRect;
  {$IFDEF WINDOWS}
  Result:=KvmSafeMonitorWorkRect(Screen.Monitors[Index].BoundsRect,Result);
  {$ENDIF}
end;

function TKvmViewForm.GetLocalSpanRect(const Indices: TKvmIntegerArray; Count: Integer;
  AFullScreen: Boolean; out SpanRect: TRect): Boolean;
var
  I: Integer;
  R,WorkUnion,BoundsUnion: TRect;
  SpanW,SpanH: Integer;
begin
  Result:=False; SpanRect:=Rect(0,0,0,0);
  if (Screen=nil) or (Count<1) or (Length(Indices)<Count) then Exit;

  BoundsUnion:=Screen.Monitors[Indices[0]].BoundsRect;
  if AFullScreen then WorkUnion:=BoundsUnion
  else WorkUnion:=LocalMonitorWorkRect(Indices[0]);
  for I:=1 to Count-1 do
  begin
    R:=Screen.Monitors[Indices[I]].BoundsRect;
    BoundsUnion.Left:=Min(BoundsUnion.Left,R.Left);
    BoundsUnion.Top:=Min(BoundsUnion.Top,R.Top);
    BoundsUnion.Right:=Max(BoundsUnion.Right,R.Right);
    BoundsUnion.Bottom:=Max(BoundsUnion.Bottom,R.Bottom);
    if not AFullScreen then
    begin
      R:=LocalMonitorWorkRect(Indices[I]);
      WorkUnion.Left:=Min(WorkUnion.Left,R.Left);
      WorkUnion.Top:=Min(WorkUnion.Top,R.Top);
      WorkUnion.Right:=Max(WorkUnion.Right,R.Right);
      WorkUnion.Bottom:=Max(WorkUnion.Bottom,R.Bottom);
    end;
  end;

  if AFullScreen then
    SpanRect:=BoundsUnion
  else
  begin
    // A single top-level window is rectangular.  The union of WorkareaRect
    // values is unsafe when only one monitor owns the Windows taskbar: the
    // larger Bottom/Top from another monitor makes the window cover that
    // taskbar.  Keep the long axis spanning all selected displays, but use
    // the common safe work-area band on the short axis.
    SpanW:=BoundsUnion.Right-BoundsUnion.Left;
    SpanH:=BoundsUnion.Bottom-BoundsUnion.Top;
    if SpanW>=SpanH then
    begin
      SpanRect.Left:=WorkUnion.Left;
      SpanRect.Right:=WorkUnion.Right;
      R:=LocalMonitorWorkRect(Indices[0]);
      SpanRect.Top:=R.Top;
      SpanRect.Bottom:=R.Bottom;
      for I:=1 to Count-1 do
      begin
        R:=LocalMonitorWorkRect(Indices[I]);
        SpanRect.Top:=Max(SpanRect.Top,R.Top);
        SpanRect.Bottom:=Min(SpanRect.Bottom,R.Bottom);
      end;
      if SpanRect.Bottom<=SpanRect.Top then SpanRect:=WorkUnion;
    end
    else
    begin
      SpanRect.Top:=WorkUnion.Top;
      SpanRect.Bottom:=WorkUnion.Bottom;
      R:=LocalMonitorWorkRect(Indices[0]);
      SpanRect.Left:=R.Left;
      SpanRect.Right:=R.Right;
      for I:=1 to Count-1 do
      begin
        R:=LocalMonitorWorkRect(Indices[I]);
        SpanRect.Left:=Max(SpanRect.Left,R.Left);
        SpanRect.Right:=Min(SpanRect.Right,R.Right);
      end;
      if SpanRect.Right<=SpanRect.Left then SpanRect:=WorkUnion;
    end;
  end;
  Result:=(SpanRect.Right>SpanRect.Left) and (SpanRect.Bottom>SpanRect.Top);
end;

procedure TKvmViewForm.ApplyMonitorLayout;
var
  SpanRect,R: TRect; LocalOrder: TKvmIntegerArray;
  J,SelectedCount,SpanCount,SelectedIndex,RemoteW,RemoteH,LocalW,LocalH: Integer;
  WantSpan,FitOneToOne,WasSpecial,WantSpecial,Restored: Boolean;
  CX,CY,TargetMonitor: Integer;
  procedure SaveRestoreState;
  begin
    if FRestoreValid then Exit;
    FRestoreBounds:=BoundsRect;
    FRestoreWindowState:=WindowState;
    FRestoreValid:=True;
  end;
  procedure RestoreNormalState;
  begin
    BorderStyle:=bsSizeable;
    Position:=poDesigned;
    WindowState:=wsNormal;
    if FRestoreValid then
    begin
      SetBounds(FRestoreBounds.Left,FRestoreBounds.Top,
        FRestoreBounds.Right-FRestoreBounds.Left,FRestoreBounds.Bottom-FRestoreBounds.Top);
      if FPreferMaximized or (FRestoreWindowState=wsMaximized) then
        WindowState:=wsMaximized;
      FRestoreValid:=False;
    end
    else if FPreferMaximized then
      WindowState:=wsMaximized
    else
      WindowState:=wsNormal;
  end;
begin
  // An embedded viewer is a child control, not an independently movable
  // desktop window: render all selected remote monitors inside its own bounds.
  if FEmbeddedMode then
  begin
    FSpanningMonitors := False;
    FFullScreenMode := False;
    FRestoreValid := False;
    LayoutOverlay;
    SyncMainMenu;
    Exit;
  end;
  SelectedCount:=SelectedRemoteMonitorCount;

  // Multi-monitor display is independent from fullscreen. With two or more
  // selected remote monitors, span the corresponding local work areas while
  // keeping ordinary window chrome. Fullscreen is explicit (F11 / View).
  WantSpan:=(SelectedCount>1) and (Screen<>nil) and (Screen.MonitorCount>1);
  WantSpecial:=WantSpan or FFullScreenMode;
  WasSpecial:=FSpanningMonitors or FRestoreValid;
  if WantSpecial and not WasSpecial then SaveRestoreState;

  if WantSpan then
  begin
    GetOrderedLocalMonitors(LocalOrder);
    SpanCount:=Min(SelectedCount,Length(LocalOrder));
    if SpanCount<1 then WantSpan:=False
    else
    begin
      if not GetLocalSpanRect(LocalOrder,SpanCount,FFullScreenMode,SpanRect) then
      begin
        WantSpan:=False;
        FSpanningMonitors:=False;
      end
      else
      begin
      FSpanningMonitors:=True;
      WindowState:=wsNormal;
      if FFullScreenMode then BorderStyle:=bsNone else BorderStyle:=bsSizeable;
      Position:=poDesigned;
      SetBounds(SpanRect.Left,SpanRect.Top,SpanRect.Right-SpanRect.Left,
        SpanRect.Bottom-SpanRect.Top);
      if FFullScreenMode then
        KvmClientLog(Format('[client-layout] full screen across %d local display(s) for %d remote monitor(s)',
          [SpanCount,SelectedCount]))
      else
        KvmClientLog(Format('[client-layout] window extended across %d local display(s) for %d remote monitor(s)',
          [SpanCount,SelectedCount]));
      end;
    end;
  end;

  if not WantSpan then
  begin
    FSpanningMonitors:=False;
    if FFullScreenMode and (Screen<>nil) and (Screen.MonitorCount>0) then
    begin
      SaveRestoreState;
      TargetMonitor:=0;
      CX:=Left+(Width div 2); CY:=Top+(Height div 2);
      for J:=0 to Screen.MonitorCount-1 do
      begin
        R:=Screen.Monitors[J].BoundsRect;
        if (CX>=R.Left) and (CX<R.Right) and (CY>=R.Top) and (CY<R.Bottom) then
        begin TargetMonitor:=J; Break; end;
      end;
      R:=Screen.Monitors[TargetMonitor].BoundsRect;
      WindowState:=wsNormal; BorderStyle:=bsNone; Position:=poDesigned;
      SetBounds(R.Left,R.Top,R.Right-R.Left,R.Bottom-R.Top);
      KvmClientLog(Format('[client-layout] explicit full screen on local monitor %d',[TargetMonitor+1]));
    end
    else
    begin
      Restored:=FRestoreValid;
      if Restored then RestoreNormalState
      else
      begin
        BorderStyle:=bsSizeable;
        Position:=poScreenCenter;
      end;

      FitOneToOne:=False; RemoteW:=0; RemoteH:=0;
      if FPreferMaximized and (SelectedCount=1) and (Screen<>nil) and
         (Screen.MonitorCount>0) and (Length(FRemoteMonitors)>0) then
      begin
        SelectedIndex:=-1;
        for J:=0 to High(FRemoteMonitorSelected) do
          if FRemoteMonitorSelected[J] then begin SelectedIndex:=J; Break; end;
        if SelectedIndex>=0 then
        begin
          if SurfaceValid(FFront.Surface) and (FRemoteLayoutW>0) and (FRemoteLayoutH>0) then
          begin
            RemoteW:=Max(1,Integer((Int64(FRemoteMonitors[SelectedIndex].W)*FFront.Surface.Width) div FRemoteLayoutW));
            RemoteH:=Max(1,Integer((Int64(FRemoteMonitors[SelectedIndex].H)*FFront.Surface.Height) div FRemoteLayoutH));
          end
          else
          begin
            RemoteW:=FRemoteMonitors[SelectedIndex].W;
            RemoteH:=FRemoteMonitors[SelectedIndex].H;
          end;
          R:=LocalMonitorWorkRect(0);
          LocalW:=R.Right-R.Left; LocalH:=R.Bottom-R.Top;
          FitOneToOne:=(RemoteW<=LocalW) and (RemoteH<=LocalH);
        end;
      end;
      if FitOneToOne then
      begin
        WindowState:=wsNormal; BorderStyle:=bsSizeable; Position:=poScreenCenter;
        ClientWidth:=Max(640,RemoteW); ClientHeight:=Max(480,RemoteH);
        KvmClientLog(Format('[client-layout] remote monitor %dx%d displayed at 100%% without maximization',
          [RemoteW,RemoteH]));
      end
      else if not Restored then
      begin
        if FPreferMaximized then WindowState:=wsMaximized else WindowState:=wsNormal;
      end;
    end;
  end;
  LayoutOverlay;
  SyncMainMenu;
end;

function TKvmViewForm.BuildDisplayLayout(out Items: TKvmDisplayItems): Boolean;
var
  Selected: TKvmIntegerArray; LocalOrder: TKvmIntegerArray;
  I,N,SrcW,SrcH,SlotW,SlotH,DestW,DestH: Integer;
  Src,Slot,Bounds,LocalBounds,RawSlot: TRect; Scale: Double; First: Boolean;
  ViewOrigin: TPoint;
  function SourceForRemote(Index: Integer): TRect;
  var M: TKvmRemoteMonitor;
  begin
    M:=FRemoteMonitors[Index];
    Result.Left:=Integer((Int64(M.X)*FFront.Surface.Width) div FRemoteLayoutW);
    Result.Top:=Integer((Int64(M.Y)*FFront.Surface.Height) div FRemoteLayoutH);
    Result.Right:=Integer(((Int64(M.X)+Int64(M.W))*FFront.Surface.Width+FRemoteLayoutW-1) div FRemoteLayoutW);
    Result.Bottom:=Integer(((Int64(M.Y)+Int64(M.H))*FFront.Surface.Height+FRemoteLayoutH-1) div FRemoteLayoutH);
    Result.Left:=EnsureRange(Result.Left,0,FFront.Surface.Width-1);
    Result.Top:=EnsureRange(Result.Top,0,FFront.Surface.Height-1);
    Result.Right:=EnsureRange(Result.Right,Result.Left+1,FFront.Surface.Width);
    Result.Bottom:=EnsureRange(Result.Bottom,Result.Top+1,FFront.Surface.Height);
  end;
begin
  Result:=False; SetLength(Items,0);
  if not SurfaceValid(FFront.Surface) or (FView.Width<1) or (FView.Height<1) then Exit;
  if (Length(FRemoteMonitors)=0) or (FRemoteLayoutW<1) or (FRemoteLayoutH<1) then
  begin
    SetLength(Items,1); Items[0].RemoteIndex:=0;
    Items[0].SourceRect:=Rect(0,0,FFront.Surface.Width,FFront.Surface.Height);
    SrcW:=FFront.Surface.Width; SrcH:=FFront.Surface.Height;
    Scale:=Min(1.0,Min(FView.Width/SrcW,FView.Height/SrcH));
    DestW:=Max(1,Round(SrcW*Scale)); DestH:=Max(1,Round(SrcH*Scale));
    Items[0].DestRect:=Rect((FView.Width-DestW) div 2,(FView.Height-DestH) div 2,
      (FView.Width-DestW) div 2+DestW,(FView.Height-DestH) div 2+DestH);
    Exit(True);
  end;
  N:=SelectedRemoteMonitorCount; if N<1 then Exit;
  SetLength(Selected,N); N:=0;
  for I:=0 to High(FRemoteMonitorSelected) do
    if FRemoteMonitorSelected[I] then begin Selected[N]:=I; Inc(N); end;
  SetLength(Items,N);

  // When there are enough local displays and the window spans them, map one
  // selected remote monitor to one local display. This removes holes such as
  // selecting remote 1 + 3 while omitting 2.
  GetOrderedLocalMonitors(LocalOrder);
  if FSpanningMonitors and (N<=Length(LocalOrder)) then
  begin
    // Map each monitor's real screen rectangle directly into FView client
    // coordinates. This is deliberately not a proportional remap of the whole
    // span: Windows may expose title bars, borders or an auto-hidden taskbar on
    // top of the form. Direct screen -> client mapping keeps video out of those
    // covered pixels and makes the remote bottom edge visible.
    if not GetLocalSpanRect(LocalOrder,N,FFullScreenMode,LocalBounds) then Exit;
    ViewOrigin:=FView.ClientToScreen(Point(0,0));
    for I:=0 to N-1 do
    begin
      Src:=SourceForRemote(Selected[I]);
      if FFullScreenMode then RawSlot:=Screen.Monitors[LocalOrder[I]].BoundsRect
      else
      begin
        RawSlot:=LocalMonitorWorkRect(LocalOrder[I]);
        RawSlot.Left:=Max(RawSlot.Left,LocalBounds.Left);
        RawSlot.Top:=Max(RawSlot.Top,LocalBounds.Top);
        RawSlot.Right:=Min(RawSlot.Right,LocalBounds.Right);
        RawSlot.Bottom:=Min(RawSlot.Bottom,LocalBounds.Bottom);
      end;
      Slot.Left:=EnsureRange(RawSlot.Left-ViewOrigin.X,0,FView.Width);
      Slot.Top:=EnsureRange(RawSlot.Top-ViewOrigin.Y,0,FView.Height);
      Slot.Right:=EnsureRange(RawSlot.Right-ViewOrigin.X,0,FView.Width);
      Slot.Bottom:=EnsureRange(RawSlot.Bottom-ViewOrigin.Y,0,FView.Height);
      if (Slot.Right<=Slot.Left) or (Slot.Bottom<=Slot.Top) then Exit;
      SrcW:=Src.Right-Src.Left; SrcH:=Src.Bottom-Src.Top;
      SlotW:=Max(1,Slot.Right-Slot.Left); SlotH:=Max(1,Slot.Bottom-Slot.Top);
      Scale:=Min(1.0,Min(SlotW/SrcW,SlotH/SrcH));
      DestW:=Max(1,Round(SrcW*Scale)); DestH:=Max(1,Round(SrcH*Scale));
      Items[I].RemoteIndex:=Selected[I]; Items[I].SourceRect:=Src;
      Items[I].DestRect:=Rect(Slot.Left+(SlotW-DestW) div 2,
        Slot.Top+(SlotH-DestH) div 2,
        Slot.Left+(SlotW-DestW) div 2+DestW,
        Slot.Top+(SlotH-DestH) div 2+DestH);
    end;
    Exit(True);
  end;

  // Windowed / fewer local screens: preserve the selected remote topology and
  // leave omitted monitors black. Scale down only; never enlarge above 100%.
  First:=True;
  for I:=0 to N-1 do
  begin
    Src:=SourceForRemote(Selected[I]); Items[I].RemoteIndex:=Selected[I];
    Items[I].SourceRect:=Src;
    if First then begin Bounds:=Src; First:=False; end
    else
    begin
      Bounds.Left:=Min(Bounds.Left,Src.Left); Bounds.Top:=Min(Bounds.Top,Src.Top);
      Bounds.Right:=Max(Bounds.Right,Src.Right); Bounds.Bottom:=Max(Bounds.Bottom,Src.Bottom);
    end;
  end;
  SrcW:=Bounds.Right-Bounds.Left; SrcH:=Bounds.Bottom-Bounds.Top;
  Scale:=Min(1.0,Min(FView.Width/SrcW,FView.Height/SrcH));
  DestW:=Max(1,Round(SrcW*Scale)); DestH:=Max(1,Round(SrcH*Scale));
  Slot:=Rect((FView.Width-DestW) div 2,(FView.Height-DestH) div 2,
    (FView.Width-DestW) div 2+DestW,(FView.Height-DestH) div 2+DestH);
  for I:=0 to N-1 do
  begin
    Src:=Items[I].SourceRect;
    Items[I].DestRect.Left:=Slot.Left+Round((Src.Left-Bounds.Left)*Scale);
    Items[I].DestRect.Top:=Slot.Top+Round((Src.Top-Bounds.Top)*Scale);
    Items[I].DestRect.Right:=Slot.Left+Round((Src.Right-Bounds.Left)*Scale);
    Items[I].DestRect.Bottom:=Slot.Top+Round((Src.Bottom-Bounds.Top)*Scale);
  end;
  Result:=True;
end;

function TKvmViewForm.MapRemoteCursorToView(NX,NY: Word; out CX,CY: Integer;
  out Item: TKvmDisplayItem): Boolean;
var Items: TKvmDisplayItems; I,SX,SY,SW,SH,DW,DH: Integer;
begin
  Result:=False; CX:=0; CY:=0; FillChar(Item,SizeOf(Item),0);
  if not BuildDisplayLayout(Items) then Exit;
  SX:=Integer((Int64(NX)*(FFront.Surface.Width-1)) div 65535);
  SY:=Integer((Int64(NY)*(FFront.Surface.Height-1)) div 65535);
  for I:=0 to High(Items) do
    if (SX>=Items[I].SourceRect.Left) and (SX<Items[I].SourceRect.Right) and
       (SY>=Items[I].SourceRect.Top) and (SY<Items[I].SourceRect.Bottom) then
    begin
      Item:=Items[I]; SW:=Item.SourceRect.Right-Item.SourceRect.Left;
      SH:=Item.SourceRect.Bottom-Item.SourceRect.Top;
      DW:=Item.DestRect.Right-Item.DestRect.Left; DH:=Item.DestRect.Bottom-Item.DestRect.Top;
      if (SW<1) or (SH<1) or (DW<1) or (DH<1) then Exit;
      if SW>1 then CX:=Item.DestRect.Left+Integer(((Int64(SX)-Int64(Item.SourceRect.Left))*(DW-1)) div (SW-1))
      else CX:=Item.DestRect.Left;
      if SH>1 then CY:=Item.DestRect.Top+Integer(((Int64(SY)-Int64(Item.SourceRect.Top))*(DH-1)) div (SH-1))
      else CY:=Item.DestRect.Top;
      Exit(True);
    end;
end;

procedure TKvmViewForm.StopClipboardWorker;
var Worker: TKvmClipboardClientWorker;
begin
  EnterCriticalSection(FLock);
  try Worker:=FClipboardWorker; FClipboardWorker:=nil;
  finally LeaveCriticalSection(FLock); end;
  if Worker<>nil then begin Worker.Stop; Worker.Free; end;
end;

procedure TKvmViewForm.SyncClipboardOptions;
var Allowed: Boolean; Mask: Byte;
begin
  if (FClipToRemote=nil) or (FClipFromRemote=nil) then Exit;
  Allowed:=ControlAllowed and (FClipboardWorker<>nil);
  FClipboardChanging:=True;
  try
    FClipToRemote.Enabled:=Allowed; FClipFromRemote.Enabled:=Allowed;
    if not Allowed then
    begin FClipToRemote.Checked:=False; FClipFromRemote.Checked:=False; end;
  finally FClipboardChanging:=False; end;
  Mask:=0;
  if Allowed and FClipToRemote.Checked then Mask:=Mask or KVM_CLIP_WRITE;
  if Allowed and FClipFromRemote.Checked then Mask:=Mask or KVM_CLIP_READ;
  if FClipboardWorker<>nil then FClipboardWorker.Configure(Mask,FDesktopEpoch);
  SyncMainMenu;
end;

procedure TKvmViewForm.ClipboardClick(Sender: TObject);
begin
  if FClipboardChanging then Exit;
  SyncClipboardOptions;
  if not ControlAllowed then Exit;
  SetStatus('Clipboard: local -> remote='+BoolToStr(FClipToRemote.Checked,True)+
    '; remote -> local='+BoolToStr(FClipFromRemote.Checked,True));
end;

procedure TKvmViewForm.StopVideoWorker;
var Worker: TKvmVideoWorker;
begin
  // Detach before joining: IncomingFrame cannot enqueue into a freed worker.
  EnterCriticalSection(FLock);
  try Worker:=FDecoder; FDecoder:=nil;
  finally LeaveCriticalSection(FLock); end;
  if Worker<>nil then begin Worker.Stop; Worker.Free; end;
end;

procedure TKvmViewForm.DecodeReply(const Payload: RawByteString);
var Frame: TWebSocketFrame;
begin
  // Called by video/clipboard workers. CloseSocket joins BOTH before freeing
  // FSocket; mORMot2 SendFrame serializes writes with its own output lock.
  if (FSocket=nil) or (FSocket.WebSockets=nil) then Exit;
  Frame.opcode:=focBinary; Frame.content:=[]; Frame.tix:=0;
  Frame.payload:=Copy(Payload,1,Length(Payload));
  try
    if FSocket.WebSockets.SendFrame(Frame) then Exit;
  except end;
  EnterCriticalSection(FLock);
  try FWorkerFault:=True; finally LeaveCriticalSection(FLock); end;
end;

procedure TKvmViewForm.CloseSocket;
begin
  StopClipboardWorker; // no native clipboard or send callbacks after this join
  // Best-effort release. The server also has disconnect/heartbeat cleanup.
  if FAuthorized and FControlGranted and (FSocket <> nil) then
    SendPacket('L');
  StopVideoWorker; // stops ACK sends before freeing the WebSocket
  // Freeing the mORMot client waits for its WebSocket processing thread.
  FreeAndNil(FSocket); FTransportFault:=False;
  if FInputs<>nil then FInputs.Reset; FDesktopEpoch:=0;
  ClearSurface(FFront.Surface);
  ClearCursorShape(FFront.CursorShape);
  FStatsTick := GetTickCount64;
  FRawImportMs:=0; FPaintMs:=0; FPaintCount:=0; FPresentCount:=0;
  FAuthorized := False;
  FRemoteControl := False;
  FControlGranted := False;
  FAutoControlPending := False;
  if GetCaptureControl = FView then SetCaptureControl(nil);
  FCursorVisible := False;
  FRemoteCursorOverlay := False;
  FRemoteLayoutW := 0; FRemoteLayoutH := 0;
  SetLength(FRemoteMonitors,0); SetLength(FRemoteMonitorSelected,0);
  RebuildMonitorMenu;
  UpdateMonitorSummary;
  if not FClosing then ApplyMonitorLayout;
  FMouseEchoNext := 0;
  FillChar(FMouseEchoes,SizeOf(FMouseEchoes),0);
  FKeyboardFocus := False;
  FControl.Checked := False;
  FControl.Enabled := False;
  FRefresh.Enabled := False;
  FText.Enabled := False;
  FDesktopPaused := True;
  SyncClipboardOptions;
  ResetLocalInputs;
  FBitmap.SetSize(0, 0);
  {$IFDEF WINDOWS}if FWinPresenter<>nil then begin FWinPresenter.Reset; FWinPresenter.ClearCursor; end;{$ENDIF}
  SyncViewCursor;
  FConnect.Enabled := True;
  FDisconnect.Enabled := False;
  FHost.Enabled := True;
  FPort.Enabled := True;
  FToken.Enabled := True;
  FTls.Enabled := True;
  EnterCriticalSection(FLock);
  try
    SetLength(FPendingTexts, 0);
    FWorkerFault:=False;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TKvmViewForm.ConnectClick(Sender: TObject);
var
  Proto: TWebSocketProtocolChat;
  Frame: TWebSocketFrame;
  PortNum: Integer;
  TLSContext: TNetTlsContext;
  ConnectOptions: THttpRequestExtendedOptions;
  TargetURI: TUri;
  ConnectError: RawUtf8;
  Capability: RawByteString;
begin
  if FSocket <> nil then Exit;
  PortNum := StrToIntDef(FPort.Text, 0);
  if (PortNum < 1) or (PortNum > 65535) or
     (Trim(FHost.Text) = '') or not ValidKvmToken(FToken.Text) then
  begin
    MessageDlg('Enter a host, a valid port, and an ASCII token without spaces (16..256 characters).',
      mtWarning, [mbOK], 0);
    Exit;
  end;

  if not FTls.Checked and not FAllowInsecure and not KvmLoopbackHost(FHost.Text) then
  begin
    SetStatus('TLS is required outside loopback. Use --allow-insecure only with a trusted tunnel/VPN.');
    Exit;
  end;
  FAutoControlPending := FAutoControl;
  SetStatus('Connecting...');
  FConnect.Enabled := False;
  SyncMainMenu;
  // Reuse TLS options for the mORMot2 path that reports the HTTP
  // error code (the previous overload discarded that diagnostic).
  if FTls.Checked then
  begin
    if (FTlsCaFile<>'') and not FileExists(FTlsCaFile) then
    begin
      SetStatus('TLS CA file not found: ' + FTlsCaFile);
      FConnect.Enabled := True;
      SyncMainMenu;
      Exit;
    end;
    PrepareClientTls(FTlsCaFile,TLSContext);
  end;

  // Same setup as before, but with diagnostics for
  // failed negotiation (HTTP 400, 404, 429, TLS errors, etc.).
  ConnectOptions.InitDefault;
  ConnectOptions.Proxy := 'none';
  ConnectOptions.CreateTimeoutMS := 10000;
  if FTls.Checked then
    ConnectOptions.TLS := TLSContext;
  if not TargetURI.FromScheme(WS_SCHEME[FTls.Checked],
      RawUtf8(FHost.Text), RawUtf8(FPort.Text), KVM_WS_PATH) then
  begin
    SetStatus('Invalid WebSocket address.');
    FConnect.Enabled := True;
    SyncMainMenu;
    Exit;
  end;
  try
    FDecoder:=TKvmVideoWorker.Create(FEnableH264,@DecodeReply);
    Capability:='jpeg';
    if FDecoder.H264Available then Capability:='h264';
    if FDecoder.NativeAvailable then
      KvmClientLog('[client-video] TurboJPEG on worker; ACK after CPU composition')
    else KvmClientLog('[client-video] Fallback to FCL JPEG worker (no GUI decoding)');
    Proto := TWebSocketProtocolChat.Create(KVM_SUBPROTOCOL, KVM_WS_PATH,
      @IncomingFrame);
    // mORMot2 handles Proto destruction, including on failure.
    ConnectError := '';
    FSocket := THttpClientWebSockets.WebSocketsConnect(
      TargetURI, ConnectOptions, Proto, nil, '', '', @ConnectError);
    if FSocket = nil then
    begin
      if ConnectError = '' then ConnectError := 'no response from server';
      raise Exception.Create('WebSocket failed: ' + string(ConnectError));
    end;

    Frame.opcode := focText;
    Frame.content := [];
    Frame.tix := 0;
    FSocket.WebSockets.Settings^.LoopDelay := 5;
    FSocket.WebSockets.Settings^.SendDelay := 1;
    FSocket.WebSockets.Settings^.ClientAutoUpgrade := False; // require a fresh AUTH
    Frame.payload := 'AUTH ' + RawByteString(AnsiString(FToken.Text))+' '+Capability;
    if not FSocket.WebSockets.SendFrame(Frame) then
      raise Exception.Create('Could not send the token.');

    FClipboardWorker:=TKvmClipboardClientWorker.Create(@CreateClipboardBackend,@DecodeReply);
    FDisconnect.Enabled := True;
    SyncMainMenu;
    FHost.Enabled := False;
    FPort.Enabled := False;
    FToken.Enabled := False;
    FTls.Enabled := False;
    SetStatus('Socket open; authenticating...');
  except
    on E: Exception do
    begin
      CloseSocket;
      SetStatus('Connection failed: ' + E.Message);
    end;
  end;
end;

procedure TKvmViewForm.DisconnectClick(Sender: TObject);
begin
  CloseSocket;
  SetStatus('Disconnected');
  FView.Invalidate;
end;

procedure TKvmViewForm.ControlClick(Sender: TObject);
begin
  SyncClipboardOptions;
  FText.Enabled := False;
  if GetCaptureControl = FView then SetCaptureControl(nil);
  ResetLocalInputs;
  if not FAuthorized or not FRemoteControl or FDesktopPaused then
  begin
    FControl.Checked := False;
    Exit;
  end;
  if FControl.Checked then
  begin
    FControlGranted := False;
    SendPacket('G'); // Request exclusive control from the SERVER.
    SetStatus('Requesting exclusive control from server...');
  end
  else
  begin
    FControlGranted := False;
    SendPacket('L'); // Server releases all held inputs on relinquish.
    SetStatus('View only: control released.');
  end;
  SyncViewCursor;
  SyncMainMenu;
end;

procedure TKvmViewForm.TryAutoRequestControl;
var
  SavedClick: TNotifyEvent;
begin
  // Never take control on merely opening the socket, with a view-only token,
  // or while logind/the server says the desktop is locked or unavailable.
  // The server is the sole authority: 'G' is a request, not a grant.
  if not FAutoControlPending or not FAuthorized or not FRemoteControl or
     FDesktopPaused or not FControl.Enabled or
     (FSocket=nil) or (FSocket.WebSockets=nil) then Exit;
  FAutoControlPending := False; // one request per connection, no busy retry loop
  // Updating Checked from Pascal may fire OnClick on some widgetsets.
  // Suppress the event and invoke the existing request path exactly once.
  SavedClick := FControl.OnClick;
  FControl.OnClick := nil;
  try
    FControl.Checked := True;
  finally
    FControl.OnClick := SavedClick;
  end;
  ControlClick(nil);
end;

procedure TKvmViewForm.WindowDeactivated(Sender: TObject);
begin
  if GetCaptureControl = FView then SetCaptureControl(nil);
  // The user moved to another application. Unstick remote keys/buttons.
  if FAuthorized and FControlGranted then SendPacket('Z');
  FKeyboardFocus := False;
  ResetLocalInputs;
end;

procedure TKvmViewForm.RefreshClick(Sender: TObject);
begin
  if FAuthorized then SendPacket('R');
end;

procedure TKvmViewForm.ResetLocalInputs;
begin
  FillChar(FSuppressedKeys, SizeOf(FSuppressedKeys), 0);
  FillChar(FForwardedKeys, SizeOf(FForwardedKeys), 0);
  FMouseButtons := 0; FWheelRemainder := 0; FLastShift := [];
  FPendingMouseMove := False; FLastMouseTick := 0;
  FMouseEchoNext := 0; FillChar(FMouseEchoes,SizeOf(FMouseEchoes),0);
  if GetCaptureControl = FView then SetCaptureControl(nil); FKeyboardFocus := False;
end;

procedure TKvmViewForm.ApplyDesktopState(Available: Boolean; Reason: Byte; Epoch: Cardinal);
var EpochChanged: Boolean;
begin
  if (FDesktopPaused=(not Available)) and (FDesktopEpoch=Epoch) then Exit;
  EpochChanged:=FDesktopEpoch<>Epoch;
  FDesktopEpoch:=Epoch;
  FDesktopPaused := not Available;
  if not Available or EpochChanged then
  begin
    ResetLocalInputs; FControlGranted := False; FControl.Checked := False;
    FControl.Enabled := False; FText.Enabled := False;
    FCursorVisible := False; FRemoteCursorOverlay:=False; FBitmap.SetSize(0,0);
    ClearSurface(FFront.Surface);
    ClearCursorShape(FFront.CursorShape);
    {$IFDEF WINDOWS}if FWinPresenter<>nil then FWinPresenter.ClearCursor;{$ENDIF}
    SyncViewCursor;
    FInputs.CancelQueued;
    SetStatus(DesktopStateText(Reason)+'. Control revoked.');
  end;
  if Available then
  begin
    FControl.Enabled := FAuthorized and FRemoteControl;
    SetStatus('Desktop available. Request control again if needed.');
  end;
  SyncClipboardOptions;
  FView.Invalidate;
end;

procedure TKvmViewForm.TextClick(Sender: TObject);
var Value: string; Packet,Utf8Bytes: RawByteString;
begin
  if not ControlAllowed then Exit;
  // Local input method performs composition in a normal LCL edit field.
  // A commit is not an IME event stream or a clipboard synchronization.
  SendPacket('Z'); ResetLocalInputs;
  Value := '';
  if not InputQuery('Text input', 'Text entered using your input method (256 characters max)', Value) then Exit;
  // Lazarus LCL strings are already UTF-8. Copy their bytes without an
  // intermediate AnsiString code-page conversion.
  SetLength(Utf8Bytes,Length(Value));
  if Length(Value)>0 then Move(Value[1],Utf8Bytes[1],Length(Value));
  Packet := MakeTextUtf8(Utf8Bytes);
  if Packet = '' then
    SetStatus('Text rejected: limit 256 Unicode code points / 1024 bytes, no control characters.')
  else if ControlAllowed then SendPacket(Packet);
end;

procedure TKvmViewForm.IncomingFrame(Sender: TWebSocketProcess;
  const Frame: TWebSocketFrame);
var N: Integer; TextMsg: string;
begin
  if FClosing then Exit;
  case Frame.opcode of
    focBinary:
      begin
        EnterCriticalSection(FLock);
        try
          if (Length(Frame.payload)>0) and (Frame.payload[1]='c') then
          begin
            if (FClipboardWorker=nil) or not FClipboardWorker.EnqueueReply(Frame.payload) then
              FWorkerFault:=True;
          end
          else if FDecoder<>nil then FDecoder.Enqueue(Frame.payload);
        finally LeaveCriticalSection(FLock); end;
      end;
    focText, focConnectionClose:
      begin
        if Frame.opcode = focConnectionClose then
        begin
          // A WebSocket close frame may carry a 16-bit status code in network order.
          // Do not attribute the closure to the server without further evidence.
          if Length(Frame.payload) >= 2 then
            TextMsg := 'CLOSED ' + IntToStr(Ord(Frame.payload[1])*256 + Ord(Frame.payload[2]))
          else
            TextMsg := 'CLOSED (no code)';
        end
        else if Length(Frame.payload) <= 512 then TextMsg := string(AnsiString(Frame.payload))
        else TextMsg := 'LOCAL PROTOCOL: text response too long (' + IntToStr(Length(Frame.payload)) + ' octets)';
        EnterCriticalSection(FLock);
        try
          N := Length(FPendingTexts);
          if N < 32 then
          begin
            SetLength(FPendingTexts, N + 1);
            FPendingTexts[N] := TextMsg;
          end
          else if Copy(TextMsg,1,6) = 'CLOSED' then
          begin
            SetLength(FPendingTexts, 1);
            FPendingTexts[0] := 'CLOSED';
          end;
        finally
          LeaveCriticalSection(FLock);
        end;
      end;
  end;
end;

procedure TKvmViewForm.RecordLocalMouseEcho(X,Y: Word);
var At: Integer;
begin
  At:=FMouseEchoNext;
  FMouseEchoes[At].X:=X;
  FMouseEchoes[At].Y:=Y;
  FMouseEchoes[At].Tick:=GetTickCount64;
  FMouseEchoNext:=(FMouseEchoNext+1) mod Length(FMouseEchoes);
end;

function TKvmViewForm.CursorMoveWasLocalEcho(X,Y: Word; NowTick: QWord): Boolean;
var I,DX,DY: Integer; T: QWord;
begin
  Result:=False;
  for I:=Low(FMouseEchoes) to High(FMouseEchoes) do
  begin
    T:=FMouseEchoes[I].Tick;
    if (T=0) or (NowTick<T) or (NowTick-T>KVM_MOUSE_ECHO_WINDOW_MS) then Continue;
    DX:=Abs(Integer(X)-Integer(FMouseEchoes[I].X));
    DY:=Abs(Integer(Y)-Integer(FMouseEchoes[I].Y));
    if (DX<=KVM_MOUSE_ECHO_TOLERANCE) and (DY<=KVM_MOUSE_ECHO_TOLERANCE) then
    begin
      // Consume the echo so a later independent movement back to the same
      // coordinate is not accidentally classified as ours.
      FMouseEchoes[I].Tick:=0;
      Exit(True);
    end;
  end;
end;

procedure TKvmViewForm.HideRemoteCursorOverlay;
begin
  if FRemoteCursorOverlay and FCursorVisible then
    InvalidateCursor(FCursorX,FCursorY,True);
  FRemoteCursorOverlay:=False;
end;

procedure TKvmViewForm.SyncViewCursor;
begin
  {$IFDEF WINDOWS}
  if FView=nil then Exit;
  if ControlAllowed and (FFront.CursorShape.Revision<>0) and
     (FWinPresenter<>nil) and
     (FWinPresenter.CursorRevision=FFront.CursorShape.Revision) then
  begin
    // During normal control the local OS pointer is the immediate cursor. Its
    // shape/hotspot is exactly the one selected by the remote application.
    if InstallLocalNativeCursor(KVM_LOCAL_NATIVE_CURSOR,FFront.CursorShape) then
      FView.Cursor:=KVM_LOCAL_NATIVE_CURSOR
    else
      FView.Cursor:=crDefault;
  end
  else
    FView.Cursor:=crDefault;
  {$ENDIF}
end;

procedure TKvmViewForm.InvalidateCursor(X,Y: Word; AVisible: Boolean);
var Area: TRect; CX,CY,CW,CH,HX,HY,DW,DH,SW,SH: Integer; Item: TKvmDisplayItem;
begin
  if not AVisible or (FView.Parent=nil) then Exit;
  if not MapRemoteCursorToView(X,Y,CX,CY,Item) then Exit;
  DW:=Item.DestRect.Right-Item.DestRect.Left;
  DH:=Item.DestRect.Bottom-Item.DestRect.Top;
  SW:=Item.SourceRect.Right-Item.SourceRect.Left;
  SH:=Item.SourceRect.Bottom-Item.SourceRect.Top;
  {$IFDEF WINDOWS}
  if (FFront.CursorShape.Revision<>0) and (SW>0) and (SH>0) then
  begin
    CW:=Max(1,Integer((Int64(FFront.CursorShape.Width)*DW+SW-1) div SW));
    CH:=Max(1,Integer((Int64(FFront.CursorShape.Height)*DH+SH-1) div SH));
    HX:=Integer((Int64(FFront.CursorShape.HotX)*DW+SW div 2) div SW);
    HY:=Integer((Int64(FFront.CursorShape.HotY)*DH+SH div 2) div SH);
    Area:=Rect(Max(0,CX-HX-2),Max(0,CY-HY-2),
      Min(FView.Width,CX-HX+CW+2),Min(FView.Height,CY-HY+CH+2));
  end
  else
  {$ENDIF}
    Area:=Rect(Max(0,CX-12),Max(0,CY-12),
      Min(FView.Width,CX+13),Min(FView.Height,CY+13));
  OffsetRect(Area,FView.Left,FView.Top);
  LCLIntf.InvalidateRect(FView.Parent.Handle,@Area,False);
end;

procedure TKvmViewForm.InvalidateDamage(const Damage: TRect);
var Items: TKvmDisplayItems; I,DW,DH,SW,SH: Integer; Hit,Area: TRect;
begin
  if (FView.Parent=nil) or not SurfaceValid(FFront.Surface) then Exit;
  if (Damage.Right<=Damage.Left) or (Damage.Bottom<=Damage.Top) then
  begin FView.Invalidate; Exit; end;
  if not BuildDisplayLayout(Items) then begin FView.Invalidate; Exit; end;
  for I:=0 to High(Items) do
  begin
    Hit.Left:=Max(Damage.Left,Items[I].SourceRect.Left);
    Hit.Top:=Max(Damage.Top,Items[I].SourceRect.Top);
    Hit.Right:=Min(Damage.Right,Items[I].SourceRect.Right);
    Hit.Bottom:=Min(Damage.Bottom,Items[I].SourceRect.Bottom);
    if (Hit.Right<=Hit.Left) or (Hit.Bottom<=Hit.Top) then Continue;
    SW:=Items[I].SourceRect.Right-Items[I].SourceRect.Left;
    SH:=Items[I].SourceRect.Bottom-Items[I].SourceRect.Top;
    DW:=Items[I].DestRect.Right-Items[I].DestRect.Left;
    DH:=Items[I].DestRect.Bottom-Items[I].DestRect.Top;
    if (SW<1) or (SH<1) or (DW<1) or (DH<1) then Continue;
    Area.Left:=Items[I].DestRect.Left+Integer(((Int64(Hit.Left)-Int64(Items[I].SourceRect.Left))*DW) div SW);
    Area.Top:=Items[I].DestRect.Top+Integer(((Int64(Hit.Top)-Int64(Items[I].SourceRect.Top))*DH) div SH);
    Area.Right:=Items[I].DestRect.Left+Integer(((Int64(Hit.Right)-Int64(Items[I].SourceRect.Left))*DW+SW-1) div SW);
    Area.Bottom:=Items[I].DestRect.Top+Integer(((Int64(Hit.Bottom)-Int64(Items[I].SourceRect.Top))*DH+SH-1) div SH);
    Area.Left:=Max(0,Area.Left-1); Area.Top:=Max(0,Area.Top-1);
    Area.Right:=Min(FView.Width,Area.Right+1); Area.Bottom:=Min(FView.Height,Area.Bottom+1);
    OffsetRect(Area,FView.Left,FView.Top);
    LCLIntf.InvalidateRect(FView.Parent.Handle,@Area,False);
  end;
end;

procedure TKvmViewForm.PresentSnapshot(const Snapshot: TKvmPresentation);
var Raw: TRawImage; Tick,NowTick: QWord; ImageChanged, CursorChanged, GeometryChanged,
    CursorShapeChanged, CursorPositionChanged, CursorVisibilityChanged,
    ExternalCursorMove, OldOverlayVisible, NewOverlayVisible: Boolean;
    Damage: TRect;
begin
  if not Snapshot.Available or (Snapshot.Epoch<>FDesktopEpoch) or
     FDesktopPaused or not SurfaceValid(Snapshot.Surface) then Exit;
  GeometryChanged:=(FFront.Epoch<>Snapshot.Epoch) or not SurfaceValid(FFront.Surface) or
    (FFront.Surface.Width<>Snapshot.Surface.Width) or
    (FFront.Surface.Height<>Snapshot.Surface.Height);
  ImageChanged:=(FFront.ImageRevision<>Snapshot.ImageRevision) or GeometryChanged;
  CursorShapeChanged:=FFront.CursorShape.Revision<>Snapshot.CursorShape.Revision;
  CursorVisibilityChanged:=FCursorVisible<>Snapshot.CursorVisible;
  // A hidden->visible transition is not by itself considered movement. The
  // external overlay appears only after a real position change was observed.
  CursorPositionChanged:=FCursorVisible and Snapshot.CursorVisible and
    ((FCursorX<>Snapshot.CursorX) or (FCursorY<>Snapshot.CursorY));
  CursorChanged:=CursorVisibilityChanged or CursorPositionChanged or
    (Snapshot.CursorVisible and CursorShapeChanged);
  NowTick:=GetTickCount64;
  ExternalCursorMove:=CursorPositionChanged and
    not CursorMoveWasLocalEcho(Snapshot.CursorX,Snapshot.CursorY,NowTick);

  if (FFront.Surface.Width<>Snapshot.Surface.Width) or
     (FFront.Surface.Height<>Snapshot.Surface.Height) then
    SetStatus(Format('Remote desktop: %d x %d | video worker',
      [Snapshot.Surface.Width,Snapshot.Surface.Height]));

  OldOverlayVisible:=FRemoteCursorOverlay and FCursorVisible;
  if OldOverlayVisible and CursorChanged then
    InvalidateCursor(FCursorX,FCursorY,True);

  FFront:=Snapshot;
  if GeometryChanged then ApplyMonitorLayout;
  FCursorX:=Snapshot.CursorX; FCursorY:=Snapshot.CursorY;
  FCursorVisible:=Snapshot.CursorVisible;
  {$IFDEF WINDOWS}
  if CursorShapeChanged and (FWinPresenter<>nil) then
  begin
    if FFront.CursorShape.Revision=0 then FWinPresenter.ClearCursor
    else if not FWinPresenter.UpdateCursor(FFront.CursorShape) then FWinPresenter.ClearCursor;
  end;
  {$ENDIF}

  if not FCursorVisible then
  begin
    FRemoteCursorOverlay:=False;
  end
  else if CursorPositionChanged then
  begin
    if ExternalCursorMove then
    begin
      // The server cursor moved without matching any recently transmitted
      // mouse position from this client: keep the true remote position visible
      // until this client moves/clicks again or the server hides the cursor.
      FRemoteCursorOverlay:=True;
    end
    else
    begin
      // Echo of our own injected movement: the local OS cursor is already at
      // the intended position, so painting a second remote cursor is noise.
      FRemoteCursorOverlay:=False;
    end;
  end;

  SyncViewCursor;
  NewOverlayVisible:=FRemoteCursorOverlay and FCursorVisible;
  Inc(FPresentCount);
  if not ImageChanged then
  begin
    // Cursor-only batches never reimport the framebuffer.
    if CursorChanged and NewOverlayVisible then
      InvalidateCursor(FCursorX,FCursorY,True);
    Exit;
  end;
  Damage:=FFront.Damage;
  if GeometryChanged or (Damage.Right<=Damage.Left) or (Damage.Bottom<=Damage.Top) then
    Damage:=Rect(0,0,FFront.Surface.Width,FFront.Surface.Height);
  Tick:=GetTickCount64;
  {$IFDEF WINDOWS}
  if FUseRawImage then
  begin
    if (FWinPresenter=nil) or not FWinPresenter.Update(FFront.Surface,Damage) then
      raise Exception.Create('Failed to update Windows DIB');
  end
  else
  {$ENDIF}
  begin
    Raw.Init;
    Raw.Description.Init_BPP32_B8G8R8_BIO_TTB(FFront.Surface.Width,FFront.Surface.Height);
    Raw.Data:=PByte(Pointer(FFront.Surface.Pixels));
    Raw.DataSize:=Length(FFront.Surface.Pixels);
    FBitmap.LoadFromRawImage(Raw,False);
  end;
  Inc(FRawImportMs,GetTickCount64-Tick);
  if GeometryChanged then FView.Invalidate else InvalidateDamage(Damage);
  if CursorChanged and NewOverlayVisible then
    InvalidateCursor(FCursorX,FCursorY,True);
end;

procedure TKvmViewForm.PollTimer(Sender: TObject);
var
  TextMsgs: array of string;
  TextMsg, FatalError, ClipboardNotice: string;
  DisableClipboard: Byte;
  Events: TKvmPacketList;
  Snapshot: TKvmPresentation;
  Stats: TKvmDecodeStats;
  I: Integer;
  HasSnapshot, Available: Boolean;
  Epoch: Cardinal; Reason, InputStatus: Byte; Applied: Word;
  NowTick: QWord;
begin
  if FPolling or FClosing then Exit;
  FPolling:=True;
  try
    if FTransportFault then
    begin
      CloseSocket; SetStatus('Network send interrupted: input will not be replayed.'); Exit;
    end;
    if FAutoConnect then begin FAutoConnect:=False; ConnectClick(nil); end;
    HasSnapshot:=False; FatalError:='';
    EnterCriticalSection(FLock);
    try
      TextMsgs:=FPendingTexts; FPendingTexts:=nil;
      if FWorkerFault then FatalError:='Network communication interrupted or invalid clipboard reply';
    finally LeaveCriticalSection(FLock); end;
    if FatalError<>'' then
    begin CloseSocket; SetStatus(FatalError); Exit; end;
  for I := 0 to High(TextMsgs) do
  begin
    TextMsg := TextMsgs[I];
    if TextMsg = 'OK CTRL' then
    begin
      FAuthorized := True;
      FRemoteControl := True;
      FControl.Enabled := not FDesktopPaused;
      FRefresh.Enabled := True;
      SetStatus('Connected | control available.');
      SyncMainMenu;
    end
    else if TextMsg = 'OK VIEW' then
    begin
      FAuthorized := True;
      FRemoteControl := False;
      FControl.Enabled := False;
      FRefresh.Enabled := True;
      SetStatus('Connected | view only.');
      SyncMainMenu;
    end
    else if TextMsg = 'CTRL GRANTED' then
    begin
      FControlGranted := not FDesktopPaused;
      FText.Enabled := FControlGranted;
      SetStatus('EXCLUSIVE control granted: click inside the desktop.');
    end
    else if TextMsg = 'CTRL BUSY' then
    begin
      FControlGranted := False;
      FText.Enabled := False;
      FControl.Checked := False;
      ResetLocalInputs;
      SetStatus('Another client currently controls the desktop.');
    end
    else if TextMsg = 'CTRL RELEASED' then
    begin
      FControlGranted := False;
      FText.Enabled := False;
      ResetLocalInputs;
    end
    else if Copy(TextMsg,1,15) = 'MONITOR_LAYOUT ' then
      ParseMonitorLayout(TextMsg)
    else if TextMsg = 'ERR INPUT' then
      SetStatus('Input unsupported or rejected by the remote system. Text may be incomplete.')
    else if (TextMsg = 'ERR AUTH') or (TextMsg = 'ERR LIMIT') or
            (Copy(TextMsg,1,6) = 'CLOSED') or (TextMsg = 'ERR TIMEOUT') or
            (TextMsg = 'ERR PROTOCOL') or (Copy(TextMsg,1,15) = 'LOCAL PROTOCOL:') then
    begin
      // Keep the diagnostic after CloseSocket(), which resets all GUI state.
      KvmClientLog('[client-ws] ' + TextMsg);
      CloseSocket;
      if TextMsg = 'ERR AUTH' then
        SetStatus('Authentification refusee')
      else if TextMsg = 'ERR LIMIT' then
        SetStatus('Maximum number of clients reached')
      else if TextMsg = 'ERR TIMEOUT' then
        SetStatus('Session ended: server reported a timeout')
      else if TextMsg = 'ERR PROTOCOL' then
        SetStatus('Server reported a protocol error')
      else if Copy(TextMsg,1,15) = 'LOCAL PROTOCOL:' then
        SetStatus('LOCAL receive error: ' + Copy(TextMsg,17,200))
      else
        SetStatus('WebSocket fermee : ' + TextMsg + ' (origine a determiner)');
      Exit;
    end;
  end;

    SyncViewCursor;
    if not FAuthorized then Exit;
    if FDecoder<>nil then
      FDecoder.DrainUI(Events,Snapshot,HasSnapshot,FatalError);
    if FatalError<>'' then
    begin
      KvmClientLog('[client-video] worker error: '+FatalError);
      CloseSocket; SetStatus('Video error: '+FatalError); Exit;
    end;
    // Desktop transitions and input receipts are never coalesced/dropped.
    for I:=0 to High(Events) do
      case Events[I][1] of
        'D':
          if ReadDesktopState(Events[I],Available,Reason,Epoch) then
            ApplyDesktopState(Available,Reason,Epoch)
          else begin CloseSocket; SetStatus('Invalid session state'); Exit; end;
        'I':
          begin
            if not FInputs.Receipt(Events[I],InputStatus,Applied) then
            begin CloseSocket; SetStatus('Invalid input acknowledgment'); Exit; end;
            if InputStatus=KVM_INPUT_STALE then
            begin CloseSocket; SetStatus('Input sequence out of sync'); Exit; end;
            if InputStatus<>KVM_INPUT_OK then
            begin
              FInputs.CancelQueued;
              // A rejected Unicode commit is recoverable: the receipt has
              // already cleared the in-flight serial, so keep the KVM session
              // and control ownership alive.  Only a partial OS injection may
              // have changed modifier state and therefore still releases control.
              if InputStatus=KVM_INPUT_PARTIAL then
              begin TransmitPacket('Z'); ResetLocalInputs; end;
              SetStatus(Format('Input rejected/partial (%d, %d code points)',[InputStatus,Applied]));
            end;
            DrainInputs;
          end;
      end;
    TryAutoRequestControl; // AUTH and desktop state have both been processed.
    SyncClipboardOptions;
    if (FClipboardWorker<>nil) and FClipboardWorker.TakeNotice(DisableClipboard,ClipboardNotice) then
    begin
      FClipboardChanging:=True;
      try
        if (DisableClipboard and KVM_CLIP_WRITE)<>0 then FClipToRemote.Checked:=False;
        if (DisableClipboard and KVM_CLIP_READ)<>0 then FClipFromRemote.Checked:=False;
      finally FClipboardChanging:=False; end;
      SyncClipboardOptions;
      if ClipboardNotice<>'' then SetStatus(ClipboardNotice);
    end;

    if HasSnapshot then
      try PresentSnapshot(Snapshot);
      except on E: Exception do
        begin CloseSocket; SetStatus('Display failed: '+E.Message); Exit; end; end;
    if FPendingMouseMove and ControlAllowed and
       (GetTickCount64-FLastMouseTick>=KVM_MOUSE_INTERVAL_MS) then
    begin
      FPendingMouseMove:=False; FLastMouseTick:=GetTickCount64;
      SendPacket(MakeMouse(0,0,FPendingMouseX,FPendingMouseY));
    end;
    if FInputs.TimedOut(GetTickCount64) then
    begin CloseSocket; SetStatus('Input acknowledgment missing: no retransmission'); Exit; end;
    if GetTickCount64-FLastHeartbeat>=3000 then
    begin FLastHeartbeat:=GetTickCount64; SendPacket('P'); end;
    NowTick:=GetTickCount64;
    if (NowTick-FStatsTick>=5000) and (FDecoder<>nil) then
    begin
      FDecoder.TakeStats(Stats);
      KvmClientLog('[client-video] ACK/s='+
        FormatFloat('0.0',Stats.AckCount*1000.0/(NowTick-FStatsTick))+
        ' JPEG/s='+FormatFloat('0.0',Stats.JpegCount*1000.0/(NowTick-FStatsTick))+
        ' decode worker ms='+IntToStr(Int64(Stats.DecodeMs))+
        ' copie CPU ms='+IntToStr(Int64(Stats.CopyMs))+
        ' copie CPU octets='+IntToStr(Int64(Stats.CopiedBytes))+
        ' commit+ACK ms='+IntToStr(Int64(Stats.CommitMs))+
        ' import LCL ms='+IntToStr(Int64(FRawImportMs))+
        ' PaintBox ms='+IntToStr(Int64(FPaintMs))+
        ' PaintBox/s='+FormatFloat('0.0',FPaintCount*1000.0/(NowTick-FStatsTick))+
        ' presentations='+IntToStr(FPresentCount)+
        ' presentations fusionnees='+IntToStr(Int64(Stats.Coalesced))+
        ' file max octets='+IntToStr(Int64(Stats.QueueHighBytes))+
        ' TurboJPEG='+IntToStr(Int64(Stats.NativeCount))+
        ' FCL='+IntToStr(Int64(Stats.FallbackCount))+
        ' NACK='+IntToStr(Int64(Stats.NackCount)));
      FStatsTick:=NowTick; FRawImportMs:=0; FPaintMs:=0;
      FPaintCount:=0; FPresentCount:=0;
    end;
  finally FPolling:=False; end;
end;

function TKvmViewForm.GetVideoRect: TRect;
var Items: TKvmDisplayItems; I: Integer;
begin
  Result:=Rect(0,0,0,0);
  if not BuildDisplayLayout(Items) or (Length(Items)=0) then Exit;
  Result:=Items[0].DestRect;
  for I:=1 to High(Items) do
  begin
    Result.Left:=Min(Result.Left,Items[I].DestRect.Left);
    Result.Top:=Min(Result.Top,Items[I].DestRect.Top);
    Result.Right:=Max(Result.Right,Items[I].DestRect.Right);
    Result.Bottom:=Max(Result.Bottom,Items[I].DestRect.Bottom);
  end;
end;

procedure TKvmViewForm.PaintView(Sender: TObject);
var
  Items: TKvmDisplayItems; Item: TKvmDisplayItem; I,CX,CY: Integer;
  HalfSize,CursorW,CursorH,VideoW,VideoH,SourceW,SourceH: Integer;
  PaintTick: QWord;
begin
  FView.Canvas.Brush.Color:=clBlack;
  FView.Canvas.FillRect(FView.ClientRect);
  if (FFront.Surface.Width<1) or (FFront.Surface.Height<1) then
  begin
    FView.Canvas.Font.Color:=clWhite;
    FView.Canvas.TextOut(20,20,'Waiting for remote desktop...');
    Exit;
  end;
  if not BuildDisplayLayout(Items) then Exit;
  PaintTick:=GetTickCount64;
  for I:=0 to High(Items) do
  begin
    Item:=Items[I];
    {$IFDEF WINDOWS}
    if FUseRawImage then
    begin
      if (FWinPresenter=nil) or not FWinPresenter.PaintRegion(FView.Canvas.Handle,
        Item.DestRect.Left,Item.DestRect.Top,
        Item.DestRect.Right-Item.DestRect.Left,Item.DestRect.Bottom-Item.DestRect.Top,
        Item.SourceRect.Left,Item.SourceRect.Top,
        Item.SourceRect.Right-Item.SourceRect.Left,Item.SourceRect.Bottom-Item.SourceRect.Top) then
        KvmClientLog('[client-video] Windows DIB region failed');
    end
    else
    {$ENDIF}
      FView.Canvas.CopyRect(Item.DestRect,FBitmap.Canvas,Item.SourceRect);
  end;
  Inc(FPaintMs,GetTickCount64-PaintTick); Inc(FPaintCount);
  if not FCursorVisible or not FRemoteCursorOverlay then Exit;
  if not MapRemoteCursorToView(FCursorX,FCursorY,CX,CY,Item) then Exit;
  {$IFDEF WINDOWS}
  if (FWinPresenter<>nil) and (FFront.CursorShape.Revision<>0) then
  begin
    VideoW:=Item.DestRect.Right-Item.DestRect.Left;
    VideoH:=Item.DestRect.Bottom-Item.DestRect.Top;
    SourceW:=Item.SourceRect.Right-Item.SourceRect.Left;
    SourceH:=Item.SourceRect.Bottom-Item.SourceRect.Top;
    CursorW:=Max(1,Integer((Int64(FFront.CursorShape.Width)*VideoW+SourceW div 2) div SourceW));
    CursorH:=Max(1,Integer((Int64(FFront.CursorShape.Height)*VideoH+SourceH div 2) div SourceH));
    if FWinPresenter.PaintCursor(FView.Canvas.Handle,CX,CY,CursorW,CursorH) then Exit;
  end;
  {$ENDIF}
  HalfSize:=9;
  FView.Canvas.Pen.Style:=psSolid; FView.Canvas.Pen.Color:=clBlack; FView.Canvas.Pen.Width:=3;
  FView.Canvas.MoveTo(Max(Item.DestRect.Left,CX-HalfSize),CY);
  FView.Canvas.LineTo(Min(Item.DestRect.Right-1,CX+HalfSize+1),CY);
  FView.Canvas.MoveTo(CX,Max(Item.DestRect.Top,CY-HalfSize));
  FView.Canvas.LineTo(CX,Min(Item.DestRect.Bottom-1,CY+HalfSize+1));
  FView.Canvas.Pen.Color:=clYellow; FView.Canvas.Pen.Width:=1;
  FView.Canvas.MoveTo(Max(Item.DestRect.Left,CX-HalfSize),CY);
  FView.Canvas.LineTo(Min(Item.DestRect.Right-1,CX+HalfSize+1),CY);
  FView.Canvas.MoveTo(CX,Max(Item.DestRect.Top,CY-HalfSize));
  FView.Canvas.LineTo(CX,Min(Item.DestRect.Bottom-1,CY+HalfSize+1));
end;

function TKvmViewForm.ToNormalized(X,Y: Integer; out NX,NY: Word): Boolean;
var
  Items: TKvmDisplayItems; I,Best,PX,PY,DX,DY,SrcX,SrcY,SW,SH,DW,DH: Integer;
  Dist,BestDist: Int64;
begin
  Result:=False; NX:=0; NY:=0;
  if not BuildDisplayLayout(Items) then Exit;
  Best:=-1; PX:=X; PY:=Y;
  for I:=0 to High(Items) do
    if (X>=Items[I].DestRect.Left) and (X<Items[I].DestRect.Right) and
       (Y>=Items[I].DestRect.Top) and (Y<Items[I].DestRect.Bottom) then
    begin Best:=I; Break; end;
  if (Best<0) and (FMouseButtons<>0) then
  begin
    BestDist:=High(Int64);
    for I:=0 to High(Items) do
    begin
      DX:=EnsureRange(X,Items[I].DestRect.Left,Items[I].DestRect.Right-1);
      DY:=EnsureRange(Y,Items[I].DestRect.Top,Items[I].DestRect.Bottom-1);
      Dist:=(Int64(DX)-Int64(X))*(Int64(DX)-Int64(X))+
            (Int64(DY)-Int64(Y))*(Int64(DY)-Int64(Y));
      if Dist<BestDist then begin BestDist:=Dist; Best:=I; PX:=DX; PY:=DY; end;
    end;
  end;
  if Best<0 then Exit;
  SW:=Items[Best].SourceRect.Right-Items[Best].SourceRect.Left;
  SH:=Items[Best].SourceRect.Bottom-Items[Best].SourceRect.Top;
  DW:=Items[Best].DestRect.Right-Items[Best].DestRect.Left;
  DH:=Items[Best].DestRect.Bottom-Items[Best].DestRect.Top;
  if (SW<1) or (SH<1) or (DW<1) or (DH<1) then Exit;
  if DW>1 then SrcX:=Items[Best].SourceRect.Left+
    Integer(((Int64(PX)-Int64(Items[Best].DestRect.Left))*Int64(SW-1)) div Int64(DW-1))
  else SrcX:=Items[Best].SourceRect.Left;
  if DH>1 then SrcY:=Items[Best].SourceRect.Top+
    Integer(((Int64(PY)-Int64(Items[Best].DestRect.Top))*Int64(SH-1)) div Int64(DH-1))
  else SrcY:=Items[Best].SourceRect.Top;
  if FFront.Surface.Width>1 then NX:=Word((Int64(SrcX)*65535) div Int64(FFront.Surface.Width-1));
  if FFront.Surface.Height>1 then NY:=Word((Int64(SrcY)*65535) div Int64(FFront.Surface.Height-1));
  Result:=True;
end;

function TKvmViewForm.ControlAllowed: Boolean;
begin
  Result := not FDesktopPaused and FAuthorized and FRemoteControl and FControlGranted and FControl.Checked and
    (FSocket <> nil) and (FSocket.WebSockets <> nil);
end;

function TKvmViewForm.OutgoingInputPacketValid(const Payload: RawByteString): Boolean;
var
  Serial: Cardinal;
  MouseAction,Button: Byte;
  MX,MY,VKey: Word;
  Pressed: Boolean;
  Wheel: SmallInt;
  Points: TKvmCodePoints;
begin
  Result:=False;
  if Payload='' then Exit;
  case Payload[1] of
    'P','R','G','L','Z': Result:=Length(Payload)=1;
    'A': Result:=ReadBatchAck(Payload,Serial);
    'N': Result:=ReadBatchNack(Payload,Serial);
    'M': Result:=ReadMouse(Payload,MouseAction,Button,MX,MY);
    'K': Result:=ReadKey(Payload,Pressed,VKey);
    'W': Result:=ReadWheel(Payload,Wheel);
    // Only versioned X requests may leave the local input queue.
    'X': Result:=ReadTextRequest(Payload,Serial,Points);
  end;
end;

procedure TKvmViewForm.TransmitPacket(const Payload: RawByteString);
var
  Frame: TWebSocketFrame;
  MouseAction,Button: Byte;
  MX,MY: Word;
begin
  if (Payload = '') or not FAuthorized or (FSocket = nil) or
     (FSocket.WebSockets = nil) then Exit;
  // Never let a malformed local input reach the server. In particular this
  // protects the local Unicode-text path: the server only sees a validated
  // receipt-tracked X request (local U commits never leave this process).
  if not OutgoingInputPacketValid(Payload) then
  begin
    KvmClientLog('[client-input] invalid outgoing packet blocked before WebSocket (type='+
      IntToStr(Ord(Payload[1]))+', longueur='+IntToStr(Length(Payload))+')');
    if Payload[1]='X' then FInputs.Reset;
    SetStatus('Invalid local input blocked before sending.');
    Exit;
  end;
  Frame.opcode := focBinary;
  Frame.content := [];
  Frame.tix := 0;
  Frame.payload := Payload;
  try
    if FSocket.WebSockets.SendFrame(Frame) then
    begin
      // Record only mouse positions that really reached the socket. A cursor
      // update returning to one of these positions is an echo of this client,
      // not an independent remote pointer movement.
      if ReadMouse(Payload,MouseAction,Button,MX,MY) then RecordLocalMouseEcho(MX,MY);
    end
    else
      FTransportFault:=True;
  except
    FTransportFault:=True; // UI timer closes without recursively calling CloseSocket here.
  end;
end;

procedure TKvmViewForm.SendPacket(const Payload: RawByteString);
begin
  if (Payload='') or not FAuthorized or FTransportFault then Exit;
  if Payload[1] in ['K','M','W','U'] then
  begin
    if not ControlAllowed then Exit;
    if not FInputs.Push(Payload) then
    begin
      FInputs.CancelQueued; TransmitPacket('Z'); ResetLocalInputs;
      SetStatus('Input queue full: unsent events discarded, keys released.'); Exit;
    end;
    DrainInputs;
  end
  else begin
    if Payload[1] in ['L','Z'] then FInputs.CancelQueued;
    TransmitPacket(Payload);
  end;
end;

procedure TKvmViewForm.DrainInputs;
var Packet: RawByteString;
begin
  while not FTransportFault and ControlAllowed and FInputs.Take(GetTickCount64,Packet) do TransmitPacket(Packet);
end;

procedure TKvmViewForm.KeyboardModeClick(Sender: TObject);
begin
  if FAuthorized and FControlGranted then SendPacket('Z');
  ResetLocalInputs;
  if FRemoteKeys.Checked then
    SetStatus('Physical keys: the remote desktop keyboard layout and input methods apply.')
  else
    SetStatus('Automatic mode: locally composed Unicode text; shortcuts and special keys sent separately.');
  SyncMainMenu;
end;

function TKvmViewForm.MouseButtonCode(Button: TMouseButton): Byte;
begin
  case Button of
    mbLeft: Result := 1;
    mbRight: Result := 2;
    mbMiddle: Result := 3;
  else
    Result := 0;
  end;
end;

procedure TKvmViewForm.ViewMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Integer);
var
  NX, NY: Word;
  NowTicks: QWord;
begin
  if not ControlAllowed or not ToNormalized(X, Y, NX, NY) then Exit;
  HideRemoteCursorOverlay;
  // Keep the most recent position rather than dropping movements entirely.
  FPendingMouseX := NX; FPendingMouseY := NY;
  FPendingMouseMove := True;
  NowTicks := GetTickCount64;
  if (FLastMouseTick <> 0) and
     (NowTicks-FLastMouseTick < KVM_MOUSE_INTERVAL_MS) then Exit;
  FPendingMouseMove := False;
  FLastMouseTick := NowTicks;
  SendPacket(MakeMouse(0, 0, NX, NY));
end;

procedure TKvmViewForm.ViewMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  NX, NY: Word;
begin
  if not ControlAllowed or not ToNormalized(X, Y, NX, NY) then Exit;
  HideRemoteCursorOverlay;
  if MouseButtonCode(Button) = 0 then Exit;
  FMouseButtons := FMouseButtons or (1 shl (MouseButtonCode(Button)-1));
  FKeyboardFocus := True;
  SetCaptureControl(FView);
  // The button packet contains the exact position; discard an old move.
  FPendingMouseMove := False;
  // Remove focus from login edits; keyboard events go to the form.
  ActiveControl := nil;
  SendPacket(MakeMouse(1, MouseButtonCode(Button), NX, NY));
end;

procedure TKvmViewForm.ViewMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  NX, NY: Word;
  R: TRect;
begin
  if not ControlAllowed then Exit;
  if not ToNormalized(X, Y, NX, NY) then
  begin
    // Release the remote button even if the cursor left the image.
    R := GetVideoRect;
    if (R.Right <= R.Left + 1) or (R.Bottom <= R.Top + 1) then Exit;
    X := EnsureRange(X, R.Left, R.Right - 1);
    Y := EnsureRange(Y, R.Top, R.Bottom - 1);
    if not ToNormalized(X, Y, NX, NY) then Exit;
  end;
  HideRemoteCursorOverlay;
  if MouseButtonCode(Button) = 0 then Exit;
  FPendingMouseMove := False;
  SendPacket(MakeMouse(2, MouseButtonCode(Button), NX, NY));
  FMouseButtons := FMouseButtons and not (1 shl (MouseButtonCode(Button)-1));
  if FMouseButtons <> 0 then SetCaptureControl(FView)
  else if GetCaptureControl = FView then SetCaptureControl(nil);
end;

procedure TKvmViewForm.ViewMouseWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
var
  Notches: Integer;
begin
  if not ControlAllowed then Exit;
  Inc(FWheelRemainder, EnsureRange(WheelDelta,-1440,1440));
  Notches := FWheelRemainder div 120;
  Notches := EnsureRange(Notches, -12, 12);
  Handled := True;
  if Notches = 0 then Exit;
  Dec(FWheelRemainder, Notches*120);
  SendPacket(MakeWheel(Notches));
  Handled := True;
end;

function IsPrintableVirtualKey(K: Word): Boolean;
begin
  // Windows-style VKs supplied by Lazarus. For ordinary text we rely
  // on the UTF-8 keypress event; only shortcuts/navigation use VKs.
  Result := (K = $20) or (K in [$30..$39, $41..$5a, $60..$6f,
    $ba..$c0, $db..$de]);
end;

procedure TKvmViewForm.RemoteUTF8KeyPress(Sender: TObject;
  var UTF8Key: TUTF8Char);
var
  Packet,Utf8Bytes: RawByteString;
begin
  if not ControlAllowed or not FKeyboardFocus then Exit;
  if FRemoteKeys.Checked then begin UTF8Key:=''; Exit; end;
  if (ActiveControl = FHost) or (ActiveControl = FPort) or
     (ActiveControl = FToken) then Exit;
  // Ctrl+C, Alt+F4 and similar shortcuts remain virtual-key events.
  // Ctrl+Alt together may be AltGr on international layouts.
  if ((ssCtrl in FLastShift) xor (ssAlt in FLastShift)) or (ssMeta in FLastShift) then Exit;
  // TUTF8Char is a short string in the LCL. Copy exactly the bytes delivered
  // by the widgetset; do not pass through the process ANSI code page.
  SetLength(Utf8Bytes,Length(UTF8Key));
  if Length(UTF8Key)>0 then Move(UTF8Key[1],Utf8Bytes[1],Length(UTF8Key));
  Packet := MakeTextUtf8(Utf8Bytes);
  if Packet = '' then Exit;
  SendPacket(Packet);
  UTF8Key := '';
end;

procedure TKvmViewForm.RemoteKeyDown(Sender: TObject;
  var Key: Word; Shift: TShiftState);
var
  Shortcut: Boolean;
begin
  // F11 is reserved by the CLIENT for full screen; other function keys go to the remote host.
  if Key = VK_F11 then
  begin
    if not FEmbeddedMode then
    begin
      ToggleFullScreen;
      Key := 0;
      Exit;
    end;
  end;
  FLastShift := Shift;
  if not ControlAllowed or not FKeyboardFocus then Exit;
  if (ActiveControl = FHost) or (ActiveControl = FPort) or
     (ActiveControl = FToken) then Exit;
  if (Key=0) or (Key>255) then Exit;
  Shortcut := ((ssCtrl in Shift) xor (ssAlt in Shift)) or (ssMeta in Shift);
  if not FRemoteKeys.Checked and IsPrintableVirtualKey(Key) and not Shortcut then
  begin
    FSuppressedKeys[Key] := True;
    Exit; // Wait for OnUTF8KeyPress: AZERTY, accents and Unicode.
  end;
  FForwardedKeys[Key] := True;
  SendPacket(MakeKey(True, Key));
  Key := 0;
end;

procedure TKvmViewForm.RemoteKeyUp(Sender: TObject;
  var Key: Word; Shift: TShiftState);
begin
  if Key = VK_F11 then
  begin
    if not FEmbeddedMode then
    begin
      Key := 0;
      Exit;
    end;
  end;
  FLastShift := Shift;
  if not ControlAllowed or not FKeyboardFocus then Exit;
  if (ActiveControl = FHost) or (ActiveControl = FPort) or
     (ActiveControl = FToken) then Exit;
  if (Key=0) or (Key>255) then Exit;
  // A key first suppressed as text may later repeat as a Ctrl shortcut.
  // Always release a forwarded down, even when the suppression flag is set.
  if FForwardedKeys[Key] then SendPacket(MakeKey(False, Key));
  FForwardedKeys[Key] := False; FSuppressedKeys[Key] := False;
  Key := 0;
end;

end.

unit kvm_desktop;
{$mode objfpc}{$H+}
interface
uses kvm_frame, kvm_cli, kvm_wire;
function ConfigureDesktop(const Options: TKvmServerOptions; out Reason: string): Boolean;
function ConfigureDesktopMonitor(Index: Integer; out Reason: string): Boolean;
procedure ListDesktopMonitors;
procedure CloseDesktopCapture;
procedure ReleaseDesktop;
procedure ConfigureCaptureFPS(FPS: Integer);
function DesktopBackendName: string;
function DesktopBackendReady(AllowControl: Boolean; out Reason: string): Boolean;
function DesktopSessionAvailable: Boolean;
function DesktopCaptureAvailable: Boolean; // capture-thread only
function DesktopCursorEmbedded: Boolean;
function CaptureDesktopRgb(MaxW, MaxH: Integer; var Frame: TRgbFrame): Boolean;
function GetCursorNormalized(out NX, NY: Word): Boolean;
function GetDesktopCursorState(out NX, NY: Word; out Shape: TKvmCursorShape): Boolean;
procedure InjectMouse(Action, Button: Byte; NX, NY: Word);
procedure InjectText(CodePoint: Cardinal);
procedure InjectKey(Pressed: Boolean; VKey: Word);
procedure InjectWheel(Notches: SmallInt);
procedure InjectDesktopShortcut(const Keys: TKvmShortcutKeys);
function RequestDesktopSecureAttention: TKvmSasResult;
function RequestDesktopLock: TKvmLockResult;
implementation
uses SysUtils, kvm_monitors, kvm_session_guard,
  {$IFDEF WINDOWS}Windows, kvm_capture_win, kvm_capture_dxgi, kvm_windows_session, kvm_inject_win;{$ENDIF}
  {$IFDEF LINUX}kvm_capture_x11, kvm_inject_x11, kvm_wayland;{$ENDIF}
  {$IFDEF DARWIN}kvm_capture_mac, kvm_inject_mac;{$ENDIF}
var
  Backend: string = 'auto';
  IsPortal, UseDxgi, RequireDxgi: Boolean;
  {$IFDEF LINUX}
  // Windows emits a synthetic Ctrl key around AltGr (right Alt). X11 and
  // Wayland must not see that Ctrl while Level3 is active: otherwise @/#/|
  // turn into control sequences instead of text. Track only keys injected
  // by this server, never the local Linux user's physical keyboard.
  LinuxAltGrHeld: Boolean = False;
  LinuxCtrlHeld: array[0..2] of Boolean;
  {$ENDIF}
  {$IFDEF WINDOWS}LastCaptureCursorEmbedded: Boolean;{$ENDIF}
  RequestedFPS: Integer = 3;
// The native portal and SCK bridges currently accept only 1..30 FPS.
// Keep unpaced Windows JPEG scheduling independent of these stream APIs.
function NativeCaptureFPS(FPS: Integer): Integer;
begin
  if FPS<=0 then Exit(30);
  if FPS>30 then Exit(30);
  Result:=FPS;
end;
function ConfigureDesktop(const Options: TKvmServerOptions; out Reason: string): Boolean;
begin
  Backend := Options.Backend; RequestedFPS := Options.FPS;
  Reason := ''; Result := True;
  {$IFDEF LINUX}
  LinuxAltGrHeld := False;
  FillChar(LinuxCtrlHeld, SizeOf(LinuxCtrlHeld), 0);
  IsPortal := (Backend = 'portal') or ((Backend = 'auto') and
    ((LowerCase(GetEnvironmentVariable('XDG_SESSION_TYPE')) = 'wayland') or
     (GetEnvironmentVariable('WAYLAND_DISPLAY') <> '')));
  Result := (Backend = 'auto') or (Backend = 'x11') or (Backend = 'portal');
  if Result and IsPortal and (Options.Monitor <> 0) then
  begin Result := False; Reason := 'Wayland: use --monitor 0; select the monitor in the local portal.'; end;
  {$ENDIF}
  {$IFDEF WINDOWS}
  Result := (Backend = 'auto') or (Backend = 'gdi') or (Backend = 'dxgi');
  RequireDxgi := Backend = 'dxgi';
  {$ENDIF}
  {$IFDEF DARWIN}Result := (Backend = 'auto') or (Backend = 'sck');{$ENDIF}
  if not Result and (Reason = '') then Reason := 'Backend unavailable on this system';
  if Result and not Options.ListMonitors then
    Result:=ConfigureSessionGuard(Options.SessionPolicy,Reason);
end;
function ConfigureDesktopMonitor(Index: Integer; out Reason: string): Boolean;
begin
  {$IFDEF LINUX}
  if IsPortal then begin Reason := ''; Exit(Index = 0); end;
  {$ENDIF}
  Result := ConfigureMonitor(Index,Reason);
end;
procedure ListDesktopMonitors;
begin
  {$IFDEF LINUX}
  if IsPortal then begin WriteLn('0: choose the monitor in the Wayland portal at startup (local consent required)'); Exit; end;
  {$ENDIF}
  PrintMonitors;
end;
procedure ConfigureCaptureFPS(FPS: Integer);
begin {$IFDEF DARWIN}SetMacCaptureFPS(NativeCaptureFPS(FPS));{$ENDIF} end;
procedure CloseDesktopCapture;
begin
  {$IFDEF WINDOWS}CloseDxgi; kvm_capture_win.CloseCapture;{$ENDIF}
  {$IFDEF LINUX}
  if IsPortal then PauseWayland else kvm_capture_x11.CloseCapture;
  {$ENDIF}
  {$IFDEF DARWIN}kvm_capture_mac.CloseCapture;{$ENDIF}
end;
procedure ReleaseDesktop;
begin
  {$IFDEF LINUX}
  CloseWayland;
  LinuxAltGrHeld := False;
  FillChar(LinuxCtrlHeld, SizeOf(LinuxCtrlHeld), 0);
  {$ENDIF}
end;
function DesktopBackendName: string;
begin
  {$IFDEF WINDOWS}
  if RequireDxgi then Result := 'Windows DXGI (virtual desktop and monitors)'
  else if Backend = 'gdi' then Result := 'Windows GDI'
  else Result := 'Windows automatic DXGI / GDI fallback';
  {$ENDIF}
  {$IFDEF LINUX}
  if IsPortal then Result := 'Wayland / portal / PipeWire with local consent'
  else Result := 'Linux X11 / MIT-SHM / XTest / XFixes cursor';
  {$ENDIF}
  {$IFDEF DARWIN}Result := 'macOS ScreenCaptureKit / Quartz / native cursor';{$ENDIF}
end;
function DesktopBackendReady(AllowControl: Boolean; out Reason: string): Boolean;
begin
  Reason := '';
  {$IFDEF WINDOWS}
  UseDxgi := False;
  if Backend <> 'gdi' then UseDxgi := CheckDxgi(Reason);
  WriteLn('[capture] Requested backend=', Backend, '; DXGI enabled=', UseDxgi);
  if RequireDxgi and not UseDxgi then Exit(False);
  Reason := ''; Result := (GetSystemMetrics(SM_CXSCREEN) > 0) and (GetSystemMetrics(SM_CYSCREEN) > 0);
  if not Result then Reason := 'Run in an interactive Windows desktop session';
  {$ENDIF}
  {$IFDEF LINUX}
  if IsPortal then Exit(OpenWayland(AllowControl,NativeCaptureFPS(RequestedFPS),Reason));
  Result := kvm_capture_x11.CheckX11Display(Reason);
  if Result and AllowControl then Result := kvm_inject_x11.CheckX11Control(Reason);
  {$ENDIF}
  {$IFDEF DARWIN}
  Result := kvm_capture_mac.CheckMacCapture(Reason);
  if Result and AllowControl then Result := kvm_inject_mac.CheckMacControl(Reason);
  {$ENDIF}
end;
function DesktopSessionAvailable: Boolean;
begin
  Result := SessionGuardAllowsInput;
  if not Result then Exit;
  {$IFDEF WINDOWS}Result := WindowsDesktopAvailable;{$ENDIF}
  {$IFDEF LINUX}if IsPortal then Result := WaylandAlive;{$ENDIF}
  // macOS suspension/errors are read by the owning capture thread. Never
  // dereference its stream handle from a concurrent network input thread.
end;
function DesktopCaptureAvailable: Boolean;
begin
  Result := DesktopSessionAvailable;
  {$IFDEF DARWIN}if Result then Result := MacCaptureAvailable;{$ENDIF}
end;
function DesktopCursorEmbedded: Boolean;
begin
  Result := True;
  {$IFDEF WINDOWS}Result := LastCaptureCursorEmbedded;{$ENDIF}
  {$IFDEF LINUX}if not IsPortal then Result := kvm_capture_x11.CursorEmbedded;{$ENDIF}
end;
function CaptureDesktopRgb(MaxW, MaxH: Integer; var Frame: TRgbFrame): Boolean;
begin
  {$IFDEF WINDOWS}
  Result := False; LastCaptureCursorEmbedded := False;
  if not WindowsDesktopAvailable then Exit;
  // Defence in depth: explicit GDI must never invoke the native DXGI bridge,
  // even if the cached capability flag becomes inconsistent.
  if (Backend <> 'gdi') and UseDxgi then
  begin
    Result := CaptureDxgi(MaxW,MaxH,Frame);
    LastCaptureCursorEmbedded := Result and DxgiCursorEmbedded;
  end;
  if not Result and not RequireDxgi then
  begin
    Result := kvm_capture_win.CaptureDesktopRgb(MaxW,MaxH,Frame);
    LastCaptureCursorEmbedded := False;
  end;
  {$ENDIF}
  {$IFDEF LINUX}
  if IsPortal then Result := CaptureWayland(MaxW,MaxH,Frame)
  else Result := kvm_capture_x11.CaptureDesktopRgb(MaxW,MaxH,Frame);
  {$ENDIF}
  {$IFDEF DARWIN}Result := kvm_capture_mac.CaptureDesktopRgb(MaxW,MaxH,Frame);{$ENDIF}
end;
function GetCursorNormalized(out NX, NY: Word): Boolean;
begin
  NX := 0; NY := 0; Result := False;
  {$IFDEF WINDOWS}Result := kvm_inject_win.GetCursorNormalized(NX,NY);{$ENDIF}
  {$IFDEF LINUX}if not IsPortal then Result := kvm_inject_x11.GetCursorNormalized(NX,NY);{$ENDIF}
  {$IFDEF DARWIN}Result := kvm_inject_mac.GetCursorNormalized(NX,NY);{$ENDIF}
end;
function GetDesktopCursorState(out NX, NY: Word; out Shape: TKvmCursorShape): Boolean;
begin
  NX:=0; NY:=0; ClearCursorShape(Shape); Result:=False;
  {$IFDEF WINDOWS}Result:=kvm_inject_win.GetCursorState(NX,NY,Shape);{$ENDIF}
  {$IFDEF LINUX}if not IsPortal then Result:=kvm_inject_x11.GetCursorNormalized(NX,NY);{$ENDIF}
  {$IFDEF DARWIN}Result:=kvm_inject_mac.GetCursorNormalized(NX,NY);{$ENDIF}
end;
procedure InjectMouse(Action, Button: Byte; NX, NY: Word);
begin
  {$IFDEF WINDOWS}kvm_inject_win.InjectMouse(Action,Button,NX,NY);{$ENDIF}
  {$IFDEF LINUX}if IsPortal then WaylandMouse(Action,Button,NX,NY)
    else kvm_inject_x11.InjectMouse(Action,Button,NX,NY);{$ENDIF}
  {$IFDEF DARWIN}kvm_inject_mac.InjectMouse(Action,Button,NX,NY);{$ENDIF}
end;
procedure InjectText(CodePoint: Cardinal);
begin
  {$IFDEF WINDOWS}kvm_inject_win.InjectText(CodePoint);{$ENDIF}
  {$IFDEF LINUX}if IsPortal then WaylandText(CodePoint) else kvm_inject_x11.InjectText(CodePoint);{$ENDIF}
  {$IFDEF DARWIN}kvm_inject_mac.InjectText(CodePoint);{$ENDIF}
end;
{$IFDEF LINUX}
procedure LinuxRawKey(Pressed: Boolean; VKey: Word);
begin
  if IsPortal then WaylandKey(Pressed,VKey)
  else kvm_inject_x11.InjectKey(Pressed,VKey);
end;

function LinuxCtrlIndex(VKey: Word): Integer;
begin
  case VKey of
    $11: Result := 0;  // VK_CONTROL, includes Windows synthetic Ctrl
    $a2: Result := 1;  // VK_LCONTROL
    $a3: Result := 2;  // VK_RCONTROL
  else
    Result := -1;
  end;
end;
{$ENDIF}

procedure InjectKey(Pressed: Boolean; VKey: Word);
{$IFDEF LINUX}
const CtrlVK: array[0..2] of Word = ($11,$a2,$a3);
var
  Index, I: Integer;
  Suspended: array[0..2] of Boolean;
  RestoreFailed: Boolean;
{$ENDIF}
begin
  {$IFDEF WINDOWS}kvm_inject_win.InjectKey(Pressed,VKey);{$ENDIF}
  {$IFDEF LINUX}
  Index := LinuxCtrlIndex(VKey);
  if Index >= 0 then
  begin
    // A Ctrl key can be logically held while AltGr is active. Do not
    // synthesize it in the compositor until the AltGr key is released.
    if not LinuxAltGrHeld then LinuxRawKey(Pressed,VKey);
    LinuxCtrlHeld[Index] := Pressed;
    Exit;
  end;
  if VKey = $a5 then // VK_RMENU / AltGr (normalized by the Windows client)
  begin
    if Pressed then
    begin
      if LinuxAltGrHeld then Exit; // Ignore modifier autorepeat.
      FillChar(Suspended,SizeOf(Suspended),0);
      try
        for I := Low(CtrlVK) to High(CtrlVK) do
          if LinuxCtrlHeld[I] then
          begin
            LinuxRawKey(False,CtrlVK[I]);
            Suspended[I] := True;
          end;
        LinuxRawKey(True,$a5);
        LinuxAltGrHeld := True;
      except
        // The modifier key-down failed: restore every Ctrl that we released.
        for I := High(CtrlVK) downto Low(CtrlVK) do
          if Suspended[I] and LinuxCtrlHeld[I] then
            try LinuxRawKey(True,CtrlVK[I]); except end;
        raise;
      end;
    end
    else
    begin
      if not LinuxAltGrHeld then Exit;
      LinuxRawKey(False,$a5);
      LinuxAltGrHeld := False;
      RestoreFailed := False;
      for I := Low(CtrlVK) to High(CtrlVK) do
        if LinuxCtrlHeld[I] then
          try LinuxRawKey(True,CtrlVK[I]);
          except RestoreFailed := True; end;
      if RestoreFailed then
        raise Exception.Create('Could not restore Ctrl after AltGr');
    end;
    Exit;
  end;
  LinuxRawKey(Pressed,VKey);
  {$ENDIF}
  {$IFDEF DARWIN}kvm_inject_mac.InjectKey(Pressed,VKey);{$ENDIF}
end;
procedure InjectDesktopShortcut(const Keys: TKvmShortcutKeys);
var I,Held: Integer;
begin
  {$IFDEF WINDOWS}
  kvm_inject_win.InjectShortcut(Keys);
  {$ELSE}
  // Non-Windows fallback: preserve key order and always release modifiers.
  Held:=0;
  try
    for I:=0 to High(Keys) do
    begin
      Inc(Held);
      InjectKey(True,Keys[I]);
    end;
  finally
    for I:=Held-1 downto 0 do InjectKey(False,Keys[I]);
  end;
  {$ENDIF}
end;
function RequestDesktopSecureAttention: TKvmSasResult;
begin
  // Windows SAS is privileged; no simulated Ctrl+Alt+Del fallback.
  Result:=ksrUnavailable;
  {$IFDEF WINDOWS}Result:=kvm_inject_win.RequestSecureAttention;{$ENDIF}
end;
function RequestDesktopLock: TKvmLockResult;
begin
  Result:=klrUnavailable;
  {$IFDEF WINDOWS}
  if kvm_inject_win.RequestRemoteLock then Result:=klrRequested
  else Result:=klrFailed;
  {$ENDIF}
end;
procedure InjectWheel(Notches: SmallInt);
begin
  {$IFDEF WINDOWS}kvm_inject_win.InjectWheel(Notches);{$ENDIF}
  {$IFDEF LINUX}if IsPortal then WaylandWheel(Notches) else kvm_inject_x11.InjectWheel(Notches);{$ENDIF}
  {$IFDEF DARWIN}kvm_inject_mac.InjectWheel(Notches);{$ENDIF}
end;
end.

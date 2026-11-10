unit kvm_monitors;
{$mode objfpc}{$H+}{$packrecords c}{$pointermath on}
interface
uses kvm_geometry;
type
  TKvmMonitor = record
    NativeID: QWord;
    Name: string;
    Bounds: TKvmBounds;
    PixelW, PixelH: Integer;
  end;
  TKvmMonitors = array of TKvmMonitor;
function EnumerateMonitors: TKvmMonitors;
function ConfigureMonitor(Index: Integer; out ErrorText: string): Boolean;
function RefreshMonitor: Boolean;
function CaptureMonitor: TKvmMonitor;
function CaptureDesktopMonitorCount: Integer;
function CaptureMonitorLayoutText: string;
procedure PrintMonitors;
implementation
uses SysUtils, ctypes,
  {$IFDEF WINDOWS}Windows;{$ENDIF}
  {$IFDEF LINUX}Dynlibs, kvm_x11_api, kvm_x11_session;{$ENDIF}
  {$IFDEF DARWIN}kvm_quartz_api;{$ENDIF}
var
  Guard: TRTLCriticalSection;
  Selected: TKvmMonitor;
  SelectionIndex: Integer = 0;
  SelectedID: QWord = 0;
  LastPoll: QWord = 0;

{$IFDEF WINDOWS}
type
  TKvmMonitorInfo = record Size: DWORD; Monitor, Work: TRect; Flags: DWORD;
    Device: array[0..31] of WideChar; end;
  PMonitorArray = ^TKvmMonitors;
  // Explicit Win32 ABI import: some FPC Windows units do not expose this symbol.
  TKvmMonitorEnumProc = function(M: HMONITOR; DC: HDC;
    R: PRect; User: LPARAM): BOOL; stdcall;
function NativeEnumDisplayMonitors(DC: HDC; Clip: PRect;
  Callback: TKvmMonitorEnumProc; User: LPARAM): BOOL;
  stdcall; external 'user32.dll' name 'EnumDisplayMonitors';
function NativeMonitorInfo(M: HMONITOR; Info: Pointer): LongBool;
  stdcall; external 'user32.dll' name 'GetMonitorInfoW';
function EnumOne(M: HMONITOR; DC: HDC; R: PRect; User: LPARAM): BOOL; stdcall;
var Info: TKvmMonitorInfo; A: PMonitorArray; N: Integer;
begin
  Result := True; Info.Size := SizeOf(Info);
  if not NativeMonitorInfo(M, @Info) then Exit;
  A := PMonitorArray(Pointer(User)); N := Length(A^); SetLength(A^, N + 1);
  A^[N].NativeID := QWord(PtrUInt(M)); A^[N].Name := UTF8Encode(UnicodeString(PWideChar(@Info.Device[0])));
  A^[N].Bounds.X := Info.Monitor.Left; A^[N].Bounds.Y := Info.Monitor.Top;
  A^[N].Bounds.W := Info.Monitor.Right - Info.Monitor.Left;
  A^[N].Bounds.H := Info.Monitor.Bottom - Info.Monitor.Top;
  A^[N].PixelW := A^[N].Bounds.W; A^[N].PixelH := A^[N].Bounds.H;
end;
procedure EnableDpiAwareness;
type TSetDpi = function(Value: PtrInt): LongBool; stdcall;
     TSetLegacy = function: LongBool; stdcall;
var Lib: HMODULE; SetDpi: TSetDpi; Legacy: TSetLegacy;
begin
  Lib := GetModuleHandle('user32.dll');
  Pointer(SetDpi) := GetProcAddress(Lib, 'SetProcessDpiAwarenessContext');
  if Assigned(SetDpi) then begin SetDpi(-4); Exit; end; // PER_MONITOR_AWARE_V2
  Pointer(Legacy) := GetProcAddress(Lib, 'SetProcessDPIAware');
  if Assigned(Legacy) then Legacy();
end;
{$ENDIF}

function EnumerateMonitors: TKvmMonitors;
{$IFDEF LINUX}
type
  PMonInfo = ^TMonInfo;
  TMonInfo = record
    Name: CULong; Primary, Automatic, NOutput, X, Y, W, H, MW, MH: CInt;
    Outputs: Pointer;
  end;
var
  D: Pointer; Screen, N, I, Major, Minor: CInt; A: TXWindowAttributes;
  Lib: TLibHandle; Infos: PMonInfo;
  GetMonitors: function(D: Pointer; Window: CULong; Active: CInt;
    out Count: CInt): PMonInfo; cdecl;
  FreeMonitors: procedure(M: PMonInfo); cdecl;
  QueryVersion: function(D: Pointer; var Major, Minor: CInt): CInt; cdecl;
{$ENDIF}
{$IFDEF DARWIN}
var IDs: array[0..31] of CUInt; N, I: CUInt; R: TCGRect;
{$ENDIF}
begin
  Result := nil;
  {$IFDEF WINDOWS}
  EnableDpiAwareness;
  SetLength(Result, 1); Result[0].Name := 'Bureau virtuel complet';
  Result[0].NativeID := 0;
  Result[0].Bounds.X := GetSystemMetrics(SM_XVIRTUALSCREEN);
  Result[0].Bounds.Y := GetSystemMetrics(SM_YVIRTUALSCREEN);
  Result[0].Bounds.W := GetSystemMetrics(SM_CXVIRTUALSCREEN);
  Result[0].Bounds.H := GetSystemMetrics(SM_CYVIRTUALSCREEN);
  Result[0].PixelW := Result[0].Bounds.W; Result[0].PixelH := Result[0].Bounds.H;
  NativeEnumDisplayMonitors(0, nil, @EnumOne, LPARAM(@Result));
  {$ENDIF}
  {$IFDEF LINUX}
  D := LockX11;
  try
    if D = nil then Exit;
    Screen := XDefaultScreen(D);
    if XGetWindowAttributes(D, XRootWindow(D, Screen), A) = 0 then Exit;
    SetLength(Result, 1); Result[0].Name := 'Bureau X11 complet';
    Result[0].NativeID := 0;
    Result[0].Bounds.X := 0; Result[0].Bounds.Y := 0;
    Result[0].Bounds.W := A.width; Result[0].Bounds.H := A.height;
    Result[0].PixelW := A.width; Result[0].PixelH := A.height;
    Lib := LoadLibrary('libXrandr.so.2');
    if Lib = NilHandle then Exit;
    try
      Pointer(GetMonitors) := GetProcedureAddress(Lib, 'XRRGetMonitors');
      Pointer(FreeMonitors) := GetProcedureAddress(Lib, 'XRRFreeMonitors');
      Pointer(QueryVersion) := GetProcedureAddress(Lib, 'XRRQueryVersion');
      if not Assigned(GetMonitors) or not Assigned(FreeMonitors) or
         not Assigned(QueryVersion) then Exit;
      Major := 1; Minor := 5;
      if QueryVersion(D, Major, Minor) = 0 then Exit;
      if (Major < 1) or ((Major = 1) and (Minor < 5)) then Exit;
      Infos := GetMonitors(D, XRootWindow(D, Screen), 1, N);
      if Infos = nil then Exit;
      try
        if (N < 0) or (N > 64) then Exit;
        SetLength(Result, N + 1);
        for I := 0 to N - 1 do
        begin
          Result[I+1].NativeID := Infos[I].Name;
          Result[I+1].Name := 'Moniteur XRandR ' + IntToStr(Infos[I].Name);
          Result[I+1].Bounds.X := Infos[I].X; Result[I+1].Bounds.Y := Infos[I].Y;
          Result[I+1].Bounds.W := Infos[I].W; Result[I+1].Bounds.H := Infos[I].H;
          Result[I+1].PixelW := Infos[I].W; Result[I+1].PixelH := Infos[I].H;
        end;
      finally FreeMonitors(Infos); end;
    finally UnloadLibrary(Lib); end;
  finally UnlockX11; end;
  {$ENDIF}
  {$IFDEF DARWIN}
  N := 0;
  if CGGetActiveDisplayList(32, @IDs[0], @N) <> 0 then Exit;
  SetLength(Result, N + 1);
  for I := 0 to N do
  begin
    if I = 0 then Result[I].NativeID := CGMainDisplayID
    else Result[I].NativeID := IDs[I-1];
    Result[I].Name := 'Ecran macOS ' + IntToStr(Result[I].NativeID);
    if I = 0 then Result[I].Name := 'Ecran principal';
    R := CGDisplayBounds(Result[I].NativeID);
    Result[I].Bounds.X := Round(R.Origin.X); Result[I].Bounds.Y := Round(R.Origin.Y);
    Result[I].Bounds.W := Round(R.Size.Width); Result[I].Bounds.H := Round(R.Size.Height);
    Result[I].PixelW := CGDisplayPixelsWide(Result[I].NativeID);
    Result[I].PixelH := CGDisplayPixelsHigh(Result[I].NativeID);
  end;
  {$ENDIF}
end;
function ConfigureMonitor(Index: Integer; out ErrorText: string): Boolean;
var A: TKvmMonitors;
begin
  ErrorText := ''; A := EnumerateMonitors;
  Result := (Index >= 0) and (Index < Length(A));
  if Result then Result := BoundsValid(A[Index].Bounds);
  if not Result then
  begin ErrorText := 'Moniteur absent. Utiliser --list-monitors.'; Exit; end;
  EnterCriticalSection(Guard);
  try
    Selected := A[Index]; SelectionIndex := Index; SelectedID := Selected.NativeID;
    LastPoll := GetTickCount64;
  finally LeaveCriticalSection(Guard); end;
end;
function CaptureMonitor: TKvmMonitor;
begin
  EnterCriticalSection(Guard);
  try Result := Selected; finally LeaveCriticalSection(Guard); end;
end;

function CaptureDesktopMonitorCount: Integer;
var A: TKvmMonitors; Index: Integer;
begin
  // A physical monitor selection always represents one remote display.
  // Monitor 0 is the virtual desktop on Windows/X11 and may span several
  // physical outputs. macOS monitor 0 is the primary display, not a virtual
  // desktop, so keep it at one there.
  EnterCriticalSection(Guard);
  try Index := SelectionIndex; finally LeaveCriticalSection(Guard); end;
  if Index <> 0 then Exit(1);
  {$IFDEF DARWIN}
  Exit(1);
  {$ELSE}
  A := EnumerateMonitors;
  Result := Length(A) - 1; // entry 0 is the virtual desktop
  if Result < 1 then Result := 1;
  {$ENDIF}
end;
function CaptureMonitorLayoutText: string;
var
  A: TKvmMonitors; Current: TKvmMonitor; Index, I, X, Y: Integer;
begin
  // Coordinates are relative to the captured framebuffer before optional video
  // scaling. The client scales them to the actual decoded surface dimensions.
  EnterCriticalSection(Guard);
  try
    Index := SelectionIndex;
    Current := Selected;
  finally
    LeaveCriticalSection(Guard);
  end;
  if not BoundsValid(Current.Bounds) then Exit('MONITOR_LAYOUT 0 0 0');
  if Index <> 0 then
    Exit(Format('MONITOR_LAYOUT 1 %d %d 0 0 %d %d',
      [Current.Bounds.W,Current.Bounds.H,Current.Bounds.W,Current.Bounds.H]));
  {$IFDEF DARWIN}
  Exit(Format('MONITOR_LAYOUT 1 %d %d 0 0 %d %d',
    [Current.Bounds.W,Current.Bounds.H,Current.Bounds.W,Current.Bounds.H]));
  {$ELSE}
  A := EnumerateMonitors;
  if Length(A) <= 1 then
    Exit(Format('MONITOR_LAYOUT 1 %d %d 0 0 %d %d',
      [Current.Bounds.W,Current.Bounds.H,Current.Bounds.W,Current.Bounds.H]));
  Result := Format('MONITOR_LAYOUT %d %d %d',
    [Length(A)-1,Current.Bounds.W,Current.Bounds.H]);
  for I := 1 to High(A) do
  begin
    X := A[I].Bounds.X - Current.Bounds.X;
    Y := A[I].Bounds.Y - Current.Bounds.Y;
    Result := Result + Format(' %d %d %d %d',
      [X,Y,A[I].Bounds.W,A[I].Bounds.H]);
  end;
  {$ENDIF}
end;

function RefreshMonitor: Boolean;
var A: TKvmMonitors; I, Found: Integer; Current: TKvmMonitor;
begin
  if GetTickCount64 - LastPoll < 1000 then
  begin Current := CaptureMonitor; Exit(BoundsValid(Current.Bounds)); end;
  A := EnumerateMonitors; Found := -1;
  if (SelectionIndex = 0) and (Length(A) > 0) then Found := 0
  else for I := 1 to High(A) do
    if A[I].NativeID = SelectedID then begin Found := I; Break; end;
  EnterCriticalSection(Guard);
  try
    if Found >= 0 then Selected := A[Found]
    else begin Selected.Bounds.W := 0; Selected.Bounds.H := 0; end;
    LastPoll := GetTickCount64;
    Result := BoundsValid(Selected.Bounds);
  finally LeaveCriticalSection(Guard); end;
end;
procedure PrintMonitors;
var A: TKvmMonitors; I: Integer;
begin
  A := EnumerateMonitors;
  if Length(A) = 0 then WriteLn('Aucun moniteur accessible.');
  for I := 0 to High(A) do
    WriteLn(I, ': ', A[I].Name, ' ', A[I].PixelW, 'x', A[I].PixelH,
      ' origine ', A[I].Bounds.X, ',', A[I].Bounds.Y);
end;
initialization InitCriticalSection(Guard);
finalization DoneCriticalSection(Guard);
end.

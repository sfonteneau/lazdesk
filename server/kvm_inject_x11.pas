unit kvm_inject_x11;

{$mode objfpc}{$H+}

interface

function CheckX11Control(out Reason: string): Boolean;
function GetCursorNormalized(out NX, NY: Word): Boolean;
procedure InjectMouse(Action, Button: Byte; NX, NY: Word);
procedure InjectText(CodePoint: Cardinal);
procedure InjectKey(Pressed: Boolean; VKey: Word);
procedure InjectWheel(Notches: SmallInt);

implementation

uses SysUtils, ctypes, kvm_x11_api, kvm_x11_session, kvm_monitors, kvm_geometry, kvm_keysym;

var HeldCodes: array[0..255] of Byte;

function CheckX11Control(out Reason: string): Boolean;
var
  D: Pointer;
  E, Err, Major, Minor: CInt;
begin
  Reason := '';
  D := LockX11;
  if D = nil then
  begin
    Reason := 'X11 inaccessible';
    UnlockX11; Exit(False);
  end;
  try
    Result := XTestQueryExtension(D, E, Err, Major, Minor) <> 0;
    if not Result then Reason := 'XTEST extension required for mouse/keyboard';
  finally
    UnlockX11;
  end;
end;

function GetCursorNormalized(out NX, NY: Word): Boolean;
var D: Pointer; Scr, RX, RY, WX, WY: CInt;
  Root, Child: CULong; Mask: CUInt; M: TKvmMonitor;
begin
  NX := 0; NY := 0; Result := False; M := CaptureMonitor;
  D := LockX11;
  try
    if D=nil then Exit;
    Scr := XDefaultScreen(D);
    if XQueryPointer(D, XRootWindow(D, Scr), Root, Child, RX, RY, WX, WY, Mask) = 0 then Exit;
    Result := NormalizePoint(M.Bounds, RX, RY, NX, NY);
  finally UnlockX11; end;
end;

procedure InjectMouse(Action, Button: Byte; NX, NY: Word);
var D: Pointer; Screen, X, Y: Integer; XB: CUInt; M: TKvmMonitor;
begin
  M := CaptureMonitor; D := LockX11;
  try
    if D = nil then raise Exception.Create('X11 inaccessible');
    Screen := XDefaultScreen(D);
    if DenormalizePoint(M.Bounds,NX,NY,X,Y) then
    begin if XTestFakeMotionEvent(D,Screen,X,Y,0)=0 then raise Exception.Create('XTest pointer movement rejected'); end
    else if Action<>2 then raise Exception.Create('Mouse geometry unavailable');
    if Action <> 0 then
    begin
      case Button of 1: XB := 1; 2: XB := 3; 3: XB := 2; else Exit; end;
      if XTestFakeButtonEvent(D,XB,Ord(Action=1),0)=0 then raise Exception.Create('XTest mouse button rejected');
    end;
    XFlush(D);
  finally UnlockX11; end;
end;

procedure InjectText(CodePoint: Cardinal);
var
  D: Pointer; Sym: CULong; MinCode, MaxCode, Code, Level, FoundCode, FoundLevel: CInt;
  ShiftKey, Level3Key: Byte; State: TXkbState; ShiftDown, Level3Down, CleanupOK: Boolean;
begin
  if (CodePoint < 32) or (CodePoint > $10ffff) or
     ((CodePoint >= $d800) and (CodePoint <= $dfff)) then Exit;
  if CodePoint <= $ff then Sym := CodePoint else Sym := $01000000 or CodePoint;
  D := LockX11;
  try
    if D = nil then raise Exception.Create('X11 inaccessible');
    FillChar(State, SizeOf(State), 0);
    if XkbGetState(D, $100, State) <> 0 then raise Exception.Create('Etat XKB inaccessible'); // XkbUseCoreKbd
    XDisplayKeycodes(D, MinCode, MaxCode);
    FoundCode := 0; FoundLevel := 0;
    for Level := 0 to 3 do
    begin
      for Code := MinCode to MaxCode do
        if XkbKeycodeToKeysym(D, Byte(Code), State.group, Level) = Sym then
        begin FoundCode := Code; FoundLevel := Level; Break; end;
      if FoundCode <> 0 then Break;
    end;
    if FoundCode = 0 then
    begin
      // Do NOT silently type a different symbol or rewrite the user's keymap.
      raise Exception.Create('Character not present in the active XKB layout.');
    end;
    ShiftKey := XKeysymToKeycode(D, $ffe1);
    Level3Key := XKeysymToKeycode(D, $fe03);
    if (((FoundLevel and 1) <> 0) and (ShiftKey = 0)) or
       (((FoundLevel and 2) <> 0) and (Level3Key = 0)) then
      raise Exception.Create('Required XKB modifier unavailable.');
    // CapsLock would otherwise invert upper/lowercase. Restore it afterward.
    if XkbLockModifiers(D,$100,2,0)=0 then raise Exception.Create('CapsLock XKB inaccessible');
    ShiftDown:=False; Level3Down:=False;
    try
      if (FoundLevel and 1)<>0 then
      begin ShiftDown:=XTestFakeKeyEvent(D,ShiftKey,1,0)<>0; if not ShiftDown then raise Exception.Create('Shift key rejected'); end;
      if (FoundLevel and 2)<>0 then
      begin Level3Down:=XTestFakeKeyEvent(D,Level3Key,1,0)<>0; if not Level3Down then raise Exception.Create('AltGr key rejected'); end;
      try
        if XTestFakeKeyEvent(D,FoundCode,1,0)=0 then raise Exception.Create('XTest text input rejected');
      finally
        if XTestFakeKeyEvent(D,FoundCode,0,0)=0 then raise Exception.Create('Text key release rejected');
      end;
    finally
      CleanupOK:=True;
      if Level3Down then if XTestFakeKeyEvent(D,Level3Key,0,0)=0 then CleanupOK:=False;
      if ShiftDown then if XTestFakeKeyEvent(D,ShiftKey,0,0)=0 then CleanupOK:=False;
      if XkbLockModifiers(D,$100,2,State.locked_mods and 2)=0 then CleanupOK:=False;
      XFlush(D);
      if not CleanupOK then raise Exception.Create('Could not fully restore XKB modifiers');
    end;
  finally UnlockX11; end;
end;

procedure InjectKey(Pressed: Boolean; VKey: Word);
var D: Pointer; KeyCode: Byte; Symbol: CULong;
begin
  if (VKey=0) or (VKey>255) then raise Exception.Create('Touche hors plage');
  D:=LockX11;
  try
    if D=nil then raise Exception.Create('X11 inaccessible');
    KeyCode:=HeldCodes[VKey];
    if not Pressed and (KeyCode=0) then Exit; // never injected: no release to retry
    if KeyCode=0 then
    begin
      Symbol:=KvmKeysym(VKey);
      if Symbol=0 then raise Exception.Create('Key not mapped on X11');
      KeyCode:=XKeysymToKeycode(D,Symbol);
      if (KeyCode=0) and (VKey=$a5) then KeyCode:=XKeysymToKeycode(D,$fe03);
    end;
    if KeyCode=0 then raise Exception.Create('Key not present on the remote keyboard');
    if XTestFakeKeyEvent(D,KeyCode,Ord(Pressed),0)=0 then raise Exception.Create('XTest rejected the key');
    if Pressed then HeldCodes[VKey]:=KeyCode else HeldCodes[VKey]:=0;
    XFlush(D);
  finally UnlockX11; end;
end;

procedure InjectWheel(Notches: SmallInt);
var
  D: Pointer;
  I: Integer;
  B: CUInt;
begin
  if Notches = 0 then Exit;
  D := LockX11;
  if D = nil then begin UnlockX11; raise Exception.Create('X11 inaccessible'); end;
  try
    if Notches > 0 then B := 4 else B := 5;
    for I := 1 to Abs(Notches) do
    begin
      try
        if XTestFakeButtonEvent(D,B,1,0)=0 then raise Exception.Create('Molette XTest refusee');
      finally
        if XTestFakeButtonEvent(D,B,0,0)=0 then raise Exception.Create('Mouse wheel release rejected');
      end;
    end;
    XFlush(D);
  finally
    UnlockX11;
  end;
end;

end.

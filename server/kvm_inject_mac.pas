unit kvm_inject_mac;

{$mode objfpc}{$H+}

interface

function CheckMacControl(out Reason: string): Boolean;
function GetCursorNormalized(out NX, NY: Word): Boolean;
procedure InjectMouse(Action, Button: Byte; NX, NY: Word);
procedure InjectText(CodePoint: Cardinal);
procedure InjectKey(Pressed: Boolean; VKey: Word);
procedure InjectWheel(Notches: SmallInt);

implementation

uses SysUtils, kvm_quartz_api, kvm_monitors, kvm_geometry, kvm_mouse_state;

var MouseState: TKvmMouseState;
    ModifierKeys: array[0..255] of Boolean;
    CapsOn: Boolean;
    ClickTick: QWord; ClickX, ClickY: Integer; ClickButton: Byte; ClickCount: Integer;

const
  HID_EVENT_TAP = 0;

function CheckMacControl(out Reason: string): Boolean;
begin
  Reason := '';
  Result := AXIsProcessTrusted;
  if not Result then
    Reason := 'Autoriser LazDeskServer dans macOS > Confidentialite et ' +
      'securite > Accessibilite pour injecter clavier et souris.';
end;

function MapMacKey(VK: Word): Integer;
begin
  // macOS virtual keycodes (US physical layout); not a Unicode text input API.
  Result := -1;
  case VK of
    $41: Result := 0;   // A
    $53: Result := 1;   // S
    $44: Result := 2;   // D
    $46: Result := 3;   // F
    $48: Result := 4;   // H
    $47: Result := 5;   // G
    $5a: Result := 6;   // Z
    $58: Result := 7;   // X
    $43: Result := 8;   // C
    $56: Result := 9;   // V
    $42: Result := 11;  // B
    $51: Result := 12;  // Q
    $57: Result := 13;  // W
    $45: Result := 14;  // E
    $52: Result := 15;  // R
    $59: Result := 16;  // Y
    $54: Result := 17;  // T
    $31: Result := 18;
    $32: Result := 19;
    $33: Result := 20;
    $34: Result := 21;
    $36: Result := 22;
    $35: Result := 23;
    $bb: Result := 24; // =
    $39: Result := 25;
    $37: Result := 26;
    $bd: Result := 27; // -
    $38: Result := 28;
    $30: Result := 29;
    $dd: Result := 30; // ]
    $4f: Result := 31; // O
    $55: Result := 32; // U
    $db: Result := 33; // [
    $49: Result := 34; // I
    $50: Result := 35; // P
    $0d: Result := 36; // Return
    $4c: Result := 37; // L
    $4a: Result := 38; // J
    $de: Result := 39; // '
    $4b: Result := 40; // K
    $ba: Result := 41; // ;
    $dc: Result := 42; // backslash
    $bc: Result := 43; // ,
    $bf: Result := 44; // /
    $4e: Result := 45; // N
    $4d: Result := 46; // M
    $be: Result := 47; // .
    $09: Result := 48; // Tab
    $20: Result := 49; // Space
    $c0: Result := 50; // `
    $08: Result := 51; // Backspace
    $1b: Result := 53; // Escape
    $5c: Result := 54; // Command_R
    $5b: Result := 55; // Command_L (Super)
    $10, $a0: Result := 56; // Shift
    $14: Result := 57; // Caps Lock
    $12, $a4: Result := 58; // Option
    $11, $a2: Result := 59; // Control
    $a1: Result := 60; // Right Shift
    $a5: Result := 61; // Right Option
    $a3: Result := 62; // Right Control
    $15: Result := 104; // JIS Kana
    $1d: Result := 102; // JIS Eisu / non-convert
    $7c: Result := 105; // F13
    $7d: Result := 107; // F14
    $7e: Result := 113; // F15
    $7f: Result := 106; // F16
    $80: Result := 64;  // F17
    $81: Result := 79;  // F18
    $82: Result := 80;  // F19
    $83: Result := 90;  // F20
    $70: Result := 122; // F1
    $71: Result := 120; // F2
    $72: Result := 99;  // F3
    $73: Result := 118; // F4
    $74: Result := 96;  // F5
    $75: Result := 97;  // F6
    $76: Result := 98;  // F7
    $77: Result := 100; // F8
    $78: Result := 101; // F9
    $79: Result := 109; // F10
    $7a: Result := 103; // F11
    $7b: Result := 111; // F12
    $24: Result := 115; // Home
    $23: Result := 119; // End
    $21: Result := 116; // Page Up
    $22: Result := 121; // Page Down
    $2e: Result := 117; // Forward Delete
    $25: Result := 123; // Left
    $27: Result := 124; // Right
    $28: Result := 125; // Down
    $26: Result := 126; // Up
    $60: Result := 82; // Numpad 0
    $61: Result := 83;
    $62: Result := 84;
    $63: Result := 85;
    $64: Result := 86;
    $65: Result := 87;
    $66: Result := 88;
    $67: Result := 89;
    $68: Result := 91;
    $69: Result := 92;
    $6e: Result := 65; // Numpad .
    $6a: Result := 67; // Numpad *
    $6b: Result := 69; // Numpad +
    $6d: Result := 78; // Numpad -
    $6f: Result := 75; // Numpad /
  end;
end;

procedure PostEvent(E: Pointer);
begin
  if E=nil then raise Exception.Create('Creation CGEvent impossible');
  try
    if not AXIsProcessTrusted then raise Exception.Create('Permission Accessibilite retiree');
    CGEventPost(HID_EVENT_TAP, E);
  finally
    CFRelease(E);
  end;
end;

function ModifierFlags: QWord;
begin
  Result := 0;
  if CapsOn then Result := Result or $10000;
  if ModifierKeys[$10] or ModifierKeys[$a0] or ModifierKeys[$a1] then Result := Result or $20000;
  if ModifierKeys[$11] or ModifierKeys[$a2] or ModifierKeys[$a3] then Result := Result or $40000;
  if ModifierKeys[$12] or ModifierKeys[$a4] or ModifierKeys[$a5] then Result := Result or $80000;
  if ModifierKeys[$5b] or ModifierKeys[$5c] then Result := Result or $100000;
end;

function GetCursorNormalized(out NX, NY: Word): Boolean;
var E: Pointer; P: TCGPoint; M: TKvmMonitor;
begin
  NX := 0; NY := 0; Result := False;
  E := CGEventCreate(nil); if E = nil then Exit;
  try P := CGEventGetLocation(E); finally CFRelease(E); end;
  M := CaptureMonitor;
  Result := NormalizePoint(M.Bounds, Round(P.X), Round(P.Y), NX, NY);
end;

procedure InjectMouse(Action, Button: Byte; NX, NY: Word);
var
  EventType, CGButton: Cardinal;
  Position: TCGPoint; X, Y: Integer; M: TKvmMonitor; E: Pointer;
begin
  if not AXIsProcessTrusted then raise Exception.Create('Permission Accessibilite requise');
  M := CaptureMonitor;
  if not DenormalizePoint(M.Bounds, NX, NY, X, Y) then
  begin
    if Action <> 2 then raise Exception.Create('Geometrie du moniteur indisponible');
    // A display may disappear while a button is held: still send its release.
    E := CGEventCreate(nil); if E=nil then raise Exception.Create('Creation CGEvent souris impossible');
    try Position := CGEventGetLocation(E); finally CFRelease(E); end;
  end
  else begin Position.X := X; Position.Y := Y; end;
  if not QuartzMouseEvent(MouseState, Action, Button, EventType, CGButton) then raise Exception.Create('Commande souris invalide');
  E := CGEventCreateMouseEvent(nil, EventType, Position, CGButton);
  if E=nil then raise Exception.Create('Creation CGEvent souris impossible');
  CGEventSetFlags(E, ModifierFlags);
  if Action = 1 then
  begin
    if (Button = ClickButton) and (GetTickCount64 - ClickTick <= 500) and
       (Abs(Round(Position.X) - ClickX) <= 4) and (Abs(Round(Position.Y) - ClickY) <= 4) then
      Inc(ClickCount) else ClickCount := 1;
    if ClickCount > 3 then ClickCount := 1;
    ClickButton := Button; ClickTick := GetTickCount64;
    ClickX := Round(Position.X); ClickY := Round(Position.Y);
  end;
  if Action <> 0 then CGEventSetIntegerValueField(E, 1, ClickCount);
  PostEvent(E);
end;

procedure InjectText(CodePoint: Cardinal);
var
  CodeUnits: array[0..1] of Word;
  Count: NativeUInt;
  E: Pointer;
begin
  if not AXIsProcessTrusted then raise Exception.Create('Permission Accessibilite requise');
  if (CodePoint < 32) or (CodePoint > $10ffff) then Exit;
  if CodePoint <= $ffff then
  begin
    CodeUnits[0] := Word(CodePoint);
    Count := 1;
  end
  else
  begin
    Dec(CodePoint, $10000);
    CodeUnits[0] := $d800 or Word(CodePoint shr 10);
    CodeUnits[1] := $dc00 or Word(CodePoint and $3ff);
    Count := 2;
  end;
  E := CGEventCreateKeyboardEvent(nil, 0, True);
  if E=nil then raise Exception.Create('Creation evenement texte impossible');
  begin
    CGEventSetFlags(E, 0);
    CGEventKeyboardSetUnicodeString(E, Count, @CodeUnits[0]);
    PostEvent(E);
  end;
  E := CGEventCreateKeyboardEvent(nil, 0, False);
  if E=nil then raise Exception.Create('Creation evenement texte impossible');
  begin
    CGEventSetFlags(E, 0);
    CGEventKeyboardSetUnicodeString(E, Count, @CodeUnits[0]);
    PostEvent(E);
  end;
end;

procedure InjectKey(Pressed: Boolean; VKey: Word);
var
  MacKey: Integer;
  E: Pointer;
begin
  if not AXIsProcessTrusted then raise Exception.Create('Permission Accessibilite requise');
  if (VKey=0) or (VKey>255) then raise Exception.Create('Code touche invalide');
  if not Pressed and not ModifierKeys[VKey] then Exit; // an unmapped down was never posted
  MacKey:=MapMacKey(VKey);
  if MacKey<0 then raise Exception.Create('Touche non mappee sous macOS');
  E:=CGEventCreateKeyboardEvent(nil,Word(MacKey),Pressed);
  if E=nil then raise Exception.Create('Creation CGEvent clavier impossible');
  if (VKey=$14) and Pressed and not ModifierKeys[VKey] then CapsOn:=not CapsOn;
  ModifierKeys[VKey]:=Pressed;
  CGEventSetFlags(E, ModifierFlags);
  PostEvent(E);
end;

procedure InjectWheel(Notches: SmallInt);
begin
  if not AXIsProcessTrusted then raise Exception.Create('Permission Accessibilite requise');
  if Notches = 0 then Exit;
  // kCGScrollEventUnitLine=1, wheelCount=1.
  PostEvent(CGEventCreateScrollWheelEvent(nil, 1, 1, Notches));
end;

end.

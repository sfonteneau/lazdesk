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

var
  HeldCodes: array[0..255] of Byte;
  // Only the two additional ISO/AZERTY OEM keys need synthetic modifiers
  // to resolve their logical keysyms on a differently laid-out X11 host.
  HeldOemShift, HeldOemLevel3: array[0..255] of Byte;

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

// X11's legacy EuroSign keysym ($20ac) is not the same as the Unicode
// encoding U20AC ($010020ac). Search both before refusing to type a symbol.
// The lookup never rewrites the global XKB keymap or guesses a different key.
function FindXkbSymbol(D: Pointer; Group: Byte; Symbol: CULong;
  out FoundCode, FoundLevel: CInt): Boolean;
var
  MinCode, MaxCode, Code, Level: CInt;
begin
  FoundCode := 0; FoundLevel := 0;
  XDisplayKeycodes(D, MinCode, MaxCode);
  for Level := 0 to 3 do
  begin
    for Code := MinCode to MaxCode do
      if XkbKeycodeToKeysym(D, Byte(Code), Group, Level) = Symbol then
      begin
        FoundCode := Code;
        FoundLevel := Level;
        Exit(True);
      end;
  end;
  Result := False;
end;

// The X11 core protocol has no "type Unicode" request: XTest sends only
// keycodes. An active XKB group does not necessarily contain every printable
// symbol (particularly with international layouts). For a missing symbol,
// temporarily borrow an *unassigned* keycode, and restore its exact original
// mapping immediately afterwards. This is the same fallback family used by
// xdotool for unmapped keysyms; never overwrite a real or pressed key.
// XChangeKeyboardMapping changes the X server's map globally for a very short
// time. Keep the binding until the target app has had a chance to process the
// generated KeyPress; restoring it in the same X11 roundtrip would result in a
// keycode with NoSymbol on clients that process input after the restoration.
type
  TXkbScratchSyms = array[0..63] of CULong;
  // At most 248 X11 keycodes times 64 keysyms per code (15616 entries).
  TXkbAllSyms = array[0..16383] of CULong;
  PXkbAllSyms = ^TXkbAllSyms;

function FindUnusedXkbKey(D: Pointer; const PressedMap: array of AnsiChar;
  out Scratch: Byte; out PerCode: CInt;
  out Original: TXkbScratchSyms): Boolean;
var
  MinCode, MaxCode, Candidate, I, J, VKey, Col: CInt;
  Mapped, Reserved: Boolean;
  Symbols: PKeySym;
begin
  Result := False; Scratch := 0; PerCode := 0;
  XDisplayKeycodes(D, MinCode, MaxCode);
  if (MinCode < 8) or (MaxCode > 255) or (MaxCode < MinCode) then
    raise Exception.Create('Invalid X11 keycode range for Unicode fallback');
  Symbols := XGetKeyboardMapping(D, Byte(MinCode), MaxCode-MinCode+1, PerCode);
  if Symbols = nil then
    raise Exception.Create('Cannot read X11 keyboard mapping for Unicode fallback');
  try
    if (PerCode < 1) or (PerCode > Length(Original)) then
      raise Exception.Create('Unsupported X11 mapping width for Unicode fallback');
    for Candidate := MaxCode downto MinCode do
    begin
      // Never remap a key which is physically pressed or held by a client.
      if (Ord(PressedMap[Candidate div 8]) and
          (1 shl (Candidate mod 8))) <> 0 then Continue;
      Reserved := False;
      for VKey := 0 to High(HeldCodes) do
        if HeldCodes[VKey] = Candidate then
        begin Reserved := True; Break; end;
      if Reserved then Continue;
      Mapped := False;
      for Col := 0 to PerCode-1 do
        if PXkbAllSyms(Symbols)^[(Candidate-MinCode)*PerCode+Col] <> 0 then
        begin Mapped := True; Break; end;
      if Mapped then Continue;
      // A core NoSymbol entry can still have an XKB definition: do not
      // borrow it unless all advertised groups/levels are also empty.
      for I := 0 to 3 do
      begin
        for J := 0 to 7 do
          if XkbKeycodeToKeysym(D, Byte(Candidate), I, J) <> 0 then
          begin Mapped := True; Break; end;
        if Mapped then Break;
      end;
      if Mapped then Continue;
      for Col := 0 to PerCode-1 do
        Original[Col] := PXkbAllSyms(Symbols)^[(Candidate-MinCode)*PerCode+Col];
      Scratch := Byte(Candidate);
      Exit(True);
    end;
  finally
    XFree(Symbols);
  end;
end;

// XTest delivers keyboard *events*, not characters. Before typing a Unicode
// code point, temporarily release pressed text-affecting modifiers (including
// a Ctrl that Windows may have synthesized for AltGr). Otherwise the remote
// application sees Ctrl+AltGr+key instead of the requested symbol. Restore
// exactly the keys we released, even when a subsequent XTest call fails.
// For symbols absent from the active XKB layout only, temporarily bind an
// unused keycode; always restore it afterwards. The clipboard is untouched.
const
  TextModifierSyms: array[0..14] of CULong = (
    $ffe1, $ffe2, // Shift_L, Shift_R
    $ffe3, $ffe4, // Control_L, Control_R
    $ffe7, $ffe8, // Meta_L, Meta_R
    $ffe9, $ffea, // Alt_L, Alt_R
    $ffeb, $ffec, // Super_L, Super_R
    $ffed, $ffee, // Hyper_L, Hyper_R
    $fe03, $fe11, // ISO_Level3_Shift (AltGr), ISO_Level5_Shift
    $ff7e);       // Mode_switch (older AltGr configurations)

procedure InjectText(CodePoint: Cardinal);
var
  D: Pointer; Sym: CULong; FoundCode, FoundLevel: CInt;
  ShiftKey, Level3Key, ModCode, Scratch: Byte;
  State: TXkbState;
  ShiftDown, Level3Down, KeyDown, CapsChanged, CleanupOK, AlreadyListed,
    MappedScratch, ScratchSubmitted: Boolean;
  PressedMap: array[0..31] of AnsiChar;
  ReleasedMods: array[0..14] of Byte;
  SavedSyms, TemporarySyms: TXkbScratchSyms;
  VerifySyms: PKeySym;
  ReleasedCount, Width, VerifyWidth, I, J: Integer;
begin
  if (CodePoint < 32) or (CodePoint > $10ffff) or
     ((CodePoint >= $d800) and (CodePoint <= $dfff)) then Exit;
  if CodePoint <= $ff then Sym := CodePoint else Sym := $01000000 or CodePoint;
  D := LockX11;
  try
    if D = nil then raise Exception.Create('X11 inaccessible');
    FillChar(State, SizeOf(State), 0);
    if XkbGetState(D, $100, State) <> 0 then
      raise Exception.Create('XKB state unavailable'); // XkbUseCoreKbd
    if not FindXkbSymbol(D, State.group, Sym, FoundCode, FoundLevel) then
    begin
      // Some X11 layouts expose EuroSign as the legacy $20ac keysym.
      if (CodePoint <> $20ac) or
         (not FindXkbSymbol(D, State.group, $20ac, FoundCode, FoundLevel)) then
        FoundCode := 0;
    end;
    // Snapshot actual X11 key state rather than trusting only the network
    // client's virtual keys (a key-up may have been lost on the network).
    if XQueryKeymap(D, @PressedMap[0]) = 0 then
      raise Exception.Create('X11 key state unavailable');
    Scratch := 0; Width := 0;
    if FoundCode = 0 then
    begin
      // Do not reject @/#/| simply because this Linux XKB group omits them.
      // The scratch mapping is restored in a finally block below.
      if not FindUnusedXkbKey(D, PressedMap, Scratch, Width, SavedSyms) then
        raise Exception.Create('No unused X11 keycode for Unicode fallback');
      FoundCode := Scratch;
      FoundLevel := 0;  // the temporary binding needs no Shift or AltGr
    end;
    ShiftKey := XKeysymToKeycode(D, $ffe1);
    Level3Key := XKeysymToKeycode(D, $fe03);
    if (((FoundLevel and 1) <> 0) and (ShiftKey = 0)) or
       (((FoundLevel and 2) <> 0) and (Level3Key = 0)) then
      raise Exception.Create('Required XKB text modifier unavailable');

    ShiftDown := False; Level3Down := False; KeyDown := False;
    CapsChanged := False; ReleasedCount := 0;
    MappedScratch := False; ScratchSubmitted := False;
    try
      // Preserve CapsLock exactly, including when a symbol is missing.
      if XkbLockModifiers(D, $100, 2, 0) = 0 then
        raise Exception.Create('CapsLock XKB unavailable');
      CapsChanged := True;
      for I := Low(TextModifierSyms) to High(TextModifierSyms) do
      begin
        ModCode := XKeysymToKeycode(D, TextModifierSyms[I]);
        if (ModCode = 0) or
           ((Ord(PressedMap[ModCode div 8]) and
              (1 shl (ModCode mod 8))) = 0) then Continue;
        AlreadyListed := False;
        for J := 0 to ReleasedCount-1 do
          if ReleasedMods[J] = ModCode then
          begin AlreadyListed := True; Break; end;
        if AlreadyListed then Continue;
        if XTestFakeKeyEvent(D, ModCode, 0, 0) = 0 then
          raise Exception.Create('Could not suspend X11 text modifier');
        ReleasedMods[ReleasedCount] := ModCode;
        Inc(ReleasedCount);
      end;

      if Scratch <> 0 then
      begin
        // XChangeKeyboardMapping returns 0 even when the request succeeds;
        // synchronize and read back instead of treating 0 as an error.
        FillChar(TemporarySyms, SizeOf(TemporarySyms), 0);
        for I := 0 to Width-1 do TemporarySyms[I] := Sym;
        XChangeKeyboardMapping(D, Scratch, Width, @TemporarySyms[0], 1);
        MappedScratch := True;
        XSync(D, 0);
        VerifySyms := XGetKeyboardMapping(D, Scratch, 1, VerifyWidth);
        if VerifySyms = nil then
          raise Exception.Create('Cannot verify temporary X11 Unicode mapping');
        try
          if (VerifyWidth < 1) or
             (PXkbAllSyms(VerifySyms)^[0] <> Sym) then
            raise Exception.Create('Temporary X11 Unicode mapping rejected');
        finally
          XFree(VerifySyms);
        end;
      end;

      if (FoundLevel and 1) <> 0 then
      begin
        if XTestFakeKeyEvent(D, ShiftKey, 1, 0) = 0 then
          raise Exception.Create('XTest Shift key rejected');
        ShiftDown := True;
      end;
      if (FoundLevel and 2) <> 0 then
      begin
        if XTestFakeKeyEvent(D, Level3Key, 1, 0) = 0 then
          raise Exception.Create('XTest AltGr key rejected');
        Level3Down := True;
      end;
      if XTestFakeKeyEvent(D, FoundCode, 1, 0) = 0 then
        raise Exception.Create('XTest text input rejected');
      KeyDown := True;
      if Scratch <> 0 then ScratchSubmitted := True;
      if XTestFakeKeyEvent(D, FoundCode, 0, 0) = 0 then
        raise Exception.Create('XTest text key release rejected');
      KeyDown := False;
    finally
      CleanupOK := True;
      if KeyDown then
        if XTestFakeKeyEvent(D, FoundCode, 0, 0) = 0 then CleanupOK := False;
      if Level3Down then
        if XTestFakeKeyEvent(D, Level3Key, 0, 0) = 0 then CleanupOK := False;
      if ShiftDown then
        if XTestFakeKeyEvent(D, ShiftKey, 0, 0) = 0 then CleanupOK := False;
      if MappedScratch then
      begin
        if ScratchSubmitted then
        begin
          // Dispatch the key events and allow the focused X11 client to
          // consume their *temporary* keysym before restoring NoSymbol.
          // Without this, XLookupString can see an empty mapping instead.
          XSync(D, 0);
          Sleep(25);
        end;
        XChangeKeyboardMapping(D, Scratch, Width, @SavedSyms[0], 1);
        XSync(D, 0);
      end;
      // Restore exactly the modifiers we suspended, in reverse order.
      for I := ReleasedCount-1 downto 0 do
        if XTestFakeKeyEvent(D, ReleasedMods[I], 1, 0) = 0 then CleanupOK := False;
      if CapsChanged then
        if XkbLockModifiers(D, $100, 2, State.locked_mods and 2) = 0 then
          CleanupOK := False;
      XFlush(D);
      if not CleanupOK then
        raise Exception.Create('Could not fully restore X11 text modifiers');
    end;
  finally UnlockX11; end;
end;

// VK_OEM_8 (French '!') and VK_OEM_102 (ISO '<') have no independent
// physical key identity in the old VK-only protocol. When used in physical
// mode, resolve their symbols with the modifiers required by this XKB map.
// Keep modifiers down until key-up, including during key-repeat events.
procedure InjectExtraOemKey(D: Pointer; Pressed: Boolean; VKey: Word);
var
  Code, Level: CInt;
  State: TXkbState;
  Symbol: CULong;
  ShiftKey, Level3Key, AddedShift, AddedLevel3: Byte;
  PressedMap: array[0..31] of AnsiChar;
begin
  if not Pressed then
  begin
    if HeldCodes[VKey] <> 0 then
    begin
      if XTestFakeKeyEvent(D, HeldCodes[VKey], 0, 0) = 0 then
        raise Exception.Create('XTest rejected OEM key release');
      HeldCodes[VKey] := 0;
    end;
    if HeldOemLevel3[VKey] <> 0 then
    begin
      if XTestFakeKeyEvent(D, HeldOemLevel3[VKey], 0, 0) = 0 then
        raise Exception.Create('XTest rejected OEM AltGr release');
      HeldOemLevel3[VKey] := 0;
    end;
    if HeldOemShift[VKey] <> 0 then
    begin
      if XTestFakeKeyEvent(D, HeldOemShift[VKey], 0, 0) = 0 then
        raise Exception.Create('XTest rejected OEM Shift release');
      HeldOemShift[VKey] := 0;
    end;
    Exit;
  end;

  if HeldCodes[VKey] <> 0 then
  begin
    if XTestFakeKeyEvent(D, HeldCodes[VKey], 1, 0) = 0 then
      raise Exception.Create('XTest rejected repeated OEM key');
    Exit;
  end;
  Symbol := KvmKeysym(VKey);
  if (XkbGetState(D, $100, State) <> 0) or
     not FindXkbSymbol(D, State.group, Symbol, Code, Level) then
    raise Exception.Create('OEM key not found in active XKB layout');
  ShiftKey := XKeysymToKeycode(D, $ffe1);
  Level3Key := XKeysymToKeycode(D, $fe03);
  if (((Level and 1) <> 0) and (ShiftKey = 0)) or
     (((Level and 2) <> 0) and (Level3Key = 0)) then
    raise Exception.Create('OEM XKB modifier unavailable');
  // Do not release a Shift/AltGr key that the remote user already holds.
  FillChar(PressedMap, SizeOf(PressedMap), 0);
  if XQueryKeymap(D, @PressedMap[0]) = 0 then
    raise Exception.Create('X11 key state unavailable');
  AddedShift := 0; AddedLevel3 := 0;
  try
    if ((Level and 1) <> 0) and ((State.mods and 1) = 0) then
    begin
      if XTestFakeKeyEvent(D, ShiftKey, 1, 0) = 0 then
        raise Exception.Create('XTest rejected OEM Shift');
      AddedShift := ShiftKey;
    end;
    if ((Level and 2) <> 0) and
       ((Ord(PressedMap[Level3Key div 8]) and (1 shl (Level3Key mod 8))) = 0) then
    begin
      if XTestFakeKeyEvent(D, Level3Key, 1, 0) = 0 then
        raise Exception.Create('XTest rejected OEM AltGr');
      AddedLevel3 := Level3Key;
    end;
    if XTestFakeKeyEvent(D, Code, 1, 0) = 0 then
      raise Exception.Create('XTest rejected OEM key');
    HeldCodes[VKey] := Byte(Code);
    HeldOemShift[VKey] := AddedShift;
    HeldOemLevel3[VKey] := AddedLevel3;
  except
    // A rejected key-down must never leave newly pressed modifiers stuck.
    if AddedLevel3 <> 0 then XTestFakeKeyEvent(D, AddedLevel3, 0, 0);
    if AddedShift <> 0 then XTestFakeKeyEvent(D, AddedShift, 0, 0);
    raise;
  end;
end;

procedure InjectKey(Pressed: Boolean; VKey: Word);
var D: Pointer; KeyCode: Byte; Symbol: CULong;
begin
  if (VKey=0) or (VKey>255) then raise Exception.Create('Touche hors plage');
  D:=LockX11;
  try
    if D=nil then raise Exception.Create('X11 inaccessible');
    if VKey in [$df, $e2] then
    begin
      InjectExtraOemKey(D, Pressed, VKey);
      XFlush(D);
      Exit;
    end;
    KeyCode:=HeldCodes[VKey];
    if not Pressed and (KeyCode=0) then Exit; // never injected: no release to retry
    if KeyCode=0 then
    begin
      Symbol:=KvmKeysym(VKey);
      if Symbol=0 then raise Exception.Create('Key not mapped on X11');
      // Right Alt from an AltGr keyboard is the XKB Level3 modifier.
      // The French layout often has no Alt_R keysym at all; requesting
      // ISO_Level3_Shift first also avoids selecting a plain Alt keycode.
      if VKey=$a5 then KeyCode:=XKeysymToKeycode(D,$fe03)
      else KeyCode:=0;
      if KeyCode=0 then KeyCode:=XKeysymToKeycode(D,Symbol);
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

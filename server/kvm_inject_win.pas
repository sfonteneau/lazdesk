unit kvm_inject_win;

{$mode objfpc}{$H+}{$pointermath on}

interface

uses
  Windows, SysUtils, kvm_wire;

function GetCursorNormalized(out NX, NY: Word): Boolean;
function GetCursorState(out NX, NY: Word; out Shape: TKvmCursorShape): Boolean;
procedure InjectMouse(Action, Button: Byte; NX, NY: Word);
procedure InjectText(CodePoint: Cardinal);
procedure InjectKey(Pressed: Boolean; VKey: Word);
procedure InjectWheel(Notches: SmallInt);

implementation

uses Math, kvm_monitors, kvm_geometry;

const
  // A single transient GetCursorInfo(CURSOR_SHOWING=0) must not make the
  // remote pointer disappear/reappear. Some applications briefly switch the
  // native cursor while changing focus/shape.
  // GDI polls the Win32 cursor independently of BitBlt. Windows can briefly
  // report a hidden cursor during focus/shape transitions. Keep the last
  // verified GDI shape for up to 300 ms, but never indefinitely.
  KVM_CURSOR_HIDE_DEBOUNCE_MS = 300;

var
  LastCursorHandle: HCURSOR = 0;
  LastCursorShape: TKvmCursorShape;
  LastCursorSeenTick: QWord = 0;
  LastCursorX, LastCursorY: Word;
  // SendInput normalizes to 0..65535. Even an unchanged requested screen pixel
  // used to be re-injected when the old coordinate conversion landed one
  // physical pixel away. Only the input thread touches these values.
  LastAbsoluteTargetValid: Boolean = False;
  LastAbsoluteTargetX, LastAbsoluteTargetY: Integer;

function KvmSendInput(Count: UINT; Inputs: Pointer; InputSize: Integer): UINT;
  stdcall; external 'user32.dll' name 'SendInput';
function KvmGetIconInfo(Icon: HICON; var Info: Windows.TICONINFO): LongBool;
  stdcall; external 'user32.dll' name 'GetIconInfo';
function KvmGetObject(Obj: HGDIOBJ; Size: Integer; Data: Pointer): Integer;
  stdcall; external 'gdi32.dll' name 'GetObjectA';

procedure DestroyCursorRender(var DC: HDC; var Bitmap: HBITMAP;
  var Old: HGDIOBJ);
begin
  if (Old<>0) and (DC<>0) then SelectObject(DC,Old);
  if Bitmap<>0 then DeleteObject(Bitmap);
  if DC<>0 then DeleteDC(DC);
  DC:=0; Bitmap:=0; Old:=0;
end;

function CreateCursorRender(W,H: Integer; Background: Byte; out DC: HDC;
  out Bitmap: HBITMAP; out Old: HGDIOBJ; out Bits: PByte): Boolean;
var BI: TBitmapInfo; I,Count: Integer; P: Pointer;
begin
  Result:=False; DC:=0; Bitmap:=0; Old:=0; Bits:=nil;
  DC:=CreateCompatibleDC(0);
  if DC=0 then Exit;
  FillChar(BI,SizeOf(BI),0);
  BI.bmiHeader.biSize:=SizeOf(TBitmapInfoHeader);
  BI.bmiHeader.biWidth:=W; BI.bmiHeader.biHeight:=-H;
  BI.bmiHeader.biPlanes:=1; BI.bmiHeader.biBitCount:=32;
  BI.bmiHeader.biCompression:=BI_RGB;
  P:=nil;
  Bitmap:=CreateDIBSection(DC,BI,DIB_RGB_COLORS,P,0,0);
  Bits:=PByte(P);
  if (Bitmap=0) or (Bits=nil) then Exit;
  Old:=SelectObject(DC,Bitmap);
  if (Old=0) or (PtrUInt(Old)=High(PtrUInt)) then
  begin Old:=0; Exit; end;
  Count:=W*H;
  for I:=0 to Count-1 do
  begin
    Bits[I*4+0]:=Background;
    Bits[I*4+1]:=Background;
    Bits[I*4+2]:=Background;
    Bits[I*4+3]:=255;
  end;
  Result:=True;
end;

function HashCursorShape(const Shape: TKvmCursorShape): Cardinal;
var I: Integer; H: Cardinal;
  procedure AddByte(B: Byte);
  begin H:=Cardinal((QWord(H xor B)*16777619) and $ffffffff); end;
  procedure AddWord(V: Word);
  begin AddByte(Byte(V and $ff)); AddByte(Byte(V shr 8)); end;
begin
  H:=$811c9dc5;
  AddWord(Shape.Width); AddWord(Shape.Height);
  AddWord(Shape.HotX); AddWord(Shape.HotY);
  for I:=1 to Length(Shape.Pixels) do AddByte(Ord(Shape.Pixels[I]));
  if H=0 then H:=1;
  Result:=H;
end;

function CaptureCursorShape(Cursor: HCURSOR; out Shape: TKvmCursorShape): Boolean;
var
  Info: Windows.TICONINFO;
  BM: Windows.TBitmap;
  SourceBitmap: HBITMAP;
  W,H,I,DeltaB,DeltaG,DeltaR,Transparency,Alpha: Integer;
  BlackDC,WhiteDC: HDC;
  BlackBitmap,WhiteBitmap: HBITMAP;
  BlackOld,WhiteOld: HGDIOBJ;
  BlackBits,WhiteBits,OutBits: PByte;
begin
  Result:=False; ClearCursorShape(Shape);
  FillChar(Info,SizeOf(Info),0);
  if (Cursor=0) or not KvmGetIconInfo(HICON(Cursor),Info) then Exit;
  try
    SourceBitmap:=Info.hbmColor;
    if SourceBitmap=0 then SourceBitmap:=Info.hbmMask;
    FillChar(BM,SizeOf(BM),0);
    if (SourceBitmap=0) or (KvmGetObject(HGDIOBJ(SourceBitmap),SizeOf(BM),@BM)=0) then Exit;
    W:=Abs(BM.bmWidth); H:=Abs(BM.bmHeight);
    // A monochrome cursor stores AND and XOR masks one above the other.
    if Info.hbmColor=0 then H:=H div 2;
    if (W<1) or (H<1) or (W>KVM_MAX_CURSOR_SIDE) or (H>KVM_MAX_CURSOR_SIDE) then Exit;
    if (Info.xHotspot>=DWORD(W)) or (Info.yHotspot>=DWORD(H)) then Exit;

    BlackDC:=0; WhiteDC:=0; BlackBitmap:=0; WhiteBitmap:=0;
    BlackOld:=0; WhiteOld:=0; BlackBits:=nil; WhiteBits:=nil;
    if not CreateCursorRender(W,H,0,BlackDC,BlackBitmap,BlackOld,BlackBits) then Exit;
    try
      if not CreateCursorRender(W,H,255,WhiteDC,WhiteBitmap,WhiteOld,WhiteBits) then Exit;
      try
        if not DrawIconEx(BlackDC,0,0,Cursor,W,H,0,0,DI_NORMAL) then Exit;
        if not DrawIconEx(WhiteDC,0,0,Cursor,W,H,0,0,DI_NORMAL) then Exit;
        if not GdiFlush then Exit;

        Shape.Width:=Word(W); Shape.Height:=Word(H);
        Shape.HotX:=Word(Info.xHotspot); Shape.HotY:=Word(Info.yHotspot);
        SetLength(Shape.Pixels,W*H*4);
        OutBits:=PByte(Pointer(Shape.Pixels));
        for I:=0 to W*H-1 do
        begin
          // Rendering on black and white backgrounds reconstructs an alpha
          // image for both alpha cursors and classic AND-mask cursors. The
          // resulting RGB channels are already premultiplied by alpha.
          DeltaB:=Integer(WhiteBits[I*4+0])-Integer(BlackBits[I*4+0]);
          DeltaG:=Integer(WhiteBits[I*4+1])-Integer(BlackBits[I*4+1]);
          DeltaR:=Integer(WhiteBits[I*4+2])-Integer(BlackBits[I*4+2]);
          // Classic monochrome cursors may contain XOR/invert pixels. They
          // render white on a black test surface and black on a white one,
          // i.e. a strongly negative delta. Alpha blending cannot express an
          // invert operation, and treating it as an opaque white pixel made
          // the Windows I-beam white on normal light editors. Prefer opaque
          // black for those pixels: it matches the expected editing cursor on
          // light backgrounds and avoids the distracting white I-beam.
          if (DeltaB+DeltaG+DeltaR)<-192 then
          begin
            OutBits[I*4+0]:=0; OutBits[I*4+1]:=0; OutBits[I*4+2]:=0;
            OutBits[I*4+3]:=255;
            Continue;
          end;
          Transparency:=(DeltaB+DeltaG+DeltaR) div 3;
          if Transparency<0 then Transparency:=0 else if Transparency>255 then Transparency:=255;
          Alpha:=255-Transparency;
          if Alpha=0 then
          begin
            OutBits[I*4+0]:=0; OutBits[I*4+1]:=0; OutBits[I*4+2]:=0;
          end
          else
          begin
            OutBits[I*4+0]:=Byte(Min(Alpha,Integer(BlackBits[I*4+0])));
            OutBits[I*4+1]:=Byte(Min(Alpha,Integer(BlackBits[I*4+1])));
            OutBits[I*4+2]:=Byte(Min(Alpha,Integer(BlackBits[I*4+2])));
          end;
          OutBits[I*4+3]:=Byte(Alpha);
        end;
        Shape.Revision:=HashCursorShape(Shape);
        Result:=True;
      finally
        DestroyCursorRender(WhiteDC,WhiteBitmap,WhiteOld);
      end;
    finally
      DestroyCursorRender(BlackDC,BlackBitmap,BlackOld);
    end;
  finally
    if Info.hbmColor<>0 then DeleteObject(Info.hbmColor);
    if Info.hbmMask<>0 then DeleteObject(Info.hbmMask);
  end;
end;

function GetCursorState(out NX, NY: Word; out Shape: TKvmCursorShape): Boolean;
var P: TPoint; M: TKvmMonitor; C: TCursorInfo; NowTick: QWord;
    Showing, PositionKnown, PositionValid, InfoValid: Boolean;
begin
  NX:=0; NY:=0; ClearCursorShape(Shape); Result:=False;
  NowTick:=GetTickCount64;
  FillChar(C,SizeOf(C),0); C.cbSize:=SizeOf(C);
  InfoValid:=GetCursorInfo(C);
  Showing:=InfoValid and ((C.flags and 1)<>0);
  // ptScreenPos is meaningful for a visible cursor. When hidden, query its
  // physical position separately: a hidden CURSORINFO may contain stale
  // coordinates and must not be mistaken for a monitor transition.
  PositionKnown:=False; PositionValid:=False;
  if Showing then
  begin
    P:=C.ptScreenPos;
    PositionKnown:=True;
  end
  else PositionKnown:=GetCursorPos(P);
  if PositionKnown then
  begin
    M:=CaptureMonitor;
    PositionValid:=NormalizePoint(M.Bounds,P.X,P.Y,NX,NY);
  end;

  if Showing and PositionValid then
  begin
    // A cursor handle is the stable identity of the pointer selected by the
    // application. Capture the bitmap only when that identity changes. The
    // previous 100 ms re-render could sample animated/XOR frames and make a
    // perfectly stationary cursor appear to blink on the viewer.
    if (C.hCursor<>LastCursorHandle) or (LastCursorShape.Revision=0) then
    begin
      if CaptureCursorShape(C.hCursor,Shape) then
      begin
        LastCursorHandle:=C.hCursor;
        LastCursorShape:=Shape;
      end
      else if LastCursorShape.Revision<>0 then
        Shape:=LastCursorShape;
    end
    else
      Shape:=LastCursorShape;
    // A visible flag without a valid HCURSOR bitmap produces an empty shape
    // and lets the viewer alternate between its fallback and native pointer.
    // Never publish such a half-populated cursor state.
    if Shape.Revision=0 then Exit(False);
    LastCursorX:=NX; LastCursorY:=NY; LastCursorSeenTick:=NowTick;
    Exit(True);
  end;

  // A real move to another monitor is not a transient visibility glitch.
  // Only debounce when the cursor is still on the captured monitor, or when
  // GetCursorInfo could not provide a position at all.
  if PositionKnown and not PositionValid then Exit(False);

  // Do not publish a one-frame hidden state. Windows/applications can briefly
  // clear CURSOR_SHOWING while switching focus or replacing the HCURSOR. A
  // short debounce removes the visible on/off flicker without keeping a truly
  // hidden pointer around for longer than the configured 300 ms.
  if (LastCursorShape.Revision<>0) and (LastCursorSeenTick<>0) and
     (NowTick>=LastCursorSeenTick) and
     (NowTick-LastCursorSeenTick<=KVM_CURSOR_HIDE_DEBOUNCE_MS) then
  begin
    NX:=LastCursorX; NY:=LastCursorY; Shape:=LastCursorShape;
    Result:=True;
  end;
end;

function GetCursorNormalized(out NX, NY: Word): Boolean;
var Shape: TKvmCursorShape;
begin
  Result:=GetCursorState(NX,NY,Shape);
end;

function SendAbsoluteMouseMove(X,Y: Integer): Boolean;
const
  // Keep local definitions for old FPC Windows headers.
  KVM_MOUSEEVENTF_MOVE        = DWORD($0001);
  KVM_MOUSEEVENTF_VIRTUALDESK = DWORD($4000);
  KVM_MOUSEEVENTF_ABSOLUTE    = DWORD($8000);
var
  VX,VY,VW,VH: Integer;
  TI: TInput;
  AX,AY: Int64;
  Current: TPoint;
begin
  Result:=False;
  VX:=GetSystemMetrics(SM_XVIRTUALSCREEN);
  VY:=GetSystemMetrics(SM_YVIRTUALSCREEN);
  VW:=GetSystemMetrics(SM_CXVIRTUALSCREEN);
  VH:=GetSystemMetrics(SM_CYVIRTUALSCREEN);
  if (VW<1) or (VH<1) then Exit;

  // Never resend an unchanged physical position: redundant WM_MOUSEMOVE /
  // WM_SETCURSOR messages can make the HOST cursor blink while controlled.
  // Windows may quantize a SendInput absolute position by one screen pixel.
  // Suppress that *only* when the requested destination has not changed;
  // a genuine one-pixel move to a different destination is still injected.
  // Button down/up events below this function are always preserved.
  if GetCursorPos(Current) then
  begin
    if (Current.X=X) and (Current.Y=Y) then
    begin
      LastAbsoluteTargetValid:=True;
      LastAbsoluteTargetX:=X; LastAbsoluteTargetY:=Y;
      Exit(True);
    end;
    if LastAbsoluteTargetValid and
       (LastAbsoluteTargetX=X) and (LastAbsoluteTargetY=Y) and
       (Abs(Int64(Current.X)-Int64(X))<=1) and
       (Abs(Int64(Current.Y)-Int64(Y))<=1) then Exit(True);
  end;

  // SendInput, unlike SetCursorPos, generates genuine WM_MOUSEMOVE events.
  // Position the event at the CENTER of the intended physical pixel, using
  // 65536 / virtual-desktop-width rather than 65535 / (width-1). The old
  // edge-to-edge formula mapped numerous X/Y positions to the adjacent pixel
  // and retriggered identical moves forever, even with the GetCursorPos check.
  // 64-bit arithmetic also supports virtual desktops with negative origins.
  AX:=((2*(Int64(X)-Int64(VX))+1)*65536) div (2*Int64(VW));
  AY:=((2*(Int64(Y)-Int64(VY))+1)*65536) div (2*Int64(VH));
  if AX<0 then AX:=0 else if AX>65535 then AX:=65535;
  if AY<0 then AY:=0 else if AY>65535 then AY:=65535;

  FillChar(TI,SizeOf(TI),0);
  TI._Type:=INPUT_MOUSE;
  TI.mi.dx:=LongInt(AX);
  TI.mi.dy:=LongInt(AY);
  TI.mi.dwFlags:=KVM_MOUSEEVENTF_MOVE or KVM_MOUSEEVENTF_ABSOLUTE or
    KVM_MOUSEEVENTF_VIRTUALDESK;
  Result:=KvmSendInput(1,@TI,SizeOf(TI))=1;
  if Result then
  begin
    LastAbsoluteTargetValid:=True;
    LastAbsoluteTargetX:=X; LastAbsoluteTargetY:=Y;
  end;
end;

procedure InjectMouse(Action, Button: Byte; NX, NY: Word);
var
  X, Y: Integer; M: TKvmMonitor;
  Flags: DWORD; TI: TInput;
begin
  M := CaptureMonitor;
  if DenormalizePoint(M.Bounds, NX, NY, X, Y) then
  begin
    if not SendAbsoluteMouseMove(X,Y) and (Action <> 2) then
      raise Exception.Create('Windows rejected pointer movement.');
  end
  else if Action <> 2 then Exit;
  if Action = 0 then Exit;
  Flags := 0;
  case Button of
    1: if Action = 1 then Flags := MOUSEEVENTF_LEFTDOWN
       else Flags := MOUSEEVENTF_LEFTUP;
    2: if Action = 1 then Flags := MOUSEEVENTF_RIGHTDOWN
       else Flags := MOUSEEVENTF_RIGHTUP;
    3: if Action = 1 then Flags := MOUSEEVENTF_MIDDLEDOWN
       else Flags := MOUSEEVENTF_MIDDLEUP;
  end;
  if Flags <> 0 then
  begin
    FillChar(TI,SizeOf(TI),0); TI._Type := INPUT_MOUSE; TI.mi.dwFlags := Flags;
    if KvmSendInput(1,@TI,SizeOf(TI)) <> 1 then
      raise Exception.Create('Windows rejected the mouse button event.');
  end;
end;

procedure InjectText(CodePoint: Cardinal);
var
  TI: TInput;
  KI: TKeybdInput;
  Codes: array[0..1] of Word;
  Count, I: Integer;
const
  KVM_UNICODE_FLAG = $0004;
begin
  if (CodePoint < 32) or (CodePoint > $10ffff) then Exit;
  if CodePoint <= $ffff then
  begin
    Codes[0] := Word(CodePoint);
    Count := 1;
  end
  else
  begin
    Dec(CodePoint, $10000);
    Codes[0] := $d800 or Word(CodePoint shr 10);
    Codes[1] := $dc00 or Word(CodePoint and $3ff);
    Count := 2;
  end;
  for I := 0 to Count - 1 do
  begin
    FillChar(TI, SizeOf(TI), 0);
    FillChar(KI, SizeOf(KI), 0);
    TI._Type := INPUT_KEYBOARD;
    KI.wScan := Codes[I];
    KI.dwFlags := KVM_UNICODE_FLAG;
    TI.ki := KI;
    if KvmSendInput(1, @TI, SizeOf(TI)) <> 1 then
      raise Exception.Create('Windows rejected Unicode input (session or permissions).');
    KI.dwFlags := KVM_UNICODE_FLAG or KEYEVENTF_KEYUP;
    TI.ki := KI;
    if KvmSendInput(1, @TI, SizeOf(TI)) <> 1 then
      raise Exception.Create('Windows rejected Unicode input (session or permissions).');
  end;
end;

procedure InjectKey(Pressed: Boolean; VKey: Word);
var TI: TInput;
begin
  if VKey > 255 then Exit;
  FillChar(TI, SizeOf(TI), 0); TI._Type := INPUT_KEYBOARD;
  TI.ki.wVk := VKey; TI.ki.wScan := Word(MapVirtualKey(VKey, 0));
  if VKey in [$21..$28, $2d, $2e, $5b, $5c, $5d, $6f, $90, $a3, $a5] then
    TI.ki.dwFlags := KEYEVENTF_EXTENDEDKEY;
  if not Pressed then TI.ki.dwFlags := TI.ki.dwFlags or KEYEVENTF_KEYUP;
  if KvmSendInput(1, @TI, SizeOf(TI)) <> 1 then
    raise Exception.Create('SendInput rejected (Windows session or permissions).');
end;

procedure InjectWheel(Notches: SmallInt);
var TI: TInput;
begin
  if Notches = 0 then Exit;
  FillChar(TI,SizeOf(TI),0); TI._Type := INPUT_MOUSE;
  TI.mi.dwFlags := MOUSEEVENTF_WHEEL;
  TI.mi.mouseData := DWORD(LongInt(Notches) * WHEEL_DELTA);
  if KvmSendInput(1,@TI,SizeOf(TI)) <> 1 then
    raise Exception.Create('Windows rejected the mouse wheel event.');
end;

end.

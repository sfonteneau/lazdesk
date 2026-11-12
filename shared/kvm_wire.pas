unit kvm_wire;

{$mode objfpc}{$H+}

interface

uses SysUtils;

const
  KVM_SUBPROTOCOL = 'lazdesk9'; // atomic shortcuts + Windows lock; rebuild both peers
  // Public URL path sent by the client, including the initial slash.
  KVM_WS_PATH = '/kvm';
  // mORMot2.ServerUpgrade removes the initial slash before CloneByName/UpgradeUri.
  KVM_WS_ROUTE = 'kvm';
  KVM_MAX_JPEG_BYTES = 2 * 1024 * 1024; // per dirty rectangle
  // Native multi-monitor virtual desktops (e.g. 8 x 3840x2160) are accepted.
  // Safety envelope only: u16 wire coordinates, and bounded RGB/BGRX memory.
  KVM_MAX_FRAME_SIDE = 32768;
  KVM_MAX_FRAME_PIXELS = 67108864; // 64M pixels; 256 MiB per BGRX surface
  KVM_MAX_TEXT_BYTES = 1024;
  KVM_MAX_TEXT_SCALARS = 256;
  KVM_MAX_CURSOR_SIDE = 256;
  KVM_CURSOR_SHAPE_HEADER = 13;
  KVM_MAX_SHORTCUT_KEYS = 3;
  KVM_TILE_SIZE = 256;
  // 4:4:4 TurboJPEG worst-case buffer: 512*512*6+2048 < 2 MiB.
  // Larger 4:4:4 rectangles can exceed KVM_MAX_JPEG_BYTES before encoding.
  KVM_MAX_RECT_WIDTH = 512;    // at most two adjacent tile columns
  KVM_MAX_RECT_HEIGHT = 512;   // at most two adjacent tile rows

  // All WebSocket binary messages use little-endian words:
  //   D + available:u8                          ordered desktop availability
  //   S + width:u16 + height:u16                screen reset
  //   T + x:u16 + y:u16 + w:u16 + h:u16 + jpeg   merged dirty rectangle
  //   R                                          refresh requested by viewer
  //   M + action:u8 + button:u8 + x:u16 + y:u16  mouse
  //   K + pressed:u8 + VK:u16                    LCL/Win32 virtual key
  //   Q                                          Windows secure attention (SAS) request
  //   J                                          Windows session lock request
  //   Y + count:u8 + VK:u8[count]                atomic shortcut (2..3 keys)
  //   W + wheel-notches:i16                      wheel
  //   C + visible:u8 + normalized-x:u16 + normalized-y:u16   remote pointer position
  //   H + revision:u32 + w:u16 + h:u16 + hot-x:u16 + hot-y:u16
  //       + premultiplied BGRA32 pixels                      remote pointer shape
  //   U + UTF-8 commit                         internal input queue only (never on the network)
  //   X + version:u8 + serial:u32 + bytes:u16 + UTF-8   versioned client text request
  //   B + batch-serial:u32                       end of server batch
  //   A + batch-serial:u32                       client ACK after bitmap composition
  //   N + batch-serial:u32                       rejected complete batch (NACK)
  //   P                                          client heartbeat
  //   G/L/Z                                      acquire/release/reset input control
  //   cQ/cR  bounded Unicode clipboard RPC (see kvm_clipboard_wire.pas)
  // WebSocket text: AUTH <token> <jpeg|h264>; OK VIEW; OK CTRL; ERR AUTH.

type
  TKvmCodePoints = array of Cardinal;
  TKvmShortcutKeys = array of Word;
  TKvmSasResult = (ksrUnavailable, ksrNeedsPrivileges, ksrRequested);
  TKvmLockResult = (klrUnavailable, klrFailed, klrRequested);

  TKvmCursorShape = record
    Revision: Cardinal;
    Width, Height: Word;
    HotX, HotY: Word;
    // Premultiplied BGRA32, top-down, exactly Width*Height*4 bytes.
    Pixels: RawByteString;
  end;

function ReadTextCommit(const Packet: RawByteString; out Points: TKvmCodePoints): Boolean;

function MakeScreen(W, H: Word): RawByteString;
function ReadScreen(const S: RawByteString; out W, H: Word): Boolean;
function MakeTile(X, Y, W, H: Word; const Jpeg: RawByteString): RawByteString;
function ReadTile(const S: RawByteString; out X, Y, W, H: Word;
  out Jpeg: RawByteString): Boolean;
function MakeMouse(Action, Button: Byte; X, Y: Word): RawByteString;
function ReadMouse(const S: RawByteString; out Action, Button: Byte;
  out X, Y: Word): Boolean;
function MakeKey(Pressed: Boolean; VKey: Word): RawByteString;
function ReadKey(const S: RawByteString; out Pressed: Boolean;
  out VKey: Word): Boolean;
function MakeShortcut(const Keys: array of Word): RawByteString;
function ReadShortcut(const S: RawByteString; out Keys: TKvmShortcutKeys): Boolean;
function MakeTextUtf8(const Utf8: RawByteString): RawByteString;
function ReadTextUtf8(const Packet: RawByteString;
  out CodePoint: Cardinal): Boolean;
function MakeCursor(X, Y: Word; Visible: Boolean = True): RawByteString;
function ReadCursor(const S: RawByteString; out X, Y: Word; out Visible: Boolean): Boolean;
procedure ClearCursorShape(var Shape: TKvmCursorShape);
function MakeCursorShape(const Shape: TKvmCursorShape): RawByteString;
function ReadCursorShape(const S: RawByteString; out Shape: TKvmCursorShape): Boolean;
function MakeBatchEnd(Serial: Cardinal): RawByteString;
function ReadBatchEnd(const S: RawByteString; out Serial: Cardinal): Boolean;
function MakeBatchAck(Serial: Cardinal): RawByteString;
function ReadBatchAck(const S: RawByteString; out Serial: Cardinal): Boolean;
function MakeBatchNack(Serial: Cardinal): RawByteString;
function ReadBatchNack(const S: RawByteString; out Serial: Cardinal): Boolean;
function MakeWheel(Notches: SmallInt): RawByteString;
function ReadWheel(const S: RawByteString; out Notches: SmallInt): Boolean;

implementation

function GetWordLE(const S: RawByteString; Idx: Integer): Word;
begin
  Result := Word(Ord(S[Idx])) or (Word(Ord(S[Idx + 1])) shl 8);
end;

procedure SetWordLE(var S: RawByteString; Idx: Integer; V: Word);
begin
  S[Idx] := AnsiChar(V and $ff);
  S[Idx + 1] := AnsiChar((V shr 8) and $ff);
end;

function GetCardinalLE(const S: RawByteString; Idx: Integer): Cardinal;
begin
  Result := Cardinal(Ord(S[Idx])) or (Cardinal(Ord(S[Idx+1])) shl 8) or
    (Cardinal(Ord(S[Idx+2])) shl 16) or (Cardinal(Ord(S[Idx+3])) shl 24);
end;

procedure SetCardinalLE(var S: RawByteString; Idx: Integer; V: Cardinal);
begin
  S[Idx] := AnsiChar(V and $ff);
  S[Idx+1] := AnsiChar((V shr 8) and $ff);
  S[Idx+2] := AnsiChar((V shr 16) and $ff);
  S[Idx+3] := AnsiChar((V shr 24) and $ff);
end;

function MakeScreen(W, H: Word): RawByteString;
begin
  SetLength(Result, 5);
  Result[1] := 'S';
  SetWordLE(Result, 2, W);
  SetWordLE(Result, 4, H);
end;

function ReadScreen(const S: RawByteString; out W, H: Word): Boolean;
begin
  W := 0;
  H := 0;
  Result := (Length(S) = 5) and (S <> '') and (S[1] = 'S');
  if not Result then Exit;
  W := GetWordLE(S, 2);
  H := GetWordLE(S, 4);
  Result := (W > 0) and (H > 0) and
    (W <= KVM_MAX_FRAME_SIDE) and (H <= KVM_MAX_FRAME_SIDE) and
    (Int64(W) * H <= KVM_MAX_FRAME_PIXELS);
end;

function MakeTile(X, Y, W, H: Word; const Jpeg: RawByteString): RawByteString;
begin
  SetLength(Result, 9 + Length(Jpeg));
  Result[1] := 'T';
  SetWordLE(Result, 2, X);
  SetWordLE(Result, 4, Y);
  SetWordLE(Result, 6, W);
  SetWordLE(Result, 8, H);
  if Jpeg <> '' then Move(Jpeg[1], Result[10], Length(Jpeg));
end;

function ReadTile(const S: RawByteString; out X, Y, W, H: Word;
  out Jpeg: RawByteString): Boolean;
begin
  X := 0;
  Y := 0;
  W := 0;
  H := 0;
  Jpeg := '';
  Result := (Length(S) >= 13) and (Length(S) <= KVM_MAX_JPEG_BYTES + 9);
  if not Result then Exit;
  Result := (S[1] = 'T') and (S[10] = #$ff) and (S[11] = #$d8);
  if not Result then Exit;
  X := GetWordLE(S, 2);
  Y := GetWordLE(S, 4);
  W := GetWordLE(S, 6);
  H := GetWordLE(S, 8);
  Result := (W > 0) and (H > 0) and
    (W <= KVM_MAX_RECT_WIDTH) and (H <= KVM_MAX_RECT_HEIGHT) and
    (Integer(X) + Integer(W) <= KVM_MAX_FRAME_SIDE) and
    (Integer(Y) + Integer(H) <= KVM_MAX_FRAME_SIDE);
  if not Result then Exit;
  Jpeg := Copy(S, 10, Length(S) - 9);
end;

function MakeMouse(Action, Button: Byte; X, Y: Word): RawByteString;
begin
  SetLength(Result, 7);
  Result[1] := 'M';
  Result[2] := AnsiChar(Action);
  Result[3] := AnsiChar(Button);
  SetWordLE(Result, 4, X);
  SetWordLE(Result, 6, Y);
end;

function ReadMouse(const S: RawByteString; out Action, Button: Byte;
  out X, Y: Word): Boolean;
begin
  Result := False;
  if Length(S) <> 7 then Exit;
  if S[1] <> 'M' then Exit;
  Action := Ord(S[2]);
  Button := Ord(S[3]);
  X := GetWordLE(S, 4);
  Y := GetWordLE(S, 6);
  Result := (Action <= 2) and (Button <= 3) and
    ((Action = 0) or (Button >= 1));
end;

function MakeKey(Pressed: Boolean; VKey: Word): RawByteString;
begin
  SetLength(Result, 4);
  Result[1] := 'K';
  if Pressed then Result[2] := #1 else Result[2] := #0;
  SetWordLE(Result, 3, VKey);
end;

function ReadKey(const S: RawByteString; out Pressed: Boolean;
  out VKey: Word): Boolean;
begin
  Result := False;
  if Length(S) <> 4 then Exit;
  if S[1] <> 'K' then Exit;
  Pressed := S[2] = #1;
  VKey := GetWordLE(S, 3);
  Result := ((S[2] = #0) or (S[2] = #1)) and (VKey > 0) and (VKey <= 255);
end;

function MakeShortcut(const Keys: array of Word): RawByteString;
var I: Integer;
begin
  Result:='';
  if (Length(Keys)<2) or (Length(Keys)>KVM_MAX_SHORTCUT_KEYS) then Exit;
  for I:=0 to High(Keys) do
    if (Keys[I]<1) or (Keys[I]>255) then Exit;
  SetLength(Result,2+Length(Keys));
  Result[1]:='Y'; Result[2]:=AnsiChar(Length(Keys));
  for I:=0 to High(Keys) do Result[I+3]:=AnsiChar(Keys[I]);
end;

function ReadShortcut(const S: RawByteString; out Keys: TKvmShortcutKeys): Boolean;
var I,N: Integer;
begin
  Result:=False;
  SetLength(Keys,0);
  if (Length(S)<4) or (Length(S)>2+KVM_MAX_SHORTCUT_KEYS) or (S[1]<>'Y') then Exit;
  N:=Ord(S[2]);
  if (N<2) or (N>KVM_MAX_SHORTCUT_KEYS) or (Length(S)<>N+2) then Exit;
  for I:=3 to Length(S) do if S[I]=#0 then Exit;
  SetLength(Keys,N);
  for I:=0 to N-1 do Keys[I]:=Ord(S[I+3]);
  Result:=True;
end;

function ReadTextUtf8(const Packet: RawByteString;
  out CodePoint: Cardinal): Boolean;
var
  B0, B1, B2, B3, N: Cardinal;
begin
  CodePoint := 0;
  Result := False;
  N := Length(Packet);
  if (N < 2) or (N > 5) or (Packet[1] <> 'U') then Exit;
  B0 := Ord(Packet[2]);
  if (B0 >= 32) and (B0 < 127) and (N = 2) then
    CodePoint := B0
  else if (B0 >= $c2) and (B0 <= $df) and (N = 3) then
  begin
    B1 := Ord(Packet[3]);
    if (B1 and $c0) <> $80 then Exit;
    CodePoint := ((B0 and $1f) shl 6) or (B1 and $3f);
  end
  else if (B0 >= $e0) and (B0 <= $ef) and (N = 4) then
  begin
    B1 := Ord(Packet[3]);
    B2 := Ord(Packet[4]);
    if ((B1 and $c0) <> $80) or ((B2 and $c0) <> $80) then Exit;
    CodePoint := ((B0 and $0f) shl 12) or
      ((B1 and $3f) shl 6) or (B2 and $3f);
    if (CodePoint < $800) or
       ((CodePoint >= $d800) and (CodePoint <= $dfff)) then Exit;
  end
  else if (B0 >= $f0) and (B0 <= $f4) and (N = 5) then
  begin
    B1 := Ord(Packet[3]);
    B2 := Ord(Packet[4]);
    B3 := Ord(Packet[5]);
    if ((B1 and $c0) <> $80) or ((B2 and $c0) <> $80) or
       ((B3 and $c0) <> $80) then Exit;
    CodePoint := ((B0 and 7) shl 18) or ((B1 and $3f) shl 12) or
      ((B2 and $3f) shl 6) or (B3 and $3f);
    if (CodePoint < $10000) or (CodePoint > $10ffff) then Exit;
  end
  else Exit;
  // Reject control and delete characters, including C1 controls.
  Result := (CodePoint >= 32) and (CodePoint <> 127) and
    ((CodePoint < $80) or (CodePoint >= $a0));
end;

function ReadTextCommit(const Packet: RawByteString; out Points: TKvmCodePoints): Boolean;
var I, N, Count, Bytes: Integer; CP: Cardinal; B: Byte;
begin
  Result := False;
  SetLength(Points, 0);
  N := Length(Packet);
  if (N < 2) or (N > KVM_MAX_TEXT_BYTES + 1) then Exit;
  if Packet[1] <> 'U' then Exit;
  I := 2; Count := 0;
  // Decode into a temporary bounded array; never accept a valid prefix of
  // an invalid commit. ReadTextUtf8 rejects overlong UTF-8 and surrogates.
  SetLength(Points, KVM_MAX_TEXT_SCALARS);
  while I <= N do
  begin
    B := Ord(Packet[I]); Bytes := 0;
    if B < $80 then Bytes := 1
    else if (B >= $c2) and (B <= $df) then Bytes := 2
    else if (B >= $e0) and (B <= $ef) then Bytes := 3
    else if (B >= $f0) and (B <= $f4) then Bytes := 4;
    if (Bytes = 0) or (I + Bytes - 1 > N) or
       (Count >= KVM_MAX_TEXT_SCALARS) then Break;
    if not ReadTextUtf8('U' + Copy(Packet, I, Bytes), CP) then Break;
    Points[Count] := CP; Inc(Count); Inc(I, Bytes);
  end;
  Result := (I = N + 1) and (Count > 0);
  if Result then SetLength(Points, Count) else SetLength(Points, 0);
end;

function MakeTextUtf8(const Utf8: RawByteString): RawByteString;
var Points: TKvmCodePoints;
begin
  Result := 'U' + Utf8;
  if not ReadTextCommit(Result, Points) then Result := '';
end;

function MakeCursor(X, Y: Word; Visible: Boolean): RawByteString;
begin
  SetLength(Result, 6); Result[1] := 'C'; Result[2] := AnsiChar(Ord(Visible));
  SetWordLE(Result, 3, X); SetWordLE(Result, 5, Y);
end;
function ReadCursor(const S: RawByteString; out X, Y: Word; out Visible: Boolean): Boolean;
begin
  X := 0; Y := 0; Visible := False;
  Result := (Length(S) = 6) and (S[1] = 'C') and (S[2] in [#0,#1]);
  if not Result then Exit;
  Visible := S[2] = #1; X := GetWordLE(S, 3); Y := GetWordLE(S, 5);
end;

procedure ClearCursorShape(var Shape: TKvmCursorShape);
begin
  Shape.Revision := 0;
  Shape.Width := 0;
  Shape.Height := 0;
  Shape.HotX := 0;
  Shape.HotY := 0;
  Shape.Pixels := '';
end;

function MakeCursorShape(const Shape: TKvmCursorShape): RawByteString;
var PixelBytes: Integer;
begin
  Result := '';
  if (Shape.Revision = 0) or (Shape.Width < 1) or (Shape.Height < 1) or
     (Shape.Width > KVM_MAX_CURSOR_SIDE) or (Shape.Height > KVM_MAX_CURSOR_SIDE) or
     (Shape.HotX >= Shape.Width) or (Shape.HotY >= Shape.Height) then Exit;
  PixelBytes := Integer(Shape.Width) * Integer(Shape.Height) * 4;
  if Length(Shape.Pixels) <> PixelBytes then Exit;
  SetLength(Result, KVM_CURSOR_SHAPE_HEADER + PixelBytes);
  Result[1] := 'H';
  SetCardinalLE(Result, 2, Shape.Revision);
  SetWordLE(Result, 6, Shape.Width);
  SetWordLE(Result, 8, Shape.Height);
  SetWordLE(Result, 10, Shape.HotX);
  SetWordLE(Result, 12, Shape.HotY);
  if PixelBytes > 0 then Move(Shape.Pixels[1], Result[14], PixelBytes);
end;

function ReadCursorShape(const S: RawByteString; out Shape: TKvmCursorShape): Boolean;
var PixelBytes: Integer;
begin
  ClearCursorShape(Shape);
  Result := (Length(S) >= KVM_CURSOR_SHAPE_HEADER + 4) and (S[1] = 'H');
  if not Result then Exit;
  Shape.Revision := GetCardinalLE(S, 2);
  Shape.Width := GetWordLE(S, 6);
  Shape.Height := GetWordLE(S, 8);
  Shape.HotX := GetWordLE(S, 10);
  Shape.HotY := GetWordLE(S, 12);
  Result := (Shape.Revision <> 0) and (Shape.Width > 0) and (Shape.Height > 0) and
    (Shape.Width <= KVM_MAX_CURSOR_SIDE) and (Shape.Height <= KVM_MAX_CURSOR_SIDE) and
    (Shape.HotX < Shape.Width) and (Shape.HotY < Shape.Height);
  if not Result then begin ClearCursorShape(Shape); Exit; end;
  PixelBytes := Integer(Shape.Width) * Integer(Shape.Height) * 4;
  Result := Length(S) = KVM_CURSOR_SHAPE_HEADER + PixelBytes;
  if not Result then begin ClearCursorShape(Shape); Exit; end;
  SetLength(Shape.Pixels, PixelBytes);
  if PixelBytes > 0 then Move(S[14], Shape.Pixels[1], PixelBytes);
end;

function MakeBatchEnd(Serial: Cardinal): RawByteString;
begin
  SetLength(Result, 5);
  Result[1] := 'B';
  Result[2] := AnsiChar(Serial and $ff);
  Result[3] := AnsiChar((Serial shr 8) and $ff);
  Result[4] := AnsiChar((Serial shr 16) and $ff);
  Result[5] := AnsiChar((Serial shr 24) and $ff);
end;

function ReadBatchEnd(const S: RawByteString; out Serial: Cardinal): Boolean;
begin
  Serial := 0;
  Result := (Length(S) = 5) and (S[1] = 'B');
  if Result then
  begin
    Serial := GetCardinalLE(S, 2);
    Result := Serial <> 0;
  end;
end;

function MakeBatchAck(Serial: Cardinal): RawByteString;
begin
  Result := MakeBatchEnd(Serial);
  Result[1] := 'A';
end;

function ReadBatchAck(const S: RawByteString; out Serial: Cardinal): Boolean;
begin
  Serial := 0;
  Result := (Length(S) = 5) and (S[1] = 'A');
  if Result then
  begin
    Serial := GetCardinalLE(S, 2);
    Result := Serial <> 0;
  end;
end;

function MakeBatchNack(Serial: Cardinal): RawByteString;
begin Result := MakeBatchEnd(Serial); Result[1] := 'N'; end;
function ReadBatchNack(const S: RawByteString; out Serial: Cardinal): Boolean;
begin
  Serial := 0;
  Result := (Length(S) = 5) and (S[1] = 'N');
  if Result then begin Serial := GetCardinalLE(S, 2); Result := Serial <> 0; end;
end;

function MakeWheel(Notches: SmallInt): RawByteString;
begin
  SetLength(Result, 3);
  Result[1] := 'W';
  SetWordLE(Result, 2, Word(Notches));
end;

function ReadWheel(const S: RawByteString; out Notches: SmallInt): Boolean;
begin
  Result := False;
  Notches := 0;
  if Length(S) <> 3 then Exit;
  if S[1] <> 'W' then Exit;
  Notches := SmallInt(GetWordLE(S, 2));
  Result := (Notches >= -12) and (Notches <= 12);
end;

end.

program test_wire;

{$mode objfpc}{$H+}

uses SysUtils, kvm_wire;

procedure Check(Condition: Boolean; const Msg: string);
begin
  if not Condition then
  begin
    WriteLn('ERROR: ', Msg);
    Halt(1);
  end;
end;

var
  S, Jpeg, OutJpeg: RawByteString;
  Action, Button: Byte;
  X, Y, W, H, VKey: Word;
  Pressed, Visible: Boolean;
  Wheel: SmallInt;
  CodePoint, Serial: Cardinal;
begin
  S := MakeScreen(1600, 900);
  Check(ReadScreen(S, W, H) and (W = 1600) and (H = 900), 'screen');
  Check(not ReadScreen('S' + #0 + #0 + #0 + #0, W, H), 'empty screen');
  Check(not ReadScreen(MakeScreen(32768, 32768), W, H), 'oversized bitmap safety guard');

  Jpeg := #$ff + #$d8 + #$ff + #$d9;
  S := MakeTile(256, 512, 768, 400, Jpeg);
  Check(ReadTile(S, X, Y, W, H, OutJpeg), 'tile');
  Check((X = 256) and (Y = 512) and (W = 768) and (H = 400), 'tile coords');
  Check(OutJpeg = Jpeg, 'tile jpeg bytes');
  Check(not ReadTile('T' + #0 + #0, X, Y, W, H, OutJpeg), 'short tile');
  S := MakeTile(0, 0, 513, 256, Jpeg);
  Check(not ReadTile(S, X, Y, W, H, OutJpeg), 'reject too-wide rectangle');
  S := MakeTile(0, 0, 512, 513, Jpeg);
  Check(not ReadTile(S, X, Y, W, H, OutJpeg), 'reject too-tall rectangle');

  S := MakeMouse(1, 2, 65535, 32768);
  Check(Length(S) = 7, 'mouse len');
  Check(ReadMouse(S, Action, Button, X, Y), 'mouse');
  Check((Action = 1) and (Button = 2) and (X = 65535) and (Y = 32768),
    'mouse coordinates');
  Check(not ReadMouse('M', Action, Button, X, Y), 'short mouse');

  S := MakeKey(True, 65);
  Check(Length(S) = 4, 'key len');
  Check(ReadKey(S, Pressed, VKey) and Pressed and (VKey = 65), 'key');
  Check(not ReadKey('K' + #3 + #65 + #0, Pressed, VKey), 'invalid key press');

  S := MakeWheel(-2);
  Check(ReadWheel(S, Wheel) and (Wheel = -2), 'signed wheel');
  Check(not ReadWheel('W' + #127 + #0, Wheel), 'too much wheel');

  S := MakeCursor(123, 456);
  Check(ReadCursor(S, X, Y, Visible) and (X = 123) and (Y = 456), 'cursor');
  Check(not ReadCursor('C' + #0, X, Y, Visible), 'short cursor');
  Check(Visible = False, 'invalid cursor clears visibility');
  S := MakeCursor(0,0,False);
  Check(ReadCursor(S,X,Y,Visible) and not Visible, 'hide cursor');
  S := MakeBatchNack(42);
  Check(ReadBatchNack(S,Serial) and (Serial=42), 'NACK serial');
  Check(not ReadBatchAck(S,Serial), 'NACK is not ACK');
  S := MakeTextUtf8('e');
  Check(ReadTextUtf8(S, CodePoint) and (CodePoint = Ord('e')), 'ascii text');
  S := MakeTextUtf8(#$c3 + #$a9); // e acute
  Check(ReadTextUtf8(S, CodePoint) and (CodePoint = $e9), 'utf8 accent');
  S := MakeTextUtf8(#$f0 + #$9f + #$99 + #$82); // U+1F642
  Check(ReadTextUtf8(S, CodePoint) and (CodePoint = $1f642), 'utf8 4 bytes');
  Check(MakeTextUtf8(#$c0 + #$af) = '', 'overlong UTF-8 rejected');
  Check(not ReadTextUtf8('U' + #$ed + #$a0 + #$80, CodePoint), 'surrogate rejected');
  Check(not ReadTextUtf8('U' + #10, CodePoint), 'controls rejected');
  S := MakeBatchEnd($12345678);
  Check(ReadBatchEnd(S, Serial) and (Serial = $12345678), 'batch end LE');
  Check(not ReadBatchAck(S, Serial), 'server end is not client ACK');
  S := MakeBatchAck($aabbccdd);
  Check(ReadBatchAck(S, Serial) and (Serial = $aabbccdd), 'batch ACK LE');
  Check(not ReadBatchEnd(S, Serial), 'client ACK is not server end');
  Check(not ReadBatchAck('A' + #0 + #0 + #0 + #0, Serial), 'reject zero ACK');
  Check(not ReadBatchEnd('B' + #1, Serial), 'reject short batch');
  WriteLn('OK: S/T/M/K/W/C/U/B/A wire protocol');
end.

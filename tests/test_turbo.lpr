program test_turbo;

{$mode objfpc}{$H+}

uses SysUtils, kvm_frame, kvm_wire, kvm_turbojpeg;

procedure Check(Condition: Boolean; const Msg: string);
begin
  if not Condition then
  begin
    WriteLn('FAIL: ', Msg);
    Halt(1);
  end;
end;

function JpegIs444(const S: RawByteString): Boolean;
var
  P, Marker, SizeSeg: Integer;
begin
  Result := False;
  if (Length(S) < 4) or (S[1] <> #$FF) or (S[2] <> #$D8) then Exit;
  P := 3;
  while P + 3 <= Length(S) do
  begin
    if S[P] <> #$FF then Exit;
    Inc(P);
    while (P <= Length(S)) and (S[P] = #$FF) do Inc(P);
    if P > Length(S) then Exit;
    Marker := Ord(S[P]); Inc(P);
    if Marker = $D9 then Exit;
    if (Marker >= $D0) and (Marker <= $D7) then Continue;
    if Marker = $01 then Continue;
    if P + 1 > Length(S) then Exit;
    SizeSeg := Ord(S[P]) * 256 + Ord(S[P+1]);
    if (SizeSeg < 2) or (SizeSeg > Length(S) - P + 1) then Exit;
    if Marker = $C0 then
    begin
      if (SizeSeg < 17) or (Ord(S[P+7]) <> 3) then Exit;
      Result := (Ord(S[P+9]) = $11) and
        (Ord(S[P+12]) = $11) and (Ord(S[P+15]) = $11);
      Exit;
    end;
    Inc(P, SizeSeg);
  end;
end;

var
  Encoder: TTurboJpegEncoder;
  Image: TRgbFrame;
  Jpeg: RawByteString;
  X, Y, Posn, I: Integer;
  Started: QWord;
begin
  Image.Width := 0;
  Image.Height := 0;
  Image.RGB := '';
  Check(AllocateFrame(Image, 1280, 720), 'allocate rgb buffer');
  for Y := 0 to Image.Height - 1 do
    for X := 0 to Image.Width - 1 do
    begin
      Posn := (Y * Image.Width + X) * 3 + 1;
      Image.RGB[Posn] := AnsiChar(X and 255);
      Image.RGB[Posn + 1] := AnsiChar(Y and 255);
      Image.RGB[Posn + 2] := AnsiChar((X xor Y) and 255);
    end;
  Encoder := TTurboJpegEncoder.Create;
  try
    Check(Encoder.EncodeRect(Image, 3, 5, 768, 400, 70, Jpeg),
      'TurboJPEG encodes nonzero origin with original frame stride');
    Check((Length(Jpeg) > 10) and (Jpeg[1] = #$ff) and
      (Jpeg[2] = #$d8) and (Jpeg[Length(Jpeg)-1] = #$ff) and
      (Jpeg[Length(Jpeg)] = #$d9), 'valid JPEG markers');
    Check(JpegIs444(Jpeg), 'JPEG SOF0 must specify 4:4:4 for all 3 components');
    Check(Encoder.EncodeRect(Image, 0, 0, 256, 256, 100, Jpeg),
      'TurboJPEG accepts quality=100');
    Check(JpegIs444(Jpeg), 'quality=100 must remain 4:4:4');
    Check(not Encoder.EncodeRect(Image, 0, 0, 256, 256, 101, Jpeg),
      'quality=101 is invalid');
    Check(not Encoder.EncodeRect(Image, 0, 0, 513, 256, 70, Jpeg),
      'oversized rectangle rejected');
    Started := GetTickCount64;
    for I := 1 to 20 do
      Check(Encoder.EncodeRect(Image, 0, 0, 512, 512, 70, Jpeg),
        'repeated TurboJPEG compression');
    WriteLn('OK: turbojpeg RGB24 4:4:4 encoding; 20 x 512x512 time ms=',
      GetTickCount64 - Started, '; final JPEG bytes=', Length(Jpeg));
  finally
    Encoder.Free;
  end;
end.

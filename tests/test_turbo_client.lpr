program test_turbo_client;
{$mode objfpc}{$H+}
uses SysUtils, Classes, kvm_turbojpeg_decode;

procedure Check(OK: Boolean; const Msg: string);
begin
  if not OK then begin WriteLn('FAILED: ',Msg); Halt(1); end;
end;

function Get32(const S: RawByteString; At: Integer): Cardinal;
begin
  Result := Byte(S[At+1]) or (Cardinal(Byte(S[At+2])) shl 8) or
    (Cardinal(Byte(S[At+3])) shl 16) or
    (Cardinal(Byte(S[At+4])) shl 24);
end;

var
  Jpeg, Bmp, Bgr: RawByteString;
  D: TKvmTurboJpegDecoder;
  F: TFileStream;
begin
  if ParamCount <> 1 then begin WriteLn('Usage: test_turbo_client sample.jpg'); Halt(2); end;
  F := TFileStream.Create(ParamStr(1), fmOpenRead or fmShareDenyNone);
  try
    SetLength(Jpeg, F.Size);
    if Length(Jpeg)>0 then F.ReadBuffer(Jpeg[1],Length(Jpeg));
  finally F.Free; end;
  D := TKvmTurboJpegDecoder.Create;
  try
    if not D.Available then begin WriteLn('SKIPPED: libturbojpeg missing'); Halt(2); end;
    Check(D.DecodeToBmp(Jpeg,5,3,Bmp), 'TurboJPEG decode 5x3');
    Check((Length(Bmp)=54+16*3) and (Bmp[1]='B') and (Bmp[2]='M'), 'BMP header');
    Check((Get32(Bmp,18)=5) and (Get32(Bmp,22)=3), 'BMP dimensions');
    // Bottom-up BGR: last source row is blue; first source row is red.
    Check((Byte(Bmp[55])>150) and (Byte(Bmp[57])<100), 'bottom row blue');
    Check((Byte(Bmp[87])<100) and (Byte(Bmp[89])>150), 'top row red');
    Check(not D.DecodeToBmp(Jpeg,6,3,Bmp), 'wrong expected dimensions rejected');
    Check(not D.DecodeToBmp('junk',5,3,Bmp), 'broken JPEG rejected');
    Check(D.DecodeToBgr(Jpeg,5,3,Bgr), 'direct BGR 5x3');
    Check(Length(Bgr)=16*3, 'direct BGR DWORD stride');
    // First BGR top row is red; last row is blue (unlike the BMP path).
    Check((Byte(Bgr[1])<100) and (Byte(Bgr[3])>150), 'top row red');
    Check((Byte(Bgr[33])>150) and (Byte(Bgr[35])<100), 'bottom row blue');
    Check(not D.DecodeToBgr(Jpeg,6,3,Bgr), 'direct BGR bad geometry rejected');
    Check(not D.DecodeToBgr('junk',5,3,Bgr), 'direct BGR malformed jpeg rejected');
    WriteLn('PASS: TurboJPEG client decode and BMP header');
  finally D.Free; end;
end.

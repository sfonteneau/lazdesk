unit kvm_jpeg_guard;
{$mode objfpc}{$H+}
interface
// Header sanity check before decoder allocation. Not a full JPEG validator.
// Our tjCompress2 encoder produces baseline 8-bit JPEG only.
function JpegMatchesSize(const Jpeg: RawByteString; W, H: Integer): Boolean;
implementation
function BE16(const S: RawByteString; P: Integer): Integer;
begin Result := (Ord(S[P]) shl 8) or Ord(S[P+1]); end;
function JpegMatchesSize(const Jpeg: RawByteString; W, H: Integer): Boolean;
var P, L, Marker, Components, ScanComponents: Integer; SeenSOF: Boolean;
begin
  Result := False; SeenSOF := False; Components := 0;
  if (W < 1) or (H < 1) or (Length(Jpeg) < 4) or
     (Jpeg[1] <> #$ff) or (Jpeg[2] <> #$d8) then Exit;
  P := 3;
  while P <= Length(Jpeg) do
  begin
    if Jpeg[P] <> #$ff then Exit;
    while (P <= Length(Jpeg)) and (Jpeg[P] = #$ff) do Inc(P);
    if P > Length(Jpeg) then Exit;
    Marker := Ord(Jpeg[P]); Inc(P);
    if Marker in [$00,$d8,$d9] then Exit;
    if Marker in [$01,$d0..$d7] then Continue;
    if P+1 > Length(Jpeg) then Exit;
    L := BE16(Jpeg, P);
    if (L < 2) or (L > Length(Jpeg) - P + 1) then Exit;
    if Marker in [$c0,$c1,$c2,$c3,$c5,$c6,$c7,$c9,$ca,$cb,$cd,$ce,$cf] then
    begin
      if SeenSOF or (Marker <> $c0) or (L < 8) then Exit;
      Components := Ord(Jpeg[P+7]);
      if not (Components in [1,3]) or (L <> 8 + 3*Components) or
         (Ord(Jpeg[P+2]) <> 8) or (BE16(Jpeg,P+3) <> H) or
         (BE16(Jpeg,P+5) <> W) then Exit;
      SeenSOF := True;
    end
    else if Marker = $da then
    begin
      if not SeenSOF or (L < 6) then Exit;
      ScanComponents := Ord(Jpeg[P+2]);
      Result := (ScanComponents = Components) and (L = 6 + 2*ScanComponents);
      Exit;
    end;
    Inc(P, L);
  end;
end;
end.

program test_frame;
{$mode objfpc}{$H+}
uses SysUtils, kvm_frame, kvm_damage;

procedure Check(Condition: Boolean; const Msg: string);
begin
  if not Condition then
  begin
    WriteLn('ERROR: ', Msg);
    Halt(1);
  end;
end;

var
  F, Prev: TRgbFrame;
  I, W, H: Integer;
  InitialPtr: Pointer;
  BGRA: array[0..23] of Byte;
begin
  F.Width := 0; F.Height := 0; F.RGB := '';
  Prev.Width := 0; Prev.Height := 0; Prev.RGB := '';
  Check(ScaledSize(3840, 2160, 1600, 1000, W, H), 'scale');
  Check((W = 1600) and (H = 900), 'aspect ratio');
  Check(AllocateFrame(F, 32, 32), 'allocate');
  InitialPtr := @F.RGB[1];
  Check(AllocateFrame(F, 32, 32), 'same geometry allocate');
  Check(InitialPtr = @F.RGB[1], 'capture buffer reused');
  for I := 1 to Length(F.RGB) do F.RGB[I] := #0;
  Check(RegionTileChanged(F, Prev, 0, 0, 32, 32), 'initial dirty');
  CopyFrameReuse(F, Prev);
  Check(not RegionTileChanged(F, Prev, 0, 0, 32, 32), 'unchanged');
  F.RGB[7] := #255;
  Check(RegionTileChanged(F, Prev, 0, 0, 32, 32), 'exact dirty pixel');
  CopyFrameReuse(F, Prev);
  Check(not RegionTileChanged(F, Prev, 0, 0, 32, 32), 'after commit');
  // 32-bit GDI DIB -> packed BGR24: strip alpha and row padding exactly.
  FillChar(BGRA, SizeOf(BGRA), $ee);
  BGRA[0]:=11; BGRA[1]:=22; BGRA[2]:=33; BGRA[3]:=44;
  BGRA[4]:=55; BGRA[5]:=66; BGRA[6]:=77; BGRA[7]:=88;
  BGRA[12]:=91; BGRA[13]:=92; BGRA[14]:=93; BGRA[15]:=94;
  BGRA[16]:=95; BGRA[17]:=96; BGRA[18]:=97; BGRA[19]:=98;
  Check(CopyBgraDib32(@BGRA[0],SizeOf(BGRA),12,2,2,F),'copy BGRA32 padded');
  Check((F.Width=2) and (F.Height=2) and (F.Order=kpoBGR), 'BGRA dimensions/order');
  Check((Length(F.RGB)=12) and (Ord(F.RGB[1])=11) and
    (Ord(F.RGB[2])=22) and (Ord(F.RGB[3])=33) and
    (Ord(F.RGB[4])=55) and (Ord(F.RGB[5])=66) and
    (Ord(F.RGB[6])=77) and (Ord(F.RGB[7])=91) and
    (Ord(F.RGB[9])=93) and (Ord(F.RGB[10])=95) and
    (Ord(F.RGB[12])=97), 'BGRA32 colors without alpha');
  Check(not CopyBgraDib32(@BGRA[0],19,12,2,2,F),'BGRA capacity bounds');
  Check(not CopyBgraDib32(@BGRA[0],24,7,2,2,F),'BGRA stride bounds');
  WriteLn('OK: RGB reuse, exact dirty comparison, resolution and BGRA32');
end.

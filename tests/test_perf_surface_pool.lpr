program test_perf_surface_pool;
{$mode objfpc}{$H+}
uses SysUtils, kvm_surface, kvm_surface_pool;
procedure Check(OK: Boolean; const Msg: string);
begin if not OK then raise Exception.Create(Msg); end;
function Checksum(const S: TKvmSurface): QWord;
var I: Integer;
begin
  Result:=0;
  for I:=1 to Length(S.Pixels) do Inc(Result,QWord(Ord(S.Pixels[I]))*QWord(I));
end;
procedure Change(var S: TKvmSurface; Pool: TKvmSurfacePool;
  X,Y,W,H: Integer; Value: Byte);
var Row,Col,At: Integer;
begin
  for Row:=Y to Y+H-1 do for Col:=X to X+W-1 do
  begin
    At:=(Row*S.Width+Col)*4+1;
    S.Pixels[At]:=AnsiChar(Value); S.Pixels[At+1]:=AnsiChar(Value);
    S.Pixels[At+2]:=AnsiChar(Value); S.Pixels[At+3]:=#255;
  end;
  Pool.MarkDirty(X,Y,W,H);
end;
var Pool: TKvmSurfacePool; Source,A,B,C,Cursor: TKvmSurface;
    Held: array[0..3] of TKvmSurface; Hash: array[0..3] of QWord;
    Copied,FirstHash: QWord; I,J,X,Y,W,H: Integer;
begin
  Pool:=TKvmSurfacePool.Create;
  try
    Check(AllocateSurface(Source,128,96),'allocate');
    FillChar(Source.Pixels[1],Length(Source.Pixels),0); Pool.Reset;
    Check(Pool.Snapshot(Source,A,Copied),'first snapshot');
    Check(Copied=QWord(Length(Source.Pixels)),'initial copy');
    Check(Pointer(A.Pixels)<>Pointer(Source.Pixels),'canonical buffer shared');
    FirstHash:=Checksum(A);
    Change(Source,Pool,3,5,1,1,31);
    Check(Pool.Snapshot(Source,B,Copied),'second snapshot');
    Check(Copied=QWord(Length(Source.Pixels)),'second slot initial copy');
    Check(Checksum(A)=FirstHash,'retained first snapshot changed');
    ClearSurface(A);
    Change(Source,Pool,11,7,1,1,43);
    Check(Pool.Snapshot(Source,C,Copied),'reuse first slot');
    Check(Copied=8,'two dirty pixels should copy eight bytes, not a framebuffer');
    Check(C.Pixels=Source.Pixels,'accumulated dirty spans lost');
    Check(Pool.Snapshot(Source,Cursor,Copied) and (Copied=0),'cursor copied pixels');
    Check(Pointer(Cursor.Pixels)=Pointer(C.Pixels),'cursor should share immutable image');
    Check(StringRefCount(Source.Pixels)=1,'canonical framebuffer not exclusive');
    // Both slots held: exercise safe fallback, then release and reuse again.
    FirstHash:=Checksum(B);
    Change(Source,Pool,9,10,2,2,77);
    Check(Pool.Snapshot(Source,A,Copied),'saturated pool');
    Check(Copied=QWord(Length(Source.Pixels)),'saturation fallback');
    Check(Checksum(B)=FirstHash,'fallback overwrote reader');
    Check(A.Pixels=Source.Pixels,'fallback incomplete');
    ClearSurface(A); ClearSurface(B); ClearSurface(C); ClearSurface(Cursor);
    RandSeed:=7123;
    for I:=1 to 2000 do
    begin
      X:=Random(Source.Width); Y:=Random(Source.Height);
      W:=1+Random(Source.Width-X); H:=1+Random(Source.Height-Y);
      Change(Source,Pool,X,Y,W,H,Random(256));
      ClearSurface(C);
      Check(Pool.Snapshot(Source,C,Copied),'random snapshot');
      Check(C.Pixels=Source.Pixels,'random delta lost');
      for J:=0 to High(Held) do
        if SurfaceValid(Held[J]) then
          Check(Checksum(Held[J])=Hash[J],'old immutable snapshot corrupted');
      J:=Random(Length(Held));
      if I mod 3=0 then ClearSurface(Held[J])
      else begin Held[J]:=C; Hash[J]:=Checksum(C); end;
    end;
    FirstHash:=Checksum(C);
    Pool.Reset;
    Check(AllocateSurface(Source,17,9),'new geometry');
    FillChar(Source.Pixels[1],Length(Source.Pixels),19);
    Pool.MarkDirty(0,0,17,9);
    Check(Pool.Snapshot(Source,A,Copied),'geometry snapshot');
    Check((A.Width=17) and (A.Height=9) and (A.Pixels=Source.Pixels),'geometry stale');
    Check(Checksum(C)=FirstHash,'reset invalidated retained image');
    ClearSurface(Source);
    Check(not Pool.Snapshot(Source,B,Copied),'invalid source accepted');
  finally Pool.Free; end;
  Check(SurfaceValid(C),'snapshot lifetime tied to pool');
  WriteLn('PASS: partial-copy bytes, immutable readers, saturation, 2000 delta frames and resize');
end.

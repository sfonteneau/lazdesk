program test_damage;
{$mode objfpc}{$H+}
uses SysUtils, kvm_wire, kvm_damage;

procedure Check(Condition: Boolean; const Msg: string);
begin
  if not Condition then
  begin
    WriteLn('ERROR: ', Msg);
    Halt(1);
  end;
end;

var
  Dirty: TKvmDirtyMap;
  Groups: TKvmGroupMap;
  Rectangles: TKvmRegions;
  I, Count: Integer;
begin
  SetLength(Dirty, 15); // 1080x600 => 5 columns x 3 rows
  SetLength(Groups, 15);
  for I := 0 to 14 do
  begin Dirty[I] := True; Groups[I] := I; end;
  Check(MakeDirtyRegions(Dirty, 5, 3, 1080, 600, Rectangles), 'valid geometry');
  Check(Length(Rectangles) = 6, 'six groups of at most 2x2 tiles');
  Check((Rectangles[0].X=0) and (Rectangles[0].Y=0) and
    (Rectangles[0].W=512) and (Rectangles[0].H=512), 'top-left 2x2');
  Check((Rectangles[1].X=512) and (Rectangles[1].W=512) and
    (Rectangles[1].H=512), 'top-middle 2x2');
  Check((Rectangles[2].X=1024) and (Rectangles[2].W=56) and
    (Rectangles[2].H=512), 'right edge');
  Check((Rectangles[3].X=0) and (Rectangles[3].W=512) and
    (Rectangles[3].H=88), 'bottom-left edge');
  Check((Rectangles[4].X=512) and (Rectangles[4].W=512) and
    (Rectangles[4].H=88), 'bottom-middle edge');
  Check((Rectangles[5].X=1024) and (Rectangles[5].W=56) and
    (Rectangles[5].H=88), 'corner edge');
  AssignRegionGroups(Rectangles, 5, Groups);
  Check((Groups[0]=0) and (Groups[1]=0) and
        (Groups[5]=0) and (Groups[6]=0), 'top-left group members');
  Check((Groups[4]=4) and (Groups[9]=4), 'right group members');
  for I := 0 to 14 do Dirty[I] := False;
  Dirty[6] := True; // one changed tile within an old 2x2 rectangle
  ExpandDirtyCacheGroups(Dirty, Groups);
  Count := 0;
  for I := 0 to 14 do if Dirty[I] then Inc(Count);
  Check(Count = 4, 'expand to all four tiles in cached rectangle');
  Check(MakeDirtyRegions(Dirty, 5, 3, 1080, 600, Rectangles), 'regroup');
  Check((Length(Rectangles)=1) and (Rectangles[0].Leader=0) and
    (Rectangles[0].W=512) and (Rectangles[0].H=512),
    'regrouping cannot overlap a stale cached rectangle');
  // Once an old 2x2 cache group is invalidated, a sparse update may split
  // the *whole* group into four independent tiles without stale overlaps.
  SetLength(Dirty, 16); SetLength(Groups, 16);
  for I := 0 to 15 do begin Dirty[I]:=True; Groups[I]:=I; end;
  Check(MakeDirtyRegions(Dirty,4,4,1024,1024,Rectangles), 'initial 2x2 groups');
  Check(Length(Rectangles)=4, 'initial 2x2 count');
  AssignRegionGroups(Rectangles,4,Groups);
  for I := 0 to 15 do Dirty[I] := False;
  Dirty[1] := True;
  ExpandDirtyCacheGroups(Dirty,Groups);
  Count := 0;
  for I := 0 to 15 do if Dirty[I] then Inc(Count);
  Check(Count=4, 'old group fully invalidated');
  Check(MakeDirtyRegions(Dirty,4,4,1024,1024,Rectangles,1), 'split group');
  Check(Length(Rectangles)=4, 'four independent tiles');
  for I := 0 to 3 do
    Check((Rectangles[I].W=256) and (Rectangles[I].H=256), 'fine 256x256');
  AssignRegionGroups(Rectangles,4,Groups);
  Check((Groups[0]=0) and (Groups[1]=1) and
    (Groups[4]=4) and (Groups[5]=5), 'four new leaders');
  for I := 0 to 15 do Dirty[I] := False;
  Dirty[1] := True;
  ExpandDirtyCacheGroups(Dirty,Groups);
  Count := 0;
  for I := 0 to 15 do if Dirty[I] then Inc(Count);
  Check(Count=1, 'subsequent sparse update touches only one tile');
  WriteLn('OK: 4:4:4 damage grouping, old-group expansion and safe splitting');
end.

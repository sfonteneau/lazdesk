program test_pipeline_copy;
{$mode objfpc}{$H+}
uses SysUtils, kvm_frame, kvm_damage;

procedure Check(OK: Boolean; const Msg: string);
begin
  if not OK then
  begin
    WriteLn('FAILED: ', Msg);
    Halt(1);
  end;
end;

var
  Source, Previous: TRgbFrame;
  Regions: TKvmRegions;
  OldAlias: RawByteString;
  X, Y, At: Integer;
  Thrown: Boolean;
begin
  Check(AllocateFrame(Source, 37, 19), 'allocate source');
  for At := 1 to Length(Source.RGB) do Source.RGB[At] := AnsiChar(At mod 251);
  SetLength(Regions, 1);
  Regions[0].X := 0; Regions[0].Y := 0;
  Regions[0].W := Source.Width; Regions[0].H := Source.Height;
  CopyFrameRegions(Source, Previous, Regions);
  Check(CompareMem(@Source.RGB[1], @Previous.RGB[1], Length(Source.RGB)),
    'initial snapshot copies complete source');

  // Change ONLY two disjoint areas; all other previous pixels must survive.
  for Y := 2 to 5 do for X := 3 to 11 do
  begin
    At := (Y * Source.Width + X) * 3 + 1;
    Source.RGB[At] := #255;
    Source.RGB[At+1] := #32;
    Source.RGB[At+2] := #1;
  end;
  for Y := 17 to 18 do for X := 34 to 36 do
  begin
    At := (Y * Source.Width + X) * 3 + 1;
    Source.RGB[At] := #2;
    Source.RGB[At+1] := #3;
    Source.RGB[At+2] := #4;
  end;
  SetLength(Regions, 2);
  Regions[0].X := 3; Regions[0].Y := 2;
  Regions[0].W := 9; Regions[0].H := 4;
  Regions[1].X := 34; Regions[1].Y := 17;
  Regions[1].W := 3; Regions[1].H := 2;
  OldAlias := Previous.RGB;
  CopyFrameRegions(Source, Previous, Regions);
  Check(CompareMem(@Source.RGB[1], @Previous.RGB[1], Length(Source.RGB)),
    'partial copy matches full snapshot');
  Check(OldAlias <> Previous.RGB, 'copy-on-write protects aliases');

  // Invalid regions must not corrupt the previous-frame reference.
  OldAlias := Previous.RGB;
  Regions[1].X := Source.Width - 1;
  Regions[1].W := 3;
  Thrown := False;
  try CopyFrameRegions(Source, Previous, Regions);
  except on E: Exception do Thrown := True; end;
  Check(Thrown, 'out of bounds rejected');
  Check(OldAlias = Previous.RGB, 'invalid copy leaves previous unchanged');
  WriteLn('PASS: partial reference-frame copy and alias protection');
end.

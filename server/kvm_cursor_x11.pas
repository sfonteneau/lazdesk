unit kvm_cursor_x11;
{$mode objfpc}{$H+}{$packrecords c}{$pointermath on}
interface
uses kvm_frame, kvm_monitors;
// Caller already owns the process-wide X11 lock.
function DrawX11Cursor(Display: Pointer; const Monitor: TKvmMonitor; var Frame: TRgbFrame): Boolean;
implementation
uses Dynlibs, ctypes, kvm_cursor, kvm_x11_api;
type
  PXFixesCursorImage = ^TXFixesCursorImage;
  TXFixesCursorImage = record
    X,Y: CShort; Width,Height,XHot,YHot: CUShort;
    Serial: CULong; Pixels: ^CULong;
    Atom: CULong; Name: PAnsiChar;
  end;
var
  Lib: TLibHandle = NilHandle;
  Tried: Boolean;
  GetCursor: function(D: Pointer): PXFixesCursorImage; cdecl;
  Query: function(D: Pointer; out EventBase, ErrorBase: CInt): CInt; cdecl;
  LastDisplay: Pointer = nil;
  HasXFixes: Boolean = False;
function DrawX11Cursor(Display: Pointer; const Monitor: TKvmMonitor; var Frame: TRgbFrame): Boolean;
var C: PXFixesCursorImage; Pixels: TKvmArgbPixels; I,E,R: Integer;
begin
  Result := False;
  if not Tried then
  begin
    Tried := True; Lib := LoadLibrary('libXfixes.so.3');
    if Lib <> NilHandle then
    begin
      Pointer(GetCursor) := GetProcedureAddress(Lib,'XFixesGetCursorImage');
      Pointer(Query) := GetProcedureAddress(Lib,'XFixesQueryExtension');
    end;
  end;
  if not Assigned(GetCursor) or not Assigned(Query) then Exit;
  if LastDisplay <> Display then
  begin
    LastDisplay := Display;
    HasXFixes := Query(Display,E,R) <> 0;
  end;
  if not HasXFixes then Exit;
  C := GetCursor(Display);
  if C = nil then Exit;
  try
    if (C^.Width = 0) or (C^.Height = 0) or (C^.Width > 512) or
       (C^.Height > 512) or (C^.Pixels = nil) then Exit;
    SetLength(Pixels,Integer(C^.Width)*C^.Height);
    for I := 0 to High(Pixels) do Pixels[I] := Cardinal(C^.Pixels[I] and $ffffffff);
    Result := CompositeCursor(Frame,Monitor.Bounds.W,Monitor.Bounds.H,
      C^.X-C^.XHot-Monitor.Bounds.X,C^.Y-C^.YHot-Monitor.Bounds.Y,
      C^.Width,C^.Height,Pixels);
  finally XFree(C); end;
end;
finalization if Lib <> NilHandle then UnloadLibrary(Lib);
end.

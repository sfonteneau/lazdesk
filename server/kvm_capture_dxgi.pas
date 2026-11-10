unit kvm_capture_dxgi;
{$mode objfpc}{$H+}
{$I ../shared/kvm_build.inc}
interface
uses kvm_frame;
function CheckDxgi(out Reason: string): Boolean;
function CaptureDxgi(MaxW, MaxH: Integer; var Frame: TRgbFrame): Boolean;
function DxgiCursorEmbedded: Boolean;
procedure CloseDxgi;
implementation
uses {$IFDEF KVM_STATIC_DXGI}kvm_dxgi_static,{$ENDIF} SysUtils, Dynlibs, ctypes, kvm_monitors;
var
  Lib: TLibHandle = NilHandle;
  Handle: Pointer = nil;
  Selected: QWord;
  SavedX, SavedY, SavedW, SavedH: Integer;
  RetryAfter: QWord;
  OpenNative: function(Monitor: PtrUInt; out H: Pointer; Error: PAnsiChar; Cap: CInt): CInt; cdecl;
  ReadNative: function(H: Pointer; RGB: Pointer; Cap: csize_t; W, Y: CInt;
    Error: PAnsiChar; ErrorCap: CInt): CInt; cdecl;
  CloseNative: procedure(H: Pointer); cdecl;
  CursorEmbeddedNative: function(H: Pointer): CInt; cdecl;
function CheckDxgi(out Reason: string): Boolean;
var Abi: function: CInt; cdecl;
begin
  Reason := ''; Result := False;
  {$IFDEF KVM_STANDALONE}
    {$IFDEF KVM_STATIC_DXGI}
    Abi:=@KvmDxgiAbi;
    OpenNative:=@KvmDxgiOpen; ReadNative:=@KvmDxgiRead; CloseNative:=@KvmDxgiClose;
    CursorEmbeddedNative:=@KvmDxgiCursorEmbedded;
    Result:=Abi()=3;
    if not Result then Reason:='Incompatible built-in DXGI ABI';
    Exit;
    {$ELSE}
    Reason:='DXGI is not included in this standalone profile. Rebuild with --with-dxgi or use --backend gdi.';
    Exit;
    {$ENDIF}
  {$ELSE}
  if Lib = NilHandle then
    Lib := LoadLibrary(ExtractFilePath(ExpandFileName(ParamStr(0))) + 'lazdesk_dxgi.dll');
  if Lib = NilHandle then begin Reason := 'lazdesk_dxgi.dll is missing: run native/windows/build.cmd'; Exit; end;
  Pointer(Abi) := GetProcedureAddress(Lib, 'kvm_dxgi_abi');
  if not Assigned(Abi) then begin Reason := 'DXGI bridge has no ABI version'; Exit; end;
  if Abi() <> 3 then begin Reason := 'Incompatible DXGI bridge (rebuild lazdesk_dxgi.dll)'; Exit; end;
  Pointer(OpenNative) := GetProcedureAddress(Lib, 'kvm_dxgi_open');
  Pointer(ReadNative) := GetProcedureAddress(Lib, 'kvm_dxgi_read');
  Pointer(CloseNative) := GetProcedureAddress(Lib, 'kvm_dxgi_close');
  Pointer(CursorEmbeddedNative) := GetProcedureAddress(Lib, 'kvm_dxgi_cursor_embedded');
  Result := Assigned(OpenNative) and Assigned(ReadNative) and Assigned(CloseNative) and
    Assigned(CursorEmbeddedNative);
  if not Result then Reason := 'Exports DXGI manquants';
  {$ENDIF}
end;
function DxgiCursorEmbedded: Boolean;
begin
  Result := (Handle <> nil) and Assigned(CursorEmbeddedNative);
  if Result then Result := CursorEmbeddedNative(Handle) <> 0;
end;
procedure CloseDxgi;
begin
  if (Handle <> nil) and Assigned(CloseNative) then CloseNative(Handle);
  Handle := nil;
end;
function CaptureDxgi(MaxW, MaxH: Integer; var Frame: TRgbFrame): Boolean;
var M: TKvmMonitor; W, H, Status: CInt; Err: array[0..511] of AnsiChar;
begin
  Result := False;
  if not Assigned(OpenNative) or (GetTickCount64 < RetryAfter) then Exit;
  if not RefreshMonitor then begin CloseDxgi; Exit; end;
  M := CaptureMonitor;
  if not ScaledSize(M.PixelW,M.PixelH,MaxW,MaxH,W,H) or not AllocateFrame(Frame,W,H) then Exit;
  if (Handle <> nil) and ((M.NativeID <> Selected) or (M.Bounds.X <> SavedX) or
    (M.Bounds.Y <> SavedY) or (M.PixelW <> SavedW) or (M.PixelH <> SavedH)) then CloseDxgi;
  FillChar(Err,SizeOf(Err),0);
  if Handle = nil then
  begin
    if OpenNative(PtrUInt(M.NativeID),Handle,@Err[0],SizeOf(Err)) <> 0 then
    begin RetryAfter := GetTickCount64 + 5000; WriteLn('[dxgi] ',PAnsiChar(@Err[0])); Exit; end;
    Selected := M.NativeID; SavedX := M.Bounds.X; SavedY := M.Bounds.Y;
    SavedW := M.PixelW; SavedH := M.PixelH;
  end;
  Status := ReadNative(Handle,@Frame.RGB[1],Length(Frame.RGB),W,H,@Err[0],SizeOf(Err));
  if Status < 0 then
  begin
    if Err[0] <> #0 then WriteLn('[dxgi] ',PAnsiChar(@Err[0]));
    CloseDxgi; RetryAfter := GetTickCount64 + 1000;
  end;
  Result := Status = 1;
end;
finalization
  // Stream closed by the capture worker; do not release D3D objects on another thread.
  if Lib <> NilHandle then UnloadLibrary(Lib);
end.

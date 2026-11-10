unit kvm_wayland;
{$mode objfpc}{$H+}
{$I ../shared/kvm_build.inc}
interface
uses kvm_frame;
function OpenWayland(Control: Boolean; FPS: Integer; out Reason: string): Boolean;
function CaptureWayland(MaxW, MaxH: Integer; var Frame: TRgbFrame): Boolean;
function WaylandAlive: Boolean;
procedure PauseWayland;
procedure CloseWayland;
procedure WaylandMouse(Action, Button: Byte; X, Y: Word);
procedure WaylandKey(Pressed: Boolean; VKey: Word);
procedure WaylandText(CodePoint: Cardinal);
procedure WaylandWheel(Notches: SmallInt);
implementation
uses {$IFDEF KVM_STATIC_PORTAL}kvm_portal_static,{$ENDIF} SysUtils, Dynlibs,
  ctypes, kvm_keysym, kvm_wire;
var
  Lib: TLibHandle = NilHandle;
  Handle: Pointer = nil;
  Active: Boolean;
  Buffer: RawByteString;
  NativeOpen: function(Control, FPS: CInt; out H: Pointer; Err: PAnsiChar; Cap: CInt): CInt; cdecl;
  NativeClose: procedure(H: Pointer); cdecl;
  NativeRead: function(H: Pointer; Dst: Pointer; Cap: csize_t; MaxW, MaxH: CInt;
    out W, Y: CInt; Err: PAnsiChar; ErrCap: CInt): CInt; cdecl;
  NativeAlive: function(H: Pointer): CInt; cdecl;
  NativeActive: procedure(H: Pointer; Enabled: CInt); cdecl;
  NativeMouse: function(H: Pointer; Action, Button: CInt; X, Y: Word): CInt; cdecl;
  NativeKey: function(H: Pointer; Sym: CUInt; Down: CInt): CInt; cdecl;
  NativeWheel: function(H: Pointer; Steps: CInt): CInt; cdecl;
function OpenWayland(Control: Boolean; FPS: Integer; out Reason: string): Boolean;
var Err: array[0..511] of AnsiChar;
  Abi: function: CInt; cdecl;
begin
  Reason := ''; Result := False;
  if Handle <> nil then Exit(True);
  {$IFDEF KVM_STANDALONE}
    {$IFDEF KVM_STATIC_PORTAL}
    Abi:=@KvmPortalAbi;
    if Abi()<>1 then begin Reason:='Incompatible built-in portal ABI'; Exit; end;
    NativeOpen:=@KvmPortalOpen; NativeClose:=@KvmPortalClose;
    NativeRead:=@KvmPortalRead; NativeAlive:=@KvmPortalAlive;
    NativeActive:=@KvmPortalActive; NativeMouse:=@KvmPortalMouse;
    NativeKey:=@KvmPortalKey; NativeWheel:=@KvmPortalWheel;
    {$ELSE}
    Reason:='Wayland is not included in this standalone profile. Rebuild with --with-portal; the default build targets X11.';
    Exit;
    {$ENDIF}
  {$ELSE}
  if Lib = NilHandle then
    Lib := LoadLibrary(ExtractFilePath(ExpandFileName(ParamStr(0))) + 'liblazdesk_portal.so');
  if Lib = NilHandle then
  begin Reason := 'Run native/linux/build.sh and place liblazdesk_portal.so next to the server.'; Exit; end;
  Pointer(Abi) := GetProcedureAddress(Lib, 'kvm_portal_abi');
  if not Assigned(Abi) then begin Reason := 'Portal bridge has no ABI version'; Exit; end;
  if Abi() <> 1 then begin Reason := 'Incompatible portal bridge ABI'; Exit; end;
  Pointer(NativeOpen) := GetProcedureAddress(Lib, 'kvm_portal_open');
  Pointer(NativeClose) := GetProcedureAddress(Lib, 'kvm_portal_close');
  Pointer(NativeRead) := GetProcedureAddress(Lib, 'kvm_portal_read');
  Pointer(NativeAlive) := GetProcedureAddress(Lib, 'kvm_portal_alive');
  Pointer(NativeActive) := GetProcedureAddress(Lib, 'kvm_portal_active');
  Pointer(NativeMouse) := GetProcedureAddress(Lib, 'kvm_portal_pointer');
  Pointer(NativeKey) := GetProcedureAddress(Lib, 'kvm_portal_key');
  Pointer(NativeWheel) := GetProcedureAddress(Lib, 'kvm_portal_wheel');
  if not Assigned(NativeOpen) or not Assigned(NativeClose) or not Assigned(NativeRead) or
     not Assigned(NativeAlive) or not Assigned(NativeActive) or not Assigned(NativeMouse) or
     not Assigned(NativeKey) or not Assigned(NativeWheel) then
  begin Reason := 'Incomplete portal bridge'; Exit; end;
  {$ENDIF}
  FillChar(Err, SizeOf(Err), 0);
  WriteLn('[portal] Allow screen sharing locally',
    ' and, if prompted, keyboard and mouse access. Timeout: 120 s per dialog.');
  Result := NativeOpen(Ord(Control), FPS, Handle, @Err[0], SizeOf(Err)) = 0;
  if not Result then Reason := string(PAnsiChar(@Err[0]));
  Active := Result;
  if Result then PauseWayland;
end;
function WaylandAlive: Boolean;
begin Result := (Handle <> nil) and Assigned(NativeAlive); if Result then Result := NativeAlive(Handle) <> 0; end;
procedure PauseWayland;
begin
  if Active and (Handle <> nil) and Assigned(NativeActive) then NativeActive(Handle, 0);
  Active := False;
end;
procedure CloseWayland;
begin
  if (Handle <> nil) and Assigned(NativeClose) then NativeClose(Handle);
  Handle := nil; Active := False; Buffer := '';
end;
function CaptureWayland(MaxW, MaxH: Integer; var Frame: TRgbFrame): Boolean;
var
  W, H, Status, Attempt: CInt;
  Err: array[0..511] of AnsiChar;
  Bytes: Int64;
begin
  Result := False;
  if not WaylandAlive then Exit;
  if (MaxW < 1) or (MaxH < 1) or
     (MaxW > KVM_MAX_FRAME_SIDE) or (MaxH > KVM_MAX_FRAME_SIDE) then Exit;
  // Native limits can be 32768x32768: never allocate their product upfront.
  // First read probes the actual PipeWire output size; -2 requests a resize.
  if Length(Buffer) = 0 then SetLength(Buffer, 1920 * 1080 * 3);
  if not Active then begin NativeActive(Handle, 1); Active := True; end;
  for Attempt := 0 to 2 do
  begin
    W := 0; H := 0;
    FillChar(Err, SizeOf(Err), 0);
    Status := NativeRead(Handle, @Buffer[1], Length(Buffer), MaxW, MaxH,
      W, H, @Err[0], SizeOf(Err));
    if Status = -2 then
    begin
      if (W < 1) or (H < 1) or (W > KVM_MAX_FRAME_SIDE) or
         (H > KVM_MAX_FRAME_SIDE) or
         (Int64(W) * H > KVM_MAX_FRAME_PIXELS) then
        raise Exception.Create('Portal/PipeWire: dimensions exceed limits');
      Bytes := Int64(W) * H * 3;
      if Bytes > Length(Buffer) then SetLength(Buffer, Bytes);
      Continue;
    end;
    // A paused or revoked portal is never reopened without local consent.
    if Status < 0 then
      raise Exception.Create('Portal/PipeWire: ' + string(PAnsiChar(@Err[0])));
    if (Status <> 1) or not AllocateFrame(Frame, W, H) then Exit;
    Move(Buffer[1], Frame.RGB[1], Length(Frame.RGB));
    Exit(True);
  end;
end;
procedure WaylandMouse(Action, Button: Byte; X, Y: Word);
begin
  if WaylandAlive and (NativeMouse(Handle, Action, Button, X, Y) = 0) then
    raise Exception.Create('Portal: mouse command rejected.');
end;
procedure WaylandKey(Pressed: Boolean; VKey: Word);
var Sym: Cardinal;
begin
  if (VKey = 0) or (VKey > 255) then
    raise Exception.Create('Portal: invalid keyboard key.');
  Sym := KvmKeysym(VKey);
  // NotifyKeyboardKeysym expects the logical XKB AltGr modifier, not Alt_R
  // (which may be absent or act as ordinary Alt in the remote layout).
  if VKey = $a5 then Sym := $fe03; // ISO_Level3_Shift
  if Sym = 0 then
    raise Exception.Create('Portal: key has no Wayland keysym mapping.');
  if not WaylandAlive then
    raise Exception.Create('Portal: keyboard session unavailable.');
  if NativeKey(Handle, Sym, Ord(Pressed)) = 0 then
    raise Exception.Create('Portal: keyboard command rejected.');
end;
procedure WaylandText(CodePoint: Cardinal);
var Sym: Cardinal;
begin
  if (CodePoint < 32) or (CodePoint > $10ffff) or
    ((CodePoint >= $d800) and (CodePoint <= $dfff)) or not WaylandAlive then Exit;
  if CodePoint <= $ff then Sym := CodePoint else Sym := $01000000 or CodePoint;
  if NativeKey(Handle, Sym, 1) = 0 then
    raise Exception.Create('Portal: character not accepted.');
  if NativeKey(Handle, Sym, 0) = 0 then
    raise Exception.Create('Portal: character key release rejected.');
end;
procedure WaylandWheel(Notches: SmallInt);
begin
  if WaylandAlive and (NativeWheel(Handle, Notches) = 0) then
    raise Exception.Create('Portal: mouse wheel command rejected.');
end;
finalization
  // TKvmServer is destroyed (network workers joined) before closing the portal.
  CloseWayland;
  if Lib <> NilHandle then UnloadLibrary(Lib);
end.

unit kvm_capture_mac;
{$mode objfpc}{$H+}
{$I ../shared/kvm_build.inc}
interface
uses kvm_frame;
function MacSessionState(out Identity: string): Integer;
function CaptureDesktopRgb(MaxW, MaxH: Integer; var Frame: TRgbFrame): Boolean;
function CheckMacCapture(out Reason: string): Boolean;
procedure CloseCapture;
procedure SetMacCaptureFPS(FPS: Integer);
function MacCaptureAvailable: Boolean;
implementation
uses {$IFDEF KVM_STANDALONE}kvm_sck_static,{$ENDIF} SysUtils, ctypes, Dynlibs, kvm_quartz_api, kvm_monitors;
var
  Lib: TLibHandle = NilHandle;
  Handle: Pointer = nil;
  SavedW, SavedH, SavedSourceW, SavedSourceH, SavedFPS: Integer;
  SavedDisplay: Cardinal;
  CaptureFPS: Integer = 10;
  OpenStream: function(Display: Cardinal; W, H, FPS: CInt; out Hnd: Pointer;
    Error: PAnsiChar; Capacity: CInt): CInt; cdecl;
  ReadStream: function(Hnd: Pointer; RGB: Pointer; Capacity: csize_t;
    W, H: CInt; Error: PAnsiChar; ErrorCapacity: CInt): CInt; cdecl;
  CloseStream: procedure(Hnd: Pointer); cdecl;
  Available: function(Hnd: Pointer): CInt; cdecl;
  ProbeSession: function(Identity: PAnsiChar; Capacity: CInt): CInt; cdecl;
function MacSessionState(out Identity: string): Integer;
var B: array[0..255] of AnsiChar;
begin
  Identity:=''; Result:=0;
  if not Assigned(ProbeSession) then Exit;
  FillChar(B,SizeOf(B),0); Result:=ProbeSession(@B[0],SizeOf(B));
  Identity:=string(PAnsiChar(@B[0]));
end;
function MacCaptureAvailable: Boolean;
begin Result := True; if Assigned(Available) then Result := Available(Handle) <> 0; end;
procedure SetMacCaptureFPS(FPS: Integer);
begin CaptureFPS := FPS; end;
function CheckMacCapture(out Reason: string): Boolean;
begin
  Reason := ''; Result := CGPreflightScreenCaptureAccess;
  if not Result then
  begin
    CGRequestScreenCaptureAccess;
    Reason := 'Autoriser Enregistrement de l ecran pour LazDeskServer puis relancer.';
    Exit;
  end;
  {$IFDEF KVM_STANDALONE}
  OpenStream:=@KvmSckOpen; ReadStream:=@KvmSckRead; CloseStream:=@KvmSckClose;
  Available:=@KvmSckAvailable; ProbeSession:=@KvmSckSession;
  Result:=True;
  {$ELSE}
  if Lib = NilHandle then
  begin
    // Load only beside the executable, never from the current directory.
    Lib := LoadLibrary(ExtractFilePath(ExpandFileName(ParamStr(0))) + 'liblazdesk_sck.dylib');
    if Lib <> NilHandle then
    begin
      Pointer(OpenStream) := GetProcedureAddress(Lib, 'kvm_sck_open');
      Pointer(ReadStream) := GetProcedureAddress(Lib, 'kvm_sck_read');
      Pointer(CloseStream) := GetProcedureAddress(Lib, 'kvm_sck_close');
      Pointer(Available) := GetProcedureAddress(Lib, 'kvm_sck_available');
      Pointer(ProbeSession) := GetProcedureAddress(Lib, 'kvm_sck_session');
    end;
  end;
  Result := (Lib <> NilHandle) and Assigned(OpenStream) and Assigned(ReadStream) and Assigned(CloseStream) and Assigned(Available) and Assigned(ProbeSession);
  if not Result then Reason := 'Compiler native/macos/build.sh (macOS 12.3+, Xcode), puis placer liblazdesk_sck.dylib a cote du serveur.';
  {$ENDIF}
end;
procedure CloseCapture;
begin
  if (Handle <> nil) and Assigned(CloseStream) then CloseStream(Handle);
  Handle := nil;
end;
function CaptureDesktopRgb(MaxW, MaxH: Integer; var Frame: TRgbFrame): Boolean;
var M: TKvmMonitor; W, H, Status: Integer; Err: array[0..511] of AnsiChar;
begin
  Result := False;
  if not RefreshMonitor then begin CloseCapture; Exit; end;
  M := CaptureMonitor;
  if not ScaledSize(M.PixelW, M.PixelH, MaxW, MaxH, W, H) then Exit;
  if not AllocateFrame(Frame, W, H) then Exit;
  if (Handle <> nil) and ((W <> SavedW) or (H <> SavedH) or
     (CaptureFPS <> SavedFPS) or (M.NativeID <> SavedDisplay) or (M.PixelW <> SavedSourceW) or (M.PixelH <> SavedSourceH)) then CloseCapture;
  FillChar(Err, SizeOf(Err), 0);
  if Handle = nil then
  begin
    if not Assigned(OpenStream) then Exit;
    if OpenStream(M.NativeID, W, H, CaptureFPS, Handle, @Err[0], SizeOf(Err)) <> 0 then
      raise Exception.Create('ScreenCaptureKit: ' + string(PAnsiChar(@Err[0])));
    SavedW := W; SavedH := H; SavedDisplay := M.NativeID;
    SavedSourceW := M.PixelW; SavedSourceH := M.PixelH; SavedFPS := CaptureFPS;
  end;
  Status := ReadStream(Handle, @Frame.RGB[1], Length(Frame.RGB), W, H, @Err[0], SizeOf(Err));
  if Status = -2 then Exit(False); // keep stream alive until local session resumes
  if Status < 0 then
  begin
    CloseCapture;
    raise Exception.Create('ScreenCaptureKit: ' + string(PAnsiChar(@Err[0])));
  end;
  Result := Status = 1;
end;
finalization
  // The capture thread closes its stream before exiting.
  if Lib <> NilHandle then UnloadLibrary(Lib);
end.

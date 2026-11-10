unit kvm_capture_x11;
{$mode objfpc}{$H+}{$pointermath on}
interface
uses kvm_frame;
function CaptureDesktopRgb(MaxW, MaxH: Integer; var Frame: TRgbFrame): Boolean;
function CheckX11Display(out Reason: string): Boolean;
procedure CloseCapture;
function CursorEmbedded: Boolean;
implementation
uses SysUtils, ctypes, kvm_x11_api, kvm_x11_session, kvm_monitors, kvm_cursor_x11;
const ZPixmap = 2; IPC_CREAT = 512; IPC_RMID = 0; OWNER_RW = 384;
var
  Image: PXImage = nil;
  Shared: TXShmInfo;
  Attached, Marked: Boolean;
  ImageW, ImageH: Integer;
  ScaleMap: TKvmScaleMap;
  TrapError: Boolean;
  Embedded: Boolean;
function CursorEmbedded: Boolean;
begin Result := Embedded; end;

function CaptureError(D, E: Pointer): CInt; cdecl;
begin TrapError := True; Result := 0; end;

procedure DropImage(D: Pointer);
begin
  if Attached then begin XShmDetach(D, Shared); XSync(D, 0); end;
  if Image <> nil then
  begin
    // XDestroyImage must NOT free an shmat() address with libc free().
    if Shared.shmaddr <> nil then Image^.data := nil;
    XDestroyImage(Image); Image := nil;
  end;
  if Shared.shmaddr <> nil then shmdt(Shared.shmaddr);
  if (Shared.shmid >= 0) and not Marked then shmctl(Shared.shmid, IPC_RMID, nil);
  FillChar(Shared, SizeOf(Shared), 0); Shared.shmid := -1;
  Attached := False; Marked := False; ImageW := 0; ImageH := 0;
end;
procedure CloseCapture;
var D: Pointer;
begin
  D := LockX11;
  try if D <> nil then DropImage(D); finally UnlockX11; end;
end;
function CheckX11Display(out Reason: string): Boolean;
var D: Pointer;
begin
  Reason := '';
  if LowerCase(GetEnvironmentVariable('XDG_SESSION_TYPE')) = 'wayland' then
  begin Reason := 'Wayland capture is unavailable: use an Xorg/X11 session.';
    Exit(False); end;
  if GetEnvironmentVariable('DISPLAY') = '' then
  begin Reason := 'DISPLAY is unset: run from the X11 graphical session.';
    Exit(False); end;
  D := LockX11;
  try
    Result := D <> nil;
    if not Result then Reason := 'XOpenDisplay failed: DISPLAY/XAUTHORITY.';
  finally UnlockX11; end;
end;
function NewImage(D: Pointer; Screen, W, H, X, Y: Integer): Boolean;
var OldHandler: TXErrorHandler; Size: QWord;
begin
  Result := False; DropImage(D);
  if (W < 1) or (H < 1) or (QWord(W) * QWord(H) * 4 > 128 * 1024 * 1024) then Exit;
  if XShmQueryExtension(D) <> 0 then
  begin
    Image := XShmCreateImage(D, XDefaultVisual(D, Screen),
      XDefaultDepth(D, Screen), ZPixmap, nil, Shared, W, H);
    if Image <> nil then
    begin
      Size := QWord(Image^.bytes_per_line) * QWord(H);
      if (Image^.bytes_per_line > 0) and (Size <= 128 * 1024 * 1024) then
        Shared.shmid := shmget(0, Size, IPC_CREAT or OWNER_RW);
      if Shared.shmid >= 0 then
      begin
        Shared.shmaddr := shmat(Shared.shmid, nil, 0);
        if Shared.shmaddr = Pointer(PtrInt(-1)) then Shared.shmaddr := nil;
        if Shared.shmaddr <> nil then
        begin
          Image^.data := Shared.shmaddr; Shared.readOnly := 0;
          // Trap asynchronous BadAccess (remote X server / container IPC).
          // All Xlib use in this console server holds the same global lock.
          XSync(D, 0); TrapError := False;
          OldHandler := XSetErrorHandler(@CaptureError);
          try
            Attached := XShmAttach(D, Shared) <> 0;
            XSync(D, 0); Attached := Attached and not TrapError;
          finally XSetErrorHandler(OldHandler); end;
          if Attached then
            Marked := shmctl(Shared.shmid, IPC_RMID, nil) = 0;
        end;
      end;
    end;
  end;
  if not Attached then
  begin
    DropImage(D);
    XSync(D, 0); TrapError := False;
    OldHandler := XSetErrorHandler(@CaptureError);
    try
      Image := XGetImage(D, XRootWindow(D, Screen), X, Y, W, H,
        not CULong(0), ZPixmap);
      XSync(D, 0);
    finally XSetErrorHandler(OldHandler); end;
    if TrapError then begin DropImage(D); Exit; end;
  end;
  Result := Image <> nil;
  if Result then begin ImageW := W; ImageH := H; end;
end;
function ExtractChannel(Pixel, Mask: CULong): Byte;
var Shift: Integer; MaxComponent: CULong;
begin
  Result := 0; if Mask = 0 then Exit; Shift := 0;
  while ((Mask shr Shift) and 1) = 0 do Inc(Shift);
  MaxComponent := Mask shr Shift;
  Result := Byte((QWord((Pixel and Mask) shr Shift) * 255 +
    (MaxComponent div 2)) div MaxComponent);
end;
function ReadPixel(Img: PXImage; X, Y: Integer): CULong;
var N, I: Integer; P: PByte;
begin
  Result := 0; N := Img^.bits_per_pixel div 8;
  if not (Img^.bits_per_pixel in [16, 24, 32]) then Exit(XGetPixel(Img, X, Y));
  P := PByte(PtrUInt(Img^.data) + PtrUInt(Y) * PtrUInt(Img^.bytes_per_line) +
    PtrUInt(X) * PtrUInt(N));
  if Img^.byte_order = 0 then
    for I := 0 to N-1 do Result := Result or (CULong(P[I]) shl (I*8))
  else for I := 0 to N-1 do Result := (Result shl 8) or P[I];
end;
function CaptureDesktopRgb(MaxW, MaxH: Integer; var Frame: TRgbFrame): Boolean;
var
  D: Pointer; M: TKvmMonitor;
  Screen, W, H, X, Y, SX, SY, At: Integer;
  Pixel: CULong; P, SrcLine, DstLine: PByte; Fast: Boolean;
  OldHandler: TXErrorHandler;
begin
  Result := False;
  if not RefreshMonitor then Exit;
  M := CaptureMonitor;
  if not ScaledSize(M.Bounds.W, M.Bounds.H, MaxW, MaxH, W, H) then Exit;
  D := LockX11;
  try
    if D = nil then Exit;
    Screen := XDefaultScreen(D);
    if (Image = nil) or (ImageW <> M.Bounds.W) or (ImageH <> M.Bounds.H) then
      if not NewImage(D, Screen, M.Bounds.W, M.Bounds.H, M.Bounds.X, M.Bounds.Y) then Exit;
    // A pre-capture XSync adds an avoidable X11 roundtrip.
    // The post-capture sync below is kept for error detection.
    TrapError := False;
    OldHandler := XSetErrorHandler(@CaptureError);
    try
      if Attached then
        Result := XShmGetImage(D, XRootWindow(D, Screen), Image,
          M.Bounds.X, M.Bounds.Y, not CULong(0)) <> 0
      else
        Result := XGetSubImage(D, XRootWindow(D, Screen), M.Bounds.X,
          M.Bounds.Y, M.Bounds.W, M.Bounds.H, not CULong(0), ZPixmap,
          Image, 0, 0) <> nil;
      XSync(D, 0); Result := Result and not TrapError;
    finally XSetErrorHandler(OldHandler); end;
    if not Result then begin DropImage(D); Exit; end;
    Result := False;
    if (Image^.data = nil) or (Image^.bytes_per_line <= 0) then Exit;
    if not AllocateFrame(Frame, W, H) then Exit;
    Fast := (Image^.bits_per_pixel = 32) and (Image^.byte_order = 0) and
      (Image^.red_mask = $ff0000) and (Image^.green_mask = $00ff00) and
      (Image^.blue_mask = $0000ff);
    // Most desktop sessions capture at native resolution. Avoid millions
    // of 64-bit scaling divisions on this common BGRA/X11 path.
    if Fast and (W = M.Bounds.W) and (H = M.Bounds.H) and
       (Image^.bytes_per_line >= W * 4) then
    begin
      for Y := 0 to H - 1 do
      begin
        SrcLine := PByte(PtrUInt(Image^.data) + PtrUInt(Y) * PtrUInt(Image^.bytes_per_line));
        DstLine := PByte(@Frame.RGB[Y * W * 3 + 1]);
        for X := 0 to W - 1 do
        begin
          DstLine[0] := SrcLine[2];
          DstLine[1] := SrcLine[1];
          DstLine[2] := SrcLine[0];
          Inc(SrcLine, 4);
          Inc(DstLine, 3);
        end;
      end;
    end
    else
    begin
      if not PrepareScaleMap(M.Bounds.W,M.Bounds.H,W,H,ScaleMap) then Exit;
      for Y := 0 to H-1 do
      begin
        SY := ScaleMap.Y[Y];
        for X := 0 to W-1 do
        begin
          SX := ScaleMap.X[X]; At := (Y*W + X)*3 + 1;
          if Fast then
          begin
            P := PByte(PtrUInt(Image^.data) + PtrUInt(SY) * PtrUInt(Image^.bytes_per_line) + PtrUInt(SX)*4);
            Frame.RGB[At] := AnsiChar(P[2]); Frame.RGB[At+1] := AnsiChar(P[1]);
            Frame.RGB[At+2] := AnsiChar(P[0]);
          end
          else
          begin
            Pixel := ReadPixel(Image, SX, SY);
            Frame.RGB[At] := AnsiChar(ExtractChannel(Pixel, Image^.red_mask));
            Frame.RGB[At+1] := AnsiChar(ExtractChannel(Pixel, Image^.green_mask));
            Frame.RGB[At+2] := AnsiChar(ExtractChannel(Pixel, Image^.blue_mask));
          end;
        end;
      end;
    end;
    Embedded := DrawX11Cursor(D, M, Frame);
    Result := True;
  finally UnlockX11; end;
end;
initialization Shared.shmid := -1;
end.

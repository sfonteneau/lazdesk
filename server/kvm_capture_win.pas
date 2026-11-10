unit kvm_capture_win;
{$mode objfpc}{$H+}{$pointermath on}
interface
uses Windows, kvm_frame;
function CaptureDesktopRgb(MaxW, MaxH: Integer; var Frame: TRgbFrame): Boolean;
procedure CloseCapture;
implementation
uses kvm_monitors, kvm_wire, SysUtils, Math;
const CAPTUREBLT_FLAG = $40000000;
var
  ScreenDC, MemDC: HDC;
  DIB: HBITMAP;
  OldObj: HGDIOBJ;
  Bits: Pointer;
  BufferW, BufferH, BufferStride: Integer;
  SettingsRead: Boolean = False;
  Use32BitDib, UseCaptureBlt, FastScale: Boolean;
// Environment options are read once by the single capture worker.
// CAPTUREBLT can make the REAL local Windows pointer blink while capturing.
// Use SRCCOPY alone by default. Layered windows can still be captured by
// explicitly opting in via LAZDESK_GDI_CAPTUREBLT=1, if needed.
procedure ReadCaptureSettings;
begin
  if SettingsRead then Exit;
  Use32BitDib := GetEnvironmentVariable('LAZDESK_GDI_32BIT') = '1';
  UseCaptureBlt := GetEnvironmentVariable('LAZDESK_GDI_CAPTUREBLT') = '1';
  FastScale := GetEnvironmentVariable('LAZDESK_GDI_FAST_SCALE') = '1';
  SettingsRead := True;
end;
// Called only by the capture worker, including destruction. A GetDC handle
// must be released on the thread which acquired it.
procedure CloseCapture;
begin
  if (OldObj <> 0) and (MemDC <> 0) then SelectObject(MemDC, OldObj);
  if DIB <> 0 then DeleteObject(DIB);
  if MemDC <> 0 then DeleteDC(MemDC);
  if ScreenDC <> 0 then ReleaseDC(0, ScreenDC);
  ScreenDC := 0; MemDC := 0; DIB := 0; OldObj := 0; Bits := nil;
  BufferW := 0; BufferH := 0; BufferStride := 0;
end;
function EnsureBuffer(W, H: Integer): Boolean;
var BI: TBitmapInfo;
begin
  ReadCaptureSettings;
  if (DIB <> 0) and (W = BufferW) and (H = BufferH) then Exit(True);
  CloseCapture; Result := False;
  ScreenDC := GetDC(0); if ScreenDC = 0 then Exit;
  MemDC := CreateCompatibleDC(ScreenDC); if MemDC = 0 then Exit;
  FillChar(BI, SizeOf(BI), 0);
  BI.bmiHeader.biSize := SizeOf(TBitmapInfoHeader);
  BI.bmiHeader.biWidth := W; BI.bmiHeader.biHeight := -H;
  BI.bmiHeader.biPlanes := 1;
  if Use32BitDib then BI.bmiHeader.biBitCount := 32
  else BI.bmiHeader.biBitCount := 24;
  BI.bmiHeader.biCompression := BI_RGB;
  DIB := CreateDIBSection(ScreenDC, BI, DIB_RGB_COLORS, Bits, 0, 0);
  if (DIB = 0) or (Bits = nil) then Exit;
  OldObj := SelectObject(MemDC, DIB);
  if (OldObj=0) or (PtrUInt(OldObj)=High(PtrUInt)) then
  begin OldObj:=0; Exit; end;
  if FastScale then SetStretchBltMode(MemDC, COLORONCOLOR)
  else begin
    SetStretchBltMode(MemDC, HALFTONE);
    SetBrushOrgEx(MemDC, 0, 0, nil);
  end;
  BufferW := W; BufferH := H;
  if Use32BitDib then BufferStride := W * 4
  else BufferStride := (W * 3 + 3) and not 3;
  Result := True;
end;
function CaptureDesktopRgb(MaxW, MaxH: Integer; var Frame: TRgbFrame): Boolean;
var M: TKvmMonitor; W, H: Integer; Rop: DWORD;
begin
  Result := False;
  if not RefreshMonitor then Exit;
  M := CaptureMonitor;
  if not ScaledSize(M.Bounds.W, M.Bounds.H, MaxW, MaxH, W, H) then
    raise Exception.CreateFmt(
      'Desktop %dx%d exceeds capture limits (%d px per side / %d pixels total). '
      + 'Rebuild for x64 or explicitly lower --max-width/--max-height.',
      [M.Bounds.W, M.Bounds.H, KVM_MAX_FRAME_SIDE, KVM_MAX_FRAME_PIXELS]);
  if not EnsureBuffer(W, H) then begin CloseCapture; Exit; end;
  Rop := SRCCOPY;
  if UseCaptureBlt then Rop := Rop or CAPTUREBLT_FLAG;
  if (W = M.Bounds.W) and (H = M.Bounds.H) then
    Result := BitBlt(MemDC, 0, 0, W, H, ScreenDC, M.Bounds.X, M.Bounds.Y,
      Rop)
  else
    Result := StretchBlt(MemDC, 0, 0, W, H, ScreenDC, M.Bounds.X, M.Bounds.Y,
      M.Bounds.W, M.Bounds.H, Rop);
  if not Result then begin CloseCapture; Exit; end;
  // Flush BitBlt before reading the DIB. The pointer is transmitted through
  // the dedicated cursor message instead of being burned into every frame.
  if not GdiFlush then begin CloseCapture; Exit(False); end;
  // Native BGR24 stays BGR through damage detection and TurboJPEG. No
  // per-pixel channel swap; only row padding is removed by bounded copies.
  if Use32BitDib then
    Result := CopyBgraDib32(Bits, SizeUInt(BufferStride) * SizeUInt(H),
      BufferStride, W, H, Frame)
  else
    Result := CopyBgrDib24(Bits, SizeUInt(BufferStride) * SizeUInt(H),
      BufferStride, W, H, Frame);
end;
end.

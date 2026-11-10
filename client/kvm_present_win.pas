unit kvm_present_win;
{$mode objfpc}{$H+}
interface
uses Windows, Types, Forms, Controls, kvm_surface, kvm_wire;

type
  // UI-thread owned persistent 32-bit top-down DIB. Incoming snapshots update
  // only their dirty source rectangle; paints then BitBlt/StretchBlt from this
  // stable buffer, so GDI never references a released worker snapshot.
  TKvmWinPresenter = class
  private
    FDC: HDC;
    FBitmap: HBITMAP;
    FOld: HGDIOBJ;
    FBits: Pointer;
    FWidth, FHeight, FStride: Integer;
    FCursorDC: HDC;
    FCursorBitmap: HBITMAP;
    FCursorOld: HGDIOBJ;
    FCursorBits: Pointer;
    FCursorWidth, FCursorHeight, FCursorStride: Integer;
    FCursorHotX, FCursorHotY: Integer;
    FCursorRevision: Cardinal;
    function EnsureSize(W,H: Integer): Boolean;
    function EnsureCursorSize(W,H: Integer): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Reset;
    function Update(const S: TKvmSurface; const Damage: TRect): Boolean;
    function Paint(DC: HDC; X,Y,W,H: Integer): Boolean;
    function PaintRegion(DC: HDC; DX,DY,DW,DH,SX,SY,SW,SH: Integer): Boolean;
    procedure ClearCursor;
    function UpdateCursor(const Shape: TKvmCursorShape): Boolean;
    function PaintCursor(DC: HDC; HotX,HotY,DestW,DestH: Integer): Boolean;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
    property CursorRevision: Cardinal read FCursorRevision;
  end;

// Install the native remote cursor shape as the local Windows/LCL cursor.
// The OS draws it at the local pointer position with no framebuffer repaint.
// Screen owns the registered cursor handle afterwards.
function InstallLocalNativeCursor(CursorID: TCursor; const Shape: TKvmCursorShape): Boolean;

// Windows can report a work area that still includes an auto-hidden taskbar.
// Reserve the actual Shell_TrayWnd / Shell_SecondaryTrayWnd thickness so a
// windowed multi-monitor view never ends up behind the local taskbar.
function KvmSafeMonitorWorkRect(const BoundsRect, WorkAreaRect: Types.TRect): Types.TRect;

// Legacy helper retained for tests/fallbacks. New GUI code uses TKvmWinPresenter.
function PaintWindowsSurface(DC: HDC; const S: TKvmSurface;
  X,Y,W,H: Integer): Boolean;

implementation

var
  LocalNativeCursorID: TCursor = 0;
  LocalNativeCursorRevision: Cardinal = 0;

function KvmCreateIconIndirect(var Info: TIconInfo): HICON; stdcall;
  external 'user32.dll' name 'CreateIconIndirect';
function KvmFindWindowA(ClassName, WindowName: PAnsiChar): HWND; stdcall;
  external 'user32.dll' name 'FindWindowA';
function KvmFindWindowExA(Parent, ChildAfter: HWND; ClassName, WindowName: PAnsiChar): HWND; stdcall;
  external 'user32.dll' name 'FindWindowExA';
function KvmGetWindowRect(Wnd: HWND; var R: Types.TRect): BOOL; stdcall;
  external 'user32.dll' name 'GetWindowRect';

procedure ApplyTaskbarReservation(var Safe: Types.TRect; const BoundsRect, TaskRect: Types.TRect);
var
  BW,BH,TW,TH,Overlap,Thickness,DistA,DistB,NearLimit: Integer;
begin
  BW:=BoundsRect.Right-BoundsRect.Left;
  BH:=BoundsRect.Bottom-BoundsRect.Top;
  TW:=TaskRect.Right-TaskRect.Left;
  TH:=TaskRect.Bottom-TaskRect.Top;
  if (BW<1) or (BH<1) or (TW<1) or (TH<1) then Exit;

  if TW>=TH then
  begin
    Overlap:=TaskRect.Right;
    if Overlap>BoundsRect.Right then Overlap:=BoundsRect.Right;
    if TaskRect.Left>BoundsRect.Left then Dec(Overlap,TaskRect.Left)
    else Dec(Overlap,BoundsRect.Left);
    if (Overlap<=0) or (Int64(Overlap)*2<Int64(BW)) then Exit;
    Thickness:=TH;
    if Thickness>BH div 3 then Exit;
    DistA:=Abs(TaskRect.Top-BoundsRect.Top);
    DistB:=Abs(TaskRect.Bottom-BoundsRect.Bottom);
    NearLimit:=Thickness*2; if NearLimit<8 then NearLimit:=8;
    if (DistA>NearLimit) and (DistB>NearLimit) then Exit;
    if DistA<=DistB then
    begin
      if Safe.Top<BoundsRect.Top+Thickness then Safe.Top:=BoundsRect.Top+Thickness;
    end
    else
    begin
      if Safe.Bottom>BoundsRect.Bottom-Thickness then Safe.Bottom:=BoundsRect.Bottom-Thickness;
    end;
  end
  else
  begin
    Overlap:=TaskRect.Bottom;
    if Overlap>BoundsRect.Bottom then Overlap:=BoundsRect.Bottom;
    if TaskRect.Top>BoundsRect.Top then Dec(Overlap,TaskRect.Top)
    else Dec(Overlap,BoundsRect.Top);
    if (Overlap<=0) or (Int64(Overlap)*2<Int64(BH)) then Exit;
    Thickness:=TW;
    if Thickness>BW div 3 then Exit;
    DistA:=Abs(TaskRect.Left-BoundsRect.Left);
    DistB:=Abs(TaskRect.Right-BoundsRect.Right);
    NearLimit:=Thickness*2; if NearLimit<8 then NearLimit:=8;
    if (DistA>NearLimit) and (DistB>NearLimit) then Exit;
    if DistA<=DistB then
    begin
      if Safe.Left<BoundsRect.Left+Thickness then Safe.Left:=BoundsRect.Left+Thickness;
    end
    else
    begin
      if Safe.Right>BoundsRect.Right-Thickness then Safe.Right:=BoundsRect.Right-Thickness;
    end;
  end;
end;

function KvmSafeMonitorWorkRect(const BoundsRect, WorkAreaRect: Types.TRect): Types.TRect;
var
  W: HWND;
  R: Types.TRect;
  PrimaryClass, SecondaryClass: AnsiString;
begin
  Result:=WorkAreaRect;
  PrimaryClass:='Shell_TrayWnd';
  SecondaryClass:='Shell_SecondaryTrayWnd';

  W:=KvmFindWindowA(PAnsiChar(PrimaryClass),nil);
  if (W<>0) and KvmGetWindowRect(W,R) then
    ApplyTaskbarReservation(Result,BoundsRect,R);

  W:=0;
  repeat
    W:=KvmFindWindowExA(0,W,PAnsiChar(SecondaryClass),nil);
    if W<>0 then
    begin
      if KvmGetWindowRect(W,R) then
        ApplyTaskbarReservation(Result,BoundsRect,R);
    end;
  until W=0;

  if Result.Left<BoundsRect.Left then Result.Left:=BoundsRect.Left;
  if Result.Top<BoundsRect.Top then Result.Top:=BoundsRect.Top;
  if Result.Right>BoundsRect.Right then Result.Right:=BoundsRect.Right;
  if Result.Bottom>BoundsRect.Bottom then Result.Bottom:=BoundsRect.Bottom;
  if Result.Right<=Result.Left then Result:=WorkAreaRect;
  if Result.Bottom<=Result.Top then Result:=WorkAreaRect;
end;

function InstallLocalNativeCursor(CursorID: TCursor; const Shape: TKvmCursorShape): Boolean;
var
  BI: TBitmapInfo;
  Info: TIconInfo;
  DC: HDC;
  ColorBitmap, MaskBitmap: HBITMAP;
  Bits: Pointer;
  Mask: RawByteString;
  MaskStride, X, Y, At, PixelAt: Integer;
  BitMask: Byte;
  H: HICON;
begin
  Result:=False;
  if (CursorID=0) or (Shape.Revision=0) or (Shape.Width<1) or (Shape.Height<1) or
     (Shape.Width>KVM_MAX_CURSOR_SIDE) or (Shape.Height>KVM_MAX_CURSOR_SIDE) or
     (Length(Shape.Pixels)<>Integer(Shape.Width)*Integer(Shape.Height)*4) then Exit;
  if (CursorID=LocalNativeCursorID) and
     (Shape.Revision=LocalNativeCursorRevision) then Exit(True);

  FillChar(BI,SizeOf(BI),0);
  BI.bmiHeader.biSize:=SizeOf(TBitmapInfoHeader);
  BI.bmiHeader.biWidth:=Shape.Width;
  BI.bmiHeader.biHeight:=-Integer(Shape.Height);
  BI.bmiHeader.biPlanes:=1;
  BI.bmiHeader.biBitCount:=32;
  BI.bmiHeader.biCompression:=BI_RGB;
  Bits:=nil;
  DC:=GetDC(0);
  if DC=0 then Exit;
  try
    ColorBitmap:=CreateDIBSection(DC,BI,DIB_RGB_COLORS,Bits,0,0);
  finally
    ReleaseDC(0,DC);
  end;
  if (ColorBitmap=0) or (Bits=nil) then
  begin
    if ColorBitmap<>0 then DeleteObject(ColorBitmap);
    Exit;
  end;
  Move(Shape.Pixels[1],Bits^,Length(Shape.Pixels));

  // AND mask fallback for systems/paths that do not honor 32-bit alpha.
  // 1 = transparent, 0 = use the color bitmap.
  MaskStride:=((Integer(Shape.Width)+15) div 16)*2;
  SetLength(Mask,MaskStride*Integer(Shape.Height));
  FillChar(Mask[1],Length(Mask),$ff);
  for Y:=0 to Integer(Shape.Height)-1 do
    for X:=0 to Integer(Shape.Width)-1 do
    begin
      PixelAt:=(Y*Integer(Shape.Width)+X)*4+4; // alpha, RawByteString is 1-based
      if Ord(Shape.Pixels[PixelAt])=0 then Continue;
      At:=Y*MaskStride+(X div 8)+1;
      BitMask:=Byte($80 shr (X and 7));
      Mask[At]:=AnsiChar(Ord(Mask[At]) and (255-Integer(BitMask)));
    end;
  MaskBitmap:=CreateBitmap(Shape.Width,Shape.Height,1,1,@Mask[1]);
  if MaskBitmap=0 then
  begin
    DeleteObject(ColorBitmap);
    Exit;
  end;
  try
    FillChar(Info,SizeOf(Info),0);
    Info.fIcon:=False;
    Info.xHotspot:=Shape.HotX;
    Info.yHotspot:=Shape.HotY;
    Info.hbmMask:=MaskBitmap;
    Info.hbmColor:=ColorBitmap;
    H:=KvmCreateIconIndirect(Info);
  finally
    DeleteObject(MaskBitmap);
    DeleteObject(ColorBitmap);
  end;
  if H=0 then Exit;
  Screen.Cursors[CursorID]:=HCURSOR(H);
  LocalNativeCursorID:=CursorID;
  LocalNativeCursorRevision:=Shape.Revision;
  Result:=True;
end;

// Explicit Win32 ABI avoids pointer/var overload differences between RTLs.
function KvmStretchDIBits(DC: HDC; X,Y,W,H,SX,SY,SW,SH: LongInt;
  Pixels, Info: Pointer; Usage,Rop: DWORD): LongInt; stdcall;
  external 'gdi32.dll' name 'StretchDIBits';

function KvmAlphaBlend(DestDC: HDC; X,Y,W,H: LongInt; SrcDC: HDC;
  SX,SY,SW,SH: LongInt; Blend: DWORD): LongBool; stdcall;
  external 'msimg32.dll' name 'AlphaBlend';

constructor TKvmWinPresenter.Create;
begin
  inherited Create;
  FDC:=CreateCompatibleDC(0);
  FCursorDC:=CreateCompatibleDC(0);
end;

destructor TKvmWinPresenter.Destroy;
begin
  Reset;
  ClearCursor;
  if FDC<>0 then DeleteDC(FDC);
  if FCursorDC<>0 then DeleteDC(FCursorDC);
  inherited Destroy;
end;

procedure TKvmWinPresenter.Reset;
begin
  if (FOld<>0) and (FDC<>0) then SelectObject(FDC,FOld);
  if FBitmap<>0 then DeleteObject(FBitmap);
  FBitmap:=0; FOld:=0; FBits:=nil;
  FWidth:=0; FHeight:=0; FStride:=0;
end;

procedure TKvmWinPresenter.ClearCursor;
begin
  if (FCursorOld<>0) and (FCursorDC<>0) then SelectObject(FCursorDC,FCursorOld);
  if FCursorBitmap<>0 then DeleteObject(FCursorBitmap);
  FCursorBitmap:=0; FCursorOld:=0; FCursorBits:=nil;
  FCursorWidth:=0; FCursorHeight:=0; FCursorStride:=0;
  FCursorHotX:=0; FCursorHotY:=0; FCursorRevision:=0;
end;

function TKvmWinPresenter.EnsureCursorSize(W,H: Integer): Boolean;
var BI: TBitmapInfo; B: HBITMAP; P: Pointer; Old: HGDIOBJ;
begin
  Result:=False;
  if (W<1) or (H<1) or (FCursorDC=0) then Exit;
  if (FCursorBitmap<>0) and (FCursorWidth=W) and (FCursorHeight=H) and
     (FCursorBits<>nil) then Exit(True);
  ClearCursor;
  FillChar(BI,SizeOf(BI),0);
  BI.bmiHeader.biSize:=SizeOf(TBitmapInfoHeader);
  BI.bmiHeader.biWidth:=W; BI.bmiHeader.biHeight:=-H;
  BI.bmiHeader.biPlanes:=1; BI.bmiHeader.biBitCount:=32;
  BI.bmiHeader.biCompression:=BI_RGB;
  P:=nil;
  B:=CreateDIBSection(FCursorDC,BI,DIB_RGB_COLORS,P,0,0);
  if (B=0) or (P=nil) then
  begin if B<>0 then DeleteObject(B); Exit; end;
  Old:=SelectObject(FCursorDC,B);
  if (Old=0) or (PtrUInt(Old)=High(PtrUInt)) then
  begin DeleteObject(B); Exit; end;
  FCursorBitmap:=B; FCursorOld:=Old; FCursorBits:=P;
  FCursorWidth:=W; FCursorHeight:=H; FCursorStride:=W*4;
  Result:=True;
end;

function TKvmWinPresenter.UpdateCursor(const Shape: TKvmCursorShape): Boolean;
var Bytes: Integer;
begin
  Result:=False;
  if (Shape.Revision=0) or (Shape.Width<1) or (Shape.Height<1) or
     (Shape.Width>KVM_MAX_CURSOR_SIDE) or (Shape.Height>KVM_MAX_CURSOR_SIDE) then Exit;
  Bytes:=Integer(Shape.Width)*Integer(Shape.Height)*4;
  if Length(Shape.Pixels)<>Bytes then Exit;
  if (FCursorRevision=Shape.Revision) and (FCursorWidth=Shape.Width) and
     (FCursorHeight=Shape.Height) and (FCursorBitmap<>0) then Exit(True);
  if not EnsureCursorSize(Shape.Width,Shape.Height) then Exit;
  Move(Shape.Pixels[1],FCursorBits^,Bytes);
  FCursorHotX:=Shape.HotX; FCursorHotY:=Shape.HotY;
  FCursorRevision:=Shape.Revision;
  Result:=True;
end;

function TKvmWinPresenter.PaintCursor(DC: HDC; HotX,HotY,DestW,DestH: Integer): Boolean;
var Blend: DWORD; X,Y: Integer; R: LongBool;
begin
  Result:=False;
  if (DC=0) or (FCursorDC=0) or (FCursorBitmap=0) or
     (FCursorWidth<1) or (FCursorHeight<1) or (DestW<1) or (DestH<1) then Exit;
  X:=HotX-(FCursorHotX*DestW div FCursorWidth);
  Y:=HotY-(FCursorHotY*DestH div FCursorHeight);
  // BLENDFUNCTION bytes: AC_SRC_OVER, 0, 255, AC_SRC_ALPHA.
  Blend:=DWORD(255) shl 16 or DWORD(1) shl 24;
  R:=KvmAlphaBlend(DC,X,Y,DestW,DestH,FCursorDC,0,0,
    FCursorWidth,FCursorHeight,Blend);
  if R then Result:=True;
end;

function TKvmWinPresenter.EnsureSize(W,H: Integer): Boolean;
var BI: TBitmapInfo; B: HBITMAP; P: Pointer; Old: HGDIOBJ;
begin
  Result:=False;
  if (W<1) or (H<1) or (FDC=0) then Exit;
  if (FBitmap<>0) and (FWidth=W) and (FHeight=H) and (FBits<>nil) then Exit(True);
  Reset;
  FillChar(BI,SizeOf(BI),0);
  BI.bmiHeader.biSize:=SizeOf(TBitmapInfoHeader);
  BI.bmiHeader.biWidth:=W; BI.bmiHeader.biHeight:=-H;
  BI.bmiHeader.biPlanes:=1; BI.bmiHeader.biBitCount:=32;
  BI.bmiHeader.biCompression:=BI_RGB;
  P:=nil;
  B:=CreateDIBSection(FDC,BI,DIB_RGB_COLORS,P,0,0);
  if (B=0) or (P=nil) then
  begin
    if B<>0 then DeleteObject(B);
    Exit;
  end;
  Old:=SelectObject(FDC,B);
  if (Old=0) or (PtrUInt(Old)=High(PtrUInt)) then
  begin DeleteObject(B); Exit; end;
  FBitmap:=B; FOld:=Old; FBits:=P;
  FWidth:=W; FHeight:=H; FStride:=W*4;
  Result:=True;
end;

function TKvmWinPresenter.Update(const S: TKvmSurface; const Damage: TRect): Boolean;
var R: TRect; Row,Count: Integer; Src,Dst: PByte; NewSurface: Boolean;
begin
  Result:=False;
  if not SurfaceValid(S) then Exit;
  NewSurface:=(FWidth<>S.Width) or (FHeight<>S.Height) or (FBitmap=0);
  if not EnsureSize(S.Width,S.Height) then Exit;
  if NewSurface then R:=Rect(0,0,S.Width,S.Height) else R:=Damage;
  if R.Left<0 then R.Left:=0;
  if R.Top<0 then R.Top:=0;
  if R.Right>S.Width then R.Right:=S.Width;
  if R.Bottom>S.Height then R.Bottom:=S.Height;
  if (R.Right<=R.Left) or (R.Bottom<=R.Top) then Exit(True);
  Count:=(R.Right-R.Left)*4;
  for Row:=R.Top to R.Bottom-1 do
  begin
    Src:=PByte(Pointer(S.Pixels)) + (Row*S.Width+R.Left)*4;
    Dst:=PByte(FBits) + Row*FStride + R.Left*4;
    Move(Src^,Dst^,Count);
  end;
  Result:=True;
end;

function TKvmWinPresenter.Paint(DC: HDC; X,Y,W,H: Integer): Boolean;
var OldMode: Integer; OldOrigin: TPoint; R: LongBool;
begin
  Result:=False;
  if (DC=0) or (FDC=0) or (FBitmap=0) or (W<1) or (H<1) or
     (FWidth<1) or (FHeight<1) then Exit;
  OldMode:=0; FillChar(OldOrigin,SizeOf(OldOrigin),0);
  if (W=FWidth) and (H=FHeight) then
    R:=BitBlt(DC,X,Y,W,H,FDC,0,0,SRCCOPY)
  else
  begin
    OldMode:=SetStretchBltMode(DC,HALFTONE);
    SetBrushOrgEx(DC,0,0,@OldOrigin);
    R:=StretchBlt(DC,X,Y,W,H,FDC,0,0,FWidth,FHeight,SRCCOPY);
    if OldMode<>0 then
    begin
      SetStretchBltMode(DC,OldMode);
      SetBrushOrgEx(DC,OldOrigin.X,OldOrigin.Y,nil);
    end;
  end;
  // No GdiFlush: the persistent DIB remains alive after Paint returns.
  if R then Result:=True else Result:=False;
end;

function TKvmWinPresenter.PaintRegion(DC: HDC; DX,DY,DW,DH,SX,SY,SW,SH: Integer): Boolean;
var OldMode: Integer; OldOrigin: TPoint; R: LongBool;
begin
  Result:=False;
  if (DC=0) or (FDC=0) or (FBitmap=0) or (DW<1) or (DH<1) or
     (SW<1) or (SH<1) or (SX<0) or (SY<0) or
     (SX+SW>FWidth) or (SY+SH>FHeight) then Exit;
  OldMode:=0; FillChar(OldOrigin,SizeOf(OldOrigin),0);
  if (DW=SW) and (DH=SH) then
    R:=BitBlt(DC,DX,DY,DW,DH,FDC,SX,SY,SRCCOPY)
  else
  begin
    OldMode:=SetStretchBltMode(DC,HALFTONE);
    SetBrushOrgEx(DC,0,0,@OldOrigin);
    R:=StretchBlt(DC,DX,DY,DW,DH,FDC,SX,SY,SW,SH,SRCCOPY);
    if OldMode<>0 then
    begin
      SetStretchBltMode(DC,OldMode);
      SetBrushOrgEx(DC,OldOrigin.X,OldOrigin.Y,nil);
    end;
  end;
  if R then Result:=True else Result:=False;
end;

function PaintWindowsSurface(DC: HDC; const S: TKvmSurface;
  X,Y,W,H: Integer): Boolean;
var BI: TBitmapInfo; Lines, OldMode: Integer; OldOrigin: TPoint;
begin
  Result:=False;
  if (DC=0) or not SurfaceValid(S) or (W<1) or (H<1) then Exit;
  FillChar(BI,SizeOf(BI),0);
  BI.bmiHeader.biSize:=SizeOf(TBitmapInfoHeader);
  BI.bmiHeader.biWidth:=S.Width; BI.bmiHeader.biHeight:=-S.Height;
  BI.bmiHeader.biPlanes:=1; BI.bmiHeader.biBitCount:=32;
  BI.bmiHeader.biCompression:=BI_RGB;
  OldMode:=0; FillChar(OldOrigin,SizeOf(OldOrigin),0);
  if (W<>S.Width) or (H<>S.Height) then
  begin
    OldMode:=SetStretchBltMode(DC,HALFTONE);
    SetBrushOrgEx(DC,0,0,@OldOrigin);
  end;
  Lines:=KvmStretchDIBits(DC,X,Y,W,H,0,0,S.Width,S.Height,
    Pointer(S.Pixels),@BI,DIB_RGB_COLORS,SRCCOPY);
  GdiFlush; // source snapshot may be released immediately after this call
  if OldMode<>0 then
  begin SetStretchBltMode(DC,OldMode); SetBrushOrgEx(DC,OldOrigin.X,OldOrigin.Y,nil); end;
  Result:=(Lines<>0) and (Lines<>-1);
end;
end.

unit kvm_turbojpeg_decode;

{$mode objfpc}{$H+}
{$I ../shared/kvm_build.inc}

// TurboJPEG worker decoder: direct CPU BGRX32 rectangle composition.
// Legacy BGR24/BMP helpers remain for existing tests, not the UI hot path.
// No LCL object is accessed by this unit.

interface

uses SysUtils, Dynlibs, ctypes, kvm_surface;

type
  TKvmTurboJpegDecoder = class
  private
    FLibrary: TLibHandle;
    FHandle: Pointer;
    FInit: function: Pointer; cdecl;
    FDestroy: function(Handle: Pointer): CInt; cdecl;
    FHeader: function(Handle: Pointer; Buffer: PByte; Size: CULong;
      out Width, Height, Subsample, ColorSpace: CInt): CInt; cdecl;
    FDecompress: function(Handle: Pointer; Buffer: PByte; Size: CULong;
      Pixels: PByte; Width, Pitch, Height, PixelFormat, Flags: CInt): CInt; cdecl;
  public
    constructor Create;
    destructor Destroy; override;
    function Available: Boolean;
    function DecodeIntoSurface(const JPEG: RawByteString; X,Y,W,H: Integer;
      var Surface: TKvmSurface): Boolean;
    function DecodeToBgr(const JPEG: RawByteString; W, H: Integer;
      var BGR: RawByteString): Boolean;
    function DecodeToBmp(const JPEG: RawByteString; W, H: Integer;
      var BMP: RawByteString): Boolean;
  end;

implementation

uses {$IFDEF KVM_STANDALONE}kvm_turbojpeg_static,{$ENDIF} kvm_wire;

const
  TJPF_BGR = 1;
  TJFLAG_BOTTOMUP = 2;

procedure Put16(var S: RawByteString; At: Integer; V: Word); inline;
begin
  S[At+1] := AnsiChar(V and 255);
  S[At+2] := AnsiChar((V shr 8) and 255);
end;

procedure Put32(var S: RawByteString; At: Integer; V: Cardinal); inline;
begin
  S[At+1] := AnsiChar(V and 255);
  S[At+2] := AnsiChar((V shr 8) and 255);
  S[At+3] := AnsiChar((V shr 16) and 255);
  S[At+4] := AnsiChar((V shr 24) and 255);
end;

constructor TKvmTurboJpegDecoder.Create;
{$IFNDEF KVM_STANDALONE}
const
  {$IFDEF WINDOWS}
  Candidates: array[0..1] of string = ('turbojpeg.dll', 'libturbojpeg.dll');
  {$ELSE}
    {$IFDEF DARWIN}
    Candidates: array[0..5] of string = ('libturbojpeg.0.dylib',
      'libturbojpeg.dylib', '/opt/homebrew/lib/libturbojpeg.dylib',
      '/usr/local/lib/libturbojpeg.dylib',
      '/opt/homebrew/opt/jpeg-turbo/lib/libturbojpeg.0.dylib',
      '/usr/local/opt/jpeg-turbo/lib/libturbojpeg.0.dylib');
    {$ELSE}
    Candidates: array[0..1] of string = ('libturbojpeg.so.0', 'libturbojpeg.so');
    {$ENDIF}
  {$ENDIF}
var
  I: Integer;
{$ENDIF}
begin
  inherited Create;
  FLibrary := NilHandle;
  FHandle := nil;
  {$IFDEF KVM_STANDALONE}
  FInit := @KvmTjInitDecompress;
  FDestroy := @KvmTjDestroy;
  FHeader := @KvmTjHeader;
  FDecompress := @KvmTjDecompress;
  {$ELSE}
  for I := Low(Candidates) to High(Candidates) do
  begin
    FLibrary := LoadLibrary(Candidates[I]);
    if FLibrary <> NilHandle then Break;
  end;
  if FLibrary = NilHandle then Exit; // LCL TJPEGImage fallback remains usable
  Pointer(FInit) := GetProcedureAddress(FLibrary, 'tjInitDecompress');
  Pointer(FDestroy) := GetProcedureAddress(FLibrary, 'tjDestroy');
  Pointer(FHeader) := GetProcedureAddress(FLibrary, 'tjDecompressHeader3');
  Pointer(FDecompress) := GetProcedureAddress(FLibrary, 'tjDecompress2');
  {$ENDIF}
  if Assigned(FInit) and Assigned(FDestroy) and Assigned(FHeader) and
     Assigned(FDecompress) then FHandle := FInit();
  if FHandle = nil then
  begin
    if FLibrary <> NilHandle then UnloadLibrary(FLibrary);
    FLibrary := NilHandle;
  end;
end;

destructor TKvmTurboJpegDecoder.Destroy;
begin
  if (FHandle <> nil) and Assigned(FDestroy) then FDestroy(FHandle);
  FHandle := nil;
  if FLibrary <> NilHandle then UnloadLibrary(FLibrary);
  inherited Destroy;
end;

function TKvmTurboJpegDecoder.Available: Boolean;
begin
  Result := FHandle <> nil;
end;

// A handle is used by ONE decode worker. The destination is CPU memory.
// Preserve published snapshots using copy-on-write before modifying pixels.
function TKvmTurboJpegDecoder.DecodeIntoSurface(const JPEG: RawByteString;
  X,Y,W,H: Integer; var Surface: TKvmSurface): Boolean;
const TJPF_BGRX = 3;
var ActualW,ActualH,Subsamp,CS: CInt; Offset: PtrUInt;
begin
  Result:=False;
  if not Available or not SurfaceValid(Surface) or
    (Length(JPEG)<4) or (Length(JPEG)>KVM_MAX_JPEG_BYTES) or
    (X<0) or (Y<0) or (W<1) or (H<1) or
    (W>KVM_MAX_RECT_WIDTH) or (H>KVM_MAX_RECT_HEIGHT) or
    (Int64(X)+W>Surface.Width) or (Int64(Y)+H>Surface.Height) then Exit;
  if FHeader(FHandle,PByte(Pointer(JPEG)),CULong(Length(JPEG)),
    ActualW,ActualH,Subsamp,CS)<>0 then Exit;
  if (ActualW<>W) or (ActualH<>H) then Exit;
  UniqueString(Surface.Pixels);
  Offset:=PtrUInt(Y*Surface.Width+X)*4;
  Result:=FDecompress(FHandle,PByte(Pointer(JPEG)),CULong(Length(JPEG)),
    PByte(PtrUInt(Pointer(Surface.Pixels))+Offset),W,Surface.Width*4,H,
    TJPF_BGRX,0)=0;
end;

function TKvmTurboJpegDecoder.DecodeToBgr(const JPEG: RawByteString;
  W, H: Integer; var BGR: RawByteString): Boolean;
var
  ActualW, ActualH, Subsamp, CS: CInt;
  Stride, DataBytes: Int64;
begin
  Result := False;
  if not Available or (Length(JPEG) < 4) or
     (W < 1) or (H < 1) or (W > KVM_MAX_RECT_WIDTH) or
     (H > KVM_MAX_RECT_HEIGHT) or
     (Length(JPEG) > KVM_MAX_JPEG_BYTES) then Exit;
  if FHeader(FHandle, PByte(@JPEG[1]), CULong(Length(JPEG)),
    ActualW, ActualH, Subsamp, CS) <> 0 then Exit;
  if (ActualW <> W) or (ActualH <> H) then Exit;
  Stride := (Int64(W) * 3 + 3) and not Int64(3);
  DataBytes := Stride * H;
  if (DataBytes <= 0) or (DataBytes > 4 * 1024 * 1024) then Exit;
  SetLength(BGR, Integer(DataBytes));
  Result := FDecompress(FHandle, PByte(@JPEG[1]), CULong(Length(JPEG)),
    PByte(@BGR[1]), W, CInt(Stride), H, TJPF_BGR, 0) = 0;
end;

function TKvmTurboJpegDecoder.DecodeToBmp(const JPEG: RawByteString;
  W, H: Integer; var BMP: RawByteString): Boolean;
var
  ActualW, ActualH, Subsamp, CS: CInt;
  Stride, DataBytes, Total: Int64;
begin
  Result := False;
  if not Available or (Length(JPEG) < 4) or
     (W < 1) or (H < 1) or (W > KVM_MAX_RECT_WIDTH) or
     (H > KVM_MAX_RECT_HEIGHT) or
     (Length(JPEG) > KVM_MAX_JPEG_BYTES) then Exit;

  // Do not trust the tile header alone: the JPEG itself must match its
  // advertised geometry before allocating or decompressing the pixels.
  if FHeader(FHandle, PByte(@JPEG[1]), CULong(Length(JPEG)),
    ActualW, ActualH, Subsamp, CS) <> 0 then Exit;
  if (ActualW <> W) or (ActualH <> H) then Exit;

  Stride := (Int64(W) * 3 + 3) and not Int64(3);
  DataBytes := Stride * H;
  Total := 54 + DataBytes;
  if (Total > 4 * 1024 * 1024) or (Total <= 54) then Exit;
  SetLength(BMP, Integer(Total));
  FillChar(BMP[1], 54, 0);
  BMP[1] := 'B'; BMP[2] := 'M';
  Put32(BMP, 2, Cardinal(Total)); // BITMAPFILEHEADER.bfSize
  Put32(BMP, 10, 54);             // bfOffBits
  Put32(BMP, 14, 40);             // BITMAPINFOHEADER.biSize
  Put32(BMP, 18, Cardinal(W));
  Put32(BMP, 22, Cardinal(H));     // positive: bottom-up row order
  Put16(BMP, 26, 1);              // planes
  Put16(BMP, 28, 24);             // BGR24
  Put32(BMP, 34, Cardinal(DataBytes));
  // Bottom-up output matches the standard uncompressed BMP pixel layout.
  Result := FDecompress(FHandle, PByte(@JPEG[1]), CULong(Length(JPEG)),
    PByte(@BMP[55]), W, CInt(Stride), H, TJPF_BGR, TJFLAG_BOTTOMUP) = 0;
end;

end.

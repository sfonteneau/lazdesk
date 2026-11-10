unit kvm_turbojpeg;

{$mode objfpc}{$H+}
{$I ../shared/kvm_build.inc}

// TurboJPEG classic API. Standalone uses a real static archive; the Default
// profile keeps dynamic loading. No extraction and no slow encoder fallback.

interface

uses SysUtils, Dynlibs, ctypes, kvm_frame;

type
  ETurboJpeg = class(Exception);
  PPByteKvm = ^PByte;
  PCULongKvm = ^culong;

  TTurboJpegEncoder = class
  private
    FLibrary: TLibHandle;
    FHandle: Pointer;
    FScratch: RawByteString;
    FInit: function: Pointer; cdecl;
    FDestroy: function(Handle: Pointer): cint; cdecl;
    FBufferSize: function(Width, Height, Subsamp: cint): culong; cdecl;
    FCompress: function(Handle: Pointer; Pixels: PByte;
      Width, Pitch, Height, PixelFormat: cint; JpegBuffer: PPByteKvm;
      JpegSize: PCULongKvm; Subsample, Quality, Flags: cint): cint; cdecl;
    FGetError: function(Handle: Pointer): PAnsiChar; cdecl;
    function ErrorMessage: string;
  public
    constructor Create;
    destructor Destroy; override;
    function EncodeRect(const Frame: TRgbFrame; X, Y, W, H, Quality: Integer;
      out Jpeg: RawByteString): Boolean;
  end;

implementation

uses {$IFDEF KVM_STANDALONE}kvm_turbojpeg_static,{$ENDIF} kvm_wire;

const
  TJPF_RGB = 0;
  TJPF_BGR = 1;
  // Chroma 4:4:4: no loss of color resolution around desktop text/icons.
  TJSAMP_444 = 0;
  TJFLAG_NOREALLOC = 1024;

constructor TTurboJpegEncoder.Create;
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
  FInit := @KvmTjInitCompress;
  FDestroy := @KvmTjDestroy;
  FBufferSize := @KvmTjBufSize;
  Pointer(FCompress) := @KvmTjCompress;
  FGetError := @KvmTjError;
  {$ELSE}
  for I := Low(Candidates) to High(Candidates) do
  begin
    FLibrary := LoadLibrary(Candidates[I]);
    if FLibrary <> NilHandle then Break;
  end;
  if FLibrary = NilHandle then
    raise ETurboJpeg.Create('TurboJPEG introuvable : installer libturbojpeg ' +
      '(libturbojpeg0 sous Linux, turbojpeg.dll sous Windows, ' +
      'libturbojpeg.dylib sous macOS).');

  Pointer(FInit) := GetProcedureAddress(FLibrary, 'tjInitCompress');
  Pointer(FDestroy) := GetProcedureAddress(FLibrary, 'tjDestroy');
  Pointer(FBufferSize) := GetProcedureAddress(FLibrary, 'tjBufSize');
  Pointer(FCompress) := GetProcedureAddress(FLibrary, 'tjCompress2');
  Pointer(FGetError) := GetProcedureAddress(FLibrary, 'tjGetErrorStr2');
  {$ENDIF}
  if (not Assigned(FInit)) or (not Assigned(FDestroy)) or
     (not Assigned(FBufferSize)) or (not Assigned(FCompress)) then
    raise ETurboJpeg.Create('API TurboJPEG incomplete (tjCompress2 requis).');
  FHandle := FInit();
  if FHandle = nil then
    raise ETurboJpeg.Create('tjInitCompress a echoue.');
end;

destructor TTurboJpegEncoder.Destroy;
begin
  if (FHandle <> nil) and Assigned(FDestroy) then
    FDestroy(FHandle);
  FHandle := nil;
  if FLibrary <> NilHandle then UnloadLibrary(FLibrary);
  inherited Destroy;
end;

function TTurboJpegEncoder.ErrorMessage: string;
var
  P: PAnsiChar;
begin
  Result := 'erreur TurboJPEG';
  if not Assigned(FGetError) then Exit;
  P := FGetError(FHandle);
  if P <> nil then Result := string(P);
end;

function TTurboJpegEncoder.EncodeRect(const Frame: TRgbFrame;
  X, Y, W, H, Quality: Integer; out Jpeg: RawByteString): Boolean;
var
  Needed, Size: culong;
  Dst, Src: PByte;
  Offset: PtrUInt;
  PixelFormat: CInt;
begin
  Result := False;
  Jpeg := '';
  if (FHandle = nil) or (Quality < 1) or (Quality > 100) or
     (X < 0) or (Y < 0) or (W < 1) or (H < 1) or
     (W > KVM_MAX_RECT_WIDTH) or (H > KVM_MAX_RECT_HEIGHT) or
     (X + W > Frame.Width) or (Y + H > Frame.Height) or
     (Length(Frame.RGB) <> Int64(Frame.Width) * Frame.Height * 3) then Exit;

  Needed := FBufferSize(W, H, TJSAMP_444);
  if (Needed = 0) or (Needed > KVM_MAX_JPEG_BYTES) then Exit;
  if Length(FScratch) < Int64(Needed) then SetLength(FScratch, Needed);
  Dst := PByte(@FScratch[1]);
  Size := culong(Length(FScratch));
  Offset := PtrUInt((Y * Frame.Width + X) * 3);
  Src := PByte(PtrUInt(@Frame.RGB[1]) + Offset);
  PixelFormat := TJPF_RGB;
  if Frame.Order = kpoBGR then PixelFormat := TJPF_BGR;
  if FCompress(FHandle, Src, W, Frame.Width * 3, H, PixelFormat,
    @Dst, @Size, TJSAMP_444, Quality,
    TJFLAG_NOREALLOC) <> 0 then
    raise ETurboJpeg.Create(ErrorMessage);
  // NOREALLOC guarantees that TurboJPEG never takes ownership of FScratch.
  if (Dst <> PByte(@FScratch[1])) or (Size < 4) or
     (Size > KVM_MAX_JPEG_BYTES) then Exit;
  SetLength(Jpeg, Size);
  Move(FScratch[1], Jpeg[1], Size);
  Result := True;
end;

end.

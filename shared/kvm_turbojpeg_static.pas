unit kvm_turbojpeg_static;
{$mode objfpc}{$H+}
interface
uses ctypes;
{$LINKLIB kvm_turbojpeg}
{$I kvm_turbojpeg_link.inc}
type
  PKvmULong = ^culong;
  PPKvmByte = ^PByte;
function KvmTjInitCompress: Pointer; cdecl; external name 'tjInitCompress';
function KvmTjInitDecompress: Pointer; cdecl; external name 'tjInitDecompress';
function KvmTjDestroy(Handle: Pointer): cint; cdecl; external name 'tjDestroy';
function KvmTjBufSize(W,H,Subsample: cint): culong; cdecl; external name 'tjBufSize';
function KvmTjCompress(Handle: Pointer; Pixels: PByte;
  W,Pitch,H,PixelFormat: cint; Jpeg: PPKvmByte; Size: PKvmULong;
  Subsample,Quality,Flags: cint): cint; cdecl; external name 'tjCompress2';
function KvmTjError(Handle: Pointer): PAnsiChar; cdecl; external name 'tjGetErrorStr2';
function KvmTjHeader(Handle: Pointer; Buffer: PByte; Size: culong;
  out W,H,Subsample,ColorSpace: cint): cint; cdecl; external name 'tjDecompressHeader3';
function KvmTjDecompress(Handle: Pointer; Buffer: PByte; Size: culong;
  Pixels: PByte; W,Pitch,H,PixelFormat,Flags: cint): cint; cdecl; external name 'tjDecompress2';
implementation
end.

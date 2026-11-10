unit kvm_codec_static;
{$mode objfpc}{$H+}
interface
uses ctypes;
{$LINKLIB kvm_codec}
{$I kvm_codec_link.inc}
type PKvmSize = ^csize_t;
function KvmCodecAbi: cuint32; cdecl; external name 'lazdesk_codec_abi';
function KvmEncoderOpen(Name,Device: PAnsiChar; W,H,FPS,Kbps: cint;
  Error: PAnsiChar; Cap: csize_t): Pointer; cdecl; external name 'lazdesk_encoder_open';
function KvmEncode(Handle,RGB: Pointer; RGBSize: csize_t; Dest: Pointer;
  Cap: csize_t; Written: PKvmSize; Error: PAnsiChar; ErrorCap: csize_t): cint;
  cdecl; external name 'lazdesk_encode';
function KvmEncodeBgr24(Handle,RGB: Pointer; RGBSize: csize_t; Dest: Pointer;
  Cap: csize_t; Written: PKvmSize; Error: PAnsiChar; ErrorCap: csize_t): cint;
  cdecl; external name 'lazdesk_encode_bgr24';
function KvmDecodeBgrx32(Handle,Data: Pointer; Size: csize_t; W,H: cint; Dest: Pointer;
  Cap: csize_t; Error: PAnsiChar; ErrorCap: csize_t): cint;
  cdecl; external name 'lazdesk_decode_bgrx32';
procedure KvmEncoderClose(Handle: Pointer); cdecl; external name 'lazdesk_encoder_close';
function KvmDecoderOpen(Error: PAnsiChar; Cap: csize_t): Pointer;
  cdecl; external name 'lazdesk_decoder_open';
function KvmDecode(Handle,Data: Pointer; Size: csize_t; W,H: cint; Dest: Pointer;
  Cap: csize_t; Error: PAnsiChar; ErrorCap: csize_t): cint;
  cdecl; external name 'lazdesk_decode';
procedure KvmDecoderClose(Handle: Pointer); cdecl; external name 'lazdesk_decoder_close';
implementation
end.

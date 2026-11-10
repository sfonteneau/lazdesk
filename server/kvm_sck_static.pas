unit kvm_sck_static;
{$mode objfpc}{$H+}
interface
uses ctypes;
{$LINKLIB kvm_sck}
{$LINKFRAMEWORK Foundation}
{$LINKFRAMEWORK ScreenCaptureKit}
{$LINKFRAMEWORK CoreMedia}
{$LINKFRAMEWORK CoreVideo}
{$LINKFRAMEWORK CoreGraphics}
{$LINKLIB objc}
function KvmSckOpen(Display: Cardinal; W,H,FPS: cint; out Handle: Pointer;
  Error: PAnsiChar; Capacity: cint): cint; cdecl; external name 'kvm_sck_open';
function KvmSckRead(Handle,RGB: Pointer; Cap: csize_t; W,H: cint;
  Error: PAnsiChar; ErrorCap: cint): cint; cdecl; external name 'kvm_sck_read';
procedure KvmSckClose(Handle: Pointer); cdecl; external name 'kvm_sck_close';
function KvmSckAvailable(Handle: Pointer): cint; cdecl; external name 'kvm_sck_available';
function KvmSckSession(Identity: PAnsiChar; Capacity: cint): cint; cdecl;
  external name 'kvm_sck_session';
implementation
end.

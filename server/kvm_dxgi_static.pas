unit kvm_dxgi_static;
{$mode objfpc}{$H+}
interface
uses ctypes;
{$LINKLIB kvm_dxgi}
{$I kvm_dxgi_link.inc}
function KvmDxgiAbi: cint; cdecl; external name 'kvm_dxgi_abi';
function KvmDxgiOpen(Monitor: PtrUInt; out Handle: Pointer; Error: PAnsiChar;
  Cap: cint): cint; cdecl; external name 'kvm_dxgi_open';
function KvmDxgiRead(Handle,RGB: Pointer; Cap: csize_t; W,H: cint;
  Error: PAnsiChar; ErrorCap: cint): cint; cdecl; external name 'kvm_dxgi_read';
procedure KvmDxgiClose(Handle: Pointer); cdecl; external name 'kvm_dxgi_close';
function KvmDxgiCursorEmbedded(Handle: Pointer): cint; cdecl;
  external name 'kvm_dxgi_cursor_embedded';
implementation
end.

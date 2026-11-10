unit kvm_portal_static;
{$mode objfpc}{$H+}
interface
uses ctypes;
{$LINKLIB kvm_portal}
{$I kvm_portal_link.inc}
function KvmPortalAbi: cint; cdecl; external name 'kvm_portal_abi';
function KvmPortalOpen(Control,FPS: cint; out Handle: Pointer;
  Error: PAnsiChar; Capacity: cint): cint; cdecl; external name 'kvm_portal_open';
procedure KvmPortalClose(Handle: Pointer); cdecl; external name 'kvm_portal_close';
function KvmPortalRead(Handle,Dst: Pointer; Cap: csize_t; MaxW,MaxH: cint;
  out W,H: cint; Error: PAnsiChar; ErrorCap: cint): cint;
  cdecl; external name 'kvm_portal_read';
function KvmPortalAlive(Handle: Pointer): cint; cdecl; external name 'kvm_portal_alive';
procedure KvmPortalActive(Handle: Pointer; Enabled: cint); cdecl;
  external name 'kvm_portal_active';
function KvmPortalMouse(Handle: Pointer; Action,Button: cint; X,Y: Word): cint;
  cdecl; external name 'kvm_portal_pointer';
function KvmPortalKey(Handle: Pointer; Sym: cuint; Down: cint): cint;
  cdecl; external name 'kvm_portal_key';
function KvmPortalWheel(Handle: Pointer; Steps: cint): cint;
  cdecl; external name 'kvm_portal_wheel';
implementation
end.

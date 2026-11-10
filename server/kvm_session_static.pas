unit kvm_session_static;
{$mode objfpc}{$H+}
interface
uses ctypes;
{$LINKLIB kvm_session}
{$LINKLIB c}
{$LINKLIB dl}
function KvmSessionAbi: cuint32; cdecl; external name 'lazdesk_session_abi';
function KvmSessionOpen: Pointer; cdecl; external name 'lazdesk_session_open';
function KvmSessionOpenEx(Error: PAnsiChar; Capacity: csize_t): Pointer; cdecl;
  external name 'lazdesk_session_open_ex';
function KvmSessionPoll(Handle: Pointer; Identity: PAnsiChar; Capacity: csize_t): cint;
  cdecl; external name 'lazdesk_session_poll';
procedure KvmSessionClose(Handle: Pointer); cdecl; external name 'lazdesk_session_close';
implementation
end.

unit kvm_x11_session;
{$mode objfpc}{$H+}
interface
// All Xlib calls in the server are serialized, including temporary error
// traps around MIT-SHM. There is one persistent connection, not one/event.
function LockX11: Pointer;
procedure UnlockX11;
procedure CloseX11Session;
implementation
uses SysUtils, kvm_x11_api;
var Guard: TRTLCriticalSection; Display: Pointer = nil;
function LockX11: Pointer;
begin
  EnterCriticalSection(Guard);
  if Display = nil then Display := XOpenDisplay(nil);
  Result := Display;
end;
procedure UnlockX11;
begin LeaveCriticalSection(Guard); end;
procedure CloseX11Session;
begin
  EnterCriticalSection(Guard);
  try
    if Display <> nil then XCloseDisplay(Display);
    Display := nil;
  finally LeaveCriticalSection(Guard); end;
end;
initialization
  InitCriticalSection(Guard);
finalization
  CloseX11Session;
  DoneCriticalSection(Guard);
end.

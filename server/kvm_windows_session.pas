unit kvm_windows_session;
{$mode objfpc}{$H+}
interface
function WindowsSessionState(out Identity: string): Integer;
function WindowsDesktopAvailable: Boolean;
implementation
uses Windows, SysUtils;
function WTSQuerySessionInformationW(Server: THandle; SessionID, InfoClass: DWORD;
  var Buffer: Pointer; var Bytes: DWORD): LongBool; stdcall; external 'wtsapi32.dll';
procedure WTSFreeMemory(Buffer: Pointer); stdcall; external 'wtsapi32.dll';
function NativeProcessSession(ProcessID: DWORD; var SessionID: DWORD): LongBool; stdcall;
  external 'kernel32.dll' name 'ProcessIdToSessionId';

function NativeObjectName(Obj: THandle; Kind: Integer; Info: Pointer;
  Size: DWORD; Needed: PDWORD): LongBool; stdcall;
  external 'user32.dll' name 'GetUserObjectInformationW';
function WindowsDesktopAvailable: Boolean;
var D: HDESK; InputName, OwnName: array[0..255] of WideChar; Needed: DWORD;
begin
  Result := False;
  D := OpenInputDesktop(0,False,DESKTOP_READOBJECTS);
  if D = 0 then Exit;
  try
    FillChar(InputName,SizeOf(InputName),0); FillChar(OwnName,SizeOf(OwnName),0);
    if not NativeObjectName(D,UOI_NAME,@InputName[0],SizeOf(InputName),@Needed) then Exit;
    if not NativeObjectName(GetThreadDesktop(GetCurrentThreadId),UOI_NAME,
      @OwnName[0],SizeOf(OwnName),@Needed) then Exit;
    // No switch to a secure desktop and no elevation.
    Result := (lstrcmpiW(@InputName[0],@OwnName[0]) = 0) and
      (lstrcmpiW(@InputName[0],PWideChar(WideString('Winlogon'))) <> 0);
  finally CloseDesktop(D); end;
end;
function WindowsSessionState(out Identity: string): Integer;
var ID, Bytes: DWORD; Data: Pointer;
begin
  Identity:=''; Result:=0;
  if not NativeProcessSession(GetCurrentProcessId,ID) then Exit;
  Identity:='windows:'+IntToStr(ID);
  if ID=0 then Exit(3); // session zero is never an interactive desktop
  Data:=nil; Bytes:=0;
  if not WTSQuerySessionInformationW(0,ID,8,Data,Bytes) then Exit;
  try
    if (Data=nil) or (Bytes<SizeOf(DWORD)) then Exit;
    if PDWORD(Data)^<>0 then Exit(3); // WTSActive=0
  finally WTSFreeMemory(Data); end;
  if WindowsDesktopAvailable then Result:=1 else Result:=2;
end;
end.

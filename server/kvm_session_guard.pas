unit kvm_session_guard;
{$mode objfpc}{$H+}
{$I ../shared/kvm_build.inc}
interface
uses SysUtils, kvm_extwire;
function ConfigureSessionGuard(const Policy: string; out Reason: string): Boolean;
procedure PollSessionGuard;
function SessionGuardAllowsInput: Boolean;
procedure SessionGuardState(out State: Byte; out Epoch: Cardinal);
procedure CloseSessionGuard;
implementation
uses Dynlibs, ctypes,
  {$IFDEF KVM_STANDALONE}{$IFDEF LINUX}kvm_session_static,{$ENDIF}{$ENDIF}
  {$IFDEF WINDOWS}kvm_windows_session,{$ENDIF}
  {$IFDEF DARWIN}kvm_capture_mac,{$ENDIF}
  Classes;
type
  TGuardAbi = function: cuint32; cdecl;
  TGuardOpen = function: Pointer; cdecl;
  TGuardPoll = function(Handle: Pointer; Identity: PAnsiChar; Capacity: csize_t): cint; cdecl;
  TGuardClose = procedure(Handle: Pointer); cdecl;
var
  Lock: TRTLCriticalSection;
  Strict: Boolean = True;
  State: Byte = KVM_SESSION_UNKNOWN;
  Epoch: Cardinal = 1;
  LastPoll: QWord = 0;
  InitialIdentity: string = '';
  IdentityChanged: Boolean = False;
  Lib: TLibHandle = NilHandle;
  Handle: Pointer;
  GuardPoll: TGuardPoll;
  GuardClose: TGuardClose;
function ConfigureSessionGuard(const Policy: string; out Reason: string): Boolean;
{$IFDEF LINUX}
var Name: string; Abi: TGuardAbi; OpenGuard: TGuardOpen;
  {$IFDEF KVM_STANDALONE}NativeError: array[0..511] of AnsiChar;{$ENDIF}
{$ENDIF}
begin
  CloseSessionGuard;
  Strict:=Policy='strict'; Reason:=''; Result:=True;
  State:=KVM_SESSION_UNKNOWN; LastPoll:=0; InitialIdentity:=''; IdentityChanged:=False;
  {$IFDEF LINUX}
  {$IFDEF KVM_STANDALONE}
  Abi:=@KvmSessionAbi; OpenGuard:=@KvmSessionOpen;
  GuardPoll:=@KvmSessionPoll; GuardClose:=@KvmSessionClose;
  Result:=Abi()=$00090001;
  if Result then
  begin
    FillChar(NativeError,SizeOf(NativeError),0);
    Handle:=KvmSessionOpenEx(@NativeError[0],SizeOf(NativeError));
    Result:=Handle<>nil;
    if not Result then Reason:='Garde integre: '+string(PAnsiChar(@NativeError[0]));
  end else Reason:='ABI garde integre incompatible';
  {$ELSE}
  Name:=ExtractFilePath(ExpandFileName(ParamStr(0)))+'liblazdesk_session.so';
  Lib:=LoadLibrary(Name);
  if Lib<>NilHandle then
  begin
    Pointer(Abi):=GetProcedureAddress(Lib,'lazdesk_session_abi');
    Pointer(OpenGuard):=GetProcedureAddress(Lib,'lazdesk_session_open');
    Pointer(GuardPoll):=GetProcedureAddress(Lib,'lazdesk_session_poll');
    Pointer(GuardClose):=GetProcedureAddress(Lib,'lazdesk_session_close');
    Result:=Assigned(Abi) and Assigned(OpenGuard) and Assigned(GuardPoll) and Assigned(GuardClose);
    if Result then Result:=Abi()=$00090001;
    if Result then Handle:=OpenGuard();
    Result:=Result and (Handle<>nil);
  end else Result:=False;
  {$ENDIF}
  if not Result then
  begin
    if Reason='' then
      {$IFDEF KVM_STANDALONE}
      Reason:='Garde de session integre indisponible: verifier le runtime libsystemd et la session utilisateur.';
      {$ELSE}
      Reason:='Garde de session Linux indisponible. Compiler native/session/build.sh (libsystemd runtime requis).';
      {$ENDIF}
    if not Strict then begin Result:=True; Reason:=''; end;
  end;
  {$ENDIF}
end;
procedure PollSessionGuard;
var NewState: Integer; NowTick: QWord; Identity: string;
  Buffer: array[0..255] of AnsiChar;
begin
  // Called by the capture owner only, at most every 200ms. Network threads
  // consume a bounded-age snapshot, never dereference a native capture handle.
  NowTick:=GetTickCount64;
  if (LastPoll<>0) and (NowTick-LastPoll<200) then Exit;
  NewState:=KVM_SESSION_UNKNOWN; Identity:='';
  try
  {$IFDEF LINUX}
  if (Handle<>nil) and Assigned(GuardPoll) then
  begin
    FillChar(Buffer,SizeOf(Buffer),0);
    NewState:=GuardPoll(Handle,@Buffer[0],SizeOf(Buffer));
    Identity:=string(PAnsiChar(@Buffer[0]));
  end;
  {$ENDIF}
  {$IFDEF WINDOWS}NewState:=WindowsSessionState(Identity);{$ENDIF}
  {$IFDEF DARWIN}NewState:=MacSessionState(Identity);{$ENDIF}
  except
    NewState:=KVM_SESSION_UNKNOWN; Identity:='';
  end;
  if (NewState<0) or (NewState>4) then NewState:=KVM_SESSION_UNKNOWN;
  if NewState=KVM_SESSION_CHANGED then IdentityChanged:=True;
  if (Identity<>'') and (InitialIdentity='') then InitialIdentity:=Identity;
  if (Identity<>'') and (InitialIdentity<>Identity) then IdentityChanged:=True;
  if IdentityChanged then NewState:=KVM_SESSION_CHANGED;
  // Backend mode only relaxes UNKNOWN, never LOCKED/INACTIVE/CHANGED.
  if (NewState=KVM_SESSION_UNKNOWN) and not Strict then NewState:=KVM_SESSION_ACTIVE;
  EnterCriticalSection(Lock);
  try
    if State<>NewState then
    begin
      State:=Byte(NewState); Epoch:=NextSerial(Epoch);
      WriteLn('[session] ',DesktopStateText(State),' epoch=',Epoch);
    end;
    LastPoll:=GetTickCount64;
  finally LeaveCriticalSection(Lock); end;
end;
procedure SessionGuardState(out State: Byte; out Epoch: Cardinal);
begin
  EnterCriticalSection(Lock);
  try
    State:=kvm_session_guard.State; Epoch:=kvm_session_guard.Epoch;
    if (LastPoll=0) or (GetTickCount64-LastPoll>1000) then State:=KVM_SESSION_UNKNOWN;
  finally LeaveCriticalSection(Lock); end;
end;
function SessionGuardAllowsInput: Boolean;
var S: Byte; E: Cardinal;
begin SessionGuardState(S,E); Result:=S=KVM_SESSION_ACTIVE; end;
procedure CloseSessionGuard;
begin
  if (Handle<>nil) and Assigned(GuardClose) then GuardClose(Handle);
  Handle:=nil;
  if Lib<>NilHandle then UnloadLibrary(Lib); Lib:=NilHandle;
  GuardPoll:=nil; GuardClose:=nil;
end;
initialization InitCriticalSection(Lock);
finalization CloseSessionGuard; DoneCriticalSection(Lock);
end.

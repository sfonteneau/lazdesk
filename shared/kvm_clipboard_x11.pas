unit kvm_clipboard_x11;
{$mode objfpc}{$H+}{$B-}{$packrecords c}
// Private XCB connection: does not replace Xlib's process-wide error handler
// used by GDI/X11 capture, and does not touch the PRIMARY selection.
interface
uses SysUtils, ctypes, kvm_clipboard_base, kvm_clipboard_wire;
type
  TKvmX11Clipboard = class(TKvmClipboardBackend)
  private
    FC: Pointer;
    FRoot, FOwnerWindow, FReadWindow: Cardinal;
    FClipboard, FUtf8, FTargets, FProperty, FIncr, FMime, FReadTarget: Cardinal;
    FOwnedText, FReadText: RawByteString;
    FReadState: Integer; // 0 idle, 1 SelectionNotify, 2 INCR chunks, 3 complete
    FReadResult: TKvmClipResult;
    FDeadline: QWord;
    function Request(Opcode: Byte; IsVoid: Boolean; var Data: RawByteString): Cardinal;
    function Reply(Opcode: Byte; var Data: RawByteString): Pointer;
    function Checked(Opcode: Byte; var Data: RawByteString): Boolean;
    function Atom(const Name: RawByteString): Cardinal;
    function NewWindow: Cardinal;
    procedure DeleteWindow(var W: Cardinal);
    function SelectionOwner: Cardinal;
    procedure Convert(Target: Cardinal);
    procedure Serve(Event: Pointer);
    procedure ReceiveProperty(Incremental: Boolean);
    procedure FinishRead(Status: TKvmClipResult);
  public
    constructor Create;
    destructor Destroy; override;
    function Ready: Boolean; override;
    procedure Pump; override;
    procedure CancelRead; override;
    function ReadText(out Text: RawByteString): TKvmClipResult; override;
    function WriteText(const Text: RawByteString): TKvmClipResult; override;
  end;
implementation
const XcbLib='libxcb.so.1';
type
  TIovec = record Base: Pointer; Len: csize_t; end;
  TXcbRequest = record Count: csize_t; Ext: Pointer; Opcode,IsVoid: Byte; end;
function xcb_connect(Name: PAnsiChar; Screen: Pointer): Pointer; cdecl; external XcbLib;
procedure xcb_disconnect(C: Pointer); cdecl; external XcbLib;
function xcb_connection_has_error(C: Pointer): cint; cdecl; external XcbLib;
function xcb_get_setup(C: Pointer): Pointer; cdecl; external XcbLib;
function xcb_generate_id(C: Pointer): Cardinal; cdecl; external XcbLib;
function xcb_get_maximum_request_length(C: Pointer): Cardinal; cdecl; external XcbLib;
function xcb_send_request(C: Pointer; Flags: cint; Vector,RequestInfo: Pointer): Cardinal; cdecl; external XcbLib;
function xcb_wait_for_reply(C: Pointer; Sequence: Cardinal; Error: Pointer): Pointer; cdecl; external XcbLib;
// xcb_void_cookie_t has exactly one uint32 field; by-value cookie ABI is scalar.
function xcb_request_check(C: Pointer; Cookie: Cardinal): Pointer; cdecl; external XcbLib;
function xcb_flush(C: Pointer): cint; cdecl; external XcbLib;
function xcb_poll_for_event(C: Pointer): Pointer; cdecl; external XcbLib;
procedure CFree(P: Pointer); cdecl; external 'c' name 'free';
function U32(P: Pointer; Offset: PtrUInt): Cardinal;
begin Move(PByte(PtrUInt(P)+Offset)^,Result,4); end;
function U16(P: Pointer; Offset: PtrUInt): Word;
begin Move(PByte(PtrUInt(P)+Offset)^,Result,2); end;
procedure Put32(var S: RawByteString; Offset: Integer; V: Cardinal);
begin Move(V,S[Offset+1],4); end;
procedure Put16(var S: RawByteString; Offset: Integer; V: Word);
begin Move(V,S[Offset+1],2); end;
function Buffer(N: Integer): RawByteString;
begin SetLength(Result,N); if N>0 then FillChar(Result[1],N,0); end;
function TKvmX11Clipboard.Request(Opcode: Byte; IsVoid: Boolean; var Data: RawByteString): Cardinal;
var V: array[0..2] of TIovec; R: TXcbRequest;
begin
  Result:=0; if (FC=nil) or (Length(Data)<4) or ((Length(Data) and 3)<>0) then Exit;
  FillChar(V,SizeOf(V),0); FillChar(R,SizeOf(R),0);
  // xcb_send_request needs TWO valid iovecs before the passed pointer.
  UniqueString(Data); V[2].Base:=Pointer(Data); V[2].Len:=Length(Data);
  R.Count:=1; R.Opcode:=Opcode; R.IsVoid:=Ord(IsVoid);
  Result:=xcb_send_request(FC,1,@V[2],@R);
end;
function TKvmX11Clipboard.Reply(Opcode: Byte; var Data: RawByteString): Pointer;
var Seq: Cardinal; Err: Pointer;
begin
  Result:=nil; Seq:=Request(Opcode,False,Data); if Seq=0 then Exit;
  Err:=nil; Result:=xcb_wait_for_reply(FC,Seq,@Err);
  if Err<>nil then begin CFree(Err); if Result<>nil then CFree(Result); Result:=nil; end;
end;
function TKvmX11Clipboard.Checked(Opcode: Byte; var Data: RawByteString): Boolean;
var Seq: Cardinal; Err: Pointer;
begin
  Seq:=Request(Opcode,True,Data); if Seq=0 then Exit(False);
  Err:=xcb_request_check(FC,Seq); Result:=Err=nil;
  if Err<>nil then CFree(Err);
end;
function TKvmX11Clipboard.Atom(const Name: RawByteString): Cardinal;
var D: RawByteString; P: Pointer;
begin
  Result:=0; D:=Buffer((8+Length(Name)+3) and not 3); Put16(D,4,Length(Name));
  if Name<>'' then Move(Name[1],D[9],Length(Name));
  P:=Reply(16,D); if P<>nil then begin Result:=U32(P,8); CFree(P); end;
end;
function TKvmX11Clipboard.NewWindow: Cardinal;
var D: RawByteString;
begin
  Result:=xcb_generate_id(FC); D:=Buffer(36);
  Put32(D,4,Result); Put32(D,8,FRoot); Put16(D,16,1); Put16(D,18,1);
  Put16(D,22,2); // InputOnly, depth/visual CopyFromParent
  Put32(D,28,1 shl 11); Put32(D,32,1 shl 22); // CW_EVENT_MASK / PropertyChange
  if not Checked(1,D) then Result:=0;
end;
procedure TKvmX11Clipboard.DeleteWindow(var W: Cardinal);
var D: RawByteString;
begin
  if (FC<>nil) and (W<>0) then begin D:=Buffer(8); Put32(D,4,W); Checked(4,D); end;
  W:=0;
end;
constructor TKvmX11Clipboard.Create;
var Setup: Pointer; Offset,Bytes: PtrUInt;
begin
  inherited Create;
  // XWayland is not a reliable bridge to the compositor clipboard. Do not
  // silently claim Wayland support or bypass the portal's local consent.
  if (GetEnvironmentVariable('WAYLAND_DISPLAY')<>'') or
     (LowerCase(GetEnvironmentVariable('XDG_SESSION_TYPE'))='wayland') then Exit;
  if GetEnvironmentVariable('DISPLAY')='' then Exit;
  FC:=xcb_connect(nil,nil);
  if (FC=nil) or (xcb_connection_has_error(FC)<>0) then Exit;
  Setup:=xcb_get_setup(FC); if Setup=nil then Exit;
  Bytes:=8+PtrUInt(U16(Setup,6))*4;
  if (Bytes<40) or (PByte(PtrUInt(Setup)+28)^=0) then Exit;
  Offset:=40+((PtrUInt(U16(Setup,24))+3) and not PtrUInt(3))+
    PtrUInt(PByte(PtrUInt(Setup)+29)^)*8;
  if Offset+40>Bytes then Exit;
  FRoot:=U32(Setup,Offset); FOwnerWindow:=NewWindow;
  FClipboard:=Atom('CLIPBOARD'); FUtf8:=Atom('UTF8_STRING'); FTargets:=Atom('TARGETS');
  FProperty:=Atom('LAZDESK_CLIPBOARD_TEXT'); FIncr:=Atom('INCR');
  FMime:=Atom('text/plain;charset=utf-8');
end;
destructor TKvmX11Clipboard.Destroy;
begin
  CancelRead; DeleteWindow(FOwnerWindow);
  if FC<>nil then xcb_disconnect(FC); FC:=nil;
  FOwnedText:=''; inherited Destroy;
end;
function TKvmX11Clipboard.Ready: Boolean;
begin
  Result:=(FC<>nil) and (FOwnerWindow<>0) and (FClipboard<>0) and (FUtf8<>0) and
    (FTargets<>0) and (FProperty<>0) and (FIncr<>0) and (FMime<>0);
  if Result then Result:=xcb_connection_has_error(FC)=0;
end;
function TKvmX11Clipboard.SelectionOwner: Cardinal;
var D: RawByteString; P: Pointer;
begin
  Result:=0; D:=Buffer(8); Put32(D,4,FClipboard); P:=Reply(23,D);
  if P<>nil then begin Result:=U32(P,8); CFree(P); end;
end;
procedure TKvmX11Clipboard.Convert(Target: Cardinal);
var D: RawByteString;
begin
  FReadTarget:=Target; D:=Buffer(24);
  Put32(D,4,FReadWindow); Put32(D,8,FClipboard); Put32(D,12,Target);
  Put32(D,16,FProperty); // CurrentTime = 0
  if not Checked(24,D) then FinishRead(crFailed);
  xcb_flush(FC);
end;
procedure TKvmX11Clipboard.CancelRead;
begin DeleteWindow(FReadWindow); FReadState:=0; FReadText:=''; end;
procedure TKvmX11Clipboard.FinishRead(Status: TKvmClipResult);
begin
  FReadResult:=Status; FReadState:=3; DeleteWindow(FReadWindow);
  if Status<>crOk then FReadText:='';
end;
procedure TKvmX11Clipboard.ReceiveProperty(Incremental: Boolean);
var D,S,T: RawByteString; P: Pointer; Kind,N,AfterBytes: Cardinal; Fmt: Byte; I,K: Integer;
begin
  D:=Buffer(24); D[2]:=#1; Put32(D,4,FReadWindow); Put32(D,8,FProperty);
  Put32(D,20,(KVM_CLIP_MAX_BYTES+3) div 4);
  P:=Reply(20,D); if P=nil then begin FinishRead(crFailed); Exit; end;
  try
    Fmt:=PByte(PtrUInt(P)+1)^; Kind:=U32(P,8); AfterBytes:=U32(P,12); N:=U32(P,16);
    if AfterBytes<>0 then begin FinishRead(crTooLarge); Exit; end;
    if not Incremental and (Kind=FIncr) then
    begin
      if (Fmt<>32) or (N<>1) then begin FinishRead(crInvalid); Exit; end;
      if U32(P,32)>KVM_CLIP_MAX_BYTES then begin FinishRead(crTooLarge); Exit; end;
      FReadState:=2; FReadText:=''; xcb_flush(FC); Exit;
    end;
    if (Fmt<>8) or (Kind<>FReadTarget) then begin FinishRead(crInvalid); Exit; end;
    if (N>KVM_CLIP_MAX_BYTES) or (Length(FReadText)>KVM_CLIP_MAX_BYTES-Integer(N)) then
    begin FinishRead(crTooLarge); Exit; end;
    SetString(S,PAnsiChar(PtrUInt(P)+32),N);
    FReadText:=FReadText+S;
    if Incremental and (N<>0) then begin xcb_flush(FC); Exit; end;
    if FReadTarget=31 then // XA_STRING / ISO-8859-1, not locale guessing
    begin
      SetLength(T,2*Length(FReadText)); K:=0;
      for I:=1 to Length(FReadText) do
      begin
        Inc(K);
        if Ord(FReadText[I])<$80 then T[K]:=FReadText[I]
        else
        begin
          T[K]:=AnsiChar($c0 or (Ord(FReadText[I]) shr 6)); Inc(K);
          T[K]:=AnsiChar($80 or (Ord(FReadText[I]) and $3f));
        end;
      end;
      SetLength(T,K); FReadText:=T;
    end;
    if Length(FReadText)>KVM_CLIP_MAX_BYTES then begin FinishRead(crTooLarge); Exit; end;
    if not CanonicalClipboardText(FReadText,T) then begin FinishRead(crInvalid); Exit; end;
    FReadText:=T; FinishRead(crOk);
  finally CFree(P); end;
end;
procedure TKvmX11Clipboard.Serve(Event: Pointer);
var Destination,Target,Prop,Time1,Kind,N: Cardinal; D,Value: RawByteString;
  U: UnicodeString; I: Integer; Ok: Boolean;
begin
  Time1:=U32(Event,4); Destination:=U32(Event,12); Target:=U32(Event,20);
  Prop:=U32(Event,24); if Prop=0 then Prop:=Target;
  Ok:=(U32(Event,8)=FOwnerWindow) and (U32(Event,16)=FClipboard) and
    (SelectionOwner=FOwnerWindow) and (Prop<>0);
  Kind:=Target; Value:=''; N:=0;
  if Ok then
  begin
    if Target=FTargets then
    begin
      Value:=Buffer(16); Put32(Value,0,FTargets); Put32(Value,4,FUtf8);
      Put32(Value,8,FMime); Put32(Value,12,31); Kind:=4; N:=4; // ATOM, format 32
    end
    else if (Target=FUtf8) or (Target=FMime) then
    begin Value:=FOwnedText; N:=Length(Value); end
    else if Target=31 then
    begin
      U:=UTF8Decode(FOwnedText); SetLength(Value,Length(U));
      for I:=1 to Length(U) do
      begin if Ord(U[I])>255 then begin Ok:=False; Break; end; Value[I]:=AnsiChar(Ord(U[I])); end;
      N:=Length(Value);
    end
    else Ok:=False;
  end;
  if Ok then
  begin
    D:=Buffer((24+Length(Value)+3) and not 3);
    if Cardinal(Length(D) div 4)>xcb_get_maximum_request_length(FC) then Ok:=False
    else
    begin
      Put32(D,4,Destination); Put32(D,8,Prop); Put32(D,12,Kind);
      if Target=FTargets then D[17]:=#32 else D[17]:=#8;
      Put32(D,20,N); if Value<>'' then Move(Value[1],D[25],Length(Value));
      Ok:=Checked(18,D); // BadWindow is a returned error, never a process abort.
    end;
  end;
  D:=Buffer(44); Put32(D,4,Destination);
  D[13]:=#31; Put32(D,16,Time1); Put32(D,20,Destination);
  Put32(D,24,FClipboard); Put32(D,28,Target);
  if Ok then Put32(D,32,Prop); Checked(25,D); xcb_flush(FC);
end;
procedure TKvmX11Clipboard.Pump;
var E: Pointer; I: Integer; K: Byte;
begin
  if not Ready then Exit;
  for I:=1 to 32 do
  begin
    E:=xcb_poll_for_event(FC); if E=nil then Break;
    try
      K:=PByte(E)^ and $7f;
      case K of
        29: if (U32(E,8)=FOwnerWindow) and (SelectionOwner<>FOwnerWindow) then FOwnedText:='';
        30: Serve(E);
        31: if (FReadState=1) and (U32(E,8)=FReadWindow) and
          (U32(E,12)=FClipboard) and (U32(E,16)=FReadTarget) then
          begin
            if U32(E,20)=0 then
            begin
              if FReadTarget=FUtf8 then Convert(31) else FinishRead(crNoText);
            end
            else if U32(E,20)=FProperty then ReceiveProperty(False);
          end;
        28: if (FReadState=2) and (U32(E,4)=FReadWindow) and
          (U32(E,8)=FProperty) and (PByte(PtrUInt(E)+16)^=0) then ReceiveProperty(True);
      end;
    finally CFree(E); end;
  end;
  if (FReadState in [1,2]) and (GetTickCount64>FDeadline) then FinishRead(crBusy);
end;
function TKvmX11Clipboard.ReadText(out Text: RawByteString): TKvmClipResult;
var Owner1: Cardinal;
begin
  Text:=''; if not Ready then Exit(crUnsupported);
  Pump;
  if FReadState=3 then
  begin Result:=FReadResult; Text:=FReadText; FReadText:=''; FReadState:=0; Exit; end;
  if FReadState<>0 then Exit(crBusy);
  Owner1:=SelectionOwner;
  if Owner1=0 then Exit(crNoText);
  if Owner1=FOwnerWindow then begin Text:=FOwnedText; Exit(crOk); end;
  FReadWindow:=NewWindow; if FReadWindow=0 then Exit(crFailed);
  FReadState:=1; FDeadline:=GetTickCount64+2000; FReadText:='';
  Convert(FUtf8); Result:=crBusy;
end;
function TKvmX11Clipboard.WriteText(const Text: RawByteString): TKvmClipResult;
var S,D: RawByteString;
begin
  if not Ready then Exit(crUnsupported);
  if not CanonicalClipboardText(Text,S) then Exit(crInvalid);
  if QWord(Length(S))+24>QWord(xcb_get_maximum_request_length(FC))*4 then Exit(crTooLarge);
  CancelRead; D:=Buffer(16); Put32(D,4,FOwnerWindow); Put32(D,8,FClipboard);
  if not Checked(22,D) then Exit(crFailed);
  if SelectionOwner<>FOwnerWindow then Exit(crFailed);
  FOwnedText:=S; Result:=crOk; xcb_flush(FC);
end;
end.

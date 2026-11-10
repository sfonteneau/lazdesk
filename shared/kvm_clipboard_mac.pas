unit kvm_clipboard_mac;
{$mode objfpc}{$H+}{$B-}
{$linkframework Foundation}
{$linkframework AppKit}
// Typed objc_msgSend declarations: no untyped varargs, valid on x64/arm64.
interface
uses SysUtils, ctypes, kvm_clipboard_base, kvm_clipboard_wire;
type
  TKvmMacClipboard = class(TKvmClipboardBackend)
  public
    function ChangeStamp: QWord; override;
    function Ready: Boolean; override;
    function ReadText(out Text: RawByteString): TKvmClipResult; override;
    function WriteText(const Text: RawByteString): TKvmClipResult; override;
  end;
implementation
const ObjCLib='/usr/lib/libobjc.A.dylib'; UTF8Encoding=4;
function objc_getClass(Name: PAnsiChar): Pointer; cdecl; external ObjCLib;
function sel_registerName(Name: PAnsiChar): Pointer; cdecl; external ObjCLib;
function Msg0(O,S: Pointer): Pointer; cdecl; external ObjCLib name 'objc_msgSend';
function Msg1(O,S,A: Pointer): Pointer; cdecl; external ObjCLib name 'objc_msgSend';
function MsgSize(O,S: Pointer; Encoding: PtrUInt): PtrUInt; cdecl; external ObjCLib name 'objc_msgSend';
function MsgString(O,S,Bytes: Pointer; Count,Encoding: PtrUInt): Pointer; cdecl; external ObjCLib name 'objc_msgSend';
function MsgSet(O,S,A,B: Pointer): Byte; cdecl; external ObjCLib name 'objc_msgSend';
function NewString(const S: RawByteString): Pointer;
begin
  Result:=Msg0(objc_getClass('NSString'),sel_registerName('alloc'));
  Result:=MsgString(Result,sel_registerName('initWithBytes:length:encoding:'),
    Pointer(S),Length(S),UTF8Encoding);
end;
function Pool: Pointer;
begin Result:=Msg0(Msg0(objc_getClass('NSAutoreleasePool'),sel_registerName('alloc')),sel_registerName('init')); end;
function TKvmMacClipboard.ChangeStamp: QWord;
var P,B: Pointer;
begin
  P:=Pool;
  try
    B:=Msg0(objc_getClass('NSPasteboard'),sel_registerName('generalPasteboard'));
    Result:=PtrUInt(Msg0(B,sel_registerName('changeCount')));
  finally Msg0(P,sel_registerName('drain')); end;
end;
function TKvmMacClipboard.Ready: Boolean;
begin Result:=objc_getClass('NSPasteboard')<>nil; end;
function TKvmMacClipboard.ReadText(out Text: RawByteString): TKvmClipResult;
var P,B,T,V,Data: Pointer; N: PtrUInt; S: RawByteString;
begin
  Text:=''; if not Ready then Exit(crUnsupported);
  P:=Pool; T:=nil;
  try
    B:=Msg0(objc_getClass('NSPasteboard'),sel_registerName('generalPasteboard'));
    T:=NewString('public.utf8-plain-text');
    V:=Msg1(B,sel_registerName('stringForType:'),T); if V=nil then Exit(crNoText);
    N:=MsgSize(V,sel_registerName('lengthOfBytesUsingEncoding:'),UTF8Encoding);
    if N>KVM_CLIP_MAX_BYTES then Exit(crTooLarge);
    Data:=Msg0(V,sel_registerName('UTF8String')); if Data=nil then Exit(crFailed);
    SetString(S,PAnsiChar(Data),N);
    if not CanonicalClipboardText(S,Text) then Exit(crInvalid);
    Result:=crOk;
  finally
    if T<>nil then Msg0(T,sel_registerName('release'));
    Msg0(P,sel_registerName('drain'));
  end;
end;
function TKvmMacClipboard.WriteText(const Text: RawByteString): TKvmClipResult;
var P,B,T,V: Pointer; S: RawByteString;
begin
  if not Ready then Exit(crUnsupported);
  if not CanonicalClipboardText(Text,S) then Exit(crInvalid);
  P:=Pool; T:=nil; V:=nil;
  try
    B:=Msg0(objc_getClass('NSPasteboard'),sel_registerName('generalPasteboard'));
    T:=NewString('public.utf8-plain-text'); V:=NewString(S);
    if (B=nil) or (V=nil) or (T=nil) then Exit(crFailed);
    Msg0(B,sel_registerName('clearContents'));
    if MsgSet(B,sel_registerName('setString:forType:'),V,T)<>0 then Result:=crOk
    else Result:=crFailed;
  finally
    if V<>nil then Msg0(V,sel_registerName('release'));
    if T<>nil then Msg0(T,sel_registerName('release'));
    Msg0(P,sel_registerName('drain'));
  end;
end;
end.

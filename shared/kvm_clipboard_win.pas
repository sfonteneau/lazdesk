unit kvm_clipboard_win;
{$mode objfpc}{$H+}{$B-}
interface
uses Windows, SysUtils, kvm_clipboard_base, kvm_clipboard_wire;
type
  TKvmWindowsClipboard = class(TKvmClipboardBackend)
  private FOwner: HWND;
  public
    constructor Create;
    destructor Destroy; override;
    function Ready: Boolean; override;
    function ChangeStamp: QWord; override;
    procedure Pump; override;
    function ReadText(out Text: RawByteString): TKvmClipResult; override;
    function WriteText(const Text: RawByteString): TKvmClipResult; override;
  end;
implementation
function KvmClipboardSequence: DWORD; stdcall;
  external 'user32.dll' name 'GetClipboardSequenceNumber';
function TKvmWindowsClipboard.ChangeStamp: QWord;
begin Result:=KvmClipboardSequence; end;
constructor TKvmWindowsClipboard.Create;
begin
  inherited Create;
  // A real owner HWND is mandatory: OpenClipboard(0)+EmptyClipboard loses
  // ownership and SetClipboardData may fail. STATIC is a system window class.
  FOwner:=CreateWindowExW(0,'STATIC','LazDesk clipboard',0,0,0,0,0,
    HWND(not PtrUInt(2)),0,GetModuleHandle(nil),nil);
end;
destructor TKvmWindowsClipboard.Destroy;
begin
  if FOwner<>0 then DestroyWindow(FOwner);
  inherited Destroy;
end;
function TKvmWindowsClipboard.Ready: Boolean;
begin Result:=FOwner<>0; end;
procedure TKvmWindowsClipboard.Pump;
var Msg: TMsg;
begin
  if FOwner=0 then Exit;
  while PeekMessage(Msg,FOwner,0,0,PM_REMOVE) do
  begin TranslateMessage(Msg); DispatchMessage(Msg); end;
end;
function TKvmWindowsClipboard.ReadText(out Text: RawByteString): TKvmClipResult;
var Mem: HGLOBAL; P: PWideChar; Size,N,I: SizeUInt; U: UnicodeString; S: RawByteString;
begin
  Text:=''; if not Ready then Exit(crUnsupported);
  if not OpenClipboard(FOwner) then Exit(crBusy);
  try
    if not IsClipboardFormatAvailable(CF_UNICODETEXT) then Exit(crNoText);
    Mem:=GetClipboardData(CF_UNICODETEXT); if Mem=0 then Exit(crFailed);
    Size:=GlobalSize(Mem);
    if (Size<2) or ((Size and 1)<>0) then Exit(crInvalid);
    // Bound before copying. No truncation and no unbounded PWideChar scan.
    if Size>2*(KVM_CLIP_MAX_BYTES+1) then Exit(crTooLarge);
    P:=GlobalLock(Mem); if P=nil then Exit(crFailed);
    try
      N:=0; while (N<Size div 2) and (P[N]<>#0) do Inc(N);
      if N=Size div 2 then Exit(crInvalid);
      I:=0;
      while I<N do
      begin
        if (Ord(P[I])>=$d800) and (Ord(P[I])<=$dbff) then
        begin
          Inc(I); if (I>=N) or (Ord(P[I])<$dc00) or (Ord(P[I])>$dfff) then Exit(crInvalid);
        end
        else if (Ord(P[I])>=$dc00) and (Ord(P[I])<=$dfff) then Exit(crInvalid);
        Inc(I);
      end;
      SetString(U,P,N); S:=UTF8Encode(U);
    finally GlobalUnlock(Mem); end;
    if Length(S)>KVM_CLIP_MAX_BYTES then Exit(crTooLarge);
    if not CanonicalClipboardText(S,Text) then Exit(crInvalid);
    Result:=crOk;
  finally CloseClipboard; end;
end;
function TKvmWindowsClipboard.WriteText(const Text: RawByteString): TKvmClipResult;
var Mem: HGLOBAL; P: Pointer; U: UnicodeString; S: RawByteString; Bytes: SizeUInt;
begin
  if not Ready then Exit(crUnsupported);
  if not CanonicalClipboardText(Text,S) then Exit(crInvalid);
  U:=UTF8Decode(StringReplace(string(S),#10,#13#10,[rfReplaceAll]));
  Bytes:=(Length(U)+1)*SizeOf(WideChar);
  Mem:=GlobalAlloc(GMEM_MOVEABLE,Bytes); if Mem=0 then Exit(crFailed);
  try
    P:=GlobalLock(Mem); if P=nil then Exit(crFailed);
    try
      if U<>'' then Move(U[1],P^,Length(U)*SizeOf(WideChar));
      PWideChar(P)[Length(U)]:=#0;
    finally GlobalUnlock(Mem); end;
    if not OpenClipboard(FOwner) then Exit(crBusy);
    try
      if not EmptyClipboard then Exit(crFailed);
      if SetClipboardData(CF_UNICODETEXT,Mem)=0 then Exit(crFailed);
      Mem:=0; // Windows now owns this allocation; never free after success.
      Result:=crOk;
    finally CloseClipboard; end;
  finally if Mem<>0 then GlobalFree(Mem); end;
end;
end.

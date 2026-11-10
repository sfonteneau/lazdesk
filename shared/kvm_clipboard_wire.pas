unit kvm_clipboard_wire;
{$mode objfpc}{$H+}{$B-}
// Clipboard messages are independent from video/input ACKs. No text is logged.
interface
uses SysUtils;
const
  KVM_CLIP_MAX_BYTES = 64 * 1024;
  KVM_CLIP_REQUEST_HEADER = 15;
  KVM_CLIP_REPLY_HEADER = 13;
  KVM_CLIP_WRITE = 1;
  KVM_CLIP_READ = 2;
  KVM_CLIP_POLL_MS = 250;
  KVM_CLIP_TIMEOUT_MS = 5000;
type
  TKvmClipResult = (crSkip, crOk, crBusy, crUnsupported, crDenied,
    crTooLarge, crInvalid, crFailed, crUnchanged, crNoText);
  TKvmClipRequest = record
    Epoch, Serial, KnownReadSerial: Cardinal;
    Flags: Byte;
    Text: RawByteString;
  end;
  TKvmClipReply = record
    Epoch, Serial: Cardinal;
    WriteResult, ReadResult: TKvmClipResult;
    HasText: Boolean;
    Text: RawByteString;
  end;
function ClipboardTextValid(const S: RawByteString): Boolean;
function CanonicalClipboardText(const S: RawByteString; out Text: RawByteString): Boolean;
function ClipNextSerial(V: Cardinal): Cardinal;
function MakeClipRequest(const R: TKvmClipRequest): RawByteString;
function ReadClipRequest(const S: RawByteString; out R: TKvmClipRequest): Boolean;
function MakeClipReply(const R: TKvmClipReply): RawByteString;
function ReadClipReply(const S: RawByteString; out R: TKvmClipReply): Boolean;
function ClipResultText(R: TKvmClipResult): string;
implementation
function ClipNextSerial(V: Cardinal): Cardinal;
begin if V=High(Cardinal) then Result:=1 else Result:=V+1; end;
function ClipboardTextValid(const S: RawByteString): Boolean;
var I,J,N: SizeInt; B: Byte; U, Minimum: Cardinal;
begin
  Result:=False;
  if Length(S)>KVM_CLIP_MAX_BYTES then Exit;
  I:=1;
  while I<=Length(S) do
  begin
    B:=Ord(S[I]); Inc(I);
    if B=0 then Exit; // CF_UNICODETEXT cannot represent embedded NUL.
    if B<$80 then Continue;
    if (B>=$c2) and (B<=$df) then begin N:=1; U:=B and $1f; Minimum:=$80; end
    else if (B>=$e0) and (B<=$ef) then begin N:=2; U:=B and $0f; Minimum:=$800; end
    else if (B>=$f0) and (B<=$f4) then begin N:=3; U:=B and 7; Minimum:=$10000; end
    else Exit;
    if Length(S)-I+1<N then Exit;
    for J:=1 to N do
    begin
      B:=Ord(S[I]); Inc(I);
      if (B and $c0)<>$80 then Exit;
      U:=(U shl 6) or (B and $3f);
    end;
    if (U<Minimum) or (U>$10ffff) or ((U>=$d800) and (U<=$dfff)) then Exit;
  end;
  Result:=True;
end;
function CanonicalClipboardText(const S: RawByteString; out Text: RawByteString): Boolean;
var I,N: SizeInt;
begin
  Text:=''; Result:=ClipboardTextValid(S); if not Result then Exit;
  SetLength(Text,Length(S)); I:=1; N:=0;
  while I<=Length(S) do
  begin
    Inc(N);
    if S[I]=#13 then
    begin
      Text[N]:=#10;
      if (I<Length(S)) and (S[I+1]=#10) then Inc(I);
    end
    else Text[N]:=S[I];
    Inc(I);
  end;
  SetLength(Text,N);
end;
function Get32(const S: RawByteString; P: Integer): Cardinal;
begin Result:=Ord(S[P]) or (Cardinal(Ord(S[P+1])) shl 8) or
  (Cardinal(Ord(S[P+2])) shl 16) or (Cardinal(Ord(S[P+3])) shl 24); end;
procedure Put32(var S: RawByteString; P: Integer; V: Cardinal);
begin S[P]:=AnsiChar(V and 255); S[P+1]:=AnsiChar((V shr 8) and 255);
  S[P+2]:=AnsiChar((V shr 16) and 255); S[P+3]:=AnsiChar(V shr 24); end;
function MakeClipRequest(const R: TKvmClipRequest): RawByteString;
begin
  Result:='';
  if (R.Serial=0) or (R.Epoch=0) or (R.Flags=0) or (R.Flags>3) then Exit;
  if (R.Flags and KVM_CLIP_WRITE)=0 then
  begin if R.Text<>'' then Exit; end
  else if not ClipboardTextValid(R.Text) then Exit;
  SetLength(Result,KVM_CLIP_REQUEST_HEADER+Length(R.Text));
  Result[1]:='c'; Result[2]:='Q'; Put32(Result,3,R.Epoch); Put32(Result,7,R.Serial);
  Result[11]:=AnsiChar(R.Flags); Put32(Result,12,R.KnownReadSerial);
  if R.Text<>'' then Move(R.Text[1],Result[16],Length(R.Text));
end;
function ReadClipRequest(const S: RawByteString; out R: TKvmClipRequest): Boolean;
begin
  R.Epoch:=0; R.Serial:=0; R.KnownReadSerial:=0; R.Flags:=0; R.Text:='';
  Result:=False;
  if (Length(S)<KVM_CLIP_REQUEST_HEADER) or
     (Length(S)>KVM_CLIP_REQUEST_HEADER+KVM_CLIP_MAX_BYTES) then Exit;
  if (S[1]<>'c') or (S[2]<>'Q') then Exit;
  R.Epoch:=Get32(S,3); R.Serial:=Get32(S,7); R.Flags:=Ord(S[11]);
  R.KnownReadSerial:=Get32(S,12);
  if (R.Epoch=0) or (R.Serial=0) or (R.Flags=0) or (R.Flags>3) then Exit;
  R.Text:=Copy(S,16,Length(S)-15);
  if (R.Flags and KVM_CLIP_WRITE)=0 then Result:=R.Text=''
  else Result:=ClipboardTextValid(R.Text);
end;
function MakeClipReply(const R: TKvmClipReply): RawByteString;
begin
  Result:='';
  if (R.Serial=0) or (R.Epoch=0) then Exit;
  if R.HasText then
  begin if (R.ReadResult<>crOk) or not ClipboardTextValid(R.Text) then Exit; end
  else if (R.Text<>'') or (R.ReadResult=crOk) then Exit;
  SetLength(Result,KVM_CLIP_REPLY_HEADER+Length(R.Text));
  Result[1]:='c'; Result[2]:='R'; Put32(Result,3,R.Epoch); Put32(Result,7,R.Serial);
  Result[11]:=AnsiChar(Ord(R.WriteResult)); Result[12]:=AnsiChar(Ord(R.ReadResult));
  Result[13]:=AnsiChar(Ord(R.HasText));
  if R.Text<>'' then Move(R.Text[1],Result[14],Length(R.Text));
end;
function ReadClipReply(const S: RawByteString; out R: TKvmClipReply): Boolean;
begin
  R.Epoch:=0; R.Serial:=0; R.WriteResult:=crSkip; R.ReadResult:=crSkip;
  R.HasText:=False; R.Text:=''; Result:=False;
  if (Length(S)<KVM_CLIP_REPLY_HEADER) or
     (Length(S)>KVM_CLIP_REPLY_HEADER+KVM_CLIP_MAX_BYTES) then Exit;
  if (S[1]<>'c') or (S[2]<>'R') or (Ord(S[11])>Ord(High(TKvmClipResult))) or
    (Ord(S[12])>Ord(High(TKvmClipResult))) or (Ord(S[13])>1) then Exit;
  R.Epoch:=Get32(S,3); R.Serial:=Get32(S,7);
  if (R.Epoch=0) or (R.Serial=0) then Exit;
  R.WriteResult:=TKvmClipResult(Ord(S[11])); R.ReadResult:=TKvmClipResult(Ord(S[12]));
  R.HasText:=S[13]=#1; R.Text:=Copy(S,14,Length(S)-13);
  if R.HasText then Result:=(R.ReadResult=crOk) and ClipboardTextValid(R.Text)
  else Result:=(R.Text='') and (R.ReadResult<>crOk);
end;
function ClipResultText(R: TKvmClipResult): string;
begin
  case R of
    crSkip: Result:='not requested'; crOk: Result:='OK'; crBusy: Result:='occupe/delai depasse';
    crUnsupported: Result:='unavailable on this desktop'; crDenied: Result:='control/session denied';
    crTooLarge: Result:='text exceeds 64 KiB'; crInvalid: Result:='invalid Unicode text';
    crFailed: Result:='system clipboard error'; crUnchanged: Result:='inchange';
    crNoText: Result:='no text (images/files are not transferred)';
  end;
end;
end.

unit kvm_clipboard_native;
{$mode objfpc}{$H+}{$B-}
interface
uses kvm_clipboard_base;
function CreateClipboardBackend: TKvmClipboardBackend;
implementation
uses kvm_clipboard_wire
  {$IFDEF WINDOWS}, kvm_clipboard_win{$ENDIF}
  {$IFDEF LINUX}, kvm_clipboard_x11{$ENDIF}
  {$IFDEF DARWIN}, kvm_clipboard_mac{$ENDIF};
type
  TUnavailableClipboard = class(TKvmClipboardBackend)
    function Ready: Boolean; override;
    function ReadText(out Text: RawByteString): TKvmClipResult; override;
    function WriteText(const Text: RawByteString): TKvmClipResult; override;
  end;
function TUnavailableClipboard.Ready: Boolean; begin Result:=False; end;
function TUnavailableClipboard.ReadText(out Text: RawByteString): TKvmClipResult;
begin Text:=''; Result:=crUnsupported; end;
function TUnavailableClipboard.WriteText(const Text: RawByteString): TKvmClipResult;
begin Result:=crUnsupported; end;
function CreateClipboardBackend: TKvmClipboardBackend;
begin
  {$IFDEF WINDOWS}Result:=TKvmWindowsClipboard.Create;{$ELSE}
  {$IFDEF LINUX}Result:=TKvmX11Clipboard.Create;{$ELSE}
  {$IFDEF DARWIN}Result:=TKvmMacClipboard.Create;{$ELSE}
  Result:=TUnavailableClipboard.Create;
  {$ENDIF}{$ENDIF}{$ENDIF}
end;
end.

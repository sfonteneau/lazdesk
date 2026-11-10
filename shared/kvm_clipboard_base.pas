unit kvm_clipboard_base;
{$mode objfpc}{$H+}{$B-}
interface
uses kvm_clipboard_wire;
type
  // Construct, pump and destroy on ONE owner thread. No LCL access here.
  TKvmClipboardBackend = class
  public
    function Ready: Boolean; virtual; abstract;
    function ChangeStamp: QWord; virtual; // 0 when the platform has no counter
    procedure Pump; virtual;
    procedure CancelRead; virtual;
    function ReadText(out Text: RawByteString): TKvmClipResult; virtual; abstract;
    function WriteText(const Text: RawByteString): TKvmClipResult; virtual; abstract;
  end;
  TKvmClipboardFactory = function: TKvmClipboardBackend;
implementation
function TKvmClipboardBackend.ChangeStamp: QWord; begin Result:=0; end;
procedure TKvmClipboardBackend.Pump; begin end;
procedure TKvmClipboardBackend.CancelRead; begin end;
end.

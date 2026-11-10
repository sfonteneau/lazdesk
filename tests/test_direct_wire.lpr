program test_direct_wire;
{$mode objfpc}{$H+}

uses SysUtils, kvm_direct_wire;

procedure Check(Condition: Boolean; const Msg: string);
begin
  if not Condition then raise Exception.Create(Msg);
end;

var
  Data, OutData, Packed, Invalid: RawByteString;
  Kind: AnsiChar;
  N: Integer;
  Raised: Boolean;
begin
  // JPEG payloads larger than the old 64-KiB tunnel limit remain one frame.
  Data := StringOfChar('J',160000);
  Data[9] := #0;
  Data[100000] := #255;
  Packed := KvmDirectPack('B',Data);
  Check(Length(Packed)=Length(Data)+1,'message was fragmented');
  Check(KvmDirectUnpack(Packed,Kind,OutData),'binary frame rejected');
  Check((Kind='B') and (OutData=Data),'binary round-trip failed');
  Packed := KvmDirectPack('T','AUTH secret-16-chars jpeg');
  Check(KvmDirectUnpack(Packed,Kind,OutData),'short text frame rejected');
  Check((Kind='T') and (OutData='AUTH secret-16-chars jpeg'),
    'text round-trip failed');
  Invalid := #1 + Data;
  Check(not KvmDirectUnpack(Invalid,Kind,OutData),'invalid kind accepted');
  Check(not KvmDirectUnpack('B',Kind,OutData),'empty frame accepted');
  Invalid := StringOfChar('x',KVM_DIRECT_FRAME_MAX_BYTES + 1);
  Invalid[1] := 'B';
  Invalid := Invalid+'x';
  Check(not KvmDirectUnpack(Invalid,Kind,OutData),'oversized frame accepted');
  Raised := False;
  try
    Packed := KvmDirectPack('B',Copy(Invalid,2,Length(Invalid)));
  except on ERangeError do Raised := True; end;
  Check(Raised,'oversized outgoing frame accepted');
  N := Length(Data);
  WriteLn('OK: full direct KVM messages (including ',N,'-byte binary frame)');
end.

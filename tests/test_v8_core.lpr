program test_v8_core;
{$mode objfpc}{$H+}
uses SysUtils, kvm_wire, kvm_flow, kvm_frame, kvm_damage, kvm_cursor, kvm_keysym;
procedure Check(OK: Boolean; const Msg: string);
begin if not OK then raise Exception.Create(Msg); end;
var CP: TKvmCodePoints; Text: RawByteString; I: Integer;
  F,G: TRgbFrame; Pixels: TKvmArgbPixels;
  State: TKvmFlowState; Batch: TKvmFlowBatch;
  Cache: array[0..0] of RawByteString; Versions: array[0..0] of Cardinal;
  Groups: array[0..0] of Integer;
begin
  Text := 'A'+#$c3+#$a9+#$f0+#$9f+#$98+#$80;
  Check(ReadTextCommit('U'+Text,CP),'three scalar commit');
  Check((Length(CP)=3) and (CP[0]=$41) and (CP[1]=$e9) and (CP[2]=$1f600),'UTF8 decode');
  Check(MakeTextUtf8(Text)='U'+Text,'multi-scalar wire');
  Check(not ReadTextCommit('Uab'+#$c0+#$80,CP),'overlong sequence rejected');
  Check(Length(CP)=0,'no partial invalid commit');
  Check(not ReadTextCommit('U'+#$ed+#$a0+#$80,CP),'surrogate rejected');
  Check(not ReadTextCommit('U'+#$f4+#$90+#$80+#$80,CP),'out of Unicode range');
  Check(not ReadTextCommit('Ua'+#10,CP),'control char rejected');
  Check(not ReadTextCommit('U'+StringOfChar('a',257),CP),'scalar budget');
  Check(ReadTextCommit('U'+StringOfChar('a',256),CP),'exact scalar budget');
  Check(not ReadTextCommit('U'+StringOfChar('a',1025),CP),'byte budget');

  Cache[0] := MakeTile(0,0,1,1,#$ff+#$d8+#$ff+#$d9); Versions[0]:=1; Groups[0]:=0;
  InitFlow(State); State.Serial:=High(Cardinal);
  Check(PrepareFlowBatch(State,Cache,Versions,Groups,False,0,0,100,Batch),'wrap prepare');
  Check(Batch.Serial=1,'explicit serial wrap under -Co');
  InvalidateFlowGeometry(State);
  Check(not PrepareFlowBatch(State,Cache,Versions,Groups,False,0,0,101,Batch),'pause cannot abandon flight');
  Check(RejectFlowBatch(State,1),'reject unsent atomic queue attempt');
  Check(PrepareFlowBatch(State,Cache,Versions,Groups,False,0,0,102,Batch) and Batch.SendScreen,'queue retry resync');
  Check(AcknowledgeFlowBatch(State,Batch.Serial),'ACK retry');

  F.Width:=4; F.Height:=4; F.RGB:=''; G:=F;
  Check(RegionTileChanged(F,G,0,0,4,4),'malformed RGB never dereferenced');
  Check(not AllocateFrame(F,32768,32768),'one frame allocation matches protocol limit');
  Check(AllocateFrame(F,4,4),'small frame');
  for I:=1 to Length(F.RGB) do F.RGB[I]:=#100;
  G:=F; SetLength(Pixels,1); Pixels[0]:=$80800000;
  Check(CompositeCursor(F,4,4,1,1,1,1,Pixels),'premultiplied cursor');
  I:=(1*4+1)*3+1;
  Check((Ord(F.RGB[I])=178) and (Ord(F.RGB[I+1])=50),'alpha blend');
  Check(Ord(G.RGB[I])=100,'cursor does not mutate shared frame alias');
  Check(CompositeCursor(F,4,4,-20,-20,1,1,Pixels),'offscreen cursor safely clipped');
  Check(KvmKeysym($25)=$ff51,'left key mapping');
  Check(KVM_SUBPROTOCOL='lazdesk9','v8 protocol only');
  WriteLn('PASS: Pascal v8 commit/limits/serial wrap/cursor/frame/keysym tests');
end.

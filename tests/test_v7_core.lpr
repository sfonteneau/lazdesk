program test_v7_core;
{$mode objfpc}{$H+}
uses SysUtils, kvm_geometry, kvm_adaptive, kvm_mouse_state, kvm_frame, kvm_jpeg_guard;
procedure Check(OK: Boolean; const Why: string);
begin if not OK then raise Exception.Create(Why); end;
var
  B: TKvmBounds; NX, NY: Word; X, Y, I, W, H, Q, FPS: Integer;
  S: TKvmAdaptiveState; Mouse: TKvmMouseState;
  E, Button: Cardinal; NowTick: QWord; A, C: TRgbFrame; J: RawByteString;
begin
  B.X := -1920; B.Y := -20; B.W := 1920; B.H := 1080;
  Check(DenormalizePoint(B,0,0,X,Y) and (X=-1920) and (Y=-20),'negative monitor origin');
  Check(DenormalizePoint(B,65535,65535,X,Y) and (X=-1) and (Y=1059),'last pixel');
  Check(NormalizePoint(B,X,Y,NX,NY) and (NX=65535) and (NY=65535),'inverse corner');
  Check(not NormalizePoint(B,0,0,NX,NY),'cursor outside selected monitor hidden');
  B.W := 1; B.H := 1;
  Check(DenormalizePoint(B,65535,65535,X,Y) and (X=B.X),'single-pixel display');
  B.W := 0; Check(not DenormalizePoint(B,0,0,X,Y),'unplugged display');

  FillChar(Mouse,SizeOf(Mouse),0);
  Check(QuartzMouseEvent(Mouse,0,0,E,Button) and (E=5),'unpressed move');
  Check(QuartzMouseEvent(Mouse,1,1,E,Button) and (E=1),'left down');
  Check(QuartzMouseEvent(Mouse,0,0,E,Button) and (E=6),'left drag');
  Check(QuartzMouseEvent(Mouse,2,1,E,Button) and (E=2),'left up');
  Check(QuartzMouseEvent(Mouse,0,0,E,Button) and (E=5),'drag stops after release');
  Check(QuartzMouseEvent(Mouse,1,2,E,Button),'right down');
  Check(QuartzMouseEvent(Mouse,0,0,E,Button) and (E=7) and (Button=1),'right drag');
  Check(QuartzMouseEvent(Mouse,2,2,E,Button),'right up');
  Check(QuartzMouseEvent(Mouse,1,3,E,Button),'middle down');
  Check(QuartzMouseEvent(Mouse,0,0,E,Button) and (E=27) and (Button=2),'middle drag');
  Check(not QuartzMouseEvent(Mouse,3,1,E,Button),'invalid action');

  InitAdaptive(S); NowTick := 10000;
  for I:=1 to 3 do begin Inc(NowTick,1000); ObserveAck(S,NowTick,1200,524288,True); end;
  Check(S.Profile=1,'slow viewer reduced');
  for I:=1 to 3 do begin Inc(NowTick,1000); ObserveAck(S,NowTick,1200,524288,True); end;
  Check(S.Profile=1,'cooldown prevents oscillation');
  Inc(NowTick,5000); ObserveAck(S,NowTick,1200,524288,True);
  Check(S.Profile=2,'second downgrade');
  for I:=1 to 60 do begin Inc(NowTick,500); ObserveAck(S,NowTick,80,524288,True); end;
  Check(S.Profile=0,'stable fast path recovers');
  InitAdaptive(S);
  for I:=1 to 20 do ObserveAck(S,I*1000,1200,100,True);
  Check(S.Profile=0,'cursor-only ACKs ignored');
  for I:=1 to 20 do ObserveAck(S,I*1000,1200,524288,False);
  Check(S.Profile=0,'no-adaptive fixes profile');
  Check((AdaptiveBudget(S)>=128*1024) and (AdaptiveBudget(S)<=3*1024*1024),'budget clamp');
  ProfileSettings(2,3840,2160,80,30,W,H,Q,FPS);
  Check((W=1920) and (H=1080) and (Q=35) and (FPS=3),'low profile settings');
  ProfileSettings(0,3840,2160,100,0,W,H,Q,FPS);
  Check((W=3840) and (H=2160) and (Q=100) and (FPS=0),'unpaced full profile');
  ProfileSettings(1,3840,2160,100,0,W,H,Q,FPS);
  Check((Q=55) and (FPS=30),'balanced profile has bounded FPS with unlimited base');
  ProfileSettings(2,3840,2160,100,0,W,H,Q,FPS);
  Check((Q=35) and (FPS=10),'low profile has bounded FPS with unlimited base');

  Check(AllocateFrame(A,4,2),'frame allocation');
  for I:=1 to Length(A.RGB) do A.RGB[I]:=AnsiChar(I);
  Check(ResizeFrame(A,2,1,C),'resize');
  Check((C.Width=2) and (C.Height=1) and (C.RGB[1]=#1) and (C.RGB[4]=#7),'nearest-neighbour coordinates');
  C:=A; Check(AllocateFrame(A,4,2),'unique write buffer'); A.RGB[1]:=#99;
  Check(C.RGB[1]=#1,'copy-on-write protects a retained frame');
  // Baseline SOF and SOS headers; this fixture is not a decodable JPEG.
  J:=#$ff+#$d8+#$ff+#$c0+#0+#11+#8+#0+#2+#0+#4+#1+#1+#17+#0;
  Check(not JpegMatchesSize(J,4,2),'SOF without scan rejected');
  J := J + #$ff+#$da+#0+#8+#1+#1+#0+#0+#63+#0;
  Check(JpegMatchesSize(J,4,2),'JPEG header accepted');
  Check(not JpegMatchesSize(J,8,2),'JPEG dimensions checked before allocation');
  Check(not JpegMatchesSize(Copy(J,1,15)+Copy(J,3,13)+Copy(J,16,10),4,2),
    'multiple SOF headers rejected');
  Check(not JpegMatchesSize(Copy(J,1,8),4,2),'truncated JPEG rejected');
  Check(not JpegMatchesSize(#$ff+#$d8+#$ff+#$da,4,2),'scan before SOF rejected');
  WriteLn('OK: geometry, macOS drag state, adaptive profiles, resize and JPEG guard');
end.

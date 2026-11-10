program test_native_resolution;
{$mode objfpc}{$H+}
uses SysUtils, kvm_frame, kvm_wire, kvm_adaptive;
procedure Check(B: Boolean; const Explanation: string);
begin
  if not B then raise Exception.Create(Explanation);
end;
var W,H,Q,FPS: Integer; SW,SH: Word;
begin
  // These checks validate dimensions only. Large frames are never allocated.
  Check(ScaledSize(7680,2160,KVM_MAX_FRAME_SIDE,KVM_MAX_FRAME_SIDE,W,H)
    and (W=7680) and (H=2160),'2 UHD monitors unscaled');
  Check(ScaledSize(15360,2160,KVM_MAX_FRAME_SIDE,KVM_MAX_FRAME_SIDE,W,H)
    and (W=15360) and (H=2160),'4 UHD monitors unscaled');
  Check(ScaledSize(30720,2160,KVM_MAX_FRAME_SIDE,KVM_MAX_FRAME_SIDE,W,H)
    and (W=30720) and (H=2160),'8 UHD monitors unscaled');
  Check(not ScaledSize(32768,32768,KVM_MAX_FRAME_SIDE,KVM_MAX_FRAME_SIDE,W,H),
    'native mode must reject unsafe pixel count');
  Check(ScaledSize(32768,32768,3840,2160,W,H)
    and (W=2160) and (H=2160),'explicit bounded downscale');
  Check(ReadScreen(MakeScreen(30720,2160),SW,SH)
    and (SW=30720) and (SH=2160),'wire accepts large native desktop');
  Check(not ReadScreen(MakeScreen(32768,32768),SW,SH),
    'wire rejects oversized native desktop');
  ProfileSettings(0,KVM_MAX_FRAME_SIDE,KVM_MAX_FRAME_SIDE,90,20,W,H,Q,FPS);
  Check((W=KVM_MAX_FRAME_SIDE) and (H=KVM_MAX_FRAME_SIDE)
    and (Q=90) and (FPS=20),'high profile is unscaled');
  WriteLn('PASS: native multi-monitor dimensions and independent safety limits');
end.

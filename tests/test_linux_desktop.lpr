program test_linux_desktop;
{$mode objfpc}{$H+}
uses cthreads, SysUtils, kvm_capture_x11, kvm_inject_x11, kvm_monitors, kvm_frame;
var Reason: string; F: TRgbFrame; A: TKvmMonitors; X,Y: Word;
begin
  if not CheckX11Display(Reason) then raise Exception.Create(Reason);
  if not CheckX11Control(Reason) then raise Exception.Create(Reason);
  if not ConfigureMonitor(0,Reason) then raise Exception.Create(Reason);
  try
    A:=EnumerateMonitors;
    if Length(A)=0 then raise Exception.Create('No displays');
    if not CaptureDesktopRgb(640,360,F) then raise Exception.Create('Capture #1 failed');
    if not CaptureDesktopRgb(640,360,F) then raise Exception.Create('Capture #2 failed');
    if Length(F.RGB) <> F.Width*F.Height*3 then raise Exception.Create('Bad RGB size');
    InjectMouse(0,0,32768,32768);
    if not GetCursorNormalized(X,Y) then raise Exception.Create('Cursor not visible');
    if (Abs(Integer(X)-32768)>200) or (Abs(Integer(Y)-32768)>200) then
      raise Exception.Create('Input/capture coordinates disagree');
    WriteLn('OK: Linux persistent capture and input on Xvfb: ',F.Width,'x',F.Height);
  finally CloseCapture; end;
end.

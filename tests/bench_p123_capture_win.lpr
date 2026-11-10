program bench_p123_capture_win;
{$mode objfpc}{$H+}
// Run explicitly from an unlocked interactive desktop. No server/network test.
uses Windows, SysUtils, kvm_frame, kvm_monitors, kvm_capture_win, kvm_capture_dxgi;
var Frame: TRgbFrame; Reason: string; I,Ok,N: Integer; T0,T1,Freq,Total,Worst: Int64;
procedure Bench(IsDxgi: Boolean);
var Success: Boolean;
begin
  Total:=0; Worst:=0; Ok:=0;
  for I:=1 to N do
  begin
    QueryPerformanceCounter(T0);
    if IsDxgi then Success:=CaptureDxgi(3840,2160,Frame)
    else Success:=kvm_capture_win.CaptureDesktopRgb(3840,2160,Frame);
    QueryPerformanceCounter(T1);
    if Success then
    begin
      Inc(Ok); Inc(Total,T1-T0); if T1-T0>Worst then Worst:=T1-T0;
      if (not IsDxgi) and (Frame.Order<>kpoBGR) then raise Exception.Create('GDI format is not BGR');
    end;
    Sleep(10);
  end;
  if Ok=0 then raise Exception.Create('No frame captured');
  if IsDxgi then Write('DXGI') else Write('GDI-BGR24');
  WriteLn(': captures=',Ok,'/',N,' size=',Frame.Width,'x',Frame.Height,
    ' mean_ms=',(Total*1000.0/Freq/Ok):0:3,' max_ms=',(Worst*1000.0/Freq):0:3);
end;
begin
  N:=120; if ParamCount>0 then N:=StrToInt(ParamStr(1));
  if (N<1) or (N>10000) then raise Exception.Create('Capture count outside 1..10000');
  if not QueryPerformanceFrequency(Freq) then raise Exception.Create('QPC unavailable');
  if not ConfigureMonitor(1,Reason) then raise Exception.Create(Reason);
  try Bench(False); finally CloseCapture; end;
  if CheckDxgi(Reason) then
    try Bench(True); finally CloseDxgi; end
  else WriteLn('NOT RUN: DXGI: ',Reason);
  WriteLn('Capture calls only, not FPS, not end-to-end latency; DXGI may reuse unchanged frames.');
end.

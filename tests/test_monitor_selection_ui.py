from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
form = (ROOT/'client/kvm_view_form.pas').read_text(encoding='utf-8')
server = (ROOT/'server/kvm_server.pas').read_text(encoding='utf-8')
monitors = (ROOT/'server/kvm_monitors.pas').read_text(encoding='utf-8')
present = (ROOT/'client/kvm_present_win.pas').read_text(encoding='utf-8')
assert "FMenuMonitors.Caption:='Monitors'" in form
assert "Item.Caption:='All monitors'" in form
assert "Item.Caption:=Format('Monitor %d  -  %dx%d'" in form
assert 'procedure TKvmViewForm.MonitorMenuClick' in form
assert 'FRemoteMonitorSelected[Index]:=not FRemoteMonitorSelected[Index]' in form
assert 'SelectedRemoteMonitorCount<=1' in form
assert 'TCheckListBox.Create(Dlg)' not in form
assert 'SelectedRemoteMonitorCount' in form
assert 'WantSpan:=(SelectedCount>1)' in form
assert 'WorkareaRect' in form
assert 'LocalMonitorWorkRect' in form
assert 'KvmSafeMonitorWorkRect' in form
assert 'FView.ClientToScreen(Point(0,0))' in form
assert "Shell_TrayWnd" in present
assert "Shell_SecondaryTrayWnd" in present
assert 'function TKvmViewForm.GetLocalSpanRect' in form
assert 'SpanRect.Bottom:=Min(SpanRect.Bottom,R.Bottom)' in form
assert 'SpanRect.Top:=Max(SpanRect.Top,R.Top)' in form
assert 'GetLocalSpanRect(LocalOrder,SpanCount,FFullScreenMode,SpanRect)' in form
assert 'if FFullScreenMode then BorderStyle:=bsNone else BorderStyle:=bsSizeable' in form
assert 'BuildDisplayLayout' in form
assert 'Scale:=Min(1.0,Min(' in form
assert 'Items[Best].SourceRect' in form
assert 'MapRemoteCursorToView' in form
assert 'PaintRegion' in present
assert 'CaptureMonitorLayoutText' in monitors
assert 'SendText(ID,CaptureMonitorLayoutText)' in server
print('PASS: checkable monitor submenu/topology/no-upscale source guards')

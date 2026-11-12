"""Source wiring checks only: neither a Pascal build nor an FPS benchmark."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
def text(path):
    return (ROOT / path).read_text(encoding='utf-8')
class PerformanceSources(unittest.TestCase):
    def test_linear_flow_and_retained_scratch(self):
        source = text('shared/kvm_flow.pas')
        self.assertNotIn('for K := 0 to N - 1', source)
        self.assertIn('State.GroupFlags[Leader]', source)
        ack = source.split('function AcknowledgeFlowBatch', 2)[2].split('function RejectFlowBatch')[0]
        self.assertNotIn('SetLength(State.FlightVersions, 0)', ack)

    def test_three_flight_ack_window(self):
        flow = text('shared/kvm_flow.pas')
        server = text('server/kvm_server.pas')
        self.assertIn('KVM_FLOW_MAX_IN_FLIGHT = 3', flow)
        self.assertIn('FlightCount: Integer', flow)
        self.assertIn('not VersionPending(State, J, Versions[J])', flow)
        demand = server.split('procedure TKvmServer.CaptureDemand', 1)[1].split('procedure TKvmServer.WakeVideoWorkers')[0]
        self.assertNotIn('FlowCanQueue(FClients[I].Flow)', demand)
        self.assertIn('Wanted[P+Ord(FClients[I].H264)*KVM_PROFILE_COUNT] := True', demand)
        self.assertIn('AcknowledgeFlowBatch(FClients[I].Flow, Serial, NowTick)', server)
        dispatch = server.split('procedure TKvmServer.DispatchBatches', 1)[1].split('procedure TKvmServer.ActivateClient')[0]
        self.assertIn('repeat', dispatch)
        self.assertIn('until False', dispatch)


    def test_backpressure_does_not_force_resync(self):
        transport = text('server/kvm_transport.pas')
        server = text('server/kvm_server.pas')
        flow = text('shared/kvm_flow.pas')
        self.assertIn('kqrBusy', transport)
        self.assertIn('QueueResult := QueueFrames(ClientID,Frames)', server)
        self.assertIn('Result:=FSocket.TryQueueEx(ID,Frames)', server)
        dispatch = server.split('procedure TKvmServer.DispatchBatches', 1)[1].split('procedure TKvmServer.ActivateClient')[0]
        self.assertIn('CancelPreparedFlowBatch', dispatch)
        self.assertNotIn('RejectFlowBatch(FClients[Index].Flow, Batch.Serial)', dispatch)
        self.assertIn('function CancelPreparedFlowBatch', flow)

    def test_capture_encode_latest_frame_pipeline(self):
        server = text('server/kvm_server.pas')
        self.assertIn('TEncodeThread = class(TThread)', server)
        self.assertIn('procedure TEncodeThread.SubmitLatest', server)
        self.assertIn('Tmp := FPending;', server)
        self.assertIn('FPending := Frame;', server)
        self.assertIn('FOwner.FEncoderWorker.SubmitLatest(Frame,Started,CursorValid,CX,CY,CursorShape)', server)
        self.assertIn('if not Wanted[P] then', server)
        self.assertIn('if Wanted[P] and CacheValid[P]', server)

    def test_gdi_cursor_is_separate(self):
        capture = text('server/kvm_capture_win.pas')
        desktop = text('server/kvm_desktop.pas')
        self.assertNotIn('procedure DrawCursor', capture)
        self.assertNotIn('DrawCursor(MemDC', capture)
        self.assertIn('LastCaptureCursorEmbedded := False', desktop)
        self.assertIn('CursorValid:=GetDesktopCursorState(CX,CY,CursorShape)', text('server/kvm_server.pas'))
        inject = text('server/kvm_inject_win.pas')
        self.assertIn('GetCursorInfo(C)', inject)
        self.assertIn('InfoValid:=GetCursorInfo(C);', inject)
        self.assertIn('Showing:=InfoValid and ((C.flags and 1)<>0);', inject)
        self.assertIn("external 'user32.dll' name 'GetIconInfo'", inject)
        self.assertIn('KvmGetIconInfo(HICON(Cursor),Info)', inject)
        self.assertIn('DrawIconEx(BlackDC', inject)
        self.assertIn('HashCursorShape', inject)
        wire = text('shared/kvm_wire.pas')
        self.assertIn('MakeCursorShape', wire)
        self.assertIn("Result[1] := 'H'", wire)
        present = text('client/kvm_present_win.pas')
        self.assertIn('function TKvmWinPresenter.UpdateCursor', present)
        self.assertIn('KvmAlphaBlend', present)
        form = text('client/kvm_view_form.pas')
        self.assertIn('KVM_LOCAL_NATIVE_CURSOR', form)
        self.assertIn('InstallLocalNativeCursor(KVM_LOCAL_NATIVE_CURSOR,FFront.CursorShape)', form)
        self.assertIn('function InstallLocalNativeCursor', present)
        self.assertNotIn('InstallLocalDotCursor', present)
        self.assertNotIn('FView.Cursor:=crNone', form)
        self.assertIn('FWinPresenter.CursorRevision=FFront.CursorShape.Revision', form)
        self.assertIn('CursorMoveWasLocalEcho', form)
        self.assertIn('FRemoteCursorOverlay', form)
        self.assertNotIn('KVM_REMOTE_CURSOR_OVERLAY_MS', form)
        self.assertNotIn('FRemoteCursorOverlayUntil', form)
        self.assertNotIn('NowTick>=FRemoteCursorOverlayUntil', form)
        self.assertIn('procedure TKvmViewForm.HideRemoteCursorOverlay;', form)
        self.assertIn('if not FCursorVisible or not FRemoteCursorOverlay then Exit;', form)
        self.assertIn('ReadMouse(Payload,MouseAction,Button,MX,MY)', form)
        self.assertIn('KVM_CURSOR_HIDE_DEBOUNCE_MS', inject)
        self.assertIn('(DeltaB+DeltaG+DeltaR)<-192', inject)
        self.assertNotIn('LastCursorShapeTick', inject)
        # Remote movement must be a real Windows input event so native hover
        # states (menus/list views/TrackMouseEvent) update like a physical mouse.
        self.assertIn('function SendAbsoluteMouseMove', inject)
        self.assertIn('KVM_MOUSEEVENTF_VIRTUALDESK', inject)
        self.assertIn('KVM_MOUSEEVENTF_ABSOLUTE', inject)
        self.assertIn('KVM_MOUSEEVENTF_MOVE', inject)
        inject_mouse = inject.split('procedure InjectMouse', 2)[2].split('procedure InjectText', 1)[0]
        self.assertIn('SendAbsoluteMouseMove(X,Y)', inject_mouse)
        self.assertNotIn('SetCursorPos', inject_mouse)

    def test_monitor_topology_selection_and_no_upscale(self):
        monitors = text('server/kvm_monitors.pas')
        server = text('server/kvm_server.pas')
        form = text('client/kvm_view_form.pas')
        present = text('client/kvm_present_win.pas')
        self.assertIn('function CaptureDesktopMonitorCount', monitors)
        self.assertIn('function CaptureMonitorLayoutText', monitors)
        self.assertIn("Result := Format('MONITOR_LAYOUT %d %d %d'", monitors)
        self.assertNotIn("SendText(Sender,'MONITORS '", server)
        self.assertNotIn("FRemoteMonitorCount", form)
        self.assertIn('SendText(ID,CaptureMonitorLayoutText)', server)
        self.assertIn("Copy(TextMsg,1,15) = 'MONITOR_LAYOUT '", form)
        self.assertIn('procedure TKvmViewForm.MonitorMenuClick', form)
        self.assertIn("Item.Caption:=rsViewerMonitorAll", form)
        self.assertIn('FRemoteMonitorSelected[Index]:=not FRemoteMonitorSelected[Index]', form)
        self.assertNotIn('TCheckListBox.Create(Dlg)', form)
        self.assertIn('function TKvmViewForm.BuildDisplayLayout', form)
        self.assertIn('Scale:=Min(1.0,Min(', form)
        self.assertIn('function TKvmWinPresenter.PaintRegion', present)
        self.assertIn('Items[I].SourceRect', form)
        self.assertIn('Items[Best].SourceRect', form)
        self.assertIn('BorderStyle:=bsNone', form)
        self.assertIn('FPreferMaximized := Options.Maximized', form)

    def test_classic_menu_bar_and_f11_fullscreen(self):
        form = text('client/kvm_view_form.pas')
        self.assertIn('Menus,', form)
        self.assertIn('FMainMenu: TMainMenu', form)
        self.assertIn("FFileMenu.Caption:='File'", form)
        self.assertIn("FViewMenu.Caption:='View'", form)
        self.assertIn("FControlMenu.Caption:='Control'", form)
        self.assertIn("FMenuMonitors.Caption:='Monitors'", form)
        self.assertIn("Item.Caption:=rsViewerMonitorAll", form)
        self.assertIn("FMenuFullscreen.Caption:='Full screen'+#9+'F11'", form)
        self.assertIn('if Key = VK_F11 then', form)
        self.assertNotIn('if Key = VK_F8 then', form)
        self.assertIn('ToggleFullScreen;', form)
        self.assertIn('if FFullScreenMode then Menu:=nil else Menu:=FMainMenu', form)
        self.assertNotIn('FMenuButton', form)

    def test_windows_persistent_dib_and_damage(self):
        present = text('client/kvm_present_win.pas')
        worker = text('client/kvm_video_worker.pas')
        form = text('client/kvm_view_form.pas')
        self.assertIn('TKvmWinPresenter = class', present)
        self.assertIn('CreateDIBSection', present)
        self.assertIn('function TKvmWinPresenter.Update', present)
        self.assertIn('Damage: TRect', worker)
        self.assertIn('AddDamage(FBatchDamage', worker)
        self.assertIn('FWinPresenter.Update(FFront.Surface,Damage)', form)
        self.assertIn('InvalidateDamage(Damage)', form)

    def test_canonical_pixels_never_published(self):
        pool = text('shared/kvm_surface_pool.pas')
        worker = text('client/kvm_video_worker.pas')
        self.assertIn('StringRefCount(FSlots[I].Surface.Pixels)=1', pool)
        self.assertIn('Slot^.Right[Row]-Slot^.Left[Row]', pool)
        self.assertIn('FSurfaces.Snapshot(FWork.Surface,Image,Bytes)', worker)
        self.assertIn('FPublished.Surface:=Image;', worker)
    def test_cursor_only_avoids_bitmap_import(self):
        source = text('client/kvm_view_form.pas')
        present = source.split('procedure TKvmViewForm.PresentSnapshot', 1)[1].split('procedure TKvmViewForm.PollTimer')[0]
        self.assertLess(present.index('if not ImageChanged then'), present.index('FBitmap.LoadFromRawImage'))
        self.assertIn('FFront.ImageRevision<>Snapshot.ImageRevision', present)
        self.assertIn('Cursor-only batches never reimport the framebuffer.', present)
        self.assertIn('InvalidateCursor(FCursorX,FCursorY,True)', present)
    def test_scaling_maps_in_hot_paths(self):
        for path in ('server/kvm_capture_x11.pas', 'server/kvm_video.pas'):
            source = text(path)
            self.assertNotIn('SX := (Int64(X)', source)
            self.assertNotIn('SX:=(Int64(X)', source)
            self.assertIn('ScaleMap', source)
    def test_codec_requires_current_native_bridge(self):
        codec = text('shared/kvm_codec.pas')
        self.assertIn('Assigned(EncodeBgrProc)', codec)
        self.assertIn('Assigned(DecodeBgrxProc)', codec)
        self.assertNotIn('FFrameScratch', codec)
        self.assertNotIn('FRgbScratch', codec)
        self.assertIn('#define ABI 0x00090001u', text('native/codec/kvm_codec.c'))
        for symbol in ('lazdesk_encode_bgr24', 'lazdesk_decode_bgrx32'):
            for path in ('native/codec/kvm_codec.h', 'native/codec/kvm_codec.c',
                         'shared/kvm_codec.pas', 'shared/kvm_codec_static.pas'):
                self.assertIn(symbol, text(path))
    def test_dxgi_cached_clean_rgb_and_partial_conversion(self):
        source = text('native/windows/kvm_dxgi.cpp')
        self.assertIn('for (const auto &r:c->damage)', source)
        self.assertIn('kvm_pixels_rgb_rect', source)
        self.assertIn('desktop_changed || full_conversion', source)
        self.assertIn('if (copy_result) std::memcpy(rgb,c->rgb_pixels.data()', source)
        self.assertNotIn('draw_cursor(',source)
        self.assertIn('kvm_dxgi_cursor_embedded',source)
if __name__ == '__main__':
    unittest.main(verbosity=2)

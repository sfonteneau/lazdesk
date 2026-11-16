"""Static implementation contracts for merged / independently detached viewers.

Run native LCL/Win32 tests as well: these checks cannot simulate DPI focus or GDI.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
VIEW = (ROOT / 'client/kvm_view_form.pas').read_text(encoding='utf-8')
I18N = (ROOT / 'client/kvm_viewer_i18n.pas').read_text(encoding='utf-8')


def section(method: str, next_method: str) -> str:
    first = VIEW.index(method, VIEW.index('implementation'))
    second = VIEW.index(next_method, first + len(method))
    return VIEW[first:second]


def test_default_fusion_and_menu_toggle():
    parse = section('procedure TKvmViewForm.ParseMonitorLayout(',
                    'procedure TKvmViewForm.RebuildMonitorMenu;')
    assert 'FRemoteMonitorDetached[I]:=False' in parse
    assert 'FRemoteMonitorDetached[I]:=OldDetached[I]' in parse
    menu = section('procedure TKvmViewForm.RebuildMonitorMenu;',
                   'procedure TKvmViewForm.SyncMonitorMenu;')
    assert 'FMenuFusion.Caption:=rsViewerMenuFusion' in menu
    assert 'Item.OnClick:=@FusionMenuClick' in menu
    sync = section('procedure TKvmViewForm.SyncMonitorMenu;',
                   'procedure TKvmViewForm.FusionMenuClick(')
    assert 'not FRemoteMonitorDetached[I]' in sync
    assert 'FRemoteMonitorSelected[I]' in sync
    assert 'not FEmbeddedMode' in sync
    toggle = section('procedure TKvmViewForm.FusionMenuClick(',
                     'procedure TKvmViewForm.MonitorMenuClick(')
    assert 'FRemoteMonitorDetached[I]:=not FRemoteMonitorDetached[I]' in toggle
    assert 'SyncDetachedWindows;' in toggle
    assert 'ApplyMonitorLayout;' in toggle


def test_windows_share_session_and_detached_close_reattaches():
    new_form = section('constructor TKvmDetachedMonitorForm.CreateMonitor(',
                       'procedure TKvmDetachedMonitorForm.RefreshCaption;')
    assert 'inherited CreateNew(ASession,1);' in new_form
    assert 'FView:=TPaintBox.Create(Self)' in new_form
    assert 'FView.OnPaint:=@ASession.PaintView' in new_form
    assert 'FView.OnMouseDown:=@ASession.ViewMouseDown' in new_form
    assert 'OnKeyDown:=@ASession.RemoteKeyDown' in new_form
    assert 'TKvmVideoWorker.Create' not in new_form
    assert 'THttpClientWebSockets.Create' not in new_form
    closing = section('procedure TKvmViewForm.DetachedWindowClosed(',
                      'procedure TKvmViewForm.InvalidateAllViews;')
    assert 'FRemoteMonitorDetached[I]:=False' in closing
    assert 'FDetachedWindows[I]:=nil' in closing
    assert 'ApplyMonitorLayout' in closing
    assert 'CloseSocket' not in closing
    release = section('procedure TKvmViewForm.CloseSocket;',
                      'procedure TKvmViewForm.ConnectClick(')
    assert 'FreeDetachedWindows;' in release


def test_source_region_is_not_recaptured_or_redecoded():
    display = section('function TKvmViewForm.BuildDisplayLayoutFor(',
                      'function TKvmViewForm.MapRemoteCursorToView(')
    assert 'RemoteOnly:=MonitorForView(AView)' in display
    assert 'Src:=SourceForRemote(RemoteOnly)' in display
    assert 'Scale:=Min(AView.Width/SrcW,AView.Height/SrcH)' in display
    assert 'N:=FusedRemoteMonitorCount' in display
    assert 'FRemoteMonitorSelected[I] and not FRemoteMonitorDetached[I]' in display
    assert 'FFront.Surface.Width' in display
    paint = section('procedure TKvmViewForm.PaintView(',
                    'function TKvmViewForm.ToNormalized(')
    assert 'AView:=TPaintBox(Sender)' in paint
    assert 'FWinPresenter.PaintRegion(AView.Canvas.Handle' in paint
    assert 'MapRemoteCursorToView(AView,' in paint
    damage = section('procedure TKvmViewForm.InvalidateDamage(',
                     'procedure TKvmViewForm.PresentSnapshot(')
    assert 'InvalidateDamageInView(FDetachedWindows[I].View,Damage)' in damage
    assert 'BuildDisplayLayoutFor(AView,Items)' in damage


def test_input_mapping_and_per_window_fullscreen():
    assert VIEW.count('ToNormalized(AView, X, Y, NX, NY)') >= 4
    assert 'ResolveDragView(AView,X,Y)' in VIEW
    assert 'SetCaptureControl(AView)' in VIEW
    assert 'if FMouseButtons=0 then ReleaseSessionCapture' in VIEW
    assert 'if Sender is TKvmDetachedMonitorForm then' in VIEW
    assert 'TKvmDetachedMonitorForm(Sender).ToggleFullScreen' in VIEW
    assert 'KVM_FOCUS_GRACE_MS = 60' in VIEW
    assert 'if SessionWindowActive then FDeactivationPending:=False' in VIEW
    assert 'ActiveWindow:=Screen.ActiveCustomForm' in VIEW
    assert 'if FAuthorized and FControlGranted then SendPacket(\'Z\')' in VIEW


def test_i18n_translations_and_embedded_mode():
    assert "rsViewerMenuFusion = 'Fusion'" in I18N
    assert 'rsViewerViewAllDetached' in I18N
    for language in ('fr', 'en', ''):
        po = ROOT / 'client/languages' / ('LazDeskClient' + ('.'+language if language else '') + '.po')
        text = po.read_text(encoding='utf-8')
        assert 'kvm_viewer_i18n.rsviewermenufusion' in text
        assert 'kvm_viewer_i18n.rsviewerviewalldetached' in text
        assert text.count('msgid "Fusion"') == 1
    assert 'WantWindow:=not FClosing and not FEmbeddedMode and FAuthorized' in VIEW
    assert 'Menu := nil' in VIEW


def test_method_declarations_and_implementations_agree():
    # Catch accidental class methods that were declared but omitted.
    header = VIEW[VIEW.index('TKvmViewForm = class(TForm)'):VIEW.index('TKvmDetachedMonitorForm = class(TForm)')]
    required = re.findall(r'^    (?:procedure|function) (\w+)\(', header, re.M)
    required += re.findall(r'^    (?:procedure|function) (\w+);', header, re.M)
    for method in required:
        assert re.search(r'\b(?:procedure|function) TKvmViewForm\.'+re.escape(method)+r'\b', VIEW), method

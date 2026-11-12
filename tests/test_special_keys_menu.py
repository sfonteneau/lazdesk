"""Static regression checks for special-key menu and Windows SAS protocol.

Does not replace compilation or live Windows/LCL testing.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VIEW = (ROOT / 'client/kvm_view_form.pas').read_text()
QUEUE = (ROOT / 'shared/kvm_input_queue.pas').read_text()
WIRE = (ROOT / 'shared/kvm_wire.pas').read_text()
SERVER = (ROOT / 'server/kvm_server.pas').read_text()
DESKTOP = (ROOT / 'server/kvm_desktop.pas').read_text()
WIN = (ROOT / 'server/kvm_inject_win.pas').read_text()


def test_viewer_menu_shortcut_entries_and_access():
    assert "FMenuSpecialKeys.Caption:='Send special keys'" in VIEW
    assert 'FControlMenu.Add(FMenuSpecialKeys)' in VIEW
    for caption in ('Ctrl+Alt+Del (Windows)', 'F11 (remote)',
                    'Windows key (Start)', 'Ctrl+Esc (Start)',
                    'Alt+Tab (switch window)', 'Ctrl+Shift+Esc (Task Manager)',
                    'Win+R (Run)', 'Win+E (Explorer)', 'Win+D (desktop)',
                    'Win+L (lock remote session)', 'Alt+F4 (close window)'):
        assert "AddSpecialKeyItem('" + caption + "'" in VIEW
    assert "AddSpecialKeyItem('F8" not in VIEW
    assert 'FMenuSpecialKeys.Enabled:=ControlAllowed' in VIEW
    assert 'if not (Sender is TMenuItem) or not ControlAllowed then Exit;' in VIEW
    assert "SetStatus(rsViewerStatusControlGranted);\n      SyncMainMenu;" in VIEW


def test_remote_f11_does_not_toggle_local_fullscreen():
    assert 'if Key = VK_F11 then' in VIEW
    handler = VIEW.split('procedure TKvmViewForm.SpecialKeyClick(Sender: TObject);', 2)[-1]
    handler = handler.split('procedure TKvmViewForm.ClipboardMenuClick', 1)[0]
    assert 'KVM_SPECIAL_F11: begin Keys[0]:=VK_F11; Count:=1; end' in handler
    assert 'ToggleFullScreen' not in handler
    assert 'Keys[0]:=$5b; Count:=1;' in handler
    assert "MessageDlg(rsViewerDialogLockWarning," in handler
    assert 'for I:=0 to Count-1 do SendPacket(MakeKey(True,Keys[I]));' in handler
    assert 'for I:=Count-1 downto 0 do SendPacket(MakeKey(False,Keys[I]));' in handler


def test_sas_request_is_queued_validated_and_authorized():
    assert "SendPacket('Q');" in VIEW
    assert "'P','R','G','L','Z','Q': Result:=Length(Payload)=1;" in VIEW
    assert "['K','M','W','U','Q']" in VIEW
    assert "['K','M','W','U','Q']" in QUEUE
    assert "(Packet[1]='Q') and (Length(Packet)<>1)" in QUEUE
    assert 'Q                                          Windows secure attention' in WIRE
    assert "'P','R','G','L','Z','Q': Valid:=Length(Frame.payload)=1;" in SERVER
    assert "'Q': HandleSecureAttention(ID);" in SERVER
    handler = SERVER.split('procedure TKvmServer.HandleSecureAttention(ID: THttpServerConnectionID);', 2)[-1]
    handler = handler.split('function TKvmServer.RejectText', 1)[0]
    for check in ('FClients[I].CanControl', '(FController=ID)',
                  'FDesktopAvailable', 'DesktopSessionAvailable'):
        assert check in handler
    assert "Status:='SAS DENIED'" in handler
    assert "if RequestDesktopSecureAttention then Status:='SAS REQUESTED'" in handler


def test_windows_native_sas_does_not_fake_ctrl_alt_del():
    assert 'function RequestDesktopSecureAttention: Boolean;' in DESKTOP
    assert '{$IFDEF WINDOWS}Result:=kvm_inject_win.RequestSecureAttention;{$ENDIF}' in DESKTOP
    code = WIN.split('function RequestSecureAttention: Boolean;', 2)[-1]
    code = code.split('procedure InjectWheel', 1)[0]
    assert 'Windows.GetSystemDirectoryW' in code
    assert 'Windows.LoadLibraryW(PWideChar(SasPath))' in code
    assert "Windows.GetProcAddress(SasLib,PChar('SendSAS'))" in code
    assert 'SendSASProc(True);' in code
    assert 'KvmSendInput' not in code
    assert "TextMsg = 'SAS REQUESTED'" in VIEW
    assert 'rsViewerStatusSasRequested' in VIEW
    assert 'Windows may block it' in (ROOT/'client/kvm_viewer_i18n.pas').read_text()

"""Static regressions for key chords, lock workstation, and privileged SAS.

These tests do not replace a Lazarus build or live Windows integration tests.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VIEW = (ROOT / 'client/kvm_view_form.pas').read_text(encoding='utf-8')
QUEUE = (ROOT / 'shared/kvm_input_queue.pas').read_text(encoding='utf-8')
WIRE = (ROOT / 'shared/kvm_wire.pas').read_text(encoding='utf-8')
SERVER = (ROOT / 'server/kvm_server.pas').read_text(encoding='utf-8')
DESKTOP = (ROOT / 'server/kvm_desktop.pas').read_text(encoding='utf-8')
WIN = (ROOT / 'server/kvm_inject_win.pas').read_text(encoding='utf-8')
I18N = (ROOT / 'client/kvm_viewer_i18n.pas').read_text(encoding='utf-8')


def routine(text, signature, next_signature):
    return text.split(signature)[-1].split(next_signature)[0]


def test_menu_entries_no_alt_f4_and_exclusive_control():
    assert "FMenuSpecialKeys.Caption:='Send special keys'" in VIEW
    assert 'FControlMenu.Add(FMenuSpecialKeys)' in VIEW
    for caption in ('Ctrl+Alt+Del (Windows)', 'F11 (remote)',
                    'Windows key (Start)', 'Ctrl+Esc (Start)',
                    'Alt+Tab (switch window)', 'Ctrl+Shift+Esc (Task Manager)',
                    'Win+R (Run)', 'Win+E (Explorer)', 'Win+D (desktop)',
                    'Win+L (lock remote session)'):
        assert "AddSpecialKeyItem('" + caption + "'" in VIEW
    assert 'Alt+F4' not in VIEW
    assert 'AltF4' not in I18N
    assert 'KVM_SPECIAL_ALT_F4' not in VIEW
    assert 'FMenuSpecialKeys.Enabled:=ControlAllowed' in VIEW
    assert 'if not (Sender is TMenuItem) or not ControlAllowed then Exit;' in VIEW


def test_f11_and_windows_key_unchanged_vs_shortcuts_batched():
    assert 'if Key = VK_F11 then' in VIEW
    handler = routine(VIEW, 'procedure TKvmViewForm.SpecialKeyClick(Sender: TObject);',
                      'procedure TKvmViewForm.ClipboardMenuClick')
    assert 'KVM_SPECIAL_F11: begin Keys[0]:=VK_F11; Count:=1; end' in handler
    assert 'KVM_SPECIAL_START: begin Keys[0]:=$5b; Count:=1; end' in handler
    assert 'ToggleFullScreen' not in handler
    assert 'SendPacket(MakeKey(True,Keys[0]));' in handler
    assert 'SendPacket(MakeKey(False,Keys[0]));' in handler
    assert 'KVM_SPECIAL_CTRL_ESC: begin Keys[0]:=$11; Keys[1]:=$1b; Count:=2; end;' in handler
    assert 'SendPacket(MakeShortcut(Slice(Keys,Count)));' in handler
    assert 'for I:=0 to Count-1 do SendPacket(MakeKey(' not in handler
    assert 'KVM_MAX_SHORTCUT_KEYS = 3;' in WIRE
    assert 'function ReadShortcut(const S:' in WIRE
    assert "Result[1]:='Y'; Result[2]:=AnsiChar(Length(Keys));" in WIRE
    assert "(S[1]<>'Y')" in WIRE
    assert "(Packet[1]='Y') and not ReadShortcut(Packet,Keys)" in QUEUE
    assert "'Y': Result:=ReadShortcut(Payload,Keys);" in VIEW
    assert "'Y': Valid:=ReadShortcut(Frame.payload,ShortcutKeys);" in SERVER
    assert "'Y': HandleShortcut(ID,ShortcutKeys);" in SERVER
    server_handler = routine(SERVER,
        'procedure TKvmServer.HandleShortcut(ID: THttpServerConnectionID;',
        'procedure TKvmServer.HandleRemoteLock')
    for check in ('FClients[I].CanControl', '(FController<>ID)',
                  'FDesktopAvailable', 'DesktopSessionAvailable'):
        assert check in server_handler
    assert 'InjectDesktopShortcut(Keys);' in server_handler
    assert 'kvm_inject_win.InjectShortcut(Keys)' in DESKTOP
    native = routine(WIN, 'procedure InjectShortcut(const Keys: TKvmShortcutKeys);',
                     'function RequestRemoteLock')
    assert 'KvmSendInput(UINT(2*N),@Inputs[0],SizeOf(TInput))' in native
    assert 'if I>=N then Flags:=Flags or KEYEVENTF_KEYUP;' in native


def test_lock_remote_is_dedicated_privileged_command():
    handler = routine(VIEW, 'procedure TKvmViewForm.SpecialKeyClick(Sender: TObject);',
                      'procedure TKvmViewForm.ClipboardMenuClick')
    assert 'MessageDlg(rsViewerDialogLockWarning,' in handler
    assert "SendPacket('J');" in handler
    assert "Keys[1]:=Ord('L')" not in handler
    assert "['K','M','W','U','Q','J','Y']" in VIEW
    assert "['K','M','W','U','Q','J','Y']" in QUEUE
    assert "(Packet[1] in ['Q','J']) and (Length(Packet)<>1)" in QUEUE
    assert "'P','R','G','L','Z','Q','J': Valid:=Length(Frame.payload)=1;" in SERVER
    assert "'J': HandleRemoteLock(ID);" in SERVER
    lock = routine(SERVER,
        'procedure TKvmServer.HandleRemoteLock(ID: THttpServerConnectionID);',
        'procedure TKvmServer.HandleSecureAttention')
    for check in ('FClients[I].CanControl', '(FController=ID)',
                  'FDesktopAvailable', 'DesktopSessionAvailable'):
        assert check in lock
    for result in ('LOCK DENIED','LOCK REQUESTED','LOCK FAILED','LOCK UNAVAILABLE'):
        assert result in lock and f"TextMsg = '{result}'" in VIEW
    assert 'RequestDesktopLock' in DESKTOP
    assert "name 'LockWorkStation'" in WIN
    assert 'Result:=KvmWinLockWorkStation;' in WIN


def test_sas_reports_privileges_without_faking_secure_attention():
    assert "SendPacket('Q');" in VIEW
    assert "'Q': HandleSecureAttention(ID);" in SERVER
    handler = routine(SERVER,
        'procedure TKvmServer.HandleSecureAttention(ID: THttpServerConnectionID);',
        'function TKvmServer.RejectText')
    for check in ('FClients[I].CanControl', '(FController=ID)',
                  'FDesktopAvailable', 'DesktopSessionAvailable'):
        assert check in handler
    for result in ('SAS DENIED','SAS REQUESTED','SAS PRIVILEGES','SAS UNAVAILABLE'):
        assert result in handler and f"TextMsg = '{result}'" in VIEW
    assert 'function RequestDesktopSecureAttention: TKvmSasResult;' in DESKTOP
    assert '{$IFDEF WINDOWS}Result:=kvm_inject_win.RequestSecureAttention;{$ENDIF}' in DESKTOP
    native = routine(WIN, 'function RequestSecureAttention: TKvmSasResult;',
                     'procedure InjectWheel')
    assert 'Windows.GetSystemDirectoryW' in native
    assert 'Windows.LoadLibraryW(PWideChar(SasPath))' in native
    assert "Windows.GetProcAddress(SasLib,PChar('SendSAS'))" in native
    assert 'KvmWinCanRequestSas(AsUser)' in native
    assert 'SendSASProc(AsUser);' in native
    assert 'KvmSendInput' not in native
    assert 'KvmWinGetTokenInformation(Token,26,' in WIN
    assert 'rsViewerStatusSasPrivileges' in I18N
    assert 'Windows may block it' in I18N


def test_protocol_version_incompatible_clients_rejected_at_handshake():
    assert "KVM_SUBPROTOCOL = 'lazdesk9'" in WIRE
    assert "KVM_SUBPROTOCOL = 'lazdesk8'" not in WIRE

"""Structural regression checks, NOT Pascal compilation/runtime tests."""
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parents[1]
def text(p): return (ROOT/p).read_text()
class ClipboardSourceTests(unittest.TestCase):
    def test_two_independent_defaults(self):
        s=text('client/kvm_view_form.pas')
        for name in ('FClipToRemote','FClipFromRemote'):
            self.assertIn(name+'.Checked:=False',s)
        self.assertIn("FMenuClipToRemote.OnClick:=@ClipboardMenuClick",s)
        self.assertIn("FMenuClipFromRemote.OnClick:=@ClipboardMenuClick",s)
        self.assertIn('procedure TKvmViewForm.ClipboardMenuClick',s)
        self.assertIn('if Allowed and FClipToRemote.Checked then Mask:=Mask or KVM_CLIP_WRITE',s)
        self.assertIn('if Allowed and FClipFromRemote.Checked then Mask:=Mask or KVM_CLIP_READ',s)
    def test_server_authority(self):
        s=text('server/kvm_server.pas')
        body=s.split('function TKvmServer.ClipboardAllowed')[1].split('function TKvmServer.ClipboardReply')[0]
        for token in ('Authenticated','CanControl','FController','FDesktopAvailable','FDesktopEpoch=Epoch','DesktopSessionAvailable'):
            self.assertIn(token,body)
        self.assertIn('Req.Serial=NextSerial(FClients[I].LastClipboardSerial)',s)
        self.assertIn('ClipboardBytes',s)
    def test_not_a_video_packet(self):
        s=text('client/kvm_view_form.pas')
        body=s.split('procedure TKvmViewForm.IncomingFrame')[1].split('procedure TKvmViewForm.PresentSnapshot')[0]
        self.assertIn("Frame.payload[1]='c'",body)
        self.assertIn('FClipboardWorker.EnqueueReply',body)
        self.assertIn('else if FDecoder<>nil',body)
    def test_new_protocol_consistent(self):
        for p in ('shared/kvm_wire.pas','server/LazDeskServer.lpr'):
            self.assertIn('lazdesk9',text(p)); self.assertNotIn('lazdesk7',text(p))
    def test_no_private_binary_or_shell_clipboard(self):
        names=list((ROOT/'shared').glob('kvm_clipboard_*.pas'))+list((ROOT/'client').glob('kvm_clipboard_*.pas'))
        for p in names:
            s=p.read_text()
            for token in ('TProcess','ShellExecute','LoadLibrary','Synchronize(','QueueAsyncCall','WriteLn('):
                self.assertNotIn(token,s,p.name)
    def test_bounded_and_owner_thread(self):
        s=text('shared/kvm_clipboard_wire.pas'); self.assertIn('KVM_CLIP_MAX_BYTES = 64 * 1024',s)
        s=text('shared/kvm_clipboard_server_worker.pas')
        self.assertIn('not FBusy',s); self.assertGreaterEqual(s.count('CanProceed'),5)
        s=text('client/kvm_clipboard_client_worker.pas')
        self.assertIn('if Terminated or FHaveReply then Exit',s)
        self.assertIn('LocalStamp:=B.ChangeStamp',s)
        self.assertIn('RequestGen',s)
    def test_project_units(self):
        for who in ('Client','Server'):
            tree=ET.parse(ROOT/who.lower()/f'LazDesk{who}.lpi')
            paths=[n.get('Value') for n in tree.findall('.//Units/Unit/Filename')]
            self.assertIn('../shared/kvm_clipboard_wire.pas',paths)
            for p in paths: self.assertTrue((ROOT/who.lower()/p).exists(),p)
    def test_linux_isolated_from_xlib_traps(self):
        s=text('shared/kvm_clipboard_x11.pas')
        self.assertIn('xcb_connect',s); self.assertNotIn('XSetErrorHandler',s)
        self.assertIn("Atom('CLIPBOARD')",s); self.assertNotIn("Atom('PRIMARY')",s)
        self.assertIn('WAYLAND_DISPLAY',s)
        self.assertIn('FReadState:=2',s)
        self.assertIn('GetTickCount64>FDeadline',s)
if __name__=='__main__': unittest.main(verbosity=2)

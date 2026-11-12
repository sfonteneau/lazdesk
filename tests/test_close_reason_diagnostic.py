#!/usr/bin/env python3
from pathlib import Path
root=Path(__file__).resolve().parents[1]
c=(root/'client/kvm_view_form.pas').read_text()
s=(root/'server/kvm_server.pas').read_text()
w=(root/'client/kvm_video_worker.pas').read_text()
assert 'Decode queue full or frame exceeds limits' in w
assert 'rsViewerStatusVideoError' in c
assert "rsViewerStatusVideoError = 'Video error: %s'" in (root/'client/kvm_viewer_i18n.pas').read_text()
assert 'Network communication interrupted or invalid clipboard reply' in c
assert "TextMsg := 'CLOSED ' + IntToStr(" in c
assert 'Format(rsViewerStatusSocketClosed,[TextMsg])' in c
assert 'rsViewerStatusLocalReceive' in c
assert "SetStatus('Connection closed by the server')" not in c
assert "WriteLn('[ws] Connection closed: '" in s
assert "WriteLn('[ws/direct] Invalid frame from client '" in s
assert "WriteLn('[video] NACK from client '" in s
assert "WriteLn('[auth] Rejected client '" in s
print('OK - distinct diagnostic messages in sources (lexical test only)')

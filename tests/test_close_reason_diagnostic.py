#!/usr/bin/env python3
from pathlib import Path
root=Path(__file__).resolve().parents[1]
c=(root/'client/kvm_view_form.pas').read_text()
s=(root/'server/kvm_server.pas').read_text()
w=(root/'client/kvm_video_worker.pas').read_text()
assert 'File decode pleine ou trame hors limite' in w
assert 'Erreur video : ' in c
assert 'Echange reseau interrompu ou reponse presse-papiers invalide' in c
assert "TextMsg := 'CLOSED ' + IntToStr(" in c
assert 'WebSocket fermee : ' in c
assert 'Erreur LOCALE de reception : ' in c
assert "SetStatus('Connexion fermee par le serveur')" not in c
assert "WriteLn('[ws] Connexion terminee : '" in s
assert "WriteLn('[ws] Trame invalide, client '" in s
assert "WriteLn('[video] NACK client '" in s
assert "WriteLn('[auth] Refuse client '" in s
print('OK - messages de diagnostic distincts dans les sources (test lexical uniquement)')

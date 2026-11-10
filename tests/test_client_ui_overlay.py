#!/usr/bin/env python3
"""Source-level guards for the native menu-only client UI. Not an LCL GUI test."""
from pathlib import Path
p = Path(__file__).resolve().parents[1] / 'client' / 'kvm_view_form.pas'
s = p.read_text(encoding='utf-8')
assert 'FView.Align := alClient;' in s
assert 'FMainMenu: TMainMenu' in s
assert "FFileMenu.Caption:='Fichier'" in s
assert "FViewMenu.Caption:='Affichage'" in s
assert "FControlMenu.Caption:='Controle'" in s
assert "FMenuConnectionSettings.Caption:='Parametres de connexion...'" in s
assert "FMenuFullscreen.Caption:='Plein ecran'+#9+'F11'" in s
assert "FMenuControl.Caption:='Autoriser mon controle'" in s
assert "FMenuKeyboardMode.Caption:='Mode clavier'" in s
assert "FMenuUnicodeKeys.Caption:='Automatique : texte Unicode + raccourcis'" in s
assert "FMenuRemoteKeys.Caption:='Touches physiques : disposition distante'" in s
assert "FMenuText.Caption:='Saisir / coller du texte Unicode...'" in s
assert "FMenuClipboard.Caption:='Presse-papiers'" in s
assert 'FMenuButton' not in s, 'Legacy top-right ... button must stay removed'
assert 'Commandes avancees' not in s, 'No hidden F8 command panel in the visible UI'
assert 'procedure TKvmViewForm.ConnectionSettingsClick' in s
keydown = s[s.index('procedure TKvmViewForm.RemoteKeyDown'):]
keyup = s[s.index('procedure TKvmViewForm.RemoteKeyUp'):]
assert 'if Key = VK_F11 then' in keydown, 'Local F11 fullscreen handler'
assert 'if Key = VK_F8 then' not in keydown, 'F8 must be forwarded to the remote desktop'
assert '(Key = VK_F8)' not in keyup and 'VK_F8) or' not in keyup, 'No local F8 keyup interception'
assert 'if FFullScreenMode then Menu:=nil else Menu:=FMainMenu' in s, 'Hide native menu only in fullscreen'
assert "Caption := 'LazDesk | '" in s, 'Status remains visible in the title'
print('PASS: menu-only client UI and F11/F8 source guards (not compiled)')

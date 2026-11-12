"""Static validation of the Viewer native Lazarus/gettext migration.

These asset/source checks do not replace compiling with Lazarus or running
an LCL client on Windows.
"""
from pathlib import Path
import json
import re
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[1]
VIEW = (ROOT / 'client/kvm_view_form.pas').read_text(encoding='utf-8')
I18N = (ROOT / 'client/kvm_viewer_i18n.pas').read_text(encoding='utf-8')
LPR = (ROOT / 'client/LazDeskClient.lpr').read_text(encoding='utf-8')
CATALOG = ROOT / 'client/languages'


def po_strings(block, field):
    """Read a gettext field, including any continuation lines."""
    lines = block.splitlines()
    for i, line in enumerate(lines):
        if line.startswith(field + ' '):
            chunks = [json.loads(line[len(field) + 1:])]
            for more in lines[i + 1:]:
                if more.startswith('"'):
                    chunks.append(json.loads(more))
                else:
                    break
            return ''.join(chunks)
    return None


def messages(lang):
    path = CATALOG / ('LazDeskClient' + ('.' + lang if lang else '') + '.po')
    content = path.read_text(encoding='utf-8')
    assert 'Content-Type: text/plain; charset=UTF-8' in content
    results = {}
    for block in re.split(r'\r?\n\s*\r?\n', content):
        match = re.search(r'^#: (kvm_viewer_i18n\.\w+)\s*$', block, re.M)
        if match:
            ident = match.group(1).lower()
            assert ident not in results
            results[ident] = (po_strings(block, 'msgid'), po_strings(block, 'msgstr'))
    return results


def original_resources():
    declarations = I18N.split('resourcestring\n', 1)[1].split('\ntype\n', 1)[0]
    result = {}
    for name, text in re.findall(r"(?m)^\s+(rsViewer\w+)\s*=\s*'((?:[^']|'')*)';", declarations):
        result['kvm_viewer_i18n.' + name.lower()] = (name, text.replace("''", "'"))
    return result


def placeholders(value):
    return re.findall(r'(?<!%)%(?:\d+:)?[sd]', value)


def test_native_resourcestrings_are_complete_and_referenced():
    resources = original_resources()
    assert len(resources) == 107
    assert 'resourcestring' in I18N
    assert '{$codepage utf8}' in I18N
    assert 'function TKvmViewForm.Tr(' not in VIEW
    assert not re.search(r"\bTr\('", VIEW)

    en, fr, template = messages('en'), messages('fr'), messages('')
    assert en.keys() == fr.keys() == template.keys() == resources.keys()
    for ident, (name, source) in resources.items():
        assert name in VIEW or name in LPR, name
        assert en[ident] == (source, source), ident
        assert fr[ident][0] == source, ident
        assert fr[ident][1], ident
        assert template[ident] == (source, ''), ident
        assert placeholders(source) == placeholders(fr[ident][1]), ident
    assert fr['kvm_viewer_i18n.rsviewerspecialf11'][1] == 'F11 (distant)'
    assert 'Suppr' in fr['kvm_viewer_i18n.rsviewerspecialsas'][1]
    assert all('F8' not in entry[1] for key, entry in fr.items()
               if '.rsviewerspecial' in key)


def test_native_catalog_loading_and_language_preferences():
    assert 'LCLTranslator' in I18N
    assert "KVM_VIEWER_PO_DOMAIN = 'LazDeskClient'" in I18N
    assert 'SetDefaultLang(Wanted,FDirectory,KVM_VIEWER_PO_DOMAIN,False)' in I18N
    assert "FDirectory:=IncludeTrailingPathDelimiter(ExeDir)+'languages'+PathDelim" in I18N
    assert "GetEnvironmentVariable('LAZDESK_LANG_DIR')" in I18N
    assert "GetEnvironmentVariable('LAZDESK_LANG')" in I18N
    assert 'GetUserDefaultUILanguage' in I18N
    assert "Ini.WriteString('viewer','language',Language)" in I18N
    assert 'if GViewerLanguage=\'\' then SetLanguage(KvmViewerDefaultLanguage);' in I18N
    assert "Wanted:='en';" in I18N
    assert 'TMemIniFile.Create(FileName)' in I18N  # preference only
    assert 'TMemIniFile.Create(FDirectory' not in I18N
    assert not (ROOT / 'client/lang/en.ini').exists()
    assert not (ROOT / 'client/lang/fr.ini').exists()


def test_live_switch_updates_every_open_viewer_without_remote_input():
    assert "SetViewerLanguage('fr')" in VIEW
    assert "SetViewerLanguage('en')" in VIEW
    assert 'FTranslations.SavePreference;' in VIEW
    assert "FMenuLanguageFR.Checked:=FTranslations.Language='fr'" in VIEW
    assert "FMenuLanguageEN.Checked:=FTranslations.Language='en'" in VIEW
    switch = VIEW.split('procedure TKvmViewForm.SetViewerLanguage(const Code: string);', 1)[1]
    switch = switch.split('procedure TKvmViewForm.ApplyOptions(', 1)[0]
    assert 'Screen.CustomFormCount' in switch
    assert 'OtherViewer.ApplyTranslations;' in switch
    assert 'OtherViewer.SyncMainMenu;' in switch
    assert 'ApplyTranslations;' in switch
    assert 'SendPacket' not in switch
    translate = VIEW.split('procedure TKvmViewForm.ApplyTranslations;', 1)[1]
    translate = translate.split('procedure TKvmViewForm.SyncMainMenu;', 1)[0]
    for name in ('Sas', 'F11', 'Start', 'CtrlEsc', 'AltTab', 'TaskManager',
                 'Run', 'Explorer', 'Desktop', 'Lock', 'AltF4'):
        assert 'rsViewerSpecial' + name in translate
    assert 'RebuildMonitorMenu;' in translate
    assert 'SendPacket' not in translate
    assert 'SetStatus(rsViewerStatus' in VIEW


def test_standalone_builder_project_and_host_api():
    xml = ElementTree.parse(ROOT / 'client/LazDeskClient.lpi')
    assert xml.find('.//i18n/EnableI18N').get('Value') == 'True'
    assert xml.find('.//i18n/EnableI18N').get('LFM') == 'False'
    assert xml.find('.//i18n/OutDir').get('Value') == 'languages'
    units = [e.get('Value') for e in xml.findall('.//Units/Unit/Filename')]
    assert 'kvm_viewer_i18n.pas' in units
    pkg = ElementTree.parse(ROOT / 'packages/LazDeskViewer.lpk')
    files = [item.find('Filename').get('Value') for item in pkg.findall('.//Files/*')]
    assert '../client/kvm_viewer_i18n.pas' in files
    build = (ROOT / 'build/build_standalone.py').read_text(encoding='utf-8')
    assert "shutil.copytree(ROOT/'client/languages',output/'languages',dirs_exist_ok=True)" in build
    frame = (ROOT / 'client/kvm_viewer_frame.pas').read_text(encoding='utf-8')
    assert 'property Language: string read GetLanguage write SetLanguage;' in frame
    assert 'FViewer.SetViewerLanguage(Code);' in frame
    assert 'procedure SetViewerLanguage(const Code: string);' in VIEW
    assert 'rsViewerDialogArgumentsTitle' in LPR and 'rsViewerDialogHelpTitle' in LPR
    assert 'Translations := TKvmViewerI18n.Create;' in LPR

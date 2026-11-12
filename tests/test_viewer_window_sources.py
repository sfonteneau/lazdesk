"""Static regression checks for LazDesk's in-process top-level viewer.

These checks do not replace native compilation / LCL GUI testing.
"""
from pathlib import Path
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[1]


def test_window_unit_is_listed_in_runtime_package():
    pkg = ROOT / 'packages/LazDeskViewer.lpk'
    tree = ElementTree.parse(pkg)
    assert tree.getroot().tag == 'CONFIG'
    content = pkg.read_text()
    assert '<Files Count="4">' in content
    assert '../client/kvm_viewer_window.pas' in content
    assert 'mormot2' in content and 'LCL' in content


def test_viewer_window_reuses_existing_form_without_external_process():
    code = (ROOT / 'client/kvm_viewer_window.pas').read_text()
    assert 'TKvmViewerWindow = class(TKvmViewForm)' in code
    assert 'inherited Create(AOwner);' in code
    assert 'Result.Show;' in code
    assert 'Result.Connect;' in code
    assert 'Result.Configure(Options);' in code
    assert 'CreateProcess' not in code
    assert 'ShellExecute' not in code
    assert 'Application.Run' not in code
    assert 'Application.CreateForm' not in code


def test_closing_secondary_window_frees_viewer_without_exiting_host():
    code = (ROOT / 'client/kvm_viewer_window.pas').read_text()
    assert 'OnClose := @WindowClosing;' in code
    assert 'CloseAction := caFree;' in code
    assert 'FOnWindowClosed(Self);' in code
    assert 'Application.Terminate' not in code
    assert 'OnClose := @WindowClosing;' in code
    form = (ROOT / 'client/kvm_view_form.pas').read_text()
    assert 'destructor TKvmViewForm.Destroy;' in form
    assert 'CloseSocket' in form


def test_window_options_disable_legacy_cli_auto_connect():
    code = (ROOT / 'client/kvm_viewer_window.pas').read_text()
    assert 'Local.AutoConnect := False;' in code
    assert 'if Connected then' in code
    assert 'procedure TKvmViewerWindow.TakeControl(Enabled: Boolean);' in code
    assert 'RequestControl(Enabled);' in code
    assert 'function DefaultViewerWindowOptions: TKvmClientOptions;' in code


def test_docs_explain_top_level_window_and_transport_limits():
    docs = (ROOT / 'VIEWER_EMBEDDING.md').read_text()
    assert 'OpenLazDeskViewerWindow' in docs
    assert 'LazDeskClient.exe' in docs
    assert 'WebSocket only' in docs
    assert 'OpenDirect()' in docs
    assert 'OnWindowClosed' in docs

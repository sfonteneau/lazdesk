"""Static contract checks for the optional in-process LCL viewer.

These do not replace compiling and running it with Lazarus/Free Pascal.
"""
from pathlib import Path
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[1]


def test_viewer_package_includes_lcl_units():
    doc = ElementTree.parse(ROOT / 'packages/LazDeskViewer.lpk')
    text = (ROOT / 'packages/LazDeskViewer.lpk').read_text()
    assert doc.getroot().tag == 'CONFIG'
    assert '<PackageName Value="LCL"/>' in text
    assert '<PackageName Value="mormot2"/>' in text
    assert '../client/kvm_viewer_frame.pas' in text
    assert (ROOT / 'client/kvm_viewer_frame.lfm').exists()


def test_embedded_viewer_disables_top_level_geometry_and_menu():
    form = (ROOT / 'client/kvm_view_form.pas').read_text()
    assert 'procedure TKvmViewForm.EnableEmbeddedMode;' in form
    assert 'if FEmbeddedMode then Menu := nil' in form
    assert 'if FEmbeddedMode then\n  begin\n    FSpanningMonitors := False;' in form
    assert 'if FEmbeddedMode then Exit; // host owns top-level window' in form
    assert 'if not FEmbeddedMode then' in form  # F11 remains remote in embed mode
    assert 'if FEmbeddedMode then FPreferMaximized := False;' in form


def test_frame_api_and_shared_worker():
    s = (ROOT / 'client/kvm_viewer_frame.pas').read_text()
    assert 'TKvmViewerFrame = class(TFrame)' in s
    assert 'FViewer := TKvmViewForm.Create(Self);' in s
    assert 'FViewer.Parent := Self;' in s
    assert 'FViewer.Align := alClient;' in s
    assert 'FViewer.EnableEmbeddedMode;' in s
    for name in ('Configure', 'Connect', 'Disconnect', 'TakeControl',
                 'RefreshDesktop', 'ReleaseLocalInputs'):
        assert f'procedure TKvmViewerFrame.{name}' in s
    assert 'FViewer.OnStatusChange := nil;' in s
    assert 'FreeAndNil(FViewer)' in s
    assert 'FViewer.Connect;' in s
    assert 'FViewer.RequestControl(Enabled);' in s


def test_docs_are_explicit_about_current_websocket_only_support():
    readme = (ROOT / 'README.md').read_text()
    docs = (ROOT / 'VIEWER_EMBEDDING.md').read_text()
    assert 'TKvmViewerFrame' in readme
    assert 'WebSocket only' in docs
    assert 'OpenDirect()' in docs
    assert 'not verified' in docs

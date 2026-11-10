from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(name):
    return (ROOT / name).read_text()


def test_mormot_direct_integration_is_optional():
    embedded = read('server/kvm_embedded.pas')
    server = read('server/kvm_server.pas')
    standalone = read('server/LazDeskServer.lpr')
    assert 'FTunnel.OpenDirect(Session,Transmit,FEndpointRef,[toEcdhe]' in embedded
    assert 'TKvmServer.Create(FOptions,True)' in embedded
    assert 'if not DirectMode then' in server
    assert 'FSocket := TKvmWebSocketServer.Create' in server
    assert 'TKvmServer.Create(Options)' in standalone
    assert 'kvm_embedded' not in standalone


def test_direct_transport_keeps_auth_and_ack_path():
    server = read('server/kvm_server.pas')
    assert 'HandleIncoming(Sender.Protocol.ConnectionID,Frame)' in server
    assert 'HandleIncoming(1,Frame)' in server
    assert 'RegisterClient(1)' in server
    assert 'SecureTokenEqual(Token,FToken)' in server
    assert "'A': AckBatch(ID,Serial)" in server
    assert 'QueueResult := QueueFrames(ClientID,Frames);' in server
    assert 'if FDirectMode then DirectClose' in server


def test_native_direct_full_frames_and_validation():
    wire = read('shared/kvm_direct_wire.pas')
    endpoint = read('shared/kvm_direct_endpoint.pas')
    embedded = read('server/kvm_embedded.pas')
    assert 'KVM_DIRECT_FRAME_MAX_BYTES = 3 * 1024 * 1024' in wire
    assert 'KvmDirectPack' in wire and 'KvmDirectUnpack' in wire
    assert 'Tunnel.SendData(KvmDirectPack(Opcode,Payload));' in endpoint
    assert 'KvmDirectUnpack(Frame,Kind,Payload)' in endpoint
    assert 'KVM_DIRECT_FRAGMENT_BYTES' not in wire
    assert 'FDecoder' not in endpoint
    # Upstream 2.4.17970 supports 16-MiB direct frames. Do not refer to the
    # deleted private constant: it does not exist in official mORMot2.
    assert 'TUNNEL_DIRECT_MAX_DATA_BYTES' not in embedded
    assert '74cfe56d2' in embedded


def test_no_custom_mormot_patch_required():
    assert not (ROOT / 'tools/enable_mormot_large_direct_frames.py').exists()
    assert not (ROOT / 'tests/test_patch_mormot_direct.py').exists()
    docs = read('EMBEDDING.md')
    readme = read('README.md')
    assert '2.4.17970' in docs and '74cfe56d2' in docs
    assert '16-MiB direct payload' in docs
    assert '16-MiB direct payloads' in readme
    assert 'TUNNEL_DIRECT_MAX_DATA_BYTES' not in read('server/kvm_embedded.pas')

"""Static safety checks for Win7/GDI timeout diagnostics (not a Windows runtime test)."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DESKTOP = (ROOT / 'server/kvm_desktop.pas').read_text(encoding='utf-8')
SERVER = (ROOT / 'server/kvm_server.pas').read_text(encoding='utf-8')


def test_explicit_gdi_bypasses_dxgi():
    assert "if Backend <> 'gdi' then UseDxgi := CheckDxgi(Reason)" in DESKTOP
    assert "if (Backend <> 'gdi') and UseDxgi then" in DESKTOP
    assert 'Result := CaptureDxgi(MaxW,MaxH,Frame);' in DESKTOP


def test_expiry_clock_is_read_after_session_lock():
    body = SERVER.split('procedure TKvmServer.ExpireIdleClients;', 2)[-1].split('procedure TKvmServer.CaptureDemand')[0]
    assert body.index('EnterCriticalSection(FLock);') < body.index('NowTick := GetTickCount64;')
    assert 'if NowTick >= FClients[I].LastSeen then' in body
    assert 'FlowTimedOut(FClients[I].Flow, NowTick)' in body


def test_expiry_diagnostic_identifies_cause():
    body = SERVER.split('procedure TKvmServer.ExpireIdleClients;', 2)[-1].split('procedure TKvmServer.CaptureDemand')[0]
    for marker in ('auth timeout', 'video ACK timeout', 'client idle timeout',
                   'idle_ms=', 'ack_ms=', 'in_flight='):
        assert marker in body

#!/usr/bin/env python3
"""Source/package integrity checks only: never substitutes for a Pascal build."""
from pathlib import Path
import ctypes
import ctypes.util
import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
COUNT = 0

def check(condition, message):
    global COUNT
    if not condition:
        raise AssertionError(message)
    COUNT += 1

def text(name):
    return (ROOT / name).read_text(encoding="utf-8")

expected = {
    "shared/kvm_wire.pas", "shared/kvm_frame.pas", "shared/kvm_damage.pas",
    "shared/kvm_keysym.pas", "shared/kvm_cursor.pas", "server/kvm_transport.pas",
    "server/kvm_wayland.pas", "server/kvm_capture_dxgi.pas", "server/kvm_cursor_x11.pas",
    "native/linux/kvm_portal.c", "native/windows/kvm_dxgi.cpp", "native/common/kvm_pixels.h",
    "tests/test_pixels.c", "tests/test_v8_core.lpr",
    "shared/kvm_flow.pas", "shared/kvm_cli.pas", "shared/kvm_adaptive.pas",
    "shared/kvm_geometry.pas", "shared/kvm_mouse_state.pas", "shared/kvm_jpeg_guard.pas",
    "server/kvm_server.pas", "server/kvm_video.pas", "server/kvm_jpeg_batch.pas", "server/kvm_monitors.pas",
    "server/kvm_desktop.pas", "server/kvm_turbojpeg.pas", "server/kvm_x11_api.pas",
    "server/kvm_x11_session.pas", "server/kvm_quartz_api.pas",
    "server/kvm_capture_win.pas", "server/kvm_capture_x11.pas", "server/kvm_capture_mac.pas",
    "server/kvm_inject_win.pas", "server/kvm_inject_x11.pas", "server/kvm_inject_mac.pas",
    "client/kvm_view_form.pas", "native/macos/kvm_sck.m", "native/macos/build.sh",
    "tests/test_v7_core.lpr", "tests/test_linux_desktop.lpr", "tests/test_x11_native_abi.py",
    "docs/CHANGEMENTS_V7.md", "docs/VALIDATION_V7.md", "docs/PROTOCOLE.md",
}
expected.update({
    "native/codec/kvm_codec.c", "native/codec/kvm_codec.h", "native/common/kvm_h264.h",
    "native/session/kvm_session_linux.c", "shared/kvm_codec.pas", "shared/kvm_extwire.pas",
    "shared/kvm_security.pas", "shared/kvm_input_queue.pas", "shared/kvm_rgb_bitmap.pas",
    "shared/kvm_tls_policy.pas", "server/kvm_session_guard.pas", "server/kvm_metrics.pas",
    "tests/test_v9_core.lpr", "tests/test_h264.c", "tests/test_session.c",
    "tests/test_security_network.py", "tests/test_tls_network.py", "tests/test_tls_probe.lpi",
    "tools/bench_codec.py", "tools/bench_network.py", "tools/bench_process.py",
})
for name in sorted(expected):
    check((ROOT / name).is_file(), f"Missing {name}")

# Unit declarations, paths and uses resolution for our units, not external RTL/LCL.
units = {p.stem.lower(): p for p in ROOT.rglob("*.pas")}
for name, path in units.items():
    source = path.read_text()
    check(bool(re.search(r"\bunit\s+" + re.escape(name) + r"\s*;", source, re.I)), str(path))
    check(source.rstrip().lower().endswith("end."), f"Unit has no terminator: {path}")
    for uses in re.findall(r"\buses\s+(.*?);", source, re.S | re.I):
        for dependency in re.findall(r"\bkvm_[a-z0-9_]+\b", re.sub(r"\{\$[^}]*\}", "", uses), re.I):
            check(dependency.lower() in units, f"Unknown unit {dependency}: {path}")

for path in ROOT.rglob("*.lpi"):
    tree = ET.parse(path)
    names = tree.findall(".//Units/Unit/Filename")
    check(bool(names), f"Empty project {path}")
    for elem in names:
        check((path.parent / elem.attrib["Value"]).is_file(), f"Invalid project path: {elem.attrib}")
    packages = {e.attrib["Value"] for e in tree.findall(".//RequiredPackages/Item/PackageName")}
    check("mormot2" in packages, f"Missing mORMot2 requirement: {path}")
    if "Client" in path.name:
        check("LCL" in packages, "Client must depend on the LCL")

wire = text("shared/kvm_wire.pas")
server = text("server/kvm_server.pas")
client = text("client/kvm_view_form.pas")
worker = text("client/kvm_video_worker.pas")
flow = text("shared/kvm_flow.pas")
video = text("server/kvm_video.pas")
cli = text("shared/kvm_cli.pas")
check("KVM_SUBPROTOCOL = 'lazdesk8'" in wire, "Protocol must be v9 only")
for source in [*ROOT.rglob("*.pas"), *ROOT.rglob("*.lpr")]:
    check(not re.search(r"lazdesk[0-6]\b", source.read_text()), f"Old protocol in {source}")
for word in ["MakeBatchNack", "ReadBatchNack", "ReadCursor", "ReadTextUtf8", "KVM_MAX_FRAME_PIXELS"]:
    check(word in wire, word)
for word in ["RejectFlowBatch", "AcknowledgeFlowBatch", "InvalidateFlowGeometry", "FlowTimedOut"]:
    check(word in flow and word in server, f"Missing flow integration {word}")
check("ReadBatchNack(Frame.payload,Serial)" in server, "NACK dispatch")
check("MakeBatchNack(Serial)" in worker and "ReadBatchEnd" in worker, "NACK client")
check("JpegMatchesSize(JPEG,W,H)" in worker, "Validate JPEG before decode")
check("ERR PROTOCOL" in client and "KVM_DECODE_QUEUE_BYTES" in worker, "Overflow closes; resync preserves delimiters")
check("QuartzMouseEvent" in text("server/kvm_inject_mac.pas"), "macOS drag state integration")
check("CGDisplayCreateImage" not in text("server/kvm_capture_mac.pas"), "No deprecated macOS capture fallback")
check("SCFrameStatusComplete" in text("native/macos/kvm_sck.m"), "Only complete SCK frames")
check("config.queueDepth = 3" in text("native/macos/kvm_sck.m"), "Bounded SCK queue")
check("CaptureRate := Max(CaptureRate, FPS)" in server, "Native capture cadence")
for word in ["CaptureDemand", "ObserveAck", "ProfileSettings", "AdaptiveBudget", "ActivateClient"]:
    check(word in server, f"Adaptive/auth integration {word}")
for word in ["RegionTileChanged", "ExpandDirtyCacheGroups", "MakeDirtyRegions", "CopyFrameReuse"]:
    check(word in video, f"Profile cache {word}")
check("FEncoder.Encode(Current, FRegions, Quality, FPackets)" in video and
      "EncodeRect" in text("server/kvm_jpeg_batch.pas"),
      "Persistent JPEG batch encoder integration")
for option in ["--listen", "--port", "--token", "--host", "--fps", "--quality", "--control",
               "--view-token", "--tls-cert", "--tls-key", "--tls-ca", "--monitor",
               "--list-monitors", "--max-width", "--max-height", "--no-adaptive", "--backend",
               "--encoder", "--gpu-device", "--bitrate-kbps", "--session-policy", "--keyboard",
               "--metrics-csv", "--allow-insecure", "--no-h264"]:
    check(option in cli, f"CLI missing {option}")
check("ReadLn(Input)" not in text("server/LazDeskServer.lpr"), "No interactive stdin dependency")
check("0.0.0.0" in cli and "Options.Listen := '127.0.0.1'" in cli, "Listen options")
check("XOpenDisplay" not in text("server/kvm_inject_x11.pas"), "X11 input connection must be reused")
check("XOpenDisplay" not in text("server/kvm_capture_x11.pas").replace("XOpenDisplay failed", ""), "X11 capture connection must be reused")
for word in ["XShmGetImage", "XGetSubImage", "OWNER_RW = 384", "Image^.data := nil"]:
    check(word in text("server/kvm_capture_x11.pas"), f"X11 path {word}")
for name in ["kvm_capture_win", "kvm_capture_x11", "kvm_capture_mac"]:
    check(name + ".CloseCapture" in text("server/kvm_desktop.pas"), f"Cleanup {name}")
check("CloseDesktopCapture;" in server, "Capture worker owns native cleanup")
check("TJFLAG_NOREALLOC" in text("server/kvm_turbojpeg.pas"), "Reusable TurboJPEG output buffer")
check("FCursorVisible:=Snapshot.CursorVisible" in client, "Cursor hide packet")

# These are integration-presence checks, not proof of API or thread correctness.
for token in ["AllowUpgrade", "AcceptPacket", "LastTextReceipt", "KVM_AUTH_TIMEOUT_MS",
              "FMetrics.Queue", "KVM_INPUT_PARTIAL", "PollSessionGuard"]:
    check(token in server, "v9 server integration: " + token)
for token in ["ReadDesktopState", "PresentSnapshot", "FInputs.Receipt", "PrepareClientTls"]:
    check(token in client, "v9 client integration: " + token)
check("mormot.lib.openssl11" in text("shared/kvm_tls_policy.pas"), "Load POSIX TLS provider")
check("mormot.lib.openssl11" in text("server/LazDeskServer.lpr"), "Load server TLS provider")
check("IgnoreCertificateErrors:=False" in text("shared/kvm_tls_policy.pas"), "No unchecked TLS")
for token in ["kvm_h264_allocation_ok", "KVM_NAL_IDR", "avcodec_send_frame", "avcodec_receive_frame"]:
    check(token in text("native/codec/kvm_codec.c"), "codec integration: " + token)

for script in ROOT.rglob("*.sh"):
    subprocess.run(["sh", "-n", str(script)], check=True)
    COUNT += 1

# Symbol existence alone, not a native behavior or Pascal ABI test.
if sys.platform.startswith("linux"):
    for library, symbols in {
        "X11": ["XGetSubImage", "XDestroyImage", "XkbGetState", "XkbLockModifiers"],
        "Xext": ["XShmCreateImage", "XShmGetImage", "XShmAttach"],
        "Xtst": ["XTestFakeMotionEvent", "XTestFakeKeyEvent"],
    }.items():
        found = ctypes.util.find_library(library)
        if not found:
            print(f"SKIP symbol check: {library} not installed")
            continue
        handle = ctypes.CDLL(found)
        for symbol in symbols:
            check(hasattr(handle, symbol), f"Missing native symbol: {symbol}")

# Optional inspection of the user's provided mORMot2 archive, without compiling it.
mormot = os.environ.get("MORMOT2_DIR")
if mormot:
    ws = Path(mormot) / "src/net/mormot.net.ws.core.pas"
    check(ws.is_file(), "MORMOT2_DIR does not point to mORMot2 sources")
    source = ws.read_text(encoding="utf-8-sig")
    for word in ["LoopDelay", "SendDelay", "TWebSocketProtocolChat", "SendFrame"]:
        check(word in source, f"Missing mORMot2 declaration {word}")

print(f"PASS: {COUNT} structural/lexical assertions and shell syntax checks (not behavioral tests)")
print("NOT A BUILD: these checks do not prove Pascal compilation or desktop operation.")
print("FPC:", shutil.which("fpc") or "not installed")
print("Lazarus lazbuild:", shutil.which("lazbuild") or "not installed")

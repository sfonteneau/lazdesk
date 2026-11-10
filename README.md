# LazDesk

LazDesk is a lightweight remote desktop control solution, with a **server** on the computer being controlled and a **client** on the controlling computer.

## Features

- JPEG screen capture with configurable quality and frame rate.
- Multi-monitor support and native resolution.
- Keyboard, mouse, remote cursor, and Unicode text clipboard.
- **Windows**: GDI or DXGI capture (including multi-monitor desktops).
- **Linux**: X11, or Wayland via the desktop capture portal.
- **macOS**: ScreenCaptureKit capture.
- Standalone builds: one server executable and one client executable, without separate LazDesk DLLs.

## Embedding inside another Pascal application (mORMot2 OpenDirect)

The new `kvm_embedded` unit and `packages/LazDeskEmbedded.lpk` let an existing
Lazarus/FPC application host LazDesk **without launching LazDeskServer.exe**.
`StartWebSocket()` preserves compatibility with existing clients.
`StartDirect()` uses mORMot2 **`TTunnelLocal.OpenDirect()`** (version
**2.4.17970+**, commit [`74cfe56d2`](https://github.com/synopse/mORMot2/commit/74cfe56d2)
or newer) to transport KVM packets through `ITunnelTransmit`, with **no local
listening socket**. Upstream mORMot2 now supports **16-MiB direct payloads**,
so JPEG/KVM frames stay whole without any custom mORMot2 patch.
The remote endpoint needs the same one-byte KVM text/binary framing;
the existing viewer uses WebSocket only.

See **[EMBEDDING.md](EMBEDDING.md)** and
`examples/embedded_in_existing_app.pas` for usage and limitations.

## Viewer inside an existing application: separate window (recommended)

`packages/LazDeskViewer.lpk` contains **`TKvmViewerWindow`**, a normal modeless
Lazarus `TForm` created by the **host application's process**. Call
`TKvmViewerWindow.Create(Self)` / `Show` / `Connect`, or the helper
`OpenLazDeskViewerWindow(Self, Options)`. Its **own Windows window** has the
original LazDesk menus, multi-monitor features, keyboard/mouse and JPEG viewer.
Closing it frees the viewer and **does not close the host application**. No
`LazDeskClient.exe` process is started, and no viewer executable is required.

For an in-form viewer, the same package still provides `TKvmViewerFrame` for a
`TPanel` or `TTabSheet`. Both modes currently use the **WebSocket** transport;
they cannot yet connect to a server configured as `OpenDirect()`-only.

See [VIEWER_EMBEDDING.md](VIEWER_EMBEDDING.md),
`examples/viewer_separate_window.pas`, and
`examples/viewer_in_existing_form.pas`.

## Building

Requirements: **Free Pascal / Lazarus**, **mORMot2**, **TurboJPEG**, and platform-specific build tools. On Windows, you also need **MinGW-w64** and **Python 3**.

### Windows x86 with statically linked DXGI

Example for a Lazarus / MSYS2 installation:

```bat
build_standalone_windows.cmd --arch x86 ^
  --fpc "C:\lazarus_4_8\fpc\bin\i386-win32\fpc.exe" ^
  --lazbuild "C:\lazarus_4_8\lazarus\lazbuild.exe" ^
  --toolchain-bin "C:\msys64\mingw32\bin" ^
  --turbojpeg-archive "C:\msys64\mingw32\lib\libturbojpeg.a" ^
  --mormot-dir "C:\tranquilit\mORMot2" ^
  --with-dxgi
```

For **x64**, use `--arch x64`, the x64 FPC compiler, and the corresponding `mingw64` libraries.

x86 output: `dist/i386-win32/`. In standalone mode, DXGI is linked into the server: **`lazdesk_dxgi.dll` is not required**.

### Linux / macOS

```sh
sh build/build_standalone.sh --turbojpeg-archive /path/to/libturbojpeg.a
```

On Linux, add `--with-portal` to enable Wayland capture. Platform system libraries are still required.

## Quick start

Set the same token on both machines (`LAZDESK_TOKEN`, at least 16 ASCII characters).

Example Windows server with two monitors:

```bat
set "LAZDESK_TOKEN=replace-with-a-secret-token"
dist\i386-win32\LazDeskServer.exe --listen 0.0.0.0 --port 7900 --control --backend dxgi --monitor 0 --fps 30 --quality 100 --no-adaptive
```

On the Windows client:

```bat
set "LAZDESK_TOKEN=replace-with-a-secret-token"
dist\i386-win32\LazDeskClient.exe --host SERVER_IP --port 7900 --control
```

`--monitor 0` selects the entire virtual desktop. To force GDI capture, replace `dxgi` with `gdi`. With `--backend auto`, DXGI falls back to GDI if unavailable.

**Security:** avoid exposing the control port directly to the Internet; use a private network or secure tunnel. For non-loopback connections, configure TLS or explicitly use `--allow-insecure` only behind a trusted VPN or tunnel.

## Current protocol and cleanup

- **One client and one server**: `LazDeskClient` / `LazDeskServer`, using WebSocket subprotocol `lazdesk8`.
- Unicode text input over the network uses only the `X` message with `I` acknowledgments. The `U` marker remains **internal** to the input queue (it is not a legacy client message).
- Monitor topology is transmitted exclusively via `MONITOR_LAYOUT`.
- Capture fallbacks (DXGI/GDI, X11/Wayland, etc.), codecs, and security fallbacks are retained; they are not legacy client or server versions.
- The V7/V8/V9 tests are **regression tests against the current code**, not old applications. They remain in this repository.

This repository no longer ships a precompiled Linux library. To build the session bridge in dynamic mode on Linux:

```sh
sh native/session/build.sh
```

## Windows 7: GDI capture and session timeout diagnostics

Windows 7 does not support DXGI Desktop Duplication. Start the server with
`--backend gdi` and preferably build a Windows 7/GDI-only server without
`--with-dxgi` in the standalone build command.

The startup log contains `[capture] Requested backend=gdi; DXGI enabled=FALSE`.
If `[dxgi]` errors still appear with this startup message, first verify that
the running `.exe` was actually rebuilt from these sources and check for
other running server processes. The compiled-in DXGI feature list alone
is **not** an indication that DXGI capture is selected.

A session expiration now reports the exact cause and elapsed durations:
`reason=client idle timeout` means no accepted client message (including
heartbeat `P`) for over 15 seconds; `reason=video ACK timeout` means the
oldest in-flight video batch has remained unacknowledged for over 20 seconds;
`reason=auth timeout` means an unauthenticated connection timed out.
The timestamps are sampled under the client-state lock to avoid unsigned
clock-subtraction underflow on busy systems.

For troubleshooting a heavily loaded Windows 7 computer, try
`--fps 10 --quality 75 --adaptive --max-width 1280 --max-height 720`
while keeping `--backend gdi`. This is a diagnostic workload reduction,
not a change to the session timeouts.

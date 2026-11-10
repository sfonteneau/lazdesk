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

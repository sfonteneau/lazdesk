# LazDesk embedded / mORMot2 OpenDirect integration

## What this changes

LazDesk now exposes **`server/kvm_embedded.pas`** as an in-process server
API, while the existing standalone `LazDeskServer.lpr` remains supported.
Use `packages/LazDeskEmbedded.lpk` as a runtime package in Lazarus, or put
`server/` and `shared/` on the application's FPC search path.

**Two deployment modes:**

| Mode | LazDesk executable | Local TCP / WebSocket listener | Remote peer |
| --- | --- | --- | --- |
| `TKvmEmbedded.StartWebSocket` | None: code linked into host | Yes | Current `LazDeskClient` |
| `TKvmEmbedded.StartDirect` | None: code linked into host | **No** | Application using `TTunnelLocalClient.OpenDirect` and native KVM messages |

There is still a **host application binary** containing the Pascal units and
native libraries. This feature does not make a running application binary-free.
In the default non-standalone build, TurboJPEG is loaded dynamically, so the
host still needs the platform TurboJPEG library (`turbojpeg.dll`, etc.).

## mORMot2 version

**Use upstream mORMot2 2.4.17970 or newer**, containing commit
[`74cfe56d2`](https://github.com/synopse/mORMot2/commit/74cfe56d2).
This includes `TTunnelLocal.OpenDirect()` (introduced in commit
[`a2b3264ba`](https://github.com/synopse/mORMot2/commit/a2b3264ba))
and the official **16-MiB direct payload limit**. Both the sender
(`SendData`) and receiver (`TunnelSend`) accept full KVM/JPEG records after the
direct tunnel handshake. The normal TCP-backed send path still limits its
payloads to 64 KiB. Oversized frames remain rejected.

**No local modification of mORMot2 is needed.** The previous LazDesk-specific
patcher has been removed. If it was previously applied to a local mORMot2
checkout, restore a clean official source tree and update to commit `74cfe56d2`
or a descendant before compiling LazDesk. Do not apply the old 4-MiB patch
to the upstream implementation.

```cmd
git -C "C:\path\to\mORMot2" fetch origin
git -C "C:\path\to\mORMot2" merge-base --is-ancestor 74cfe56d2 HEAD
```

The second command exits successfully when the checked-out branch includes
the required commit. If it fails, update/check out a branch that includes it
and rebuild the mORMot2 units and the two direct-mode applications. For
example, when the Lazarus package is used:

```cmd
lazbuild --build-all C:\path\to\mORMot2\packages\lazarus\mormot2.lpk
```

The direct-mode source uses `OpenDirect()` and relies on the upstream 16-MiB
limit: no private mORMot2 constant or source patch is referenced. When using
an older mORMot2 checkout containing `OpenDirect()` but not the limit change,
large JPEG frames may fail at runtime. Verify the mORMot2 source version
on **both ends** before deployment. The relay forwards opaque frames and
must likewise support their size/buffering requirements.

## Start/stop inside a host application

`examples/embedded_in_existing_app.pas` is a standalone **Pascal unit**, not
an executable. Its owner can add it to an existing LCL application:

```pascal
var
  Host: TKvmEmbedded;
  Opt: TKvmServerOptions;
begin
  Opt := DefaultEmbeddedKvmOptions;
  Opt.Token := GetEnvironmentVariable('LAZDESK_TOKEN'); // 16+ ASCII chars
  Opt.AllowControl := True;
  Opt.Backend := 'gdi';  // Win7: no DXGI Desktop Duplication
  Host := TKvmEmbedded.Create(Opt);
  try
    Host.StartWebSocket; // embedded server; current client still works
    // Keep Host alive as long as the host application should serve KVM.
  finally
    Host.Free;
  end;
end;
```

For **portless direct mode**, the host's existing mORMot2 relay must supply
an `ITunnelTransmit` connected to the remote peer. The relay session ID and
strong E2EE secret should be provisioned securely by that host:

```pascal
var
  Host: TKvmEmbedded;
  Opt: TKvmServerOptions;
  Relay: ITunnelTransmit;     // obtained from the host's mORMot SOA relay
  Session: TTunnelSession;   // allocated/accepted by that relay
  E2EESecret: RawUtf8;       // independent random >=128-bit secret
begin
  Opt := DefaultEmbeddedKvmOptions;
  Opt.Token := GetEnvironmentVariable('LAZDESK_TOKEN');
  Opt.AllowControl := True;
  Opt.Backend := 'gdi';
  Host := TKvmEmbedded.Create(Opt);
  // On the host's worker thread, with Relay, Session and E2EESecret set:
  Host.StartDirect(Session, Relay, E2EESecret);
  // No HTTP server or local TCP port has been opened.
  // Call Host.Stop and Host.Free when the relay session ends.
end;
```

**`StartDirect` blocks during its reciprocal mORMot2 handshake.** Both sides
must call `OpenDirect` (one on `TTunnelLocalServer`, the other on
`TTunnelLocalClient`) and use the same session, options, and secret. Do this
from a background worker to avoid freezing the host GUI. The host application
is responsible for `TunnelPrepare` / `TunnelAccept` / `TunnelCommit` /
`TunnelRollback` if it uses mORMot2's relay workflow.

Only one `TKvmEmbedded` instance is intended per process for now; desktop
capture/session-guard globals are not multi-instance safe. Never allow it to
outlive the UI/session or to receive callbacks after `Stop`.

## Remote endpoint for direct mode

A remote *embedded client* needs a `TTunnelLocalClient`, a
`TKvmDirectEndpoint` and the host application's own handling of KVM frames.
It cannot connect with the existing WebSocket-only `LazDeskClient.exe`.

1. Create `TTunnelLocalClient` and `TKvmDirectEndpoint` and attach the latter
   to the former using a message callback (plus an invalid-packet callback).
2. Call `TTunnelLocalClient.OpenDirect(Session, Relay, Endpoint as
   ITunnelTransmit, [toEcdhe], TimeOutMS, E2EESecret, [])`, simultaneously with
   the server-side `StartDirect`.
3. Send the normal LazDesk authentication message with
   `Endpoint.Send('T', 'AUTH ' + Token + ' jpeg')`.
4. Use the same underlying LazDesk binary message protocol (`shared/kvm_wire.pas`
   and `shared/kvm_extwire.pas`) for screenshot tiles, mouse/keyboard,
   clipboard, control requests, heartbeats and video ACKs.
5. Send `P` heartbeats at least every 3 seconds, and acknowledge complete
   video batches (`B` -> `A`, see `kvm_flow.pas`) or the session expires.

An embeddable **WebSocket viewer UI** now exists in
`client/kvm_viewer_frame.pas` / `packages/LazDeskViewer.lpk`. It can be parented
to an existing application's panel or tab, with no `LazDeskClient.exe`.
However, the frame is not yet a **direct-mode** UI client adapter for
`OpenDirect()`; use `StartWebSocket` for this viewer. See
[VIEWER_EMBEDDING.md](VIEWER_EMBEDDING.md) for its API and limitations.

## Native direct frames (no JPEG fragmentation)

With upstream mORMot2 2.4.17970+, **one KVM message = one `TTunnelLocal.SendData()`**.
LazDesk does not split, reconstruct, or buffer JPEG fragments. The only
application-level metadata is a **single byte** used to retain the WebSocket
text/binary distinction:

```
+-----------+---------------------------------+
| 'B' / 'T' | Original LazDesk KVM payload    |
| (1 byte)  | (1..3 MiB, not split)           |
+-----------+---------------------------------+
```

`'B'` is a binary KVM frame; `'T'` is a text KVM frame (authentication,
status, monitor information). mORMot adds its own authenticated AES-GCM
record and session trailer. The endpoint `ITunnelTransmit` implementation
only dispatches the complete message to the existing KVM engine.

KVM remains limited to 3 MiB per message, below mORMot's 16-MiB direct
allowance. Invalid message kinds and oversized frames are rejected. This
changes only the **experimental direct** wire format, not existing WebSocket
clients. Older KD1 fragmenting direct clients must migrate at both ends.

## Compatibility and operational notes

- Standalone server / WebSocket packet format are unchanged.
- Win7 uses GDI, not DXGI. The in-process server must run in the active
  desktop session (a service in Session 0 cannot capture an interactive desktop).
- This integration **does not eliminate mORMot2 or TurboJPEG**; it avoids a
  separate LazDesk process and, in direct mode, eliminates a local TCP socket.
- mORMot's encryption must be enabled; `StartDirect` uses `[toEcdhe]` and
  enforces an independent 16+ byte application secret. Both ends still use
  the normal per-peer LazDesk token for control/view authorization.
- The host needs Free Pascal/Lazarus, mORMot2 as a source dependency, and
  native libraries appropriate to the chosen build mode.
- Source tests are in `tests/test_embedded_tunnel_sources.py` and the Pascal
  direct-message test `tests/test_direct_wire.lpr`. The embedded/direct feature has **not been
  compiled or exercised under Windows 7** in this environment.

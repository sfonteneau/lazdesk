# Use LazDesk Viewer in an existing Lazarus application

## Recommended: separate viewer window in the host process

Add **`packages/LazDeskViewer.lpk`** to your Lazarus/FPC application. Use
`client/kvm_viewer_window.pas` (`TKvmViewerWindow`) to create a **regular
modeless top-level window**, not a child panel. This keeps the existing viewer's
menu bar, monitor selection, full-screen toggle, keyboard/mouse, video decoder,
clipboard, and connection handling without launching **`LazDeskClient.exe`**.

- The host has **one executable**. The viewer units are compiled and linked
  into that existing application. TurboJPEG and mORMot2 dependencies still
  need to be available when building/linking the host.
- `TKvmViewerWindow` inherits the current `TKvmViewForm`; it is an LCL `TForm`
  and uses the native window system (an `HWND` on Windows). Do not manually
  invoke Win32 `CreateWindow` or run a second `Application.Run`.
- Opening/closing the viewer does not stop the main form or process. The viewer
  window's `OnClose` sets `caFree`, and the inherited destructor closes the
  WebSocket and joins its decoder/clipboard workers.
- The caller must already have initialized the **LCL GUI** and must create,
  show, connect and close the viewer on the **LCL main thread**.
- **WebSocket only** for this viewer at present: works with standalone
  `LazDeskServer` or `TKvmEmbedded.StartWebSocket`; **not yet with an
  `OpenDirect()`-only server**. No TCP listener is required *in the client*;
  a server-side WebSocket listener is still needed.

### Minimal usage: click a button to open LazDesk

Add `LazDeskViewer.lpk` as a required package, then add `kvm_cli` and
`kvm_viewer_window` to the host form's `uses`. Define
`FViewer: TKvmViewerWindow` in the main form (initialized to `nil`).

```pascal
// From a button click or another LCL-main-thread callback:
procedure TMainForm.OpenViewerClick(Sender: TObject);
var
  Opt: TKvmClientOptions;
begin
  if FViewer <> nil then
  begin
    FViewer.Show;
    FViewer.BringToFront;
    Exit;
  end;

  Opt := DefaultViewerWindowOptions;
  Opt.Host := 'remote-host.example';
  Opt.Port := 7900;
  Opt.Token := GetEnvironmentVariable('LAZDESK_TOKEN');
  Opt.TLS := True; // wss://; must be enabled on the server
  Opt.AutoControl := False;

  FViewer := TKvmViewerWindow.Create(Self);
  try
    FViewer.OnWindowClosed := @ViewerWindowClosed;
    FViewer.Configure(Opt);
    FViewer.Show;      // creates its OWN top-level window
    FViewer.Connect;   // no separate client executable
  except
    FreeAndNil(FViewer);
    raise;
  end;
end;

// Called before LazDesk schedules the viewer's destruction (caFree).
procedure TMainForm.ViewerWindowClosed(Sender: TObject);
begin
  FViewer := nil; // do NOT free Sender here; LCL will do so
end;
```

Alternatively, `OpenLazDeskViewerWindow(Self, Opt)` creates, configures,
shows and connects the viewer in one call. Set `OnWindowClosed` on the returned
object when retaining a reference. Set `ConnectNow=False` to show the window
without immediately connecting. The `Connect` method may report a failure via
`StatusText` rather than raising an exception.

The viewer provides the same `Disconnect`, `RequestControl`,
`ReleaseLocalInputs`, `RefreshDesktop`, `Connected`, `Authenticated`,
`ControlGranted`, `StatusText` and `OnStatusChange` members as the original
viewer form. `TakeControl(Enabled)` is a convenience alias for
`RequestControl(Enabled)`. `Form.Handle` is the native HWND on Windows.
Closing via the title-bar X or LazDesk's **File > Exit** closes **only** the
viewer; if the host destroys its own main form, LCL will free the owned viewer.

See `examples/viewer_separate_window.pas` for a compact standalone helper.

## Alternative: embed the viewer inside a panel or tab

Use `client/kvm_viewer_frame.pas` (`TKvmViewerFrame`) from the new runtime
package **`packages/LazDeskViewer.lpk`**. It is an LCL `TFrame` you can parent
to a `TPanel`, `TTabSheet`, or any existing `TWinControl`.

- No `LazDeskClient.exe` process and no extra top-level viewer window.
- Reuses the current JPEG/TurboJPEG decode worker, painting, keyboard/mouse,
  session authorization, and clipboard code.
- Application owns the frame, connection lifecycle and status/toolbar UI.
- A **borderless child `TKvmViewForm`** is retained internally. This is an
  incremental embedding API, **not yet a full extraction of the viewer engine**.
- **WebSocket only** in this release; it works with the standalone LazDesk server
  and `TKvmEmbedded.StartWebSocket`. It **cannot** yet connect to an
  `OpenDirect()`-only server. Direct client transport is a separate task.

## Add to the host Lazarus application

1. Add `packages/LazDeskViewer.lpk` to your project's required packages;
   ensure `mormot2` and the Lazarus `LCL` packages are available. Or add
   `client/` and `shared/` to your source search paths.
2. Add `kvm_viewer_frame`, `kvm_cli`, `Forms`, `Controls`, `ExtCtrls` to `uses`.
3. Add a `TPanel` or `TTabSheet` named `DesktopPanel` to the existing form.
4. Create, configure and connect the viewer **from the LCL main thread**:

```pascal
uses
  SysUtils, Forms, Controls, ExtCtrls,
  kvm_viewer_frame, kvm_cli;

// Fields of your existing TForm descendant:
//   FViewer: TKvmViewerFrame;

procedure TMyForm.StartRemoteDesktop;
var
  Opt: TKvmClientOptions;
begin
  FViewer := TKvmViewerFrame.Create(Self);
  FViewer.Parent := DesktopPanel;
  FViewer.Align := alClient;
  FViewer.OnStatusChange := @RemoteStatusChanged;
  Opt := DefaultViewerOptions;
  Opt.Host := 'remote-host.example';
  Opt.Port := 7900;
  Opt.Token := GetEnvironmentVariable('LAZDESK_TOKEN');
  Opt.TLS := True;             // recommended: wss://
  Opt.AutoControl := False;
  FViewer.Configure(Opt);
  FViewer.Connect;
end;

procedure TMyForm.RemoteStatusChanged(Sender: TObject);
begin
  StatusLabel.Caption := FViewer.StatusText;
end;

procedure TMyForm.TakeControlClick(Sender: TObject);
begin
  FViewer.TakeControl(True);   // server must grant exclusive control
end;

procedure TMyForm.StopRemoteDesktop;
begin
  if FViewer <> nil then
  begin
    FViewer.OnStatusChange := nil;
    FreeAndNil(FViewer); // disconnects and joins decoder workers
  end;
end;
```

For a shorter code-only helper, see `examples/viewer_in_existing_form.pas`.

## API

| Method / property | Behavior |
| --- | --- |
| `DefaultViewerOptions` | Returns safe, explicit defaults (TLS off, no token, no auto connect) |
| `Configure(Options)` | Host, port, token, TLS, keyboard mode; only while disconnected |
| `Connect`, `Disconnect` | Open/close the existing WebSocket viewer connection |
| `TakeControl(True/False)` | Request/relinquish server-authorized control; not a bypass |
| `RefreshDesktop` | Request full refresh after authentication |
| `ReleaseLocalInputs` | Release held local key/button state when hiding the tab or deactivating the host |
| `StatusText`, `OnStatusChange` | Current viewer status and GUI-thread status notification |
| `Connected` | TCP/WebSocket exists; does **not** imply AUTH completed |
| `Authenticated` | LazDesk token accepted by the server |
| `HasControl` | Server granted control and desktop is available |

The component itself does not display a menu bar. Integrate any connection
buttons, `Take control` checkbox or monitor selectors into your host UI.
The current frame has no public monitor-selection API yet: it defaults to
showing all remote monitors fitted inside the control.

## Limitations and safety

- The existing `WebSocketsConnect` handshake is synchronous; a slow or dead
  endpoint can block the LCL thread temporarily (timeout up to 10 seconds).
  Avoid blocking the UI on network failures if the host must remain responsive.
- The frame disables the old `F11` full-screen shortcut and all automatic
  top-level window resizing. In embedded mode `F11` can be forwarded to the
  remote desktop when control is granted. The host controls resizing.
- Call `ReleaseLocalInputs` when hiding the tab or changing active windows.
  On destruction, the viewer also releases its network session and workers.
- Clipboard is native to the local desktop. Avoid running multiple concurrent
  viewer instances until their clipboard interactions are explicitly tested.
- Inbound and outbound frames keep their existing protocol checks; the host
  must still configure TLS or use a private VPN for unencrypted ws://.
- **Compiling/running this viewer on Win7, and GUI behavior with nested forms,
  are not verified** in the current development environment (no Lazarus/FPC).
- An embedded viewer does not imply an embedded **server**: use
  `packages/LazDeskEmbedded.lpk` / `server/kvm_embedded.pas` separately if the
  same host also serves the desktop.

## Constraints shared by both viewer modes

- The existing `WebSocketsConnect` handshake is synchronous, so a slow network
  or unreachable server can briefly block the GUI thread (up to 10 seconds).
- The unit-based integration targets **Lazarus/LCL host applications**. A
  non-LCL Win32 host cannot simply call this Pascal API as a Win32 DLL export;
  that would require a separate library ABI and LCL message-loop integration.
- Creating multiple simultaneous viewers is possible, but multiple clipboard
  sessions have not yet been validated.
- Building/running this integration on **Windows 7** has not been verified
  here; Free Pascal and Lazarus are unavailable in this environment.

## Future OpenDirect viewer

The server `TKvmEmbedded.StartDirect` already uses the official mORMot2
`TTunnelLocal.OpenDirect()` support. To complete a **socket-free** client,
introduce a client transport abstraction that routes the same KVM text/binary
messages into the video worker and sends ACK/heartbeat/input replies through
`TKvmDirectEndpoint`. Do not create a second JPEG decoder or duplicate input
validation; keep the same viewer frame and change only its transport.

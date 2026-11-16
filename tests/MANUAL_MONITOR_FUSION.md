# Manual QA: remote monitor fusion and independent windows

The static tests in `test_monitor_fusion_detach_sources.py` validate wiring,
but **do not replace a Lazarus build and interactive Windows tests**.

## Priority: Windows mixed DPI

Remote server: two 1920x1080 monitors. Client: local 3840x2160 monitor at
Windows display scaling 200%, alongside 1920x1080 at 100%.

1. Connect normally. In **View > Monitors > Fusion**, both remote monitors
   should be checked and merged/spanned as before.
2. Uncheck **Monitor 2** in the Fusion submenu. It should open in one native,
   independently movable and resizable window. Monitor 2 must disappear from
   the merged view, with no remaining black slot. Monitor 1 stays accessible.
3. Move the separate window between the 4K and Full HD displays; check zoom,
   no incorrect hit-test offsets, consistent pointer hotspot, no extra OS
   bitmap scaling, and no cropping around Windows taskbar/title bar.
4. Press F11 with the separate window focused; verify only that window enters
   and leaves fullscreen. Then press F11 in the main viewer and verify its
   fullscreen mode is independent.
5. After acquiring exclusive control, click both remote views, type text,
   use Shift/Ctrl/AltGr and verify mouse buttons, wheel, cursor shape, Unicode
   text and shortcuts. Drag from one remote screen into another; pointer
   positions and the final mouse-button release must be correct.
6. Focus another local application while holding a remote modifier or button.
   Held input must be released promptly. Switching between LazDesk windows
   must not unnecessarily send a global input release.
7. Close the detached window with X: the monitor must be remerged, retaining
   the one session. Detach it again; then re-check its Fusion menu item and
   confirm that it remerges.
8. Detach both screens: the main viewer stays available for menus and shows
   the placeholder. Reintegrate either screen, confirm rendering resumes.
9. Hide one detached remote monitor from the regular Monitors selection list:
   the window should disappear. Reselect it: its separate window should return.
10. Disconnect/reconnect with separate windows open, then exit LazDesk with
    separate windows open. All child windows must be freed and the next
    connection must start merged. No second WebSocket/decoder is allowed.

## Other regression cases

- One local screen, two/three remote screens; move and resize all detached
  windows independently on a single local screen.
- Two local screens with same DPI; switch from two merged to one detached and
  back while main form is in normal/maximized/fullscreen state.
- Windows hotplug, change of DPI, monitor orientation, and server topology
  change; verify that stale windows and stale coordinate mappings do not linger.
- Change the UI language between French and English with detached windows open.
- In-form `TKvmViewerFrame` embedded in a host: remains merged and never
  creates detached top-level windows.
- Linux/X11 and macOS/Cocoa where supported by the local build pipeline.

## Build

Use the normal `build_standalone_windows.cmd` command in the repository's
README with a compatible FPC, Lazarus, mORMot2 and native dependencies.

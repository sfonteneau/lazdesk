unit kvm_x11_api;

{$mode objfpc}{$H+}{$packrecords c}

interface

uses ctypes;

type
  PXImage = ^TXImage;
  TXImage = record
    width, height, xoffset, format: CInt;
    data: PByte;
    byte_order, bitmap_unit, bitmap_bit_order, bitmap_pad: CInt;
    depth, bytes_per_line, bits_per_pixel: CInt;
    red_mask, green_mask, blue_mask: CULong;
  end;

type
  TXWindowAttributes = record
    x, y, width, height, border_width, depth: CInt;
    visual: Pointer; root: CULong;
    win_class, bit_gravity, win_gravity, backing_store: CInt;
    backing_planes, backing_pixel: CULong;
    save_under: CInt; colormap: CULong;
    map_installed, map_state: CInt;
    all_event_masks, your_event_mask, do_not_propagate_mask: CLong;
    override_redirect: CInt; screen: Pointer;
  end;
  TXShmInfo = record
    shmseg: CULong; shmid: CInt; shmaddr: Pointer; readOnly: CInt;
  end;
  TXErrorHandler = function(D, E: Pointer): CInt; cdecl;
  PKeySym = ^CULong;
function XGetWindowAttributes(D: Pointer; W: CULong;
  out Attr: TXWindowAttributes): CInt; cdecl; external 'libX11.so.6';
function XGetSubImage(D: Pointer; W: CULong; X, Y: CInt; Width, Height: CUInt;
  PlaneMask: CULong; Format: CInt; Dest: PXImage; DX, DY: CInt): PXImage;
  cdecl; external 'libX11.so.6';
function XDefaultVisual(D: Pointer; Screen: CInt): Pointer;
  cdecl; external 'libX11.so.6';
function XDefaultDepth(D: Pointer; Screen: CInt): CInt;
  cdecl; external 'libX11.so.6';
function XSync(D: Pointer; Discard: CInt): CInt; cdecl; external 'libX11.so.6';
function XSetErrorHandler(Handler: TXErrorHandler): TXErrorHandler;
  cdecl; external 'libX11.so.6';
function XShmQueryExtension(D: Pointer): CInt; cdecl; external 'libXext.so.6';
function XShmCreateImage(D, Visual: Pointer; Depth: CUInt; Format: CInt;
  Data: Pointer; var Info: TXShmInfo; W, H: CUInt): PXImage;
  cdecl; external 'libXext.so.6';
function XShmAttach(D: Pointer; var Info: TXShmInfo): CInt;
  cdecl; external 'libXext.so.6';
function XShmDetach(D: Pointer; var Info: TXShmInfo): CInt;
  cdecl; external 'libXext.so.6';
function XShmGetImage(D: Pointer; Drawable: CULong; Image: PXImage;
  X, Y: CInt; PlaneMask: CULong): CInt; cdecl; external 'libXext.so.6';
function shmget(Key: CInt; Size: csize_t; Flags: CInt): CInt;
  cdecl; external 'c' name 'shmget';
function shmat(ID: CInt; Addr: Pointer; Flags: CInt): Pointer;
  cdecl; external 'c' name 'shmat';
function shmdt(Addr: Pointer): CInt; cdecl; external 'c' name 'shmdt';
function shmctl(ID, Cmd: CInt; Data: Pointer): CInt;
  cdecl; external 'c' name 'shmctl';
function XDisplayKeycodes(D: Pointer; out MinCode, MaxCode: CInt): CInt;
  cdecl; external 'libX11.so.6';
function XGetKeyboardMapping(D: Pointer; First: Byte; Count: CInt;
  out PerCode: CInt): PKeySym; cdecl; external 'libX11.so.6';
function XChangeKeyboardMapping(D: Pointer; First, PerCode: CInt;
  Syms: PKeySym; Count: CInt): CInt; cdecl; external 'libX11.so.6';
function XFree(Data: Pointer): CInt; cdecl; external 'libX11.so.6';
function XQueryKeymap(D: Pointer; Keys: PAnsiChar): CInt;
  cdecl; external 'libX11.so.6';
function XkbKeycodeToKeysym(D: Pointer; Key: Byte; Group, Level: CInt): CULong;
  cdecl; external 'libX11.so.6';

type
  TXkbState = record
    group, locked_group: Byte; base_group, latched_group: CUShort;
    mods, base_mods, latched_mods, locked_mods, compat_state, grab_mods,
      compat_grab_mods, lookup_mods, compat_lookup_mods: Byte;
    ptr_buttons: CUShort;
  end;
function XkbGetState(D: Pointer; Device: CUInt; out State: TXkbState): CInt;
  cdecl; external 'libX11.so.6';
function XkbLockModifiers(D: Pointer; Device, Affect, Values: CUInt): CInt;
  cdecl; external 'libX11.so.6';

function XOpenDisplay(Name: PAnsiChar): Pointer; cdecl;
  external 'libX11.so.6' name 'XOpenDisplay';
function XCloseDisplay(D: Pointer): CInt; cdecl;
  external 'libX11.so.6' name 'XCloseDisplay';
function XDefaultScreen(D: Pointer): CInt; cdecl;
  external 'libX11.so.6' name 'XDefaultScreen';
function XRootWindow(D: Pointer; Screen: CInt): CULong; cdecl;
  external 'libX11.so.6' name 'XRootWindow';
function XDisplayWidth(D: Pointer; Screen: CInt): CInt; cdecl;
  external 'libX11.so.6' name 'XDisplayWidth';
function XDisplayHeight(D: Pointer; Screen: CInt): CInt; cdecl;
  external 'libX11.so.6' name 'XDisplayHeight';
function XGetImage(D: Pointer; Drawable: CULong; X, Y: CInt;
  W, H: CUInt; PlaneMask: CULong; Format: CInt): PXImage; cdecl;
  external 'libX11.so.6' name 'XGetImage';
function XGetPixel(Img: PXImage; X, Y: CInt): CULong; cdecl;
  external 'libX11.so.6' name 'XGetPixel';
function XDestroyImage(Img: PXImage): CInt; cdecl;
  external 'libX11.so.6' name 'XDestroyImage';
function XQueryPointer(D: Pointer; W: CULong;
  var RootReturn, ChildReturn: CULong;
  var RootX, RootY, WinX, WinY: CInt; var Mask: CUInt): CInt; cdecl;
  external 'libX11.so.6' name 'XQueryPointer';
function XKeysymToKeycode(D: Pointer; Sym: CULong): Byte; cdecl;
  external 'libX11.so.6' name 'XKeysymToKeycode';
function XFlush(D: Pointer): CInt; cdecl;
  external 'libX11.so.6' name 'XFlush';
function XTestQueryExtension(D: Pointer; var EventBase, ErrorBase,
  Major, Minor: CInt): CInt; cdecl;
  external 'libXtst.so.6' name 'XTestQueryExtension';
function XTestFakeMotionEvent(D: Pointer; Screen, X, Y: CInt;
  Delay: CULong): CInt; cdecl;
  external 'libXtst.so.6' name 'XTestFakeMotionEvent';
function XTestFakeButtonEvent(D: Pointer; Button: CUInt;
  Press: CInt; Delay: CULong): CInt; cdecl;
  external 'libXtst.so.6' name 'XTestFakeButtonEvent';
function XTestFakeKeyEvent(D: Pointer; Keycode: CUInt;
  Press: CInt; Delay: CULong): CInt; cdecl;
  external 'libXtst.so.6' name 'XTestFakeKeyEvent';

implementation
end.

unit kvm_quartz_api;

{$mode objfpc}{$H+}{$packrecords c}

interface

{$IFNDEF DARWIN}
  {$FATAL kvm_quartz_api requires macOS}
{$ENDIF}

{$linkframework CoreGraphics}
{$linkframework ApplicationServices}
{$linkframework CoreFoundation}

uses ctypes;

// On Darwin, FPC ajoute lui-meme le prefixe '_' aux symboles C.
// Ne pas le mettre dans 'external name' (sinon __CG... / __CF...).

type
  TCGPoint = record
    X, Y: Double;
  end;
  TCGSize = record
    Width, Height: Double;
  end;
  TCGRect = record
    Origin: TCGPoint;
    Size: TCGSize;
  end;

function CGGetActiveDisplayList(Max: CUInt; Displays, Count: PCUInt): CInt;
  cdecl; external name 'CGGetActiveDisplayList';
function CGDisplayPixelsWide(DisplayID: CUInt): NativeUInt;
  cdecl; external name 'CGDisplayPixelsWide';
function CGDisplayPixelsHigh(DisplayID: CUInt): NativeUInt;
  cdecl; external name 'CGDisplayPixelsHigh';
procedure CGEventSetFlags(Event: Pointer; Flags: QWord);
  cdecl; external name 'CGEventSetFlags';
procedure CGEventSetIntegerValueField(Event: Pointer; Field: CUInt; Value: Int64);
  cdecl; external name 'CGEventSetIntegerValueField';
function CGMainDisplayID: CUInt; cdecl; external name 'CGMainDisplayID';
function CGPreflightScreenCaptureAccess: Boolean; cdecl;
  external name 'CGPreflightScreenCaptureAccess';
function CGRequestScreenCaptureAccess: Boolean; cdecl;
  external name 'CGRequestScreenCaptureAccess';
function CGDisplayBounds(DisplayID: CUInt): TCGRect; cdecl;
  external name 'CGDisplayBounds';
function CGEventCreate(Source: Pointer): Pointer; cdecl;
  external name 'CGEventCreate';
function CGEventGetLocation(Event: Pointer): TCGPoint; cdecl;
  external name 'CGEventGetLocation';
function CGEventCreateMouseEvent(Source: Pointer; EventType: CUInt;
  Position: TCGPoint; Button: CUInt): Pointer; cdecl;
  external name 'CGEventCreateMouseEvent';
function CGEventCreateKeyboardEvent(Source: Pointer; KeyCode: Word;
  KeyDown: Boolean): Pointer; cdecl;
  external name 'CGEventCreateKeyboardEvent';
function CGEventCreateScrollWheelEvent(Source: Pointer; Units,
  WheelCount: CUInt; Wheel1: CInt): Pointer; cdecl; varargs;
  external name 'CGEventCreateScrollWheelEvent';
procedure CGEventKeyboardSetUnicodeString(Event: Pointer;
  StringLength: NativeUInt; UnicodeString: PWord); cdecl;
  external name 'CGEventKeyboardSetUnicodeString';
procedure CGEventPost(Tap: CUInt; Event: Pointer); cdecl;
  external name 'CGEventPost';
procedure CFRelease(Obj: Pointer); cdecl; external name 'CFRelease';
function AXIsProcessTrusted: Boolean; cdecl;
  external name 'AXIsProcessTrusted';

implementation
end.

unit kvm_mouse_state;
{$mode objfpc}{$H+}
// Pure state machine, shared by the Quartz backend and executable tests.
interface
type TKvmMouseState = record Buttons: array[1..3] of Boolean; end;
function QuartzMouseEvent(var S: TKvmMouseState; Action, Button: Byte;
  out EventType, NativeButton: Cardinal): Boolean;
implementation
function QuartzMouseEvent(var S: TKvmMouseState; Action, Button: Byte;
  out EventType, NativeButton: Cardinal): Boolean;
begin
  Result := False; EventType := 5; NativeButton := 0;
  if Action > 2 then Exit;
  if Action = 0 then
  begin
    if S.Buttons[1] then begin EventType := 6; NativeButton := 0; end
    else if S.Buttons[2] then begin EventType := 7; NativeButton := 1; end
    else if S.Buttons[3] then begin EventType := 27; NativeButton := 2; end;
  end
  else
  begin
    if (Button < 1) or (Button > 3) then Exit;
    S.Buttons[Button] := Action = 1;
    NativeButton := Button - 1;
    case Button of
      1: if Action = 1 then EventType := 1 else EventType := 2;
      2: if Action = 1 then EventType := 3 else EventType := 4;
      3: if Action = 1 then EventType := 25 else EventType := 26;
    end;
  end;
  Result := True;
end;
end.

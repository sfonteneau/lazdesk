unit kvm_keysym;
{$mode objfpc}{$H+}
interface
function KvmKeysym(VK: Word): Cardinal;
implementation
function KvmKeysym(VK: Word): Cardinal;
begin
  Result := 0;
  if (VK >= $41) and (VK <= $5a) then Exit(VK + 32); // ASCII lowercase
  if (VK >= $30) and (VK <= $39) then Exit(VK);
  if (VK >= $70) and (VK <= $87) then Exit($ffbe + VK - $70);
  if (VK >= $60) and (VK <= $69) then Exit($ffb0 + VK - $60);
  case VK of
    $08: Result := $ff08; // BackSpace
    $09: Result := $ff09; // Tab
    $0d: Result := $ff0d; // Return
    $10, $a0: Result := $ffe1; // Shift_L
    $a1: Result := $ffe2;
    $11, $a2: Result := $ffe3; // Control_L
    $a3: Result := $ffe4;
    $12, $a4: Result := $ffe9; // Alt_L
    $a5: Result := $ffea;
    $14: Result := $ffe5; // Caps_Lock
    $13: Result := $ff13; // Pause
    $15: Result := $ff27; // Hiragana_Katakana / Kana toggle
    $19: Result := $ff21; // Kanji
    $1c: Result := $ff23; // Henkan (convert)
    $1d: Result := $ff22; // Muhenkan (non-convert)
    $1f: Result := $ff7e; // Mode_switch
    $2c: Result := $ff61; // Print
    $5d: Result := $ff67; // Menu
    $1b: Result := $ff1b; // Escape
    $20: Result := $0020;
    $21: Result := $ff55; // Page_Up
    $22: Result := $ff56; // Page_Down
    $23: Result := $ff57; // End
    $24: Result := $ff50; // Home
    $25: Result := $ff51; // Left
    $26: Result := $ff52; // Up
    $27: Result := $ff53; // Right
    $28: Result := $ff54; // Down
    $2d: Result := $ff63; // Insert
    $2e: Result := $ffff; // Delete
    $5b: Result := $ffeb; // Super_L
    $5c: Result := $ffec; // Super_R
    $6a: Result := $ffaa; // KP_Multiply
    $6b: Result := $ffab; // KP_Add
    $6d: Result := $ffad; // KP_Subtract
    $6e: Result := $ffae; // KP_Decimal
    $6f: Result := $ffaf; // KP_Divide
    $90: Result := $ff7f; // NumLock
    $91: Result := $ff14; // ScrollLock
    $ba: Result := $003b; // semicolon
    $bb: Result := $003d; // equal
    $bc: Result := $002c; // comma
    $bd: Result := $002d; // minus
    $be: Result := $002e; // period
    $bf: Result := $002f; // slash
    $c0: Result := $0060; // grave
    $db: Result := $005b; // left bracket
    $dc: Result := $005c; // backslash
    $dd: Result := $005d; // right bracket
    $de: Result := $0027; // apostrophe
  end;
end;

end.

program test_p123_win_present;
{$mode objfpc}{$H+}{$pointermath on}
uses Windows, SysUtils, Types, kvm_surface, kvm_present_win;
procedure Check(Value: Boolean; const MessageText: string);
begin if not Value then raise Exception.Create(MessageText); end;
var DC,Screen: HDC; DIB: HBITMAP; Old: HGDIOBJ; Bits: Pointer;
    BI: TBitmapInfo; S: TKvmSurface; P: PByte; I,X,Y: Integer;
    Presenter: TKvmWinPresenter;
begin
  DC:=0; DIB:=0; Old:=0; Screen:=GetDC(0);
  try
    Check(Screen<>0,'GetDC'); DC:=CreateCompatibleDC(Screen); Check(DC<>0,'CreateDC');
    FillChar(BI,SizeOf(BI),0); BI.bmiHeader.biSize:=SizeOf(TBitmapInfoHeader);
    BI.bmiHeader.biWidth:=16; BI.bmiHeader.biHeight:=-16;
    BI.bmiHeader.biPlanes:=1; BI.bmiHeader.biBitCount:=32;
    BI.bmiHeader.biCompression:=BI_RGB;
    DIB:=CreateDIBSection(Screen,BI,DIB_RGB_COLORS,Bits,0,0);
    Check((DIB<>0) and (Bits<>nil),'CreateDIBSection'); Old:=SelectObject(DC,DIB);
    Check(AllocateSurface(S,16,16),'Allocate');
    for I:=0 to 255 do
    begin
      S.Pixels[I*4+1]:=#30; S.Pixels[I*4+2]:=#110;
      S.Pixels[I*4+3]:=#210; S.Pixels[I*4+4]:=#255;
    end;
    Check(PaintWindowsSurface(DC,S,0,0,16,16),'Native presentation'); GdiFlush;
    P:=PByte(Bits);
    for I:=0 to 255 do
    begin
      Check((P[0]=30) and (P[1]=110) and (P[2]=210),'Native GDI channel mismatch'); Inc(P,4);
    end;
    Check(PaintWindowsSurface(DC,S,0,0,8,8),'HALFTONE presentation');

    Presenter:=TKvmWinPresenter.Create;
    try
      Check(Presenter.Update(S,Rect(0,0,16,16)),'Persistent full update');
      Check(Presenter.Paint(DC,0,0,16,16),'Persistent full paint'); GdiFlush;
      P:=PByte(Bits);
      Check((P[0]=30) and (P[1]=110) and (P[2]=210),'Persistent initial pixel');

      // Change one pixel outside the advertised damage and a 4x4 dirty area.
      // The outside pixel must remain unchanged in the persistent DIB.
      S.Pixels[1]:=#99; S.Pixels[2]:=#98; S.Pixels[3]:=#97;
      for Y:=4 to 7 do for X:=4 to 7 do
      begin
        I:=(Y*16+X)*4;
        S.Pixels[I+1]:=#7; S.Pixels[I+2]:=#8; S.Pixels[I+3]:=#9; S.Pixels[I+4]:=#255;
      end;
      Check(Presenter.Update(S,Rect(4,4,8,8)),'Persistent dirty update');
      Check(Presenter.Paint(DC,0,0,16,16),'Persistent dirty paint'); GdiFlush;
      P:=PByte(Bits);
      Check((P[0]=30) and (P[1]=110) and (P[2]=210),
        'Pixels outside dirty rectangle were recopied');
      P:=PByte(Bits)+(5*16+5)*4;
      Check((P[0]=7) and (P[1]=8) and (P[2]=9),'Dirty rectangle was not updated');
    finally
      Presenter.Free;
    end;
    WriteLn('PASS: Windows persistent DIB, partial dirty updates and scaled GDI path');
  finally
    if (DC<>0) and (Old<>0) then SelectObject(DC,Old);
    if DIB<>0 then DeleteObject(DIB);
    if DC<>0 then DeleteDC(DC);
    if Screen<>0 then ReleaseDC(0,Screen);
  end;
end.

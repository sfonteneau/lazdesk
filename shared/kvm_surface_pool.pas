unit kvm_surface_pool;
{$mode objfpc}{$H+}
// Worker-owned canonical pixels are NEVER published. Two reusable immutable
// presentation buffers are refreshed from dirty row spans, not full frames.
// A buffer is writable only when the pool is its sole string owner. Readers
// may retain snapshots arbitrarily; saturation falls back to a private copy,
// never to blocking ACKs or overwriting a reader. Call only on the worker.
interface
uses SysUtils, kvm_surface;
type
  TKvmSurfaceSlot = record
    Surface: TKvmSurface;
    Left, Right: array of Integer; // inclusive left / exclusive right per row
  end;
  TKvmSurfacePool = class
  private
    FSlots: array[0..1] of TKvmSurfaceSlot;
    FLast: TKvmSurface;
    FChanged: Boolean;
  public
    procedure Reset;
    // Call after EVERY pixel mutation, before Snapshot. Reset on geometry or
    // desktop epoch changes. Pending damage accumulates until each slot syncs.
    procedure MarkDirty(X, Y, W, H: Integer);
    function Snapshot(const Source: TKvmSurface; out Dest: TKvmSurface;
      out CopiedBytes: QWord): Boolean;
  end;
implementation

procedure TKvmSurfacePool.Reset;
var I: Integer;
begin
  ClearSurface(FLast);
  for I:=Low(FSlots) to High(FSlots) do
  begin
    ClearSurface(FSlots[I].Surface);
    FSlots[I].Left:=nil; FSlots[I].Right:=nil;
  end;
  FChanged:=True;
end;

procedure TKvmSurfacePool.MarkDirty(X, Y, W, H: Integer);
var I, Row: Integer;
begin
  if (X<0) or (Y<0) or (W<1) or (H<1) then
    raise Exception.Create('Invalid surface damage');
  FChanged:=True;
  for I:=Low(FSlots) to High(FSlots) do
    if SurfaceValid(FSlots[I].Surface) then
    begin
      if (Int64(X)+W>FSlots[I].Surface.Width) or
         (Int64(Y)+H>FSlots[I].Surface.Height) then
        raise Exception.Create('Surface damage outside geometry');
      for Row:=Y to Y+H-1 do
      begin
        if X<FSlots[I].Left[Row] then FSlots[I].Left[Row]:=X;
        if X+W>FSlots[I].Right[Row] then FSlots[I].Right[Row]:=X+W;
      end;
    end;
end;

function TKvmSurfacePool.Snapshot(const Source: TKvmSurface;
  out Dest: TKvmSurface; out CopiedBytes: QWord): Boolean;
var I, Selected, Row, Offset, Count: Integer;
    Slot: ^TKvmSurfaceSlot;
begin
  Result:=False; CopiedBytes:=0; ClearSurface(Dest);
  if not SurfaceValid(Source) then Exit;
  if not FChanged and SurfaceValid(FLast) and
     (FLast.Width=Source.Width) and (FLast.Height=Source.Height) then
  begin
    Dest:=FLast; Exit(True); // cursor-only: no pixel copy at all
  end;
  ClearSurface(FLast);
  Selected:=-1;
  for I:=Low(FSlots) to High(FSlots) do
    // Use the public RTL function, not assumptions about string headers.
    // With refcount=1 no reader exists that could create a new alias.
    if (FSlots[I].Surface.Pixels='') or
       (StringRefCount(FSlots[I].Surface.Pixels)=1) then
    begin Selected:=I; Break; end;
  if Selected<0 then
  begin
    // Unusual caller retaining both buffers: preserve immutable snapshots
    // and ACK progress. This does not grow the pool or alias canonical pixels.
    if not AllocateSurface(FLast,Source.Width,Source.Height) then Exit;
    Move(Source.Pixels[1],FLast.Pixels[1],Length(Source.Pixels));
    CopiedBytes:=Length(Source.Pixels);
  end
  else
  begin
    Slot:=@FSlots[Selected];
    if (Slot^.Surface.Width<>Source.Width) or
       (Slot^.Surface.Height<>Source.Height) or
       not SurfaceValid(Slot^.Surface) then
    begin
      ClearSurface(Slot^.Surface);
      if not AllocateSurface(Slot^.Surface,Source.Width,Source.Height) then Exit;
      SetLength(Slot^.Left,Source.Height); SetLength(Slot^.Right,Source.Height);
      Move(Source.Pixels[1],Slot^.Surface.Pixels[1],Length(Source.Pixels));
      CopiedBytes:=Length(Source.Pixels);
    end
    else
      for Row:=0 to Source.Height-1 do
        if Slot^.Right[Row]>Slot^.Left[Row] then
        begin
          Offset:=(Row*Source.Width+Slot^.Left[Row])*4+1;
          Count:=(Slot^.Right[Row]-Slot^.Left[Row])*4;
          Move(Source.Pixels[Offset],Slot^.Surface.Pixels[Offset],Count);
          Inc(CopiedBytes,Count);
        end;
    for Row:=0 to Source.Height-1 do
    begin Slot^.Left[Row]:=Source.Width; Slot^.Right[Row]:=0; end;
    FLast:=Slot^.Surface;
  end;
  Dest:=FLast; FChanged:=False; Result:=True;
end;
end.

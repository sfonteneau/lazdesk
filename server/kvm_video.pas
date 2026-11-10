unit kvm_video;
{$mode objfpc}{$H+}
interface
uses SysUtils, kvm_frame, kvm_damage, kvm_jpeg_batch, kvm_codec;
type
  TKvmPackets = TKvmJpegPackets;
  TKvmVersions = array of Cardinal;
  TKvmVideo = class
  private
    FEncoder: TParallelJpegEncoder;
    FH264: TKvmH264Encoder;
    FHardwareName, FDevice: string;
    FUseH264: Boolean;
    FFPS, FBitrate: Integer;
    FFrame, FPrevious: TRgbFrame;
    FScaleMap: TKvmScaleMap;
    FDirty: TKvmDirtyMap;
    FRegions: TKvmRegions;
    FPackets: TKvmPackets;
    FQuality: Integer;
    FGeometryDirty, FFineDamage: Boolean;
    function UpdateH264(const Source: TRgbFrame; MaxW,MaxH: Integer;
      out GeometryChanged: Boolean): Boolean;
  public
    Cache: TKvmPackets;
    Versions: TKvmVersions;
    Groups: TKvmGroupMap;
    Width, Height: Integer;
    constructor Create(const EncoderName: string = 'turbojpeg';
      const Device: string = ''; FPS: Integer = 3; Kbps: Integer = 8000);
    destructor Destroy; override;
    function Update(const Source: TRgbFrame; MaxW, MaxH, Quality: Integer;
      out GeometryChanged: Boolean): Boolean;
  end;
implementation
uses Math, kvm_wire, kvm_extwire;
constructor TKvmVideo.Create(const EncoderName,Device: string; FPS,Kbps: Integer);
begin
  inherited Create; FEncoder:=TParallelJpegEncoder.Create;
  FFineDamage := GetEnvironmentVariable('LAZDESK_FINE_DAMAGE') <> '0';
  FHardwareName:=EncoderName; FDevice:=Device; FBitrate:=Kbps;
  FUseH264:=EncoderName<>'turbojpeg';
  // Native FFmpeg bridge currently accepts 1..60, unlike JPEG scheduling.
  // FPS=0 means unpaced JPEG, not a valid H.264 time base.
  if FPS<=0 then FFPS:=60 else FFPS:=Min(FPS,60);
end;
destructor TKvmVideo.Destroy;
begin FH264.Free; FEncoder.Free; inherited Destroy; end;
function TKvmVideo.Update(const Source: TRgbFrame; MaxW, MaxH, Quality: Integer;
  out GeometryChanged: Boolean): Boolean;
var
  W, H, Cols, Rows, R, C, X, Y, TW, TH, I, J, T: Integer;
  DirtyCount, MaxGroupTiles: Integer;
  Changed: Boolean;
  Current: TRgbFrame;
begin
  Result := False; GeometryChanged := False;
  if FUseH264 then
  begin
    try Exit(UpdateH264(Source,MaxW,MaxH,GeometryChanged));
    except on E: Exception do
      begin
        if FHardwareName<>'auto' then raise;
        WriteLn('[codec] Falling back to TurboJPEG: ',E.Message);
        FUseH264:=False; FreeAndNil(FH264);
        FQuality:=-1; FGeometryDirty:=True; Width:=0; Height:=0;
        SetLength(Cache,0); SetLength(Versions,0); SetLength(Groups,0);
        FPrevious.Width:=0; FPrevious.Height:=0; FPrevious.RGB:='';
      end;
    end;
  end;
  // Native-size path: reference the capture buffer only until this call
  // returns. Do not keep an alias in FFrame across the next capture.
  if not ScaledSize(Source.Width, Source.Height, MaxW, MaxH, W, H) then Exit;
  if (W = Source.Width) and (H = Source.Height) then
    Current := Source
  else
  begin
    if not ResizeFrameCached(Source, MaxW, MaxH, FFrame, FScaleMap) then Exit;
    Current := FFrame;
  end;
  W := Current.Width; H := Current.Height;
  Cols := (W + KVM_TILE_SIZE - 1) div KVM_TILE_SIZE;
  Rows := (H + KVM_TILE_SIZE - 1) div KVM_TILE_SIZE;
  GeometryChanged := (W <> Width) or (H <> Height);
  if GeometryChanged or (Quality <> FQuality) then
  begin
    Width := W; Height := H; FQuality := Quality;
    SetLength(Cache, Cols * Rows); SetLength(Versions, Cols * Rows);
    SetLength(Groups, Cols * Rows); SetLength(FDirty, Cols * Rows);
    for I := 0 to High(Cache) do
    begin Cache[I] := ''; Versions[I] := 0; Groups[I] := I; end;
    FPrevious.Width := 0; FPrevious.Height := 0; FPrevious.RGB := '';
    FGeometryDirty := True;
  end;
  Changed := False;
  DirtyCount := 0;
  for R := 0 to Rows - 1 do
    for C := 0 to Cols - 1 do
    begin
      X := C * KVM_TILE_SIZE; Y := R * KVM_TILE_SIZE;
      TW := Min(KVM_TILE_SIZE, W - X); TH := Min(KVM_TILE_SIZE, H - Y);
      I := R * Cols + C;
      FDirty[I] := (Cache[I] = '') or
        RegionTileChanged(Current, FPrevious, X, Y, TW, TH);
      if FDirty[I] then Inc(DirtyCount);
      Changed := Changed or FDirty[I];
    end;
  if Changed then
  begin
    ExpandDirtyCacheGroups(FDirty, Groups);
    // Large initial/full-screen changes keep efficient 2x2 JPEG groups.
    // When less than 1/8 of the *actual* tiles changed, split the expanded
    // old groups into independent 256x256 cache entries. This first sparse
    // frame may contain more packets, but subsequent small changes no longer
    // force the same entire 512x512 rectangle to be re-encoded.
    MaxGroupTiles := 2;
    if FFineDamage and (Length(FDirty) >= 16) and
       (DirtyCount <= Length(FDirty) div 8) then MaxGroupTiles := 1;
    if not MakeDirtyRegions(FDirty, Cols, Rows, W, H, FRegions,
      MaxGroupTiles) then Exit;
    SetLength(FPackets, Length(FRegions));
    if not FEncoder.Encode(Current, FRegions, Quality, FPackets) then Exit;
    // Atomic commit of all new rectangles, never half a new snapshot.
    for I := 0 to High(FRegions) do
      for R := FRegions[I].Row to FRegions[I].Row + FRegions[I].Rows - 1 do
        for C := FRegions[I].Col to FRegions[I].Col + FRegions[I].Cols - 1 do
        begin
          T := R * Cols + C; Cache[T] := FPackets[I];
          Groups[T] := FRegions[I].Leader;
          if Versions[T] = High(Cardinal) then Versions[T] := 1 else Inc(Versions[T]);
        end;
    // After the first snapshot, only modified rectangular regions need
    // copying into the previous-frame reference. Unchanged pixels remain
    // identical. ExpandDirtyCacheGroups has already expanded old JPEG groups.
    CopyFrameRegions(Current, FPrevious, FRegions);
  end;
  for J := 0 to High(Cache) do if Cache[J] = '' then Exit;
  Result := Length(Cache) > 0;
  if Result then begin GeometryChanged := FGeometryDirty; FGeometryDirty := False; end;
end;

function TKvmVideo.UpdateH264(const Source: TRgbFrame; MaxW,MaxH: Integer;
  out GeometryChanged: Boolean): Boolean;
const
  {$IFDEF WINDOWS}Candidates: array[0..2] of string = ('h264_nvenc','h264_qsv','h264_amf');{$ENDIF}
  {$IFDEF LINUX}Candidates: array[0..2] of string = ('h264_vaapi','h264_nvenc','h264_qsv');{$ENDIF}
  {$IFDEF DARWIN}Candidates: array[0..0] of string = ('h264_videotoolbox');{$ENDIF}
var
  W,H,I: Integer; Changed: Boolean;
  Current: TRgbFrame;
  Data,Packet: RawByteString; Reason,LastError: string;
begin
  Result:=False; GeometryChanged:=False;
  if (Source.Width<2) or (Source.Height<2) or
     (Length(Source.RGB)<>Int64(Source.Width)*Source.Height*3) then
    raise Exception.Create('Dimensions source H.264 invalides');
  if not ScaledSize(Source.Width,Source.Height,MaxW,MaxH,W,H) then Exit;
  W:=W and not 1; H:=H and not 1;
  // Native even dimensions: borrow only for this synchronous call.
  // Never keep the capture buffer aliased across the next capture.
  if (W=Source.Width) and (H=Source.Height) then
    Current := Source
  else
  begin
    if not ResizeFrameExact(Source,W,H,FFrame,FScaleMap) then
      raise Exception.Create('Dimensions H.264 impossibles');
    Current := FFrame;
  end;
  GeometryChanged:=(Width<>W) or (Height<>H);
  if GeometryChanged then
  begin
    FreeAndNil(FH264); Width:=W; Height:=H;
    FPrevious.RGB:=''; FPrevious.Width:=0; FPrevious.Height:=0;
    SetLength(Cache,1); Cache[0]:=''; SetLength(Versions,1); Versions[0]:=0;
    SetLength(Groups,1); Groups[0]:=0; FGeometryDirty:=True;
  end;
  if FH264=nil then
  begin
    if FHardwareName<>'auto' then
      FH264:=TKvmH264Encoder.Create(FHardwareName,FDevice,W,H,FFPS,FBitrate)
    else
    begin
      LastError:='No hardware encoder available';
      for I:=0 to High(Candidates) do
      begin
        try
          FH264:=TKvmH264Encoder.Create(Candidates[I],FDevice,W,H,FFPS,FBitrate);
          // Probe actual output, not only whether avcodec_open2 succeeded.
          if not FH264.Encode(Current,Data,Reason) then raise Exception.Create(Reason);
          WriteLn('[codec] Profil H.264 materiel : ',Candidates[I]); Break;
        except on E: Exception do begin LastError:=E.Message; FreeAndNil(FH264); end; end;
      end;
      if FH264=nil then raise Exception.Create(LastError);
    end;
  end;
  Changed:=(FPrevious.Order<>Current.Order) or
    (Length(FPrevious.RGB)<>Length(Current.RGB)) or (Cache[0]='');
  if not Changed then Changed:=not CompareMem(Pointer(FPrevious.RGB),Pointer(Current.RGB),Length(Current.RGB));
  if Changed then
  begin
    if not FH264.Encode(Current,Data,Reason) then raise Exception.Create(Reason);
    Packet:=MakeVideo(W,H,Data); if Packet='' then raise Exception.Create('H.264 packet exceeds limits');
    Cache[0]:=Packet; Versions[0]:=NextSerial(Versions[0]);
    CopyFrameReuse(Current,FPrevious);
  end;
  Result:=Cache[0]<>'';
  if Result then begin GeometryChanged:=FGeometryDirty; FGeometryDirty:=False; end;
end;
end.

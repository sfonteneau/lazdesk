unit kvm_jpeg_batch;

{$mode objfpc}{$H+}

// A small persistent JPEG worker pool. Each thread owns its own TurboJPEG
// handle and scratch buffer. Only disjoint rectangle indices are written in
// parallel, and the caller waits for every worker before committing the
// complete cache generation. The wire format and JPEG 4:4:4 stay unchanged.

interface

uses Classes, SysUtils, SyncObjs, kvm_frame, kvm_damage, kvm_turbojpeg;

type
  TKvmJpegPackets = array of RawByteString;
  PKvmJpegPackets = ^TKvmJpegPackets;

  TKvmJpegWorker = class(TThread)
  private
    FWake, FDone: TEvent;
    FEncoder: TTurboJpegEncoder;
    FFrame: TRgbFrame;
    FRegions: TKvmRegions;
    FPackets: PKvmJpegPackets;
    FQuality, FFirst, FStep: Integer;
    FSuccess: Boolean;
    FError: string;
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Submit(const Frame: TRgbFrame; const Regions: TKvmRegions;
      Quality, First, Step: Integer; var Packets: TKvmJpegPackets);
    function WaitDone: Boolean;
    property LastError: string read FError;
  end;

  TParallelJpegEncoder = class
  private
    FMain: TTurboJpegEncoder;
    FWorkers: array of TKvmJpegWorker;
    FMaxThreads: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    function Encode(const Frame: TRgbFrame; const Regions: TKvmRegions;
      Quality: Integer; var Packets: TKvmJpegPackets): Boolean;
  end;

implementation

uses Math, kvm_wire;

function EncodeOne(Encoder: TTurboJpegEncoder; const Frame: TRgbFrame;
  const Region: TKvmRegion; Quality: Integer;
  out Packet: RawByteString): Boolean;
var
  Jpeg: RawByteString;
begin
  Packet := '';
  Result := Encoder.EncodeRect(Frame, Region.X, Region.Y, Region.W,
    Region.H, Quality, Jpeg);
  if Result then
    Packet := MakeTile(Region.X, Region.Y, Region.W, Region.H, Jpeg);
end;

constructor TKvmJpegWorker.Create;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FWake := TEvent.Create(nil, False, False, '');
  FDone := TEvent.Create(nil, False, False, '');
  Start;
end;

destructor TKvmJpegWorker.Destroy;
begin
  Terminate;
  if FWake <> nil then FWake.SetEvent;
  WaitFor;
  FWake.Free;
  FDone.Free;
  inherited Destroy;
end;

procedure TKvmJpegWorker.Submit(const Frame: TRgbFrame;
  const Regions: TKvmRegions; Quality, First, Step: Integer;
  var Packets: TKvmJpegPackets);
begin
  // Called only after the previous job's completion event was consumed.
  FFrame := Frame;
  FRegions := Regions;
  FPackets := @Packets;
  FQuality := Quality;
  FFirst := First;
  FStep := Step;
  FSuccess := False;
  FError := '';
  FWake.SetEvent;
end;

function TKvmJpegWorker.WaitDone: Boolean;
begin
  Result := (FDone.WaitFor(High(Cardinal)) = wrSignaled) and FSuccess;
end;

procedure TKvmJpegWorker.Execute;
var
  I: Integer;
begin
  try
    while not Terminated do
    begin
      if FWake.WaitFor(High(Cardinal)) <> wrSignaled then Break;
      if Terminated then Break;
      try
        if FEncoder = nil then FEncoder := TTurboJpegEncoder.Create;
        FSuccess := True;
        I := FFirst;
        while I < Length(FRegions) do
        begin
          if not EncodeOne(FEncoder, FFrame, FRegions[I], FQuality,
            FPackets^[I]) then
          begin
            FSuccess := False;
            FError := 'Rectangle JPEG invalide';
            Break;
          end;
          Inc(I, FStep);
        end;
      except
        on E: Exception do
        begin
          FSuccess := False;
          FError := E.ClassName + ': ' + E.Message;
        end;
      end;
      // Do not retain the captured frame: a refcounted alias here would
      // force a large copy in the next capture's AllocateFrame call.
      FFrame.RGB := '';
      SetLength(FRegions, 0);
      FPackets := nil;
      FDone.SetEvent;
    end;
  finally
    FEncoder.Free;
  end;
end;

constructor TParallelJpegEncoder.Create;
var
  S: string;
begin
  inherited Create;
  FMain := TTurboJpegEncoder.Create;
  // 1 restores the old sequential encoder. Cap auxiliary handles/threads
  // to keep memory and CPU usage predictable across multiple profiles.
  FMaxThreads := 3;
  S := GetEnvironmentVariable('LAZDESK_JPEG_THREADS');
  if S <> '' then FMaxThreads := StrToIntDef(S, 3);
  FMaxThreads := Max(1, Min(4, FMaxThreads));
end;

destructor TParallelJpegEncoder.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FWorkers) do FWorkers[I].Free;
  FMain.Free;
  inherited Destroy;
end;

function TParallelJpegEncoder.Encode(const Frame: TRgbFrame;
  const Regions: TKvmRegions; Quality: Integer;
  var Packets: TKvmJpegPackets): Boolean;
var
  N, WorkerCount, I, W, Step, OldCount, Submitted: Integer;
  MainOK, WorkerOK: Boolean;
  NewWorker: TKvmJpegWorker;
  MainError: string;
begin
  Result := False;
  N := Length(Regions);
  if Length(Packets) <> N then Exit;
  if N = 0 then Exit(True);
  WorkerCount := 0;
  // Avoid thread dispatch overhead when only one or two tiles change.
  if (FMaxThreads > 1) and (N >= 4) then
    WorkerCount := Min(FMaxThreads - 1, (N div 2) - 1);
  while Length(FWorkers) < WorkerCount do
  begin
    OldCount := Length(FWorkers);
    NewWorker := nil;
    try
      NewWorker := TKvmJpegWorker.Create;
      SetLength(FWorkers, OldCount + 1);
      FWorkers[OldCount] := NewWorker;
      NewWorker := nil;
    except
      on E: Exception do
      begin
        WriteLn('[jpeg] Encodage auxiliaire indisponible : ', E.Message);
        WorkerCount := Length(FWorkers);
      end;
    end;
    NewWorker.Free;
    if Length(FWorkers) = OldCount then Break;
  end;
  Step := WorkerCount + 1;
  // Workers start before main-thread compression, so their work overlaps.
  // A submission failure must still join workers already dispatched.
  MainOK := True;
  MainError := '';
  Submitted := 0;
  try
    for W := 0 to WorkerCount - 1 do
    begin
      FWorkers[W].Submit(Frame, Regions, Quality, W + 1, Step, Packets);
      Inc(Submitted);
    end;
    I := 0;
    while I < N do
    begin
      if not EncodeOne(FMain, Frame, Regions[I], Quality, Packets[I]) then
      begin MainOK := False; Break; end;
      Inc(I, Step);
    end;
  except
    on E: Exception do
    begin MainOK := False; MainError := E.ClassName + ': ' + E.Message; end;
  end;
  // Always join workers even when main compression failed: only after they
  // finished may the caller recycle Frame or its cache packet array.
  WorkerOK := True;
  for W := 0 to Submitted - 1 do
    if not FWorkers[W].WaitDone then
    begin
      WorkerOK := False;
      if FWorkers[W].LastError <> '' then
        WriteLn('[jpeg] ', FWorkers[W].LastError);
    end;
  if MainError <> '' then WriteLn('[jpeg] ', MainError);
  if not MainOK then Exit(False);
  if not WorkerOK then
  begin
    // Preserve video availability when an auxiliary handle is unavailable:
    // fall back to the old sequential path for this frame and future frames.
    FMaxThreads := 1;
    WriteLn('[jpeg] Repli en encodage sequentiel.');
    for I := 0 to N - 1 do
      if not EncodeOne(FMain, Frame, Regions[I], Quality, Packets[I]) then
        Exit(False);
  end;
  Result := True;
end;

end.

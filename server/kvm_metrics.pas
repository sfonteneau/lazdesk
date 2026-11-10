unit kvm_metrics;
{$mode objfpc}{$H+}
interface
uses Classes, SysUtils;
type
  TKvmMetrics = class
  private
    FLock: TRTLCriticalSection;
    FStream: TFileStream;
    FStart, FLast, FCaptureCalls, FCaptures, FCaptureMs, FEncodeCalls, FEncodeMs,
      FQueued, FQueuedBytes, FQueueRejects, FAcks, FAckMs, FSecurityRejects: QWord;
    procedure WriteLine(const S: string);
  public
    constructor Create(const FileName: string);
    destructor Destroy; override;
    procedure Capture(Milliseconds: QWord; Success: Boolean);
    procedure Encode(Milliseconds: QWord);
    procedure Queue(Bytes: Integer; Success: Boolean);
    procedure Ack(Milliseconds: QWord);
    procedure SecurityReject;
    procedure Flush(Force: Boolean = False);
  end;
implementation
constructor TKvmMetrics.Create(const FileName: string);
begin
  inherited Create; InitCriticalSection(FLock); FStart:=GetTickCount64; FLast:=FStart;
  if FileName<>'' then
  begin
    // Never overwrite an existing measurement accidentally.
    if FileExists(FileName) then raise Exception.Create('Metrics file already exists: '+FileName);
    FStream:=TFileStream.Create(FileName,fmCreate);
    WriteLine('elapsed_ms,capture_calls,captures,capture_ms,pipeline_calls,pipeline_ms,queued_batches,queued_bytes,queue_rejects,acks,ack_total_ms,security_rejects');
  end;
end;
procedure TKvmMetrics.WriteLine(const S: string);
var R: RawByteString;
begin if FStream=nil then Exit; R:=RawByteString(S+LineEnding); FStream.WriteBuffer(R[1],Length(R)); end;
destructor TKvmMetrics.Destroy;
begin Flush(True); FStream.Free; DoneCriticalSection(FLock); inherited Destroy; end;
procedure TKvmMetrics.Capture(Milliseconds: QWord; Success: Boolean);
begin
  EnterCriticalSection(FLock); try Inc(FCaptureCalls); if Success then Inc(FCaptures); Inc(FCaptureMs,Milliseconds);
  finally LeaveCriticalSection(FLock); end;
end;
procedure TKvmMetrics.Encode(Milliseconds: QWord);
begin EnterCriticalSection(FLock); try Inc(FEncodeCalls); Inc(FEncodeMs,Milliseconds); finally LeaveCriticalSection(FLock); end; end;
procedure TKvmMetrics.Queue(Bytes: Integer; Success: Boolean);
begin
  EnterCriticalSection(FLock);
  try if Success then begin Inc(FQueued); if Bytes>0 then Inc(FQueuedBytes,QWord(Bytes)); end
    else Inc(FQueueRejects);
  finally LeaveCriticalSection(FLock); end;
end;
procedure TKvmMetrics.Ack(Milliseconds: QWord);
begin EnterCriticalSection(FLock); try Inc(FAcks); Inc(FAckMs,Milliseconds); finally LeaveCriticalSection(FLock); end; end;
procedure TKvmMetrics.SecurityReject;
begin EnterCriticalSection(FLock); try Inc(FSecurityRejects); finally LeaveCriticalSection(FLock); end; end;
procedure TKvmMetrics.Flush(Force: Boolean);
var NowTick: QWord;
begin
  if FStream=nil then Exit;
  EnterCriticalSection(FLock);
  try
    NowTick:=GetTickCount64; if not Force and (NowTick-FLast<1000) then Exit; FLast:=NowTick;
    try
      WriteLine(UIntToStr(NowTick-FStart)+','+UIntToStr(FCaptureCalls)+','+UIntToStr(FCaptures)+','+UIntToStr(FCaptureMs)+','+
      UIntToStr(FEncodeCalls)+','+UIntToStr(FEncodeMs)+','+UIntToStr(FQueued)+','+
      UIntToStr(FQueuedBytes)+','+UIntToStr(FQueueRejects)+','+UIntToStr(FAcks)+','+
      UIntToStr(FAckMs)+','+UIntToStr(FSecurityRejects));
    except
      on E: Exception do
      begin
        WriteLn('[metrics] Write failed, metrics disabled: ',E.Message);
        FreeAndNil(FStream);
      end;
    end;
  finally LeaveCriticalSection(FLock); end;
end;
end.

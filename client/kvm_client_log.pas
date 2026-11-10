unit kvm_client_log;

{$mode objfpc}{$H+}

interface

// GUI client log, usable on Windows (SUBSYSTEM:WINDOWS)
// without StdOut. The logger never discloses connection credentials.
procedure KvmClientLog(const MessageText: string);
function KvmClientLogPath: string;

implementation

uses
  Classes, SysUtils;

var
  GLogLock: TRTLCriticalSection;
  GLogPath: string;

function KvmClientLogPath: string;
begin
  Result := GLogPath;
end;

procedure KvmClientLog(const MessageText: string);
var
  Stream: TFileStream;
  Line: UTF8String;
  LogDir: string;
begin
  // Never block or crash the KVM client because the log file is unavailable.
  try
    EnterCriticalSection(GLogLock);
    try
      LogDir := ExtractFileDir(GLogPath);
      if (LogDir <> '') and not DirectoryExists(LogDir) then
        if not ForceDirectories(LogDir) then
          Exit;
      if FileExists(GLogPath) then
        Stream := TFileStream.Create(GLogPath, fmOpenReadWrite or fmShareDenyNone)
      else
        Stream := TFileStream.Create(GLogPath, fmCreate);
      try
        Stream.Position := Stream.Size; // append
        Line := UTF8String(FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) +
          ' ' + MessageText + LineEnding);
        if Length(Line) > 0 then
          Stream.WriteBuffer(Line[1], Length(Line));
      finally
        Stream.Free;
      end;
    finally
      LeaveCriticalSection(GLogLock);
    end;
  except
    // Best-effort writes: disk errors do not terminate the session.
  end;
end;

initialization
  InitCriticalSection(GLogLock);
  GLogPath := GetEnvironmentVariable('LAZDESK_CLIENT_LOG');
  if Trim(GLogPath) = '' then
    GLogPath := IncludeTrailingPathDelimiter(GetAppConfigDir(False)) +
      'lazdesk-client.log';

finalization
  DoneCriticalSection(GLogLock);
end.

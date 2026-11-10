unit kvm_client_log;

{$mode objfpc}{$H+}

interface

// Journal du client graphique, utilisable sous Windows (SUBSYSTEM:WINDOWS)
// sans StdOut. Le logger n'expose jamais les identifiants de connexion.
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
  // Ne jamais bloquer ni faire planter un client KVM pour un journal inaccessible.
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
    // Ecriture best-effort : les erreurs de disque ne ferment pas la session.
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

unit kvm_viewer_i18n;

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils;

// Lazarus project i18n extracts these resourcestrings into LazDeskClient.po.
// Keep English originals here, and translate LazDeskClient.fr.po/.en.po.
resourcestring
  rsViewerMenuFile = 'File';
  rsViewerMenuConnectionSettings = 'Connection settings...';
  rsViewerMenuConnect = 'Connect';
  rsViewerMenuDisconnect = 'Disconnect';
  rsViewerMenuQuit = 'Exit';
  rsViewerMenuLanguage = 'Language';
  rsViewerMenuLanguageEn = 'English';
  rsViewerMenuLanguageFr = 'Français';
  rsViewerMenuView = 'View';
  rsViewerMenuMonitors = 'Monitors';
  rsViewerMenuRefresh = 'Refresh';
  rsViewerMenuFullscreen = 'Full screen';
  rsViewerMenuControl = 'Control';
  rsViewerMenuTakeControl = 'Take control';
  rsViewerMenuKeyboardMode = 'Keyboard mode';
  rsViewerMenuKeyboardUnicode = 'Automatic: Unicode text + shortcuts';
  rsViewerMenuKeyboardPhysical = 'Physical keys: remote layout';
  rsViewerMenuText = 'Type / paste Unicode text...';
  rsViewerMenuSpecialKeys = 'Send special keys';
  rsViewerMenuClipboard = 'Clipboard';
  rsViewerMenuClipboardTo = 'My clipboard -> remote';
  rsViewerMenuClipboardFrom = 'Remote -> my clipboard';
  rsViewerSpecialSas = 'Ctrl+Alt+Del (Windows)';
  rsViewerSpecialF11 = 'F11 (remote)';
  rsViewerSpecialStart = 'Windows key (Start)';
  rsViewerSpecialCtrlEsc = 'Ctrl+Esc (Start)';
  rsViewerSpecialAltTab = 'Alt+Tab (switch window)';
  rsViewerSpecialTaskManager = 'Ctrl+Shift+Esc (Task Manager)';
  rsViewerSpecialRun = 'Win+R (Run)';
  rsViewerSpecialExplorer = 'Win+E (Explorer)';
  rsViewerSpecialDesktop = 'Win+D (desktop)';
  rsViewerSpecialLock = 'Win+L (lock remote session)';
  rsViewerLabelHost = 'Host / IP';
  rsViewerLabelPort = 'Port';
  rsViewerLabelToken = 'Connection token';
  rsViewerLabelTls = 'WSS / TLS';
  rsViewerLabelTextIme = 'Text / IME';
  rsViewerLabelKeyboardPhysical = 'Physical key mode (otherwise automatic Unicode)';
  rsViewerLabelClipboardHelp = 'Clipboard: Unicode text only. Both directions are independent and reset for each connection.';
  rsViewerHintClipboardTo = 'Sync the current text and future copies (64 KiB max). Control required.';
  rsViewerHintClipboardFrom = 'Allow the remote desktop to replace my text clipboard. Control required.';
  rsViewerHintLog = 'Log';
  rsViewerWindowFullscreen = 'F11 full screen';
  rsViewerMonitorNone = 'No remote monitors';
  rsViewerMonitorAll = 'All monitors';
  rsViewerMonitorItem = 'Monitor %d  -  %dx%d';
  rsViewerDialogConnectionSettings = 'Connection settings';
  rsViewerDialogToken = 'Token';
  rsViewerDialogSave = 'Save';
  rsViewerDialogCancel = 'Cancel';
  rsViewerDialogLockWarning = 'Lock remote Windows session? You may lose remote control until someone unlocks it locally.';
  rsViewerDialogInvalidConnection = 'Enter a host, a valid port, and an ASCII token without spaces (16..256 characters).';
  rsViewerDialogTextTitle = 'Text input';
  rsViewerDialogTextMessage = 'Text entered using your input method (256 characters max)';
  rsViewerStatusInitial = 'Disconnected | fit to window';
  rsViewerStatusLanguageChanged = 'Viewer language: English';
  rsViewerStatusMonitorRequired = 'At least one remote monitor must remain visible.';
  rsViewerStatusClipboardDirection = 'Clipboard: local -> remote=%s; remote -> local=%s';
  rsViewerStatusTlsRequired = 'TLS is required outside loopback. Use --allow-insecure only with a trusted tunnel/VPN.';
  rsViewerStatusConnecting = 'Connecting...';
  rsViewerStatusCaMissing = 'TLS CA file not found: %s';
  rsViewerStatusInvalidWs = 'Invalid WebSocket address.';
  rsViewerStatusSocketOpen = 'Socket open; authenticating...';
  rsViewerStatusConnectFailed = 'Connection failed: %s';
  rsViewerStatusDisconnected = 'Disconnected';
  rsViewerStatusControlRequest = 'Requesting exclusive control from server...';
  rsViewerStatusControlReleased = 'View only: control released.';
  rsViewerStatusControlRevoked = '%s. Control revoked.';
  rsViewerStatusDesktopAvailable = 'Desktop available. Request control again if needed.';
  rsViewerStatusTextRejected = 'Text rejected: limit 256 Unicode code points / 1024 bytes, no control characters.';
  rsViewerStatusRemoteDesktop = 'Remote desktop: %d x %d | video worker';
  rsViewerStatusSendInterrupted = 'Network send interrupted: input will not be replayed.';
  rsViewerStatusConnectedControl = 'Connected | control available.';
  rsViewerStatusConnectedView = 'Connected | view only.';
  rsViewerStatusControlGranted = 'EXCLUSIVE control granted: click inside the desktop.';
  rsViewerStatusControlBusy = 'Another client currently controls the desktop.';
  rsViewerStatusSasRequested = 'Ctrl+Alt+Del requested. Windows may block it (service/uiAccess and SAS policy required).';
  rsViewerStatusSasUnavailable = 'Ctrl+Alt+Del unavailable: remote host is not Windows or lacks sas.dll.';
  rsViewerStatusSasPrivileges = 'Ctrl+Alt+Del not permitted: the remote host requires a Windows service or signed uiAccess application and SAS policy.';
  rsViewerStatusLockRequested = 'Remote Windows session lock requested.';
  rsViewerStatusLockUnavailable = 'Lock unavailable: the remote host is not Windows.';
  rsViewerStatusLockFailed = 'Remote Windows session could not be locked (interactive session required).';
  rsViewerStatusLockDenied = 'Lock denied: exclusive control or active desktop required.';
  rsViewerStatusSasDenied = 'Ctrl+Alt+Del denied: exclusive control or active desktop required.';
  rsViewerStatusInputUnsupported = 'Input unsupported or rejected by the remote system. Text may be incomplete.';
  rsViewerStatusAuthDenied = 'Authentication refused';
  rsViewerStatusClientLimit = 'Maximum number of clients reached';
  rsViewerStatusTimeout = 'Session ended: server reported a timeout';
  rsViewerStatusProtocolError = 'Server reported a protocol error';
  rsViewerStatusLocalReceive = 'LOCAL receive error: %s';
  rsViewerStatusSocketClosed = 'WebSocket closed: %s (check origin)';
  rsViewerStatusVideoError = 'Video error: %s';
  rsViewerStatusInvalidSession = 'Invalid session state';
  rsViewerStatusInvalidAck = 'Invalid input acknowledgment';
  rsViewerStatusInputDesync = 'Input sequence out of sync';
  rsViewerStatusInputPartial = 'Input rejected/partial (%d, %d code points)';
  rsViewerStatusDisplayFailed = 'Display failed: %s';
  rsViewerStatusInputAckMissing = 'Input acknowledgment missing: no retransmission';
  rsViewerStatusInputBlocked = 'Invalid local input blocked before sending.';
  rsViewerStatusInputQueueFull = 'Input queue full: unsent events discarded, keys released.';
  rsViewerStatusKeyboardPhysical = 'Physical keys: the remote desktop keyboard layout and input methods apply.';
  rsViewerStatusKeyboardAuto = 'Automatic mode: locally composed Unicode text; shortcuts and special keys sent separately.';
  rsViewerViewWaiting = 'Waiting for remote desktop...';
  rsViewerSessionActive = 'Session active';
  rsViewerSessionLocked = 'Session locked';
  rsViewerSessionInactive = 'Session inactive/disconnected';
  rsViewerSessionChanged = 'Session changed: restart the server in the intended session';
  rsViewerSessionCaptureLost = 'Capture unavailable';
  rsViewerSessionUnknown = 'Unknown session state (sharing suspended)';

  // Messages shown by the standalone entry point before opening the form.
  rsViewerDialogArgumentsTitle = 'Invalid LazDesk parameters';
  rsViewerDialogHelpTitle = 'LazDeskClient - help';

type
  // LCLTranslator works process-wide; embedded viewer windows share one
  // language, unlike the old per-window custom INI catalog reader.
  TKvmViewerI18n = class
  private
    FDirectory: string;
    function GetLanguage: string;
  public
    constructor Create;
    procedure SetLanguage(const Code: string);
    procedure SavePreference;
    property Language: string read GetLanguage;
    property Directory: string read FDirectory;
  end;

function KvmViewerLanguageCode(const Value: string): string;
function KvmViewerDefaultLanguage: string;

implementation

uses
  IniFiles, LCLTranslator;

const
  KVM_VIEWER_PO_DOMAIN = 'LazDeskClient';

var
  // Resourcestrings and LCLTranslator.SetDefaultLang are global to the host.
  // Never assume that two embedded viewer windows can use separate locales.
  GViewerLanguage: string = '';

{$IFDEF WINDOWS}
function KvmGetUserDefaultUILanguage: Word; stdcall;
  external 'kernel32.dll' name 'GetUserDefaultUILanguage';
{$ENDIF}

function KvmViewerLanguageCode(const Value: string): string;
var Normalized: string;
begin
  Normalized:=LowerCase(Trim(Value));
  if (Normalized='fr') or (Copy(Normalized,1,3)='fr_') or
     (Copy(Normalized,1,3)='fr-') or (Copy(Normalized,1,3)='fr.') or
     (Copy(Normalized,1,3)='fr:') then
    Result:='fr'
  else
    Result:='en';
end;

function KvmViewerPreferenceFile: string;
begin
  Result:=IncludeTrailingPathDelimiter(GetAppConfigDir(False))+'lazdesk-viewer.ini';
end;

function KvmViewerDefaultLanguage: string;
var Value, ConfigFile: string; Ini: TMemIniFile;
begin
  Value:=Trim(GetEnvironmentVariable('LAZDESK_LANG'));
  if Value<>'' then Exit(KvmViewerLanguageCode(Value));

  ConfigFile:=KvmViewerPreferenceFile;
  if FileExists(ConfigFile) then
  begin
    Value:='';
    try
      Ini:=TMemIniFile.Create(ConfigFile);
      try Value:=Trim(Ini.ReadString('viewer','language',''));
      finally Ini.Free; end;
    except
      // A corrupt or unreadable preference should never block the viewer.
    end;
    if Value<>'' then Exit(KvmViewerLanguageCode(Value));
  end;

  Value:=GetEnvironmentVariable('LC_ALL');
  if Value='' then Value:=GetEnvironmentVariable('LC_MESSAGES');
  if Value='' then Value:=GetEnvironmentVariable('LANGUAGE');
  if Value='' then Value:=GetEnvironmentVariable('LANG');
  if Value<>'' then Exit(KvmViewerLanguageCode(Value));
  {$IFDEF WINDOWS}
  if (KvmGetUserDefaultUILanguage and $03ff)=$000c then Exit('fr');
  {$ENDIF}
  Result:='en';
end;

constructor TKvmViewerI18n.Create;
var ExeDir, OverrideDir: string;
begin
  inherited Create;
  ExeDir:=ExtractFilePath(ExpandFileName(ParamStr(0)));
  OverrideDir:=Trim(GetEnvironmentVariable('LAZDESK_LANG_DIR'));
  if OverrideDir<>'' then FDirectory:=IncludeTrailingPathDelimiter(OverrideDir)
  {$IFDEF DARWIN}
  // In an .app the executable lives in Contents/MacOS, whereas translations
  // belong in Contents/Resources/languages. Keep loose-binary compatibility.
  else if DirectoryExists(ExpandFileName(ExeDir+'../Resources/languages')) then
    FDirectory:=IncludeTrailingPathDelimiter(ExpandFileName(ExeDir+'../Resources/languages'))
  // Lazarus IDE may create a bundle containing a symlink to the project
  // executable without copying resources. Use the project catalogs there.
  else if DirectoryExists(ExpandFileName(ExeDir+'../../../languages')) then
    FDirectory:=IncludeTrailingPathDelimiter(ExpandFileName(ExeDir+'../../../languages'))
  {$ENDIF}
  else FDirectory:=IncludeTrailingPathDelimiter(ExeDir)+'languages'+PathDelim;
  // A second embedded viewer must inherit the current process-wide language,
  // not silently reset the first viewer to the user's saved preference.
  if GViewerLanguage='' then SetLanguage(KvmViewerDefaultLanguage);
end;

function TKvmViewerI18n.GetLanguage: string;
begin
  Result:=GViewerLanguage;
  if Result='' then Result:='en';
end;

procedure TKvmViewerI18n.SetLanguage(const Code: string);
var Wanted: string;
begin
  Wanted:=KvmViewerLanguageCode(Code);
  // Native Lazarus gettext reader supports .po directly, or .mo when no .po.
  // ForceUpdate=False: the viewer manages its dynamically created captions,
  // and must not translate unrelated forms belonging to an embedded host.
  if SetDefaultLang(Wanted,FDirectory,KVM_VIEWER_PO_DOMAIN,False)='' then
  begin
    // The shipped en.po resets French resourcestrings to English when
    // switching back. An absent French catalog falls back to English.
    Wanted:='en';
    SetDefaultLang(Wanted,FDirectory,KVM_VIEWER_PO_DOMAIN,False);
  end;
  GViewerLanguage:=Wanted;
end;

procedure TKvmViewerI18n.SavePreference;
var Ini: TMemIniFile; FileName: string;
begin
  FileName:=KvmViewerPreferenceFile;
  try
    if not ForceDirectories(ExtractFileDir(FileName)) then Exit;
    Ini:=TMemIniFile.Create(FileName);
    try
      Ini.WriteString('viewer','language',Language);
      Ini.UpdateFile;
    finally Ini.Free; end;
  except
    // Non-writable profiles should not prevent in-memory language changes.
  end;
end;

end.

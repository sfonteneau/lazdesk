program LazDeskClient;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, Dialogs, SysUtils, kvm_cli, kvm_view_form, kvm_client_log, kvm_build_info, kvm_viewer_i18n;

var
  MainForm: TKvmViewForm;
  Options: TKvmClientOptions;
  ErrorText: string;
  ShowHelp: Boolean;
  Translations: TKvmViewerI18n;
begin
  KvmClientLog('[client] Starting LazDeskClient');
  KvmClientLog('[client] Build: '+KvmBuildDescription);
  Application.Initialize;
  Translations := TKvmViewerI18n.Create;
  try
    if not ParseClientOptions(Options, ErrorText, ShowHelp) then
    begin
      MessageDlg(rsViewerDialogArgumentsTitle,
        ErrorText + LineEnding + LineEnding + ClientUsage, mtError, [mbOK], 0);
      Halt(2);
    end;
    if ShowHelp then
    begin
      MessageDlg(rsViewerDialogHelpTitle, ClientUsage, mtInformation, [mbOK], 0);
      Halt(0);
    end;
    Application.Title := 'LazDesk';
    Application.CreateForm(TKvmViewForm, MainForm);
    MainForm.ApplyOptions(Options);
    Application.Run;
  finally
    Translations.Free;
  end;
end.

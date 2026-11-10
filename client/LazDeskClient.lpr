program LazDeskClient;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, Dialogs, SysUtils, kvm_cli, kvm_view_form, kvm_client_log, kvm_build_info;

var
  MainForm: TKvmViewForm;
  Options: TKvmClientOptions;
  ErrorText: string;
  ShowHelp: Boolean;
begin
  KvmClientLog('[client] Demarrage LazDeskClient');
  KvmClientLog('[client] Build : '+KvmBuildDescription);
  Application.Initialize;
  if not ParseClientOptions(Options, ErrorText, ShowHelp) then
  begin
    MessageDlg('Parametres LazDesk incorrects',
      ErrorText + LineEnding + LineEnding + ClientUsage, mtError, [mbOK], 0);
    Halt(2);
  end;
  if ShowHelp then
  begin
    MessageDlg('LazDeskClient - aide', ClientUsage, mtInformation, [mbOK], 0);
    Halt(0);
  end;
  Application.Title := 'LazDesk';
  Application.CreateForm(TKvmViewForm, MainForm);
  MainForm.ApplyOptions(Options);
  Application.Run;
end.

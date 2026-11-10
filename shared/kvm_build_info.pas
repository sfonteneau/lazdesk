unit kvm_build_info;
{$mode objfpc}{$H+}
{$I kvm_build.inc}
interface
function KvmBuildDescription: string;
implementation
function KvmBuildDescription: string;
begin
  {$IFDEF KVM_STANDALONE}
  Result:='autonome: TurboJPEG integre';
  {$IFDEF LINUX}Result:=Result+'; garde session integre';{$ENDIF}
  {$IFDEF DARWIN}Result:=Result+'; ScreenCaptureKit integre';{$ENDIF}
  {$IFDEF KVM_STATIC_DXGI}Result:=Result+'; DXGI integre';{$ENDIF}
  {$IFDEF KVM_STATIC_PORTAL}Result:=Result+'; portail integre';{$ENDIF}
  {$IFDEF KVM_STATIC_CODEC}Result:=Result+'; pont H264 integre';
  {$ELSE}Result:=Result+'; codec JPEG uniquement';{$ENDIF}
  Result:=Result+'; bibliotheques systeme dynamiques';
  {$ELSE}
  Result:='standard: composants natifs charges dynamiquement';
  {$ENDIF}
end;
end.

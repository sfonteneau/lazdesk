{ Standalone is an explicit build profile, not a run-time extraction scheme.
  The feature file is generated for the target by build_standalone.py.
  Without it a standalone build MUST fail, never fall back to private DLLs. }
{$IFDEF KVM_STANDALONE}
  {$I kvm_standalone_features.inc}
{$ENDIF}

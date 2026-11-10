@echo off
setlocal
rem Choose --arch x86 or --arch x64. GCC, FPC and TurboJPEG must match.
rem --toolchain-bin selects a MinGW bin folder instead of unrelated PATH tools.
rem All options are forwarded unchanged; no implicit switch to another CPU.
where py >nul 2>nul
if not errorlevel 1 (
  py -3 "%~dp0build\build_standalone.py" %*
) else (
  python "%~dp0build\build_standalone.py" %*
)
exit /b %ERRORLEVEL%

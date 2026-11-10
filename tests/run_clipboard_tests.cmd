@echo off
setlocal
cd /d "%~dp0\.."
if not defined FPC set "FPC=fpc.exe"
if not exist tests\bin\clipboard mkdir tests\bin\clipboard
for %%T in (test_clipboard_wire test_clipboard_workers) do (
  "%FPC%" -B -gl -Cr -Co -Sa -Fushared -Fuclient -FUtests\bin\clipboard -FEtests\bin\clipboard tests\%%T.lpr
  if errorlevel 1 exit /b 1
  tests\bin\clipboard\%%T.exe
  if errorlevel 1 exit /b 1
)
exit /b 0

@echo off
setlocal
if not defined MORMOT2_DIR goto projects
lazbuild "%MORMOT2_DIR%\packages\lazarus\mormot2.lpk" || exit /b 1
:projects
if "%KVM_BUILD_DXGI%"=="1" call "%~dp0native\windows\build.cmd" || exit /b 1
if "%KVM_BUILD_CODEC%"=="1" call "%~dp0native\codec\build_msvc.cmd" || exit /b 1
lazbuild "%~dp0server\LazDeskServer.lpi" || exit /b 1
lazbuild "%~dp0client\LazDeskClient.lpi" || exit /b 1
endlocal

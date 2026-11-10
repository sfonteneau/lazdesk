@echo off
setlocal
rem Run in an x64 Native Tools Command Prompt for Visual Studio (Windows SDK).
where cl >nul 2>nul || (echo Microsoft C++ Build Tools and Windows SDK required. & exit /b 2)
pushd "%~dp0"
cl /nologo /std:c++17 /EHsc /O2 /W4 /LD kvm_dxgi.cpp /link /OUT:..\..\server\lazdesk_dxgi.dll d3d11.lib dxgi.lib user32.lib gdi32.lib
set RC=%ERRORLEVEL%
popd
exit /b %RC%

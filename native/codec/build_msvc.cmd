@echo off
setlocal
if "%FFMPEG_SDK%"=="" (echo Set FFMPEG_SDK to an FFmpeg SDK with include and lib directories & exit /b 2)
cl /nologo /std:c11 /LD /O2 /W4 /I"%FFMPEG_SDK%\include" "%~dp0kvm_codec.c" /link /LIBPATH:"%FFMPEG_SDK%\lib" avcodec.lib avutil.lib swscale.lib /OUT:"%~dp0..\..\server\lazdesk_codec.dll"
if errorlevel 1 exit /b 1
copy /y "%~dp0..\..\server\lazdesk_codec.dll" "%~dp0..\..\client\lazdesk_codec.dll" >nul

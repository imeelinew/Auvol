@echo off
call "C:\Program Files\Microsoft Visual Studio\18\Community\Common7\Tools\VsDevCmd.bat" -arch=x64 -host_arch=x64 >nul
if errorlevel 1 exit /b %errorlevel%
cl /nologo /std:c++20 /EHsc /utf-8 /DUNICODE /D_UNICODE /DNOMINMAX /W4 /WX /O2 C:\dev\Auvol\tests\mouse-share-core-tests.cpp /Fe:C:\dev\Auvol\tests\mouse-share-core-tests.exe /link user32.lib advapi32.lib ws2_32.lib ole32.lib
if errorlevel 1 exit /b %errorlevel%
C:\dev\Auvol\tests\mouse-share-core-tests.exe
exit /b %errorlevel%

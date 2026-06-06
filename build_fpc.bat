@echo off
rem Build localvector with Free Pascal (Delphi mode). Requires FPC 3.2+.
rem HTTPS downloads under FPC use OpenSSL, so libssl/libcrypto must be on PATH.
fpc -Mdelphi -O2 -Fu. -Fusrc -FE. localvector.dpr
if errorlevel 1 exit /b 1
echo.
echo Built localvector.exe
echo Remember: place a current onnxruntime.dll (^>= 1.17) next to localvector.exe.

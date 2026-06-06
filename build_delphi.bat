@echo off
rem Build localvector with the Delphi command-line compiler (Win64).
rem Requires a Delphi 11/12 install. rsvars.bat sets BDS + the RTL paths.

if defined BDS goto :havebds
for %%D in (23.0 22.0 21.0) do (
  if exist "%ProgramFiles(x86)%\Embarcadero\Studio\%%D\bin\rsvars.bat" (
    call "%ProgramFiles(x86)%\Embarcadero\Studio\%%D\bin\rsvars.bat"
    goto :havebds
  )
)
echo Could not find rsvars.bat. Open a "RAD Studio Command Prompt" and re-run,
echo or run rsvars.bat manually first.
exit /b 1

:havebds
dcc64 -B -NSSystem;Winapi -Usrc -E. localvector.dpr
if errorlevel 1 exit /b 1
echo.
echo Built localvector.exe
echo Remember: place a current onnxruntime.dll (^>= 1.17) next to localvector.exe.

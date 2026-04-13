@echo off
setlocal EnableExtensions
title Barbados Bus Tracker

REM Project flutter_app next to this scripts folder
set "FLUTTER_APP=%~dp0..\flutter_app"
set "EXE=%FLUTTER_APP%\build\windows\x64\runner\Release\barbados_bus_demo.exe"

REM Avoid "file in use" on rebuilds
taskkill /F /IM barbados_bus_demo.exe >nul 2>&1
timeout /t 1 /nobreak >nul

if exist "%EXE%" (
  start "" "%EXE%"
  exit /b 0
)

echo No Release exe yet — building once ^(may take a few minutes^)...
cd /d "%FLUTTER_APP%"
if not exist "pubspec.yaml" (
  echo ERROR: Cannot find flutter_app. Move this .bat with the scripts folder or fix paths.
  pause
  exit /b 1
)

call flutter pub get
if errorlevel 1 goto :fail
call flutter build windows --release
if errorlevel 1 goto :fail

if exist "%EXE%" (
  start "" "%EXE%"
  exit /b 0
)

:fail
echo Run failed. Try Build-BarbadosBusTracker.bat from the same folder.
pause
exit /b 1

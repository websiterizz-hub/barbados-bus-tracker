@echo off
setlocal EnableExtensions
title Build — Barbados Bus Tracker

REM Stop running instance so the linker can overwrite barbados_bus_demo.exe
taskkill /F /IM barbados_bus_demo.exe >nul 2>&1
timeout /t 1 /nobreak >nul

cd /d "%~dp0..\flutter_app"
if not exist "pubspec.yaml" (
  echo ERROR: pubspec.yaml not found. Expected folder: "%~dp0..\flutter_app"
  pause
  exit /b 1
)

echo.
echo === flutter pub get ===
call flutter pub get
if errorlevel 1 goto :fail

echo.
echo === flutter build windows --release ===
call flutter build windows --release
if errorlevel 1 goto :fail

echo.
echo Build OK: build\windows\x64\runner\Release\barbados_bus_demo.exe
exit /b 0

:fail
echo.
echo Build FAILED. If you saw LNK1104: close the app and any Explorer preview of the exe, then run this again.
pause
exit /b 1

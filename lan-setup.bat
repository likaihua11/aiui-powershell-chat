@echo off
setlocal
chcp 65001 >nul
title aiui LAN setup

net session >nul 2>&1
if errorlevel 1 (
  echo.
  echo [!] Administrator rights required.
  echo     Right-click this file  -^>  "Run as administrator"
  echo.
  pause
  exit /b 1
)

set PORT=8787
if not "%~1"=="" set PORT=%~1

echo.
echo === aiui LAN setup ===
echo Port : %PORT%
echo User : %USERDOMAIN%\%USERNAME%
echo.

echo [1/2] http urlacl ...
netsh http add urlacl url=http://+:%PORT%/ user=%USERDOMAIN%\%USERNAME%
if errorlevel 1 (
  echo      [!] failed - reservation may already exist ^(safe to ignore^)
) else (
  echo      ok
)

echo [2/2] firewall inbound rule ...
netsh advfirewall firewall delete rule name="aiui LAN %PORT%" >nul 2>&1
netsh advfirewall firewall add rule name="aiui LAN %PORT%" dir=in action=allow protocol=TCP localport=%PORT% profile=any
if errorlevel 1 (
  echo      [!] failed
) else (
  echo      ok
)

echo.
echo Done. Start the shell in LAN mode:
echo    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0serve.ps1" -Lan
echo.
pause

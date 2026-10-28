@echo off
rem Stop the hub service.
echo Stopping...
type nul > "%~dp0STOP"
schtasks /End /TN "BambuDeckHub" >nul 2>&1
taskkill /F /IM hub.exe >nul 2>&1
ping -n 3 127.0.0.1 >nul
taskkill /F /IM hub.exe >nul 2>&1
tasklist /FI "IMAGENAME eq hub.exe" 2>nul | find /I "hub.exe" >nul
if %errorlevel% equ 0 (
  echo [WARN] hub.exe still running - right-click this script and
  echo        Run as Administrator, then try again.
) else (
  echo [OK] Stopped. Start again with start.bat
)
pause

@echo off
rem Restart the hub service (also how you apply manual hub.exe/page updates).
type nul > "%~dp0STOP"
schtasks /End /TN "BambuDeckHub" >nul 2>&1
taskkill /F /IM hub.exe >nul 2>&1
ping -n 3 127.0.0.1 >nul
taskkill /F /IM hub.exe >nul 2>&1
del "%~dp0STOP" >nul 2>&1
schtasks /Run /TN "BambuDeckHub"
if %errorlevel% neq 0 (
  echo [ERROR] Could not start the service task. Run install-service.bat
  echo         first, and right-click - Run as Administrator.
  pause
  exit /b 1
)
echo [OK] Restart signal sent. Logs: logs\hub.log
pause

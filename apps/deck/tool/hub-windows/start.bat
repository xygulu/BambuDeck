@echo off
rem Start the hub service (registered by install-service.bat).
del "%~dp0STOP" >nul 2>&1
schtasks /Run /TN "BambuDeckHub"
if %errorlevel% neq 0 (
  echo [ERROR] Could not start the service task. Run install-service.bat
  echo         first, and right-click - Run as Administrator.
  pause
  exit /b 1
)
echo [OK] Start signal sent, waiting...
ping -n 3 127.0.0.1 >nul
tasklist /FI "IMAGENAME eq hub.exe" 2>nul | find /I "hub.exe" >nul
if %errorlevel% equ 0 (
  echo [OK] hub.exe is running.
) else (
  echo [WARN] hub.exe not visible yet - check logs\hub.log
)
pause

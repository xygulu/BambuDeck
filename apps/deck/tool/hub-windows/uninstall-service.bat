@echo off
rem Stop and unregister the BambuDeck hub service. Files stay in place.
rem Right-click - Run as Administrator.
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo [ERROR] Please run this script as Administrator.
  pause
  exit /b 1
)
echo Stopping...
type nul > "%~dp0STOP"
schtasks /End /TN "BambuDeckHub" >nul 2>&1
taskkill /F /IM hub.exe >nul 2>&1
ping -n 3 127.0.0.1 >nul
taskkill /F /IM hub.exe >nul 2>&1
schtasks /Delete /TN "BambuDeckHub" /F
netsh advfirewall firewall delete rule name="BambuDeck Hub" >nul 2>&1
echo [OK] Service uninstalled. The package files were left in place.
pause

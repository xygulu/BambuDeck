@echo off
rem Register the BambuDeck hub as an auto-start service (Task Scheduler,
rem SYSTEM account): starts at boot, restarts on crash, reloads config when
rem config\hub.json changes. Right-click - Run as Administrator.
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo [ERROR] Please run this script as Administrator.
  pause
  exit /b 1
)
if not exist "%~dp0hub.exe" (
  echo [ERROR] hub.exe not found next to this script.
  pause
  exit /b 1
)
if not exist "%~dp0config\hub.json" (
  echo [ERROR] config\hub.json not found.
  echo.
  echo         Copy hub.json from the Mac ^(its location: ~/.bambudeck/hub.json^)
  echo         into the config folder next to this script, then run again.
  pause
  exit /b 1
)
if not exist "%~dp0logs" mkdir "%~dp0logs"
if not exist "%~dp0ffmpeg" mkdir "%~dp0ffmpeg" >nul 2>&1

rem Firewall rule; port comes from config (settings.hubPort, default 8787).
powershell -NoProfile -ExecutionPolicy Bypass -Command "$c = Get-Content -Raw -LiteralPath '%~dp0config\hub.json' | ConvertFrom-Json; $p = $c.settings.hubPort; if (-not $p) { $p = 8787 }; netsh advfirewall firewall delete rule name=\"BambuDeck Hub\" | Out-Null; netsh advfirewall firewall add rule name=\"BambuDeck Hub\" dir=in action=allow protocol=TCP localport=$p | Out-Null; Write-Host ('[OK] firewall rule ready, port ' + $p)"

schtasks /Create /F /TN "BambuDeckHub" /TR "\"%~dp0run-hub.cmd\"" /SC ONSTART /DELAY 0000:15 /RU SYSTEM /RL HIGHEST
if %errorlevel% neq 0 (
  echo [ERROR] Failed to create the scheduled task.
  pause
  exit /b 1
)
echo [OK] Service registered: auto-start at boot, auto-restart on crash.
echo      Starting now...
del "%~dp0STOP" >nul 2>&1
schtasks /Run /TN "BambuDeckHub"
echo.
echo Web page will be at http://localhost:8787 ^(port may differ, see config^).
echo Logs: logs\hub.log
pause

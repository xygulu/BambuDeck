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
rem No config yet? (Product setup, 2026-10-28) Create a fresh one with a
rem random token - the user finishes setup by logging in on the web page.
if exist "%~dp0config\hub.json" goto hasconfig
echo [SETUP] config\hub.json not found. Creating a fresh one.
echo         Finish setup by clicking the account button on the web page.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 24 | ForEach-Object {[char]$_}); New-Item -ItemType Directory -Force -Path '%~dp0config' | Out-Null; @{settings=@{hubPort=8787;hubToken=$t};printers=@();cameras=@();accounts=@()} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath '%~dp0config\hub.json' -Encoding UTF8; Write-Host ('[KEY] Access token for the web page: ' + $t)"
:hasconfig
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

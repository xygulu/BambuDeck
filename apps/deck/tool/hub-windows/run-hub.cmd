@echo off
rem BambuDeck hub guardian loop - the real entry point of the service.
rem
rem hub.exe exits by itself when config\hub.json changes (hot reload), and this
rem loop relaunches it with the new config. If the process crashes it is also
rem relaunched, so the service self-heals. A STOP file in this folder ends the
rem loop cleanly (stop.bat / uninstall-service.bat create it).
rem
rem All paths are package-relative: hub.exe never reads ~/.bambudeck.
setlocal
cd /d "%~dp0"
set "HUB_PAGE=%~dp0assets\web\hub_page.html"
set "HUB_PLATE_SWAP=%~dp0assets\plate_swap\auto_plate_swap.3mf"
rem ffmpeg.exe dropped in the package root (or ffmpeg\ subfolder) just works,
rem also under the SYSTEM account where winget's per-user PATH is not visible.
set "PATH=%~dp0;%~dp0ffmpeg;%PATH%"
if not exist logs mkdir logs

:loop
if exist STOP (
  del STOP >nul 2>&1
  echo [%date% %time%] STOP file found, guardian exiting.
  exit /b 0
)
if exist logs\hub.log call :rotate
echo [%date% %time%] launching hub.exe, config config\hub.json >> logs\hub.log
hub.exe config\hub.json >> logs\hub.log 2>&1
echo [%date% %time%] hub.exe exited, code %errorlevel% >> logs\hub.log
rem timeout.exe needs an interactive console, which the SYSTEM task lacks.
ping -n 4 127.0.0.1 >nul
goto loop

:rotate
for %%F in (logs\hub.log) do if %%~zF GTR 10485760 (
  if exist logs\hub.old.log del logs\hub.old.log >nul 2>&1
  ren logs\hub.log hub.old.log >nul 2>&1
)
exit /b 0

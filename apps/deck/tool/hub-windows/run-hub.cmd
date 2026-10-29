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
set "HUBEXIT=%errorlevel%"
echo [%date% %time%] hub.exe exited, code %HUBEXIT% >> logs\hub.log
rem Exit code 42 = a staged self-update (the hub downloaded the new package,
rem verified its sha256 and asked us to swap). Copy update\pending over the
rem package root; config\ logs\ update\ are never touched (the staged
rem package does not contain them and copy never deletes).
if "%HUBEXIT%"=="42" (
  echo [%date% %time%] exit 42 = staged update, applying... >> logs\hub.log
  if exist update\pending\hub.exe (
    if exist hub.exe copy /Y hub.exe update\hub.exe.bak >nul 2>&1
    xcopy update\pending\* . /E /Y /I /Q >> logs\hub.log 2>&1
    rmdir /S /Q update\pending >> logs\hub.log 2>&1
    del /Q update\pending.zip >> logs\hub.log 2>&1
    rem 暂存标记用完即删: 留着会让下次启动误判「上次换装没完成」
    del /Q update\stage.json >> logs\hub.log 2>&1
    echo [%date% %time%] update applied, restarting hub.exe >> logs\hub.log
  ) else (
    echo [%date% %time%] exit 42 but update\pending missing, skip >> logs\hub.log
  )
  ping -n 3 127.0.0.1 >nul
  goto loop
)
rem timeout.exe needs an interactive console, which the SYSTEM task lacks.
ping -n 4 127.0.0.1 >nul
goto loop

:rotate
for %%F in (logs\hub.log) do if %%~zF GTR 10485760 (
  if exist logs\hub.old.log del logs\hub.old.log >nul 2>&1
  ren logs\hub.log hub.old.log >nul 2>&1
)
exit /b 0

@echo off
rem Foreground debug run (no service). Close this window or Ctrl+C to stop.
if not exist "%~dp0config\hub.json" (
  echo [ERROR] config\hub.json missing.
  echo         Copy hub.json from the Mac ^(its location: ~/.bambudeck/hub.json^)
  echo         into the config folder next to this script first.
  pause
  exit /b 1
)
call "%~dp0run-hub.cmd"

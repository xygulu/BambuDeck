@echo off
rem 2026-10-29: 端口已在听就空转等待(多实例安全); 每轮都查, 多个守护并存不打架
rem 路径全部相对本文件: 部署包解压到哪都能跑 (helper/ 与 runtime/ 平级)
cd /d "%~dp0"
:loop
netstat -ano | findstr "127.0.0.1:8799" | findstr "LISTENING" >nul
if %errorlevel%==0 (
  ping -n 30 127.0.0.1 >nul
  goto loop
)
"%~dp0..\runtime\python\python.exe" bconnect_service.py >> service.log 2>&1
ping -n 4 127.0.0.1 >nul
goto loop

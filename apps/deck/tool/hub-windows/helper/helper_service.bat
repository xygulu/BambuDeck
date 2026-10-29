@echo off
rem 2026-10-29: 端口已在听就空转等待(多实例安全); 每轮都查, 多个守护并存不打架
rem 路径全部相对本文件: 部署包解压到哪都能跑 (helper/ 与 runtime/ 平级)
cd /d "%~dp0"
rem 2026-10-29: 日志必须是 UTF-8。cmd 重定向默认按控制台码页(中文机=GBK)
rem 写盘, Python 打出来的中文全变成「?」, 排查时完全没法读 —— 换机/选机失败
rem 的原因就是这样丢的。chcp 65001 + PYTHONIOENCODING=utf-8 双保险。
chcp 65001 >nul 2>&1
set "PYTHONIOENCODING=utf-8"
:loop
netstat -ano | findstr "127.0.0.1:8799" | findstr "LISTENING" >nul
if %errorlevel%==0 (
  ping -n 30 127.0.0.1 >nul
  goto loop
)
"%~dp0..\runtime\python\python.exe" bconnect_service.py >> service.log 2>&1
ping -n 4 127.0.0.1 >nul
goto loop

@echo off
rem ============================================================
rem  aiui 一键重启（双击本文件即可）
rem  改完 serve.ps1 / index.html 后用：停掉旧后端并启动最新版，
rem  然后自动打开浏览器。
rem ============================================================
setlocal
cd /d "%~dp0"
set PORT=8787

echo [aiui] restarting backend on port %PORT% ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update.ps1" -Port %PORT% -Open
echo [aiui] done. refresh the page if it is already open.
pause

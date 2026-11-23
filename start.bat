@echo off
cd /d "%~dp0"
set NODE=node
if exist runtime\node\node.exe set NODE=runtime\node\node.exe
start "" cmd /c "timeout /t 2 >nul & start http://localhost:4455"
"%NODE%" server.js
pause

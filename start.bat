@echo off
cd /d "%~dp0"
set NODE=node
for %%P in ("runtime\node\node.exe" "runtime\node\nodejs\node.exe" "runtime\node\PFiles64\nodejs\node.exe" "node\node.exe" "nodejs\node.exe" "PFiles64\nodejs\node.exe") do if exist %%P set NODE=%%~P
start "" cmd /c "timeout /t 2 >nul & start http://localhost:4455"
"%NODE%" server.js
pause

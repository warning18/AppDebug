@echo off
cd /d "%~dp0"
set LAN=1
set NODE=node
for %%P in ("runtime\node\node.exe" "runtime\node\nodejs\node.exe" "runtime\node\PFiles64\nodejs\node.exe" "node\node.exe" "nodejs\node.exe" "PFiles64\nodejs\node.exe") do if exist %%P set NODE=%%~P
echo Windows may ask to allow network access: choose "Private networks".
"%NODE%" server.js
pause

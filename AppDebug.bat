@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File AppDebug.ps1
pause

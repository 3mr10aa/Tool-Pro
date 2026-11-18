@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0AMR_Windows_Utility_V1.ps1"
if errorlevel 1 pause

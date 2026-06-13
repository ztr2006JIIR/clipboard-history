@echo off
setlocal
cd /d "%~dp0"

if not exist "%~dp0data" mkdir "%~dp0data"

echo [%date% %time%] launch start > "%~dp0data\launch.log"
start "" powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA -File "%~dp0clipboard-history.ps1"

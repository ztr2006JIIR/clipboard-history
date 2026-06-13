@echo off
setlocal
cd /d "%~dp0"

if not exist "%~dp0data" mkdir "%~dp0data"

echo Starting Clipboard History debug mode...
echo [%date% %time%] debug launch start > "%~dp0data\launch.log"

powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0clipboard-history.ps1" 1>> "%~dp0data\launch.log" 2>>&1
set EXIT_CODE=%errorlevel%

echo [%date% %time%] debug launch exit code %EXIT_CODE% >> "%~dp0data\launch.log"
echo.
echo Clipboard History has exited. Exit code: %EXIT_CODE%
echo If you did not close the app yourself, send this window and data\launch.log to Codex.
echo.
pause

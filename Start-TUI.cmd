@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tui\RestoreTui.ps1"
if errorlevel 1 (
    echo.
    echo TUI exited with an error.
    pause
)

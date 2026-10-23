@echo off
rem Starts the CPU Stability Governor dashboard with PowerShell 7. The script asks for elevation (UAC) itself;
rem if the prompt is declined it opens read-only. Extra arguments are passed through (e.g. -NoElevate).
setlocal
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PWSH%" for %%I in (pwsh.exe) do set "PWSH=%%~$PATH:I"
if not defined PWSH (
    echo PowerShell 7 ^(pwsh.exe^) was not found. Install it with:  winget install Microsoft.PowerShell
    pause
    exit /b 1
)
start "" "%PWSH%" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0CpuGovernorGui.ps1" %*

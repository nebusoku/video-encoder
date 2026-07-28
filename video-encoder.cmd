@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%video-encoder.ps1"

if not exist "%PS_SCRIPT%" (
    echo ERROR: Missing PowerShell entry script:
    echo %PS_SCRIPT%
    pause
    exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
exit /b %ERRORLEVEL%

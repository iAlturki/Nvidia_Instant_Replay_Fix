@echo off
REM Nvidia_Instant_Replay_Fix - one-click launcher.
REM Download just THIS file and double-click it; it fetches and runs the installer.
REM Copyright (c) 2026 iALTURKi - MIT - github.com/iALTURKi/Nvidia_Instant_Replay_Fix
setlocal
set "LOCAL=%~dp0Nvidia_Instant_Replay_Fix.ps1"
set "DL=%TEMP%\Nvidia_Instant_Replay_Fix.ps1"
set "URL=https://raw.githubusercontent.com/iAlturki/Nvidia_Instant_Replay_Fix/main/Nvidia_Instant_Replay_Fix.ps1"
set "TARGET=%LOCAL%"
if not exist "%LOCAL%" (
  echo Fetching the installer...
  powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest '%URL%' -OutFile '%DL%' -UseBasicParsing -ErrorAction Stop } catch { exit 1 }"
  if errorlevel 1 (
    echo.
    echo Could not download the installer. Check your internet connection and try again.
    pause
    exit /b 1
  )
  set "TARGET=%DL%"
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" %*
endlocal

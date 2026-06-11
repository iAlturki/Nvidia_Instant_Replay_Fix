@echo off
REM Nvidia_Instant_Replay_Fix - one-click launcher.
REM Always fetches the LATEST installer (never uses a stale local copy).
REM Copyright (c) 2026 iALTURKi - MIT - github.com/iALTURKi/Nvidia_Instant_Replay_Fix
setlocal
set "DL=%TEMP%\Nvidia_Instant_Replay_Fix.ps1"
set "URL=https://raw.githubusercontent.com/iAlturki/Nvidia_Instant_Replay_Fix/main/Nvidia_Instant_Replay_Fix.ps1"
echo Fetching the latest installer...
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest '%URL%' -OutFile '%DL%' -UseBasicParsing -ErrorAction Stop } catch { exit 1 }"
if errorlevel 1 (
  echo.
  echo Could not download the installer. Check your internet connection and try again.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%DL%" %*
endlocal

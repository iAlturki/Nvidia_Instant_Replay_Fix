@echo off
REM Nvidia_Instant_Replay_Fix - double-click launcher
REM Copyright (c) 2026 iALTURKi - MIT - github.com/iALTURKi/Nvidia_Instant_Replay_Fix
REM Runs the single-file release script with the execution-policy bypass so a
REM downloaded .ps1 actually runs (Windows opens .ps1 in Notepad otherwise).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Nvidia_Instant_Replay_Fix.ps1" %*

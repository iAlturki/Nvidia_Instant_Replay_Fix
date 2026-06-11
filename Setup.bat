@echo off
rem Nvidia_Instant_Replay_Fix - Setup launcher (by iALTURKi)
rem
rem The real installer is Setup.ps1. This trampoline only exists so the
rem repo has something you can double-click from Explorer. Anything that
rem needs colours, Unicode, or proper error handling lives in PowerShell.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Setup.ps1" %*
exit /b %ERRORLEVEL%

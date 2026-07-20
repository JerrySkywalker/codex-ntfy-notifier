@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0notify-ntfy.ps1" -CodexDir "%~dp0" %*
exit /b %ERRORLEVEL%

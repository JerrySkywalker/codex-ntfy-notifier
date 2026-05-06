@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.codex\notify-ntfy.ps1"
exit /b %ERRORLEVEL%

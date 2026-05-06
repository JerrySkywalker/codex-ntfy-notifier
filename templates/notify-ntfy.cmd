@echo off
chcp 65001 >nul
where pwsh.exe >nul 2>nul
if %errorlevel%==0 (
  pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.codex\notify-ntfy.ps1"
) else (
  C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.codex\notify-ntfy.ps1"
)
exit /b 0

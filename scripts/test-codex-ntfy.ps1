param(
    [string]$CodexDir = (Join-Path $env:USERPROFILE ".codex")
)

$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $CodexDir "notify-ntfy.ps1"

if (-not (Test-Path $scriptPath)) {
    throw "notify-ntfy.ps1 not found: $scriptPath"
}

$payload = @{
    hook_event_name = "Stop"
    type = "manual-test"
    cwd = (Get-Location).Path
    model = "manual"
    last_assistant_message = "Codex ntfy notification test succeeded."
} | ConvertTo-Json -Compress

$payload | powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath

Write-Host "Test payload sent via $scriptPath"

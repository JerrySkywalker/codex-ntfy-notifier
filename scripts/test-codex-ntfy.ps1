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
    last_assistant_message = @'
## Markdown test succeeded

- **Bold text**
- `Inline code`
- Link: [ntfy publishing docs](https://docs.ntfy.sh/publish/)

```text
hello from codex-ntfy-notifier
```
'@
} | ConvertTo-Json -Compress

$payload | powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -CodexDir $CodexDir

if ($LASTEXITCODE -ne 0) {
    throw "notify script failed with exit code $LASTEXITCODE"
}

Write-Host "Test payload sent successfully via $scriptPath"

param(
    [string]$NtfyUrl,
    [string]$Topic,
    [string]$User,
    [string]$CodexDir = (Join-Path $env:USERPROFILE ".codex"),
    [string]$BackupRoot,
    [switch]$NoBackup
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$TemplateDir = Join-Path $RepoRoot "templates"

if (-not (Test-Path $TemplateDir)) {
    throw "Template directory not found: $TemplateDir"
}

if (-not $NtfyUrl -or $NtfyUrl.Trim() -eq "") {
    $NtfyUrl = Read-Host "ntfy server URL, e.g. https://ntfy.example.com"
}

if (-not $Topic -or $Topic.Trim() -eq "") {
    $Topic = Read-Host "ntfy topic, e.g. codex-topic"
}

if (-not $User -or $User.Trim() -eq "") {
    $User = Read-Host "ntfy username"
}

if (-not $BackupRoot -or $BackupRoot.Trim() -eq "") {
    $BackupRoot = Join-Path $RepoRoot "backups"
}

New-Item -ItemType Directory -Force $CodexDir | Out-Null

if (-not $NoBackup) {
    & (Join-Path $PSScriptRoot "backup-current-codex-config.ps1") `
        -CodexDir $CodexDir `
        -BackupRoot $BackupRoot
}

Copy-Item (Join-Path $TemplateDir "notify-ntfy.ps1") (Join-Path $CodexDir "notify-ntfy.ps1") -Force
Copy-Item (Join-Path $TemplateDir "notify-ntfy.cmd") (Join-Path $CodexDir "notify-ntfy.cmd") -Force

$NtfyUrl.TrimEnd("/") | Set-Content (Join-Path $CodexDir "ntfy-url.txt") -Encoding UTF8
$Topic | Set-Content (Join-Path $CodexDir "ntfy-topic.txt") -Encoding UTF8
$User | Set-Content (Join-Path $CodexDir "ntfy-user.txt") -Encoding UTF8

$secure = Read-Host "ntfy password" -AsSecureString
$secure | ConvertFrom-SecureString | Set-Content (Join-Path $CodexDir "ntfy-pass.dpapi") -Encoding UTF8

Write-Host ""
Write-Host "Installed Codex ntfy notification files to: $CodexDir"
Write-Host ""
Write-Host "Next step:"
Write-Host "  Add the hook snippet from templates/codex-config-snippet.toml to your Codex config if needed."
Write-Host ""
Write-Host "Then test:"
Write-Host "  powershell.exe -ExecutionPolicy Bypass -File .\scripts\test-codex-ntfy.ps1"

param(
    [string]$CodexDir = (Join-Path $env:USERPROFILE ".codex"),
    [string]$BackupRoot
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot

if (-not $BackupRoot -or $BackupRoot.Trim() -eq "") {
    $BackupRoot = Join-Path $RepoRoot "backups"
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $BackupRoot "codex-backup-$stamp"

New-Item -ItemType Directory -Force $backupDir | Out-Null

$names = @(
    "notify-ntfy.ps1",
    "notify-ntfy.cmd",
    "ntfy-url.txt",
    "ntfy-topic.txt",
    "ntfy-user.txt",
    "ntfy-pass.dpapi",
    "config.toml"
)

foreach ($name in $names) {
    $src = Join-Path $CodexDir $name
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $backupDir $name) -Force
    }
}

Write-Host "Backup created: $backupDir"

$CodexDir = Join-Path $env:USERPROFILE ".codex"
$BackupRoot = "C:\Dev\backups\codex-config-kit"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupDir = Join-Path $BackupRoot $Stamp
New-Item -ItemType Directory -Force $BackupDir | Out-Null
foreach ($name in @("notify-ntfy.ps1", "notify-ntfy.cmd", "ntfy-url.txt", "ntfy-topic.txt", "ntfy-user.txt", "ntfy-pass.dpapi", "config.toml")) {
    $p = Join-Path $CodexDir $name
    if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination (Join-Path $BackupDir $name) -Force }
}
Write-Host "Backed up current Codex files to $BackupDir"

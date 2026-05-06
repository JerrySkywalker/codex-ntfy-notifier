param(
    [string]$NtfyUrl = "",
    [string]$Topic = "",
    [string]$User = "",
    [switch]$SkipTest
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$CodexDir = Join-Path $env:USERPROFILE ".codex"
$BackupRoot = "C:\Dev\backups\codex-config-kit"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupDir = Join-Path $BackupRoot $Stamp

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Prompt-Default {
    param([string]$Label, [string]$Current)
    if (-not [string]::IsNullOrWhiteSpace($Current)) { return $Current }
    $v = Read-Host $Label
    if ([string]::IsNullOrWhiteSpace($v)) { throw "$Label is empty" }
    return $v.Trim()
}

New-Item -ItemType Directory -Force $CodexDir | Out-Null
New-Item -ItemType Directory -Force $BackupDir | Out-Null

foreach ($name in @("notify-ntfy.ps1", "notify-ntfy.cmd", "ntfy-url.txt", "ntfy-topic.txt", "ntfy-user.txt", "ntfy-pass.dpapi")) {
    $p = Join-Path $CodexDir $name
    if (Test-Path -LiteralPath $p) {
        Copy-Item -LiteralPath $p -Destination (Join-Path $BackupDir $name) -Force
    }
}

$NtfyUrl = Prompt-Default "ntfy server URL, e.g. https://ntfy.example.com" $NtfyUrl
$Topic   = Prompt-Default "ntfy topic" $Topic
$User    = Prompt-Default "ntfy username" $User

Copy-Item -LiteralPath (Join-Path $RepoRoot "templates\notify-ntfy.ps1") -Destination (Join-Path $CodexDir "notify-ntfy.ps1") -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot "templates\notify-ntfy.cmd") -Destination (Join-Path $CodexDir "notify-ntfy.cmd") -Force

Write-Utf8NoBom (Join-Path $CodexDir "ntfy-url.txt") $NtfyUrl
Write-Utf8NoBom (Join-Path $CodexDir "ntfy-topic.txt") $Topic
Write-Utf8NoBom (Join-Path $CodexDir "ntfy-user.txt") $User

$secure = Read-Host "ntfy password" -AsSecureString
$secure | ConvertFrom-SecureString | Set-Content (Join-Path $CodexDir "ntfy-pass.dpapi") -Encoding UTF8

Write-Host "Installed runtime files to $CodexDir"
Write-Host "Backups, if any, saved to $BackupDir"
Write-Host "Do not commit files under $CodexDir containing secrets. This repo contains templates only."

if (-not $SkipTest) {
    $payload = '{"hook_event_name":"Stop","cwd":"C:\\Dev","model":"manual-test","last_assistant_message":"Codex ntfy install test succeeded."}'
    $payload | cmd.exe /c "%USERPROFILE%\.codex\notify-ntfy.cmd"
    Write-Host "Sent test payload. Check Android ntfy."
}

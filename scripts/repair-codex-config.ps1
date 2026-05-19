param(
    [string]$CodexDir = (Join-Path $env:USERPROFILE ".codex"),
    [string]$ConfigPath,
    [string]$BackupRoot,
    [switch]$NoBackup,
    [switch]$EnableApps
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot

if (-not $BackupRoot -or $BackupRoot.Trim() -eq "") {
    $BackupRoot = Join-Path $RepoRoot "backups"
}

if (-not $ConfigPath -or $ConfigPath.Trim() -eq "") {
    $ConfigPath = Join-Path $CodexDir "config.toml"
} else {
    $CodexDir = Split-Path -Parent $ConfigPath
}

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Text
    )

    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Read-ConfigText {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    }

    return ""
}

function Update-CodexFeatureFlags {
    param(
        [string]$Text,
        [bool]$AppsEnabled
    )

    $lines = @()
    if (-not [string]::IsNullOrEmpty($Text)) {
        $lines = @($Text -split "`r?`n")
    }

    # Remove deprecated alias anywhere in config. The canonical key is [features].hooks.
    $withoutDeprecated = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -notmatch '^\s*codex_hooks\s*=') {
            [void]$withoutDeprecated.Add($line)
        }
    }
    $lines = @($withoutDeprecated.ToArray())

    $featuresStart = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[features\]\s*(#.*)?$') {
            $featuresStart = $i
            break
        }
    }

    $appsValue = if ($AppsEnabled) { "true" } else { "false" }

    if ($featuresStart -lt 0) {
        $out = New-Object System.Collections.Generic.List[string]
        foreach ($line in $lines) {
            [void]$out.Add($line)
        }

        if ($out.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($out[$out.Count - 1])) {
            [void]$out.Add("")
        }

        [void]$out.Add("[features]")
        [void]$out.Add("hooks = true")
        [void]$out.Add("apps = $appsValue")

        return (($out.ToArray()) -join "`n").TrimEnd() + "`n"
    }

    $featuresEnd = $lines.Count
    for ($j = $featuresStart + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j] -match '^\s*\[[^\]]+\]\s*(#.*)?$') {
            $featuresEnd = $j
            break
        }
    }

    $out2 = New-Object System.Collections.Generic.List[string]

    for ($i = 0; $i -le $featuresStart; $i++) {
        [void]$out2.Add($lines[$i])
    }

    [void]$out2.Add("hooks = true")
    [void]$out2.Add("apps = $appsValue")

    for ($i = $featuresStart + 1; $i -lt $featuresEnd; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*(hooks|apps)\s*=') {
            continue
        }
        [void]$out2.Add($line)
    }

    for ($i = $featuresEnd; $i -lt $lines.Count; $i++) {
        [void]$out2.Add($lines[$i])
    }

    return (($out2.ToArray()) -join "`n").TrimEnd() + "`n"
}

New-Item -ItemType Directory -Force $CodexDir | Out-Null

if (-not $NoBackup) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupDir = Join-Path $BackupRoot "codex-config-repair-$stamp"
    New-Item -ItemType Directory -Force $backupDir | Out-Null

    if (Test-Path -LiteralPath $ConfigPath) {
        Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $backupDir "config.toml") -Force
    }

    Write-Host "Backup created: $backupDir"
}

$current = Read-ConfigText -Path $ConfigPath
$updated = Update-CodexFeatureFlags -Text $current -AppsEnabled ([bool]$EnableApps)
Write-Utf8NoBom -Path $ConfigPath -Text $updated

Write-Host "Patched Codex config: $ConfigPath"
Write-Host "  [features].hooks = true"
Write-Host "  [features].apps  = $([bool]$EnableApps).ToString().ToLowerInvariant()"
Write-Host "  Removed deprecated [features].codex_hooks if present."

param(
    [string]$NtfyUrl,
    [string]$Topic,
    [string]$User,
    [SecureString]$Password,
    [string]$CodexDir = (Join-Path $env:USERPROFILE ".codex"),
    [string]$ConfigPath,
    [string]$HooksPath,
    [string]$BackupRoot,
    [switch]$NoBackup
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$TemplateDir = Join-Path $RepoRoot "templates"
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

if (-not (Test-Path -LiteralPath $TemplateDir -PathType Container)) {
    throw "Template directory not found: $TemplateDir"
}
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $CodexDir "config.toml"
}
if ([string]::IsNullOrWhiteSpace($HooksPath)) {
    $HooksPath = Join-Path $CodexDir "hooks.json"
}
if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
    $BackupRoot = Join-Path $CodexDir "backups"
}

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Text
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force $directory | Out-Null
    $temporaryPath = Join-Path $directory (".$([IO.Path]::GetFileName($Path)).$([guid]::NewGuid().ToString('N')).tmp")
    [IO.File]::WriteAllText($temporaryPath, $Text, $Utf8NoBom)
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Get-ExistingText {
    param([string]$Name)

    $path = Join-Path $CodexDir $Name
    if (Test-Path -LiteralPath $path) {
        return (Get-Content -LiteralPath $path -Raw -Encoding UTF8).Trim()
    }
    return ""
}

function Get-RequiredSetting {
    param(
        [string]$Value,
        [string]$ExistingValue,
        [string]$Prompt
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return $Value.Trim()
    }
    if (-not [string]::IsNullOrWhiteSpace($ExistingValue)) {
        return $ExistingValue.Trim()
    }
    return (Read-Host $Prompt).Trim()
}

function Test-OwnedNotifierCommand {
    param([string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command) -or $Command -notmatch '(?i)notify-ntfy\.(cmd|ps1)') {
        return $false
    }

    $normalized = $Command.Replace('/', '\').ToLowerInvariant()
    $candidates = @(
        (Join-Path $CodexDir "notify-ntfy.cmd"),
        (Join-Path $CodexDir "notify-ntfy.ps1"),
        (Join-Path $env:USERPROFILE ".codex\notify-ntfy.cmd"),
        (Join-Path $env:USERPROFILE ".codex\notify-ntfy.ps1"),
        '%USERPROFILE%\.codex\notify-ntfy.cmd',
        '%USERPROFILE%\.codex\notify-ntfy.ps1'
    ) | ForEach-Object { $_.Replace('/', '\').ToLowerInvariant() }

    foreach ($candidate in $candidates) {
        if ($normalized.Contains($candidate)) {
            return $true
        }
    }
    return $false
}

function New-OwnedNotifierCommandHook {
    $notifierPath = (Join-Path $CodexDir "notify-ntfy.ps1").Replace('"', '""')
    $notifierCodexDir = $CodexDir.Replace('"', '""')
    return [pscustomobject]@{
        type = "command"
        command = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$notifierPath`" -CodexDir `"$notifierCodexDir`""
        timeout = 5
        statusMessage = "Queueing phone notification"
    }
}

function Get-HooksDocument {
    if (-not (Test-Path -LiteralPath $HooksPath)) {
        return [pscustomobject]@{ hooks = [pscustomobject]@{} }
    }

    try {
        $document = Get-Content -LiteralPath $HooksPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Existing hooks.json is not valid JSON; it was not changed."
    }
    if ($null -eq $document.hooks) {
        $document | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
    }
    return $document
}

function Update-OwnedStopHook {
    param($HooksDocument)

    $hooksRoot = $HooksDocument.hooks
    $existingEntries = @()
    $stopProperty = $hooksRoot.PSObject.Properties["Stop"]
    if ($null -ne $stopProperty -and $null -ne $stopProperty.Value) {
        $existingEntries = @($stopProperty.Value)
    }

    $updatedEntries = New-Object System.Collections.Generic.List[object]
    $ownedFound = 0
    $replacementAdded = $false
    foreach ($entry in $existingEntries) {
        $updatedHooks = New-Object System.Collections.Generic.List[object]
        foreach ($hook in @($entry.hooks)) {
            if (Test-OwnedNotifierCommand ([string]$hook.command)) {
                $ownedFound++
                if (-not $replacementAdded) {
                    [void]$updatedHooks.Add((New-OwnedNotifierCommandHook))
                    $replacementAdded = $true
                }
            } else {
                [void]$updatedHooks.Add($hook)
            }
        }
        if ($updatedHooks.Count -gt 0) {
            $entry.hooks = @($updatedHooks.ToArray())
            [void]$updatedEntries.Add($entry)
        }
    }

    if (-not $replacementAdded) {
        [void]$updatedEntries.Add([pscustomobject]@{ hooks = @((New-OwnedNotifierCommandHook)) })
    }

    if ($null -eq $stopProperty) {
        $hooksRoot | Add-Member -NotePropertyName Stop -NotePropertyValue @($updatedEntries.ToArray())
    } else {
        $hooksRoot.Stop = @($updatedEntries.ToArray())
    }

    return $ownedFound
}

function Get-LegacyNotifyDisposition {
    param([string]$ConfigText)

    $match = [regex]::Match($ConfigText, '(?ms)^\s*notify\s*=\s*\[(?<body>.*?)^\s*\]\s*(?:\r?\n|$)')
    if (-not $match.Success) {
        return [pscustomobject]@{ Disposition = "NOT_PRESENT"; UpdatedText = $ConfigText }
    }

    $body = $match.Groups["body"].Value
    $isPowerShellNotify = $body -match '(?i)powershell(?:\.exe)?' -and $body -match '(?i)notify-ntfy\.ps1'
    $matchesOwnedPath = Test-OwnedNotifierCommand $body
    if ($isPowerShellNotify -and $matchesOwnedPath) {
        $updated = $ConfigText.Remove($match.Index, $match.Length)
        return [pscustomobject]@{ Disposition = "MIGRATED_EXACT_OWNED"; UpdatedText = $updated.TrimEnd() + "`n" }
    }

    return [pscustomobject]@{ Disposition = "CONFLICT_PRESERVED"; UpdatedText = $ConfigText }
}

New-Item -ItemType Directory -Force $CodexDir | Out-Null

if (-not $NoBackup) {
    & (Join-Path $PSScriptRoot "backup-current-codex-config.ps1") -CodexDir $CodexDir -BackupRoot $BackupRoot
}

# Keep all existing settings when callers are upgrading an already configured
# machine. A fresh machine is prompted only for its non-secret values.
$NtfyUrl = Get-RequiredSetting -Value $NtfyUrl -ExistingValue (Get-ExistingText "ntfy-url.txt") -Prompt "ntfy server URL, e.g. https://ntfy.example.com"
$Topic = Get-RequiredSetting -Value $Topic -ExistingValue (Get-ExistingText "ntfy-topic.txt") -Prompt "ntfy topic, e.g. codex-topic"
$User = Get-RequiredSetting -Value $User -ExistingValue (Get-ExistingText "ntfy-user.txt") -Prompt "ntfy username"

foreach ($file in @("notify-ntfy.ps1", "notify-ntfy-worker.ps1", "notify-ntfy.cmd")) {
    Copy-Item -LiteralPath (Join-Path $TemplateDir $file) -Destination (Join-Path $CodexDir $file) -Force
}
Write-Utf8NoBom -Path (Join-Path $CodexDir "ntfy-url.txt") -Text ($NtfyUrl.TrimEnd("/") + "`n")
Write-Utf8NoBom -Path (Join-Path $CodexDir "ntfy-topic.txt") -Text ($Topic + "`n")
Write-Utf8NoBom -Path (Join-Path $CodexDir "ntfy-user.txt") -Text ($User + "`n")

$dpapiPath = Join-Path $CodexDir "ntfy-pass.dpapi"
if ($null -ne $Password) {
    $protectedText = $Password | ConvertFrom-SecureString
    Write-Utf8NoBom -Path $dpapiPath -Text ($protectedText + "`n")
} elseif (-not (Test-Path -LiteralPath $dpapiPath)) {
    $enteredPassword = Read-Host "ntfy password" -AsSecureString
    $protectedText = $enteredPassword | ConvertFrom-SecureString
    Write-Utf8NoBom -Path $dpapiPath -Text ($protectedText + "`n")
}

# Preserve the existing feature-flag behavior while making Hooks the preferred
# integration path. The helper does not alter hook declarations or plugins.
& (Join-Path $PSScriptRoot "repair-codex-config.ps1") -CodexDir $CodexDir -ConfigPath $ConfigPath -NoBackup | Out-Null
$configText = if (Test-Path -LiteralPath $ConfigPath) { Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 } else { "" }
$legacy = Get-LegacyNotifyDisposition -ConfigText $configText
if ($legacy.UpdatedText -ne $configText) {
    Write-Utf8NoBom -Path $ConfigPath -Text $legacy.UpdatedText
}

$hooksDocument = Get-HooksDocument
$ownedHookCount = Update-OwnedStopHook -HooksDocument $hooksDocument
Write-Utf8NoBom -Path $HooksPath -Text (($hooksDocument | ConvertTo-Json -Depth 20) + "`n")

Write-Host "Installed Codex ntfy notifier files to: $CodexDir"
Write-Host "HOOK_INTEGRATION=Stop hook (synchronous local enqueue only)"
Write-Host "OWNED_STOP_HOOKS_REPLACED=$ownedHookCount"
Write-Host "LEGACY_NOTIFY_DISPOSITION=$($legacy.Disposition)"
if ($legacy.Disposition -eq "CONFLICT_PRESERVED") {
    Write-Warning "An unrelated legacy notify declaration was preserved. It may create a separate notification path."
}
Write-Host "OWNER_ACTION=review/trust the changed notifier Hook in Codex /hooks"

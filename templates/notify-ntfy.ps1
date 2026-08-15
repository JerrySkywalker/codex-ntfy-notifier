param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$NotifyArgs,
    [string]$CodexDir,
    [string]$RuntimeRoot,
    [string]$WorkerPath
)

# This script is intentionally the synchronous, local-only Stop hook ingress.
# Do not add transcript, DPAPI, DNS, TLS, HTTP, or retry work here.
$ErrorActionPreference = "Stop"

$MaxTextLength = 8192
$MaxPathLength = 2048
$MaxActiveItems = 100

try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [Console]::InputEncoding = $utf8NoBom
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding = $utf8NoBom
} catch {
}

if ([string]::IsNullOrWhiteSpace($CodexDir)) {
    $CodexDir = Join-Path $env:USERPROFILE ".codex"
}
if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
    $RuntimeRoot = [Environment]::GetEnvironmentVariable("CODEX_NTFY_RUNTIME_ROOT")
}
if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
    $RuntimeRoot = Join-Path $env:LOCALAPPDATA "CodexNtfyNotifier"
}
if ([string]::IsNullOrWhiteSpace($WorkerPath)) {
    $WorkerPath = Join-Path $PSScriptRoot "notify-ntfy-worker.ps1"
}

$PendingDir = Join-Path $RuntimeRoot "spool\pending"
$ProcessingDir = Join-Path $RuntimeRoot "spool\processing"
$LogPath = Join-Path $RuntimeRoot "ingress.log"

function Write-IngressLog {
    param([string]$EventName)

    try {
        New-Item -ItemType Directory -Force $RuntimeRoot | Out-Null
        $timestamp = [DateTime]::UtcNow.ToString("o")
        Add-Content -LiteralPath $LogPath -Value "[$timestamp] $EventName" -Encoding UTF8
    } catch {
    }
}

function Get-PropertyValue {
    param(
        $Object,
        [string[]]$Names
    )

    if ($null -eq $Object) {
        return ""
    }

    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) {
            $value = [string]$property.Value
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value.Trim()
            }
        }
    }

    return ""
}

function Limit-Text {
    param(
        [string]$Text,
        [int]$Maximum
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $trimmed = $Text.Trim()
    if ($trimmed.Length -le $Maximum) {
        return $trimmed
    }

    return $trimmed.Substring(0, $Maximum) + "`n… [truncated by local notifier]"
}

function Get-RawPayload {
    if ($null -ne $NotifyArgs -and $NotifyArgs.Count -gt 0) {
        return ($NotifyArgs -join " ")
    }

    try {
        if ([Console]::IsInputRedirected) {
            return [Console]::In.ReadToEnd()
        }
    } catch {
        Write-IngressLog "stdin_read_failed"
    }

    return ""
}

function Test-StopLikeEvent {
    param([string]$EventName)

    return $EventName -match '^(?i:Stop|agent-turn-complete|manual-test|stdin-test|arg-test|notification)$'
}

function Test-SpoolCapacity {
    try {
        $pendingCount = @(Get-ChildItem -LiteralPath $PendingDir -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
        $processingCount = @(Get-ChildItem -LiteralPath $ProcessingDir -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
        return ($pendingCount + $processingCount) -lt $MaxActiveItems
    } catch {
        return $false
    }
}

function Start-DetachedWorker {
    param(
        [string]$EnvelopePath
    )

    if (-not (Test-Path -LiteralPath $WorkerPath -PathType Leaf)) {
        throw "worker_missing"
    }

    # Only local paths are passed to the detached process. The raw hook payload,
    # envelope content, and credentials are never command-line arguments.
    $escapedWorker = $WorkerPath.Replace('"', '""')
    $escapedEnvelope = $EnvelopePath.Replace('"', '""')
    $escapedRuntime = $RuntimeRoot.Replace('"', '""')
    $escapedCodex = $CodexDir.Replace('"', '""')
    $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$escapedWorker`" -EnvelopePath `"$escapedEnvelope`" -RuntimeRoot `"$escapedRuntime`" -CodexDir `"$escapedCodex`""

    $process = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -WindowStyle Hidden -PassThru
    if ($null -eq $process) {
        throw "worker_start_failed"
    }
}

try {
    New-Item -ItemType Directory -Force $PendingDir, $ProcessingDir | Out-Null

    if (-not (Test-SpoolCapacity)) {
        throw "spool_capacity_reached"
    }

    $raw = Get-RawPayload
    if ($raw.Length -gt 0 -and [int][char]$raw[0] -eq 0xFEFF) {
        $raw = $raw.Substring(1)
    }
    Write-IngressLog ("raw_input_length_" + $raw.Length)
    $payload = $null
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        try {
            $payload = $raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-IngressLog "json_parse_failed"
        }
    }

    $eventName = Get-PropertyValue -Object $payload -Names @("hook_event_name", "type", "event")
    # Retains the useful installed-runtime compatibility behavior for manual
    # invocations which did not provide an event name.
    if ([string]::IsNullOrWhiteSpace($eventName)) {
        $eventName = "notification"
    }

    if (-not (Test-StopLikeEvent $eventName)) {
        Write-IngressLog "event_ignored"
        exit 0
    }

    $fallback = Get-PropertyValue -Object $payload -Names @("last_assistant_message", "last-assistant-message", "lastAssistantMessage", "message", "text")
    if ([string]::IsNullOrWhiteSpace($fallback)) {
        $fallback = "Codex Stop event queued."
    }

    $id = [guid]::NewGuid().ToString("N")
    $envelope = [ordered]@{
        schema_version = 1
        id = $id
        created_at = [DateTime]::UtcNow.ToString("o")
        source = "codex"
        event = (Limit-Text -Text $eventName -Maximum 128)
        session_id = (Limit-Text -Text (Get-PropertyValue -Object $payload -Names @("session_id", "sessionId")) -Maximum 256)
        turn_id = (Limit-Text -Text (Get-PropertyValue -Object $payload -Names @("turn_id", "turnId")) -Maximum 256)
        cwd = (Limit-Text -Text (Get-PropertyValue -Object $payload -Names @("cwd")) -Maximum $MaxPathLength)
        model = (Limit-Text -Text (Get-PropertyValue -Object $payload -Names @("model")) -Maximum 256)
        transcript_path = (Limit-Text -Text (Get-PropertyValue -Object $payload -Names @("transcript_path", "transcriptPath")) -Maximum $MaxPathLength)
        fallback_message = (Limit-Text -Text $fallback -Maximum $MaxTextLength)
    }

    $pendingPath = Join-Path $PendingDir ("$id.json")
    $temporaryPath = Join-Path $PendingDir (".$id.$([guid]::NewGuid().ToString('N')).tmp")
    $serialized = $envelope | ConvertTo-Json -Depth 4 -Compress
    [System.IO.File]::WriteAllText($temporaryPath, $serialized, $utf8NoBom)
    # A rename in the same local directory publishes only a complete envelope.
    [System.IO.File]::Move($temporaryPath, $pendingPath)

    try {
        Start-DetachedWorker -EnvelopePath $pendingPath
    } catch {
        # Keep the envelope pending for a safe manual worker invocation; do not
        # attempt network delivery from the hook as a fallback.
        Write-IngressLog "worker_launch_failed"
        throw
    }

    Write-IngressLog "enqueued_and_worker_started"
    exit 0
} catch {
    Write-IngressLog "local_handoff_failed"
    Write-Error "Codex ntfy local handoff failed. See the local ingress log."
    # Never return 2: this hook must not control or block the Codex lifecycle.
    exit 1
}

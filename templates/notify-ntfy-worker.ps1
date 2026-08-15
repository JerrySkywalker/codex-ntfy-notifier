param(
    [Parameter(Mandatory = $true)]
    [string]$EnvelopePath,
    [string]$RuntimeRoot,
    [string]$CodexDir
)

# Detached consumer for Codex ntfy envelopes. Network work belongs only here.
$ErrorActionPreference = "Stop"
$MaxFailedItems = 100
$MaxReceipts = 200

try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [Console]::InputEncoding = $utf8NoBom
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding = $utf8NoBom
} catch {
}

if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
    $RuntimeRoot = [Environment]::GetEnvironmentVariable("CODEX_NTFY_RUNTIME_ROOT")
}
if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
    $RuntimeRoot = Join-Path $env:LOCALAPPDATA "CodexNtfyNotifier"
}
if ([string]::IsNullOrWhiteSpace($CodexDir)) {
    $CodexDir = Join-Path $env:USERPROFILE ".codex"
}

$PendingDir = Join-Path $RuntimeRoot "spool\pending"
$ProcessingDir = Join-Path $RuntimeRoot "spool\processing"
$FailedDir = Join-Path $RuntimeRoot "spool\failed"
$ReceiptsDir = Join-Path $RuntimeRoot "receipts"
$LogPath = Join-Path $RuntimeRoot "worker.log"
$DpapiPath = Join-Path $CodexDir "ntfy-pass.dpapi"

function Write-WorkerLog {
    param([string]$EventName)

    try {
        New-Item -ItemType Directory -Force $RuntimeRoot | Out-Null
        Add-Content -LiteralPath $LogPath -Value "[$([DateTime]::UtcNow.ToString('o'))] $EventName" -Encoding UTF8
    } catch {
    }
}

function Get-PropertyValue {
    param(
        $Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function Read-ConfigText {
    param(
        [string]$Name,
        [string]$EnvironmentName
    )

    $fromEnvironment = [Environment]::GetEnvironmentVariable($EnvironmentName)
    if (-not [string]::IsNullOrWhiteSpace($fromEnvironment)) {
        return $fromEnvironment.Trim()
    }

    $path = Join-Path $CodexDir $Name
    if (Test-Path -LiteralPath $path) {
        return (Get-Content -LiteralPath $path -Raw -Encoding UTF8).Trim()
    }

    return ""
}

function Get-Password {
    $fromEnvironment = [Environment]::GetEnvironmentVariable("NTFY_CODEX_PASS")
    if (-not [string]::IsNullOrWhiteSpace($fromEnvironment)) {
        return $fromEnvironment
    }

    if (-not (Test-Path -LiteralPath $DpapiPath)) {
        return ""
    }

    try {
        $protectedText = (Get-Content -LiteralPath $DpapiPath -Raw).Trim()
        if ($protectedText.Length -gt 0 -and [int][char]$protectedText[0] -eq 0xFEFF) {
            $protectedText = $protectedText.Substring(1)
        }
        $secure = $protectedText | ConvertTo-SecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    } catch {
        throw "CONFIG_DPAPI_READ_FAILED"
    }
}

function Normalize-DisplayPath {
    param([string]$PathText)

    if ([string]::IsNullOrWhiteSpace($PathText)) {
        return ""
    }

    $normalized = $PathText.Trim()
    $normalized = $normalized -replace '^\\\\\?\\UNC\\', '\\'
    $normalized = $normalized -replace '^\\\\\?\\', ''
    return $normalized
}

function Convert-ContentToText {
    param($Value)

    if ($null -eq $Value) {
        return ""
    }
    if ($Value -is [string]) {
        return $Value
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($item in $Value) {
            $text = Convert-ContentToText $item
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                [void]$parts.Add($text)
            }
        }
        return ($parts -join "`n")
    }

    foreach ($name in @("text", "message", "content", "value", "output_text")) {
        $candidate = Get-PropertyValue -Object $Value -Name $name
        if ($null -ne $candidate) {
            $text = Convert-ContentToText $candidate
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                return $text
            }
        }
    }
    return ""
}

function Extract-AssistantTextFromObject {
    param($Object)

    if ($null -eq $Object) {
        return ""
    }
    foreach ($name in @("last_assistant_message", "last-assistant-message", "lastAssistantMessage")) {
        $candidate = Get-PropertyValue -Object $Object -Name $name
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
            return [string]$candidate
        }
    }

    $role = [string](Get-PropertyValue -Object $Object -Name "role")
    $type = [string](Get-PropertyValue -Object $Object -Name "type")
    if ($role -eq "assistant" -or $type -match "assistant|agent_message|message_output|output_text") {
        foreach ($name in @("content", "message", "text", "item")) {
            $candidate = Get-PropertyValue -Object $Object -Name $name
            if ($null -ne $candidate) {
                $text = Convert-ContentToText $candidate
                if (-not [string]::IsNullOrWhiteSpace($text)) {
                    return $text
                }
            }
        }
    }

    foreach ($name in @("payload", "item", "response")) {
        $candidate = Get-PropertyValue -Object $Object -Name $name
        if ($null -ne $candidate) {
            $text = Extract-AssistantTextFromObject $candidate
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                return $text
            }
        }
    }
    return ""
}

function Get-LastAssistantTextFromTranscript {
    param([string]$TranscriptPath)

    if ([string]::IsNullOrWhiteSpace($TranscriptPath)) {
        return ""
    }

    foreach ($path in @($TranscriptPath, (Normalize-DisplayPath $TranscriptPath) | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }
        try {
            if (-not (Test-Path -LiteralPath $path)) {
                continue
            }
            $lines = @(Get-Content -LiteralPath $path -Tail 500 -Encoding UTF8)
            for ($index = $lines.Count - 1; $index -ge 0; $index--) {
                try {
                    $text = Extract-AssistantTextFromObject ($lines[$index] | ConvertFrom-Json -ErrorAction Stop)
                    if (-not [string]::IsNullOrWhiteSpace($text)) {
                        return $text
                    }
                } catch {
                }
            }
        } catch {
            Write-WorkerLog "transcript_read_failed"
        }
    }
    return ""
}

function Get-WorkerTimeoutSec {
    $candidate = [Environment]::GetEnvironmentVariable("NTFY_CODEX_WORKER_TIMEOUT_SEC")
    $timeout = 15
    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        $parsed = 0
        if ([int]::TryParse($candidate, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 60) {
            $timeout = $parsed
        }
    }
    return $timeout
}

function Send-Ntfy {
    param(
        [string]$Title,
        [string]$Message
    )

    $server = Read-ConfigText -Name "ntfy-url.txt" -EnvironmentName "NTFY_CODEX_URL"
    $topic = Read-ConfigText -Name "ntfy-topic.txt" -EnvironmentName "NTFY_CODEX_TOPIC"
    $user = Read-ConfigText -Name "ntfy-user.txt" -EnvironmentName "NTFY_CODEX_USER"
    $password = Get-Password

    if ([string]::IsNullOrWhiteSpace($server)) { throw "CONFIG_URL_EMPTY" }
    if ([string]::IsNullOrWhiteSpace($topic)) { throw "CONFIG_TOPIC_EMPTY" }
    if ([string]::IsNullOrWhiteSpace($user)) { throw "CONFIG_USER_EMPTY" }
    if ([string]::IsNullOrWhiteSpace($password)) { throw "CONFIG_PASSWORD_EMPTY" }

    try {
        $serverUri = [Uri]$server.TrimEnd("/")
    } catch {
        throw "CONFIG_URL_INVALID"
    }
    $allowInsecureLoopback = $serverUri.Scheme -eq [Uri]::UriSchemeHttp -and $serverUri.IsLoopback -and [Environment]::GetEnvironmentVariable("NTFY_CODEX_ALLOW_INSECURE_LOOPBACK") -eq "1"
    if ($serverUri.Scheme -ne [Uri]::UriSchemeHttps -and -not $allowInsecureLoopback) {
        throw "CONFIG_URL_HTTPS_REQUIRED"
    }

    $uri = "$($serverUri.AbsoluteUri.TrimEnd('/'))/$topic"
    $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${user}:${password}"))
    $headers = @{
        Authorization = "Basic $basic"
        Title = $Title
        Priority = "4"
        Tags = "robot"
        Markdown = "yes"
    }

    Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $Message -TimeoutSec (Get-WorkerTimeoutSec) -ContentType "text/markdown; charset=utf-8" | Out-Null
}

function Write-Receipt {
    param(
        [string]$Id,
        [string]$Status,
        [string]$Stage,
        [string]$ErrorCode
    )

    $receipt = [ordered]@{
        schema_version = 1
        id = $Id
        completed_at = [DateTime]::UtcNow.ToString("o")
        status = $Status
        stage = $Stage
        error_code = $ErrorCode
    }
    $path = Join-Path $ReceiptsDir ("$Id.$([DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff')).json")
    [System.IO.File]::WriteAllText($path, ($receipt | ConvertTo-Json -Compress), $utf8NoBom)

    $receipts = @(Get-ChildItem -LiteralPath $ReceiptsDir -Filter "*.json" -File | Sort-Object LastWriteTimeUtc)
    if ($receipts.Count -gt $MaxReceipts) {
        $receipts | Select-Object -First ($receipts.Count - $MaxReceipts) | Remove-Item -Force
    }
}

function Get-SanitizedFailureCode {
    param($Exception)

    $message = [string]$Exception.Message
    if ($message -match '^CONFIG_[A-Z_]+$') {
        return $message
    }
    if ($message -match '^ENVELOPE_[A-Z_]+$') {
        return $message
    }
    return "NETWORK_DELIVERY_FAILED"
}

$claimedPath = $null
$envelope = $null
try {
    New-Item -ItemType Directory -Force $PendingDir, $ProcessingDir, $FailedDir, $ReceiptsDir | Out-Null
    $fullEnvelopePath = [System.IO.Path]::GetFullPath($EnvelopePath)
    $fullPendingDir = [System.IO.Path]::GetFullPath($PendingDir)
    if (-not $fullEnvelopePath.StartsWith($fullPendingDir, [StringComparison]::OrdinalIgnoreCase)) {
        throw "ENVELOPE_PATH_INVALID"
    }
    if (-not (Test-Path -LiteralPath $fullEnvelopePath -PathType Leaf)) {
        Write-WorkerLog "envelope_not_pending"
        exit 0
    }

    $claimedPath = Join-Path $ProcessingDir ([System.IO.Path]::GetFileName($fullEnvelopePath))
    try {
        [System.IO.File]::Move($fullEnvelopePath, $claimedPath)
    } catch {
        Write-WorkerLog "envelope_claim_lost"
        exit 0
    }

    $envelope = Get-Content -LiteralPath $claimedPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if ([int](Get-PropertyValue $envelope "schema_version") -ne 1) { throw "ENVELOPE_SCHEMA_UNSUPPORTED" }
    if ([string](Get-PropertyValue $envelope "source") -ne "codex") { throw "ENVELOPE_SOURCE_INVALID" }
    $id = [string](Get-PropertyValue $envelope "id")
    $parsedId = [guid]::Empty
    if (-not [guid]::TryParse($id, [ref]$parsedId)) { throw "ENVELOPE_ID_INVALID" }

    $assistantText = Get-LastAssistantTextFromTranscript ([string](Get-PropertyValue $envelope "transcript_path"))
    if ([string]::IsNullOrWhiteSpace($assistantText)) {
        $assistantText = [string](Get-PropertyValue $envelope "fallback_message")
    }
    if ([string]::IsNullOrWhiteSpace($assistantText)) {
        $assistantText = "_No assistant output captured._"
    }

    $timeText = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $parts = @("## Codex task finished", "", "- **Time:** ``$timeText``")
    $cwd = [string](Get-PropertyValue $envelope "cwd")
    $model = [string](Get-PropertyValue $envelope "model")
    $transcript = Normalize-DisplayPath ([string](Get-PropertyValue $envelope "transcript_path"))
    if (-not [string]::IsNullOrWhiteSpace($cwd)) { $parts += "- **Directory:** ``$cwd``" }
    if (-not [string]::IsNullOrWhiteSpace($model)) { $parts += "- **Model:** ``$model``" }
    if (-not [string]::IsNullOrWhiteSpace($transcript)) { $parts += "- **Transcript:** ``$transcript``" }
    $parts += "", "---", "", "### Codex output", "", $assistantText.Trim()

    Send-Ntfy -Title "Codex done $((Get-Date).ToString('HH:mm:ss'))" -Message ($parts -join "`n")
    Write-Receipt -Id $id -Status "success" -Stage "delivery" -ErrorCode ""
    Remove-Item -LiteralPath $claimedPath -Force
    Write-WorkerLog "delivery_succeeded"
    exit 0
} catch {
    $id = if ($null -ne $envelope) { [string](Get-PropertyValue $envelope "id") } else { [System.IO.Path]::GetFileNameWithoutExtension($EnvelopePath) }
    if ([string]::IsNullOrWhiteSpace($id)) { $id = [guid]::NewGuid().ToString('N') }
    $failureCode = Get-SanitizedFailureCode $_.Exception
    try {
        New-Item -ItemType Directory -Force $FailedDir, $ReceiptsDir | Out-Null
        Write-Receipt -Id $id -Status "failure" -Stage "delivery" -ErrorCode $failureCode
        if ($null -ne $claimedPath -and (Test-Path -LiteralPath $claimedPath)) {
            $failedCount = @(Get-ChildItem -LiteralPath $FailedDir -Filter "*.json" -File).Count
            if ($failedCount -lt $MaxFailedItems) {
                [System.IO.File]::Move($claimedPath, (Join-Path $FailedDir ([System.IO.Path]::GetFileName($claimedPath))))
            } else {
                # Keep the item recoverable without an automatic retry loop.
                [System.IO.File]::Move($claimedPath, (Join-Path $PendingDir ([System.IO.Path]::GetFileName($claimedPath))))
                Write-WorkerLog "failed_spool_capacity_reached"
            }
        }
    } catch {
        Write-WorkerLog "failure_receipt_or_recovery_failed"
    }
    Write-WorkerLog "delivery_failed"
    exit 1
}

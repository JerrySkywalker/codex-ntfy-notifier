param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$NotifyArgs
)

$ErrorActionPreference = "Stop"

try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [Console]::InputEncoding = $utf8NoBom
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding = $utf8NoBom
} catch {
}

$CodexDir = Join-Path $env:USERPROFILE ".codex"
$LogPath = Join-Path $CodexDir "notify-ntfy.log"
$DpapiPath = Join-Path $CodexDir "ntfy-pass.dpapi"

function Write-NotifyLog {
    param([string]$Text)

    try {
        New-Item -ItemType Directory -Force $CodexDir | Out-Null
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        Add-Content -Path $LogPath -Value "[$ts] $Text" -Encoding UTF8
    } catch {
    }
}

function Read-ConfigText {
    param(
        [string]$Name,
        [string]$EnvName
    )

    $envValue = [Environment]::GetEnvironmentVariable($EnvName)
    if (-not [string]::IsNullOrWhiteSpace($envValue)) {
        return $envValue.Trim()
    }

    $path = Join-Path $CodexDir $Name
    if (Test-Path $path) {
        return ((Get-Content $path -Raw -Encoding UTF8).Trim())
    }

    return ""
}

function Get-Password {
    $envPass = [Environment]::GetEnvironmentVariable("NTFY_CODEX_PASS")
    if (-not [string]::IsNullOrWhiteSpace($envPass)) {
        return $envPass
    }

    if (-not (Test-Path $DpapiPath)) {
        return ""
    }

    try {
        $secure = Get-Content $DpapiPath -Raw | ConvertTo-SecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)

        try {
            return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    } catch {
        Write-NotifyLog "DPAPI password read failed: $($_.Exception.Message)"
        return ""
    }
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
        Write-NotifyLog "Read stdin failed: $($_.Exception.Message)"
    }

    return ""
}

function Normalize-DisplayPath {
    param([string]$PathText)

    if ([string]::IsNullOrWhiteSpace($PathText)) {
        return ""
    }

    $p = $PathText.Trim()
    $p = $p -replace '^\\\\\?\\UNC\\', '\\'
    $p = $p -replace '^\\\\\?\\', ''

    return $p
}

function Get-Prop {
    param(
        $Obj,
        [string]$Name
    )

    if ($null -eq $Obj) {
        return $null
    }

    $p = $Obj.PSObject.Properties[$Name]
    if ($null -ne $p) {
        return $p.Value
    }

    return $null
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
        $items = New-Object System.Collections.Generic.List[string]

        foreach ($v in $Value) {
            $t = Convert-ContentToText $v
            if (-not [string]::IsNullOrWhiteSpace($t)) {
                [void]$items.Add($t)
            }
        }

        return ($items -join "`n")
    }

    foreach ($name in @("text", "message", "content", "value", "output_text")) {
        $pv = Get-Prop $Value $name
        if ($null -ne $pv) {
            $t = Convert-ContentToText $pv
            if (-not [string]::IsNullOrWhiteSpace($t)) {
                return $t
            }
        }
    }

    return ""
}

function Extract-AssistantTextFromObject {
    param($Obj)

    if ($null -eq $Obj) {
        return ""
    }

    foreach ($name in @("last_assistant_message", "last-assistant-message", "lastAssistantMessage")) {
        $v = Get-Prop $Obj $name
        if (-not [string]::IsNullOrWhiteSpace($v)) {
            return [string]$v
        }
    }

    $role = [string](Get-Prop $Obj "role")
    $type = [string](Get-Prop $Obj "type")

    $isAssistant = $false
    if ($role -eq "assistant") {
        $isAssistant = $true
    }
    if ($type -match "assistant|agent_message|message_output|output_text") {
        $isAssistant = $true
    }

    if ($isAssistant) {
        foreach ($name in @("content", "message", "text", "item")) {
            $pv = Get-Prop $Obj $name
            if ($null -ne $pv) {
                $t = Convert-ContentToText $pv
                if (-not [string]::IsNullOrWhiteSpace($t)) {
                    return $t
                }
            }
        }
    }

    foreach ($name in @("payload", "item", "response")) {
        $pv = Get-Prop $Obj $name
        if ($null -ne $pv) {
            $t = Extract-AssistantTextFromObject $pv
            if (-not [string]::IsNullOrWhiteSpace($t)) {
                return $t
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

    $paths = @()
    $paths += $TranscriptPath

    $normalized = Normalize-DisplayPath $TranscriptPath
    if (-not [string]::IsNullOrWhiteSpace($normalized)) {
        $paths += $normalized
    }

    foreach ($p in $paths) {
        try {
            if (-not (Test-Path -LiteralPath $p)) {
                continue
            }

            $lines = Get-Content -LiteralPath $p -Tail 500 -Encoding UTF8

            for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                $line = [string]$lines[$i]
                if ([string]::IsNullOrWhiteSpace($line)) {
                    continue
                }

                try {
                    $obj = $line | ConvertFrom-Json -ErrorAction Stop
                    $text = Extract-AssistantTextFromObject $obj
                    if (-not [string]::IsNullOrWhiteSpace($text)) {
                        return $text
                    }
                } catch {
                }
            }
        } catch {
            Write-NotifyLog "Transcript read failed: $p :: $($_.Exception.Message)"
        }
    }

    return ""
}

function Send-Ntfy {
    param(
        [string]$Title,
        [string]$Message,
        [string]$Priority = "4",
        [string]$Tags = "robot"
    )

    $server = Read-ConfigText -Name "ntfy-url.txt" -EnvName "NTFY_CODEX_URL"
    $topic = Read-ConfigText -Name "ntfy-topic.txt" -EnvName "NTFY_CODEX_TOPIC"
    $user = Read-ConfigText -Name "ntfy-user.txt" -EnvName "NTFY_CODEX_USER"
    $password = Get-Password

    if ([string]::IsNullOrWhiteSpace($server)) {
        throw "ntfy server URL is empty."
    }

    if ([string]::IsNullOrWhiteSpace($topic)) {
        throw "ntfy topic is empty."
    }

    if ([string]::IsNullOrWhiteSpace($user)) {
        throw "ntfy username is empty."
    }

    if ([string]::IsNullOrWhiteSpace($password)) {
        throw "ntfy password is empty."
    }

    $server = $server.TrimEnd("/")
    $uri = "$server/$topic"

    $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${user}:${password}"))

    $headers = @{
        Authorization = "Basic $basic"
        Title = $Title
        Priority = $Priority
        Tags = $Tags
    }

    Invoke-RestMethod `
        -Method Post `
        -Uri $uri `
        -Headers $headers `
        -Body $Message `
        -ContentType "text/plain; charset=utf-8" | Out-Null
}

try {
    Write-NotifyLog "==== notify script invoked ===="

    $raw = Get-RawPayload
    Write-NotifyLog "RawLength=$($raw.Length)"

    $json = $null

    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        try {
            $json = $raw | ConvertFrom-Json -ErrorAction Stop
            Write-NotifyLog "JSON parse success"
        } catch {
            Write-NotifyLog "JSON parse failed: $($_.Exception.Message)"
        }
    }

    $event = ""
    $cwd = ""
    $model = ""
    $transcript = ""
    $hookLast = ""

    if ($null -ne $json) {
        foreach ($name in @("hook_event_name", "type")) {
            $v = Get-Prop $json $name
            if (-not [string]::IsNullOrWhiteSpace($v)) {
                $event = [string]$v
                break
            }
        }

        $cwd = [string](Get-Prop $json "cwd")
        $model = [string](Get-Prop $json "model")
        $transcript = [string](Get-Prop $json "transcript_path")

        foreach ($name in @("last_assistant_message", "last-assistant-message", "message", "text")) {
            $v = Get-Prop $json $name
            if (-not [string]::IsNullOrWhiteSpace($v)) {
                $hookLast = [string]$v
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($event)) {
        $event = "notification"
    }

    Write-NotifyLog "Event=$event"
    Write-NotifyLog "Cwd=$cwd"
    Write-NotifyLog "Model=$model"
    Write-NotifyLog "Transcript=$transcript"

    $isStopLike = $false
    if ($event -match "Stop|manual-test|stdin-test|arg-test|notification") {
        $isStopLike = $true
    }

    if (-not $isStopLike) {
        Write-NotifyLog "Ignored event: $event"
        exit 0
    }

    $assistantText = Get-LastAssistantTextFromTranscript $transcript

    if ([string]::IsNullOrWhiteSpace($assistantText)) {
        $assistantText = $hookLast
    }

    if ([string]::IsNullOrWhiteSpace($assistantText)) {
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $assistantText = $raw
        } else {
            $assistantText = "Codex notify script was invoked."
        }
    }

    $transcriptDisplay = Normalize-DisplayPath $transcript
    $timeText = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $parts = @()
    $parts += "Status: Codex task finished"
    $parts += "Time: $timeText"

    if (-not [string]::IsNullOrWhiteSpace($cwd)) {
        $parts += "Directory: $cwd"
    }

    if (-not [string]::IsNullOrWhiteSpace($model)) {
        $parts += "Model: $model"
    }

    if (-not [string]::IsNullOrWhiteSpace($transcriptDisplay)) {
        $parts += "Transcript: $transcriptDisplay"
    }

    $parts += ""
    $parts += "==== Codex Output ===="
    $parts += $assistantText

    $message = ($parts -join "`n")
    $title = "Codex done $((Get-Date).ToString('HH:mm:ss'))"

    Send-Ntfy -Title $title -Message $message -Priority "4" -Tags "robot"

    Write-NotifyLog "ntfy send success. Title=$title"
    exit 0
} catch {
    Write-NotifyLog "Exit with error: $($_.Exception.Message)"
    Write-Error $_.Exception.Message
    exit 1
}

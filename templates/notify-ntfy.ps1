param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$NotifyArgs
)

$ErrorActionPreference = "SilentlyContinue"

try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [Console]::InputEncoding = $utf8NoBom
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding = $utf8NoBom
} catch {
}

$ConfigDir = Join-Path $env:USERPROFILE ".codex"
$ServerPath = Join-Path $ConfigDir "ntfy-url.txt"
$TopicPath  = Join-Path $ConfigDir "ntfy-topic.txt"
$UserPath   = Join-Path $ConfigDir "ntfy-user.txt"

function Get-ConfigText {
    param([string]$Path)

    try {
        if (Test-Path -LiteralPath $Path) {
            return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8).Trim()
        }
    } catch {
    }

    return ""
}

$Server = Get-ConfigText $ServerPath
$Topic  = Get-ConfigText $TopicPath
$User   = Get-ConfigText $UserPath

$ChunkSize = 3200
$LogPath = Join-Path $env:USERPROFILE ".codex\notify-ntfy.log"
$DpapiPath = Join-Path $env:USERPROFILE ".codex\ntfy-pass.dpapi"

function Write-NotifyLog {
    param([string]$Text)
    try {
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        Add-Content -Path $LogPath -Value "[$ts] $Text" -Encoding UTF8
    } catch {
    }
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

function Get-Password {
    $pass = $env:NTFY_CODEX_PASS

    if (-not [string]::IsNullOrWhiteSpace($pass)) {
        return $pass
    }

    if (Test-Path $DpapiPath) {
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
        }
    }

    return ""
}

function Get-RawPayload {
    if ($null -ne $NotifyArgs) {
        if ($NotifyArgs.Count -gt 0) {
            return ($NotifyArgs -join " ")
        }
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

function Get-JsonFieldLoose {
    param(
        [string]$Raw,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return ""
    }

    $pattern = '"' + [regex]::Escape($Name) + '"\s*:\s*"((?:\\.|[^"\\])*)"?'
    $m = [regex]::Match($Raw, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)

    if ($m.Success) {
        $v = $m.Groups[1].Value
        try {
            return [regex]::Unescape($v)
        } catch {
            return $v
        }
    }

    return ""
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

    $last = Get-Prop $Obj "last_assistant_message"
    if (-not [string]::IsNullOrWhiteSpace($last)) {
        return [string]$last
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

    $payload = Get-Prop $Obj "payload"
    if ($null -ne $payload) {
        $t = Extract-AssistantTextFromObject $payload
        if (-not [string]::IsNullOrWhiteSpace($t)) {
            return $t
        }
    }

    $item = Get-Prop $Obj "item"
    if ($null -ne $item) {
        $t = Extract-AssistantTextFromObject $item
        if (-not [string]::IsNullOrWhiteSpace($t)) {
            return $t
        }
    }

    $response = Get-Prop $Obj "response"
    if ($null -ne $response) {
        $output = Get-Prop $response "output"
        if ($null -ne $output) {
            $t = Convert-ContentToText $output
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

    $candidatePaths = @()
    $candidatePaths += $TranscriptPath

    $normalPath = Normalize-DisplayPath $TranscriptPath
    if (-not [string]::IsNullOrWhiteSpace($normalPath)) {
        $candidatePaths += $normalPath
    }

    foreach ($p in $candidatePaths) {
        try {
            if (-not (Test-Path -LiteralPath $p)) {
                continue
            }

            $lines = @()

            try {
                $lines = @(Get-Content -LiteralPath $p -Tail 800 -Encoding UTF8)
            } catch {
                $lines = @(Get-Content -LiteralPath $p -Tail 800)
            }

            for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                $line = $lines[$i]

                if ([string]::IsNullOrWhiteSpace($line)) {
                    continue
                }

                try {
                    $obj = $line | ConvertFrom-Json -ErrorAction Stop
                    $t = Extract-AssistantTextFromObject $obj

                    if (-not [string]::IsNullOrWhiteSpace($t)) {
                        return $t.Trim()
                    }
                } catch {
                }
            }
        } catch {
            Write-NotifyLog "Transcript parse failed: $($_.Exception.Message)"
        }
    }

    return ""
}

function Send-NtfySingle {
    param(
        [string]$Title,
        [string]$Message,
        [string]$Priority = "4",
        [string]$Tags = "robot"
    )

    $pass = Get-Password

    if ([string]::IsNullOrWhiteSpace($pass)) {
        Write-NotifyLog "Exit: password is empty"
        return
    }

    $Pair  = "${User}:${pass}"
    $Basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Pair))
    $BodyBytes = [Text.Encoding]::UTF8.GetBytes($Message)

    try {
        Invoke-RestMethod `
          -Method Post `
          -Uri "$Server/$Topic" `
          -Headers @{
            Authorization = "Basic $Basic"
            Title         = $Title
            Priority      = $Priority
            Tags          = $Tags
          } `
          -ContentType "text/plain; charset=utf-8" `
          -Body $BodyBytes | Out-Null

        Write-NotifyLog "ntfy send success. Title=$Title"
    } catch {
        Write-NotifyLog "ntfy send failed: $($_.Exception.Message)"
    }
}

function Send-NtfyLong {
    param(
        [string]$Title,
        [string]$Message,
        [string]$Priority = "4",
        [string]$Tags = "robot"
    )

    if ([string]::IsNullOrEmpty($Message)) {
        Send-NtfySingle -Title $Title -Message "" -Priority $Priority -Tags $Tags
        return
    }

    if ($Message.Length -le $ChunkSize) {
        Send-NtfySingle -Title $Title -Message $Message -Priority $Priority -Tags $Tags
        return
    }

    $total = [Math]::Ceiling($Message.Length / $ChunkSize)

    for ($i = 0; $i -lt $total; $i++) {
        $start = $i * $ChunkSize
        $len = [Math]::Min($ChunkSize, $Message.Length - $start)
        $chunk = $Message.Substring($start, $len)
        $chunkTitle = "$Title [$($i + 1)/$total]"

        Send-NtfySingle `
          -Title $chunkTitle `
          -Message $chunk `
          -Priority $Priority `
          -Tags $Tags
    }
}

Write-NotifyLog "==== notify script invoked ===="

if ([string]::IsNullOrWhiteSpace($Server) -or [string]::IsNullOrWhiteSpace($Topic) -or [string]::IsNullOrWhiteSpace($User)) {
    Write-NotifyLog "Exit: ntfy url/topic/user config missing"
    exit 0
}

$raw = Get-RawPayload
Write-NotifyLog "RawLength=$($raw.Length)"
Write-NotifyLog "RawPreview=$($raw.Substring(0, [Math]::Min($raw.Length, 500)))"

if ([string]::IsNullOrWhiteSpace($raw)) {
    Send-NtfySingle -Title "Codex hook fired" -Message "Codex hook fired, but payload was empty."
    exit 0
}

$json = $null
$jsonOk = $false

try {
    $json = $raw | ConvertFrom-Json -ErrorAction Stop
    $jsonOk = $true
    Write-NotifyLog "JSON parse success"
} catch {
    Write-NotifyLog "JSON parse failed: $($_.Exception.Message)"
}

$event = ""
$cwd = ""
$model = ""
$transcript = ""
$hookLast = ""

if ($jsonOk) {
    if ($json.PSObject.Properties["hook_event_name"]) {
        $event = [string]$json.PSObject.Properties["hook_event_name"].Value
    }
    if ($json.PSObject.Properties["cwd"]) {
        $cwd = [string]$json.PSObject.Properties["cwd"].Value
    }
    if ($json.PSObject.Properties["model"]) {
        $model = [string]$json.PSObject.Properties["model"].Value
    }
    if ($json.PSObject.Properties["transcript_path"]) {
        $transcript = [string]$json.PSObject.Properties["transcript_path"].Value
    }
    if ($json.PSObject.Properties["last_assistant_message"]) {
        $hookLast = [string]$json.PSObject.Properties["last_assistant_message"].Value
    }
} else {
    $event = Get-JsonFieldLoose -Raw $raw -Name "hook_event_name"
    $cwd = Get-JsonFieldLoose -Raw $raw -Name "cwd"
    $model = Get-JsonFieldLoose -Raw $raw -Name "model"
    $transcript = Get-JsonFieldLoose -Raw $raw -Name "transcript_path"
    $hookLast = Get-JsonFieldLoose -Raw $raw -Name "last_assistant_message"
}

$transcriptDisplay = Normalize-DisplayPath $transcript

Write-NotifyLog "Event=$event"
Write-NotifyLog "Cwd=$cwd"
Write-NotifyLog "Model=$model"
Write-NotifyLog "TranscriptDisplay=$transcriptDisplay"

if ($event -ne "Stop") {
    Write-NotifyLog "Ignored event: $event"
    exit 0
}

# 忽略内部标题生成等辅助 Stop
if ([string]::IsNullOrWhiteSpace($transcript) -and $model -match "mini") {
    Write-NotifyLog "Ignored auxiliary stop event: model=$model transcript is empty"
    exit 0
}

# 优先从 transcript 读取最后一条 assistant 输出，避免 hook payload 中文乱码
$assistantText = Get-LastAssistantTextFromTranscript $transcript

# 如果 transcript 读不到，再用 hook payload 里的 last_assistant_message
if ([string]::IsNullOrWhiteSpace($assistantText)) {
    $assistantText = $hookLast
}

if ([string]::IsNullOrWhiteSpace($assistantText)) {
    $assistantText = "未能提取 Codex 输出。请回到 PC 端查看结果。"
}

$timeText = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

$parts = @()
$parts += "状态: Codex 任务已完成"
$parts += "时间: $timeText"

if (-not [string]::IsNullOrWhiteSpace($cwd)) {
    $parts += "目录: $cwd"
}

if (-not [string]::IsNullOrWhiteSpace($model)) {
    $parts += "模型: $model"
}

if (-not [string]::IsNullOrWhiteSpace($transcriptDisplay)) {
    $parts += "记录: $transcriptDisplay"
}

$parts += ""
$parts += "==== Codex 输出 ===="
$parts += $assistantText

$msg = ($parts -join "`n")
$title = "Codex done $((Get-Date).ToString('HH:mm:ss'))"

Send-NtfyLong `
  -Title $title `
  -Message $msg `
  -Priority "4" `
  -Tags "robot"

exit 0

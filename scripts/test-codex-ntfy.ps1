param(
    [switch]$KeepArtifacts
)

# Self-contained, loopback-only validation. It never reads an owner's ntfy
# files, contacts an external endpoint, or prints a password/auth header.
$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$IngressPath = Join-Path $RepoRoot "templates\notify-ntfy.ps1"
$WorkerPath = Join-Path $RepoRoot "templates\notify-ntfy-worker.ps1"
$InstallerPath = Join-Path $PSScriptRoot "install-codex-ntfy.ps1"
$TestRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-ntfy-notifier-test-" + [guid]::NewGuid().ToString("N"))
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Assert-That {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw "ASSERTION_FAILED: $Message"
    }
}

function Write-TestText {
    param(
        [string]$Path,
        [string]$Text
    )
    New-Item -ItemType Directory -Force (Split-Path -Parent $Path) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Wait-Until {
    param(
        [scriptblock]$Condition,
        [int]$TimeoutSec = 10
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (& $Condition) {
            return $true
        }
        Start-Sleep -Milliseconds 100
    }
    return (& $Condition)
}

function New-TestPayload {
    param(
        [string]$TranscriptPath,
        [string]$Fallback = "Safe fallback markdown",
        [string]$ToolMarker = "RAW_TOOL_INPUT_MUST_NOT_PERSIST"
    )
    return ([ordered]@{
        hook_event_name = "Stop"
        session_id = "session-test-123"
        turn_id = "turn-test-456"
        cwd = "V:\\safe-test-cwd"
        model = "test-model"
        transcript_path = $TranscriptPath
        last_assistant_message = $Fallback
        tool_input = $ToolMarker
        tool_output = "RAW_TOOL_OUTPUT_MUST_NOT_PERSIST"
    } | ConvertTo-Json -Compress)
}

function Invoke-TestIngress {
    param(
        [string]$CodexDir,
        [string]$RuntimeRoot,
        [string]$Payload,
        [string]$WorkerOverride
    )
    $arguments = @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", $IngressPath, "-CodexDir", $CodexDir, "-RuntimeRoot", $RuntimeRoot)
    if (-not [string]::IsNullOrWhiteSpace($WorkerOverride)) {
        $arguments += @("-WorkerPath", $WorkerOverride)
    }

    # Validate and canonicalize the synthetic JSON before it crosses the
    # process boundary; this keeps the test failure local and diagnosable.
    try {
        $Payload = ($Payload | ConvertFrom-Json -ErrorAction Stop | ConvertTo-Json -Compress)
    } catch {
        throw "Synthetic Hook payload was not valid JSON."
    }

    # StandardInput is redirected explicitly so this is a real Hook-stdin
    # exercise rather than PowerShell's host-dependent native-pipeline behavior.
    $quotedArguments = $arguments | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' }
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = (Get-Command powershell.exe).Source
    $startInfo.Arguments = $quotedArguments -join " "
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($startInfo)
    $payloadBytes = $Utf8NoBom.GetBytes($Payload)
    $inputStream = $process.StandardInput.BaseStream
    $inputStream.Write($payloadBytes, 0, $payloadBytes.Length)
    $inputStream.Dispose()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $exitCode = $process.ExitCode
    $watch.Stop()
    Assert-That ($exitCode -eq 0) "Ingress exited with $($exitCode): $stdout $stderr"
    return [pscustomobject]@{ Milliseconds = $watch.Elapsed.TotalMilliseconds; ExitCode = $exitCode }
}

function Set-TestNtfyConfig {
    param(
        [string]$CodexDir,
        [string]$Url
    )
    New-Item -ItemType Directory -Force $CodexDir | Out-Null
    Write-TestText (Join-Path $CodexDir "ntfy-url.txt") ($Url + "`n")
    Write-TestText (Join-Path $CodexDir "ntfy-topic.txt") "test-topic`n"
    Write-TestText (Join-Path $CodexDir "ntfy-user.txt") "test-user`n"
    $secure = ConvertTo-SecureString "test-only-password" -AsPlainText -Force
    $protectedText = $secure | ConvertFrom-SecureString
    Write-TestText (Join-Path $CodexDir "ntfy-pass.dpapi") ($protectedText + "`n")
}

function Get-OpenLoopbackPort {
    $listener = New-Object System.Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0
    $listener.Start()
    try {
        return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

function Get-RuntimeJsonText {
    param([string]$RuntimeRoot)
    $files = @(Get-ChildItem -LiteralPath $RuntimeRoot -Recurse -Filter "*.json" -File -ErrorAction SilentlyContinue)
    return ($files | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n"
}

$originalEnvironment = @{}
$loopbackJob = $null
foreach ($name in @("NTFY_CODEX_URL", "NTFY_CODEX_TOPIC", "NTFY_CODEX_USER", "NTFY_CODEX_PASS", "NTFY_CODEX_ALLOW_INSECURE_LOOPBACK", "NTFY_CODEX_WORKER_TIMEOUT_SEC", "CODEX_NTFY_RUNTIME_ROOT")) {
    $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}

try {
    New-Item -ItemType Directory -Force $TestRoot | Out-Null
    $codexDir = Join-Path $TestRoot "codex"
    $runtimeRoot = Join-Path $TestRoot "runtime"
    $pendingDir = Join-Path $runtimeRoot "spool\pending"
    $failedDir = Join-Path $runtimeRoot "spool\failed"
    $receiptsDir = Join-Path $runtimeRoot "receipts"
    $phasePath = Join-Path $TestRoot "test-phase.txt"

    $holdingWorker = Join-Path $TestRoot "holding-worker.ps1"
    Write-TestText $holdingWorker @'
param([string]$EnvelopePath, [string]$RuntimeRoot, [string]$CodexDir)
Start-Sleep -Seconds 3
'@

    # A. Safe payload capture: only the bounded v1 envelope is written.
    Write-TestText $phasePath "payload_capture"
    $capturePayload = New-TestPayload -TranscriptPath "V:\\private\\transcript.json" -Fallback "## Safe fallback"
    $capture = Invoke-TestIngress -CodexDir $codexDir -RuntimeRoot $runtimeRoot -Payload $capturePayload -WorkerOverride $holdingWorker
    $envelopeFile = @(Get-ChildItem -LiteralPath $pendingDir -Filter "*.json" -File | Select-Object -First 1)[0]
    Assert-That ($null -ne $envelopeFile) "Ingress did not publish an envelope"
    $envelope = Get-Content -LiteralPath $envelopeFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-That ([int]$envelope.schema_version -eq 1) "Envelope schema version is not 1"
    Assert-That ($envelope.source -eq "codex" -and $envelope.event -eq "Stop") "Envelope source/event mismatch"
    Assert-That ($envelope.session_id -eq "session-test-123" -and $envelope.turn_id -eq "turn-test-456") "Envelope correlation fields missing"
    $runtimeJson = Get-RuntimeJsonText $runtimeRoot
    Assert-That (-not $runtimeJson.Contains("RAW_TOOL_INPUT_MUST_NOT_PERSIST")) "Raw tool input was persisted"
    Assert-That (-not $runtimeJson.Contains("RAW_TOOL_OUTPUT_MUST_NOT_PERSIST")) "Raw tool output was persisted"
    $payloadCaptureResult = "PASS"

    # B. P95 ingress timing with no endpoint configured or contacted.
    Write-TestText $phasePath "fast_return"
    $samples = New-Object System.Collections.Generic.List[double]
    for ($index = 0; $index -lt 5; $index++) {
        $result = Invoke-TestIngress -CodexDir $codexDir -RuntimeRoot $runtimeRoot -Payload (New-TestPayload -TranscriptPath "" -Fallback "Timing test") -WorkerOverride $holdingWorker
        [void]$samples.Add($result.Milliseconds)
    }
    $ordered = @($samples | Sort-Object)
    $p95Index = [Math]::Ceiling($ordered.Count * 0.95) - 1
    $ingressP95 = [Math]::Round($ordered[$p95Index], 2)
    Assert-That ($ingressP95 -lt 1000) "Ingress P95 $ingressP95 ms is not below 1000 ms"
    $fastReturnResult = "PASS"

    # C. The detached child still runs after its ingress process exits.
    Write-TestText $phasePath "detached_lifetime"
    $detachedWorker = Join-Path $TestRoot "detached-worker.ps1"
    $markerPath = Join-Path $runtimeRoot "detached-worker.marker"
    Write-TestText $detachedWorker @'
param([string]$EnvelopePath, [string]$RuntimeRoot, [string]$CodexDir)
Start-Sleep -Milliseconds 700
[IO.File]::WriteAllText((Join-Path $RuntimeRoot "detached-worker.marker"), "done")
'@
    $detached = Invoke-TestIngress -CodexDir $codexDir -RuntimeRoot $runtimeRoot -Payload (New-TestPayload -TranscriptPath "" -Fallback "Detached test") -WorkerOverride $detachedWorker
    Assert-That (-not (Test-Path -LiteralPath $markerPath)) "Detached worker completed before ingress returned"
    Assert-That (Wait-Until { Test-Path -LiteralPath $markerPath } 5) "Detached worker did not continue after ingress exit"
    $detachedWorkerResult = "PASS"

    # Use independent roots for workers that consume their envelope.
    $deliveryRuntime = Join-Path $TestRoot "delivery-runtime"
    Write-TestText $phasePath "loopback_delivery"
    $deliveryCodex = Join-Path $TestRoot "delivery-codex"
    $port = Get-OpenLoopbackPort
    $capturePath = Join-Path $TestRoot "loopback-capture.json"
    $loopbackJob = Start-Job -ScriptBlock {
        param($ListenerPort, $OutputPath)
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://127.0.0.1:$ListenerPort/")
        $listener.Start()
        try {
            $context = $listener.GetContext()
            $reader = New-Object IO.StreamReader($context.Request.InputStream, $context.Request.ContentEncoding)
            try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
            $result = [pscustomobject]@{ Markdown = $context.Request.Headers["Markdown"]; Body = $body }
            [IO.File]::WriteAllText($OutputPath, ($result | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
            $bytes = [Text.Encoding]::UTF8.GetBytes('{"id":"test"}')
            $context.Response.StatusCode = 200
            $context.Response.ContentType = "application/json; charset=utf-8"
            $context.Response.ContentLength64 = $bytes.Length
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $context.Response.Close()
        } finally {
            $listener.Stop()
        }
    } -ArgumentList $port, $capturePath
    Set-TestNtfyConfig -CodexDir $deliveryCodex -Url "http://127.0.0.1:$port"
    $env:NTFY_CODEX_ALLOW_INSECURE_LOOPBACK = "1"
    $transcriptPath = Join-Path $TestRoot "synthetic-transcript.jsonl"
    Write-TestText $transcriptPath (([ordered]@{ role = "assistant"; content = "## Transcript-derived output`n`n- **Markdown preserved**" } | ConvertTo-Json -Compress) + "`n")
    $loopback = Invoke-TestIngress -CodexDir $deliveryCodex -RuntimeRoot $deliveryRuntime -Payload (New-TestPayload -TranscriptPath $transcriptPath -Fallback "Fallback should not win") -WorkerOverride $WorkerPath
    Assert-That (Wait-Until { @(Get-ChildItem -LiteralPath (Join-Path $deliveryRuntime "receipts") -Filter "*.json" -File -ErrorAction SilentlyContinue).Count -ge 1 } 10) "Worker did not write loopback receipt"
    Assert-That (Wait-Until { Test-Path -LiteralPath $capturePath } 5) "Loopback server did not receive a request"
    $loopbackReceipt = Get-ChildItem -LiteralPath (Join-Path $deliveryRuntime "receipts") -Filter "*.json" -File | Select-Object -Last 1 | Get-Content -Raw | ConvertFrom-Json
    $loopbackCapture = Get-Content -LiteralPath $capturePath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-That ($loopbackReceipt.status -eq "success") "Loopback worker receipt is not success"
    Assert-That ($loopbackCapture.Markdown -eq "yes") "Markdown header was not preserved"
    Assert-That ($loopbackCapture.Body.Contains("## Codex task finished") -and $loopbackCapture.Body.Contains("**Markdown preserved**")) "Transcript Markdown was not delivered"
    Assert-That (@(Get-ChildItem -LiteralPath (Join-Path $deliveryRuntime "spool\pending") -Filter "*.json" -File -ErrorAction SilentlyContinue).Count -eq 0) "Successful envelope remains pending"
    Remove-Job -Job $loopbackJob -Force -ErrorAction SilentlyContinue
    $loopbackDeliveryResult = "PASS"

    # E. Unreachable network affects only the detached worker.
    $failureRuntime = Join-Path $TestRoot "failure-runtime"
    Write-TestText $phasePath "network_failure"
    $failureCodex = Join-Path $TestRoot "failure-codex"
    $unreachablePort = Get-OpenLoopbackPort
    Set-TestNtfyConfig -CodexDir $failureCodex -Url "http://127.0.0.1:$unreachablePort"
    $env:NTFY_CODEX_WORKER_TIMEOUT_SEC = "2"
    $networkFailure = Invoke-TestIngress -CodexDir $failureCodex -RuntimeRoot $failureRuntime -Payload (New-TestPayload -TranscriptPath "" -Fallback "Network isolation") -WorkerOverride $WorkerPath
    Assert-That ($networkFailure.Milliseconds -lt 1000) "Network failure delayed ingress for $($networkFailure.Milliseconds) ms"
    Assert-That (Wait-Until { @(Get-ChildItem -LiteralPath (Join-Path $failureRuntime "spool\failed") -Filter "*.json" -File -ErrorAction SilentlyContinue).Count -eq 1 } 10) "Failed delivery was not retained"
    $failureReceipt = Get-ChildItem -LiteralPath (Join-Path $failureRuntime "receipts") -Filter "*.json" -File | Select-Object -Last 1 | Get-Content -Raw | ConvertFrom-Json
    Assert-That ($failureReceipt.status -eq "failure" -and $failureReceipt.error_code -eq "NETWORK_DELIVERY_FAILED") "Network failure receipt is not sanitized/correct"
    $networkFailureResult = "PASS"

    # F. HTTPS remains mandatory outside the explicit loopback test gate.
    $httpsRuntime = Join-Path $TestRoot "https-runtime"
    Write-TestText $phasePath "https_policy"
    $httpsCodex = Join-Path $TestRoot "https-codex"
    Set-TestNtfyConfig -CodexDir $httpsCodex -Url "http://example.invalid"
    Remove-Item Env:NTFY_CODEX_ALLOW_INSECURE_LOOPBACK -ErrorAction SilentlyContinue
    Invoke-TestIngress -CodexDir $httpsCodex -RuntimeRoot $httpsRuntime -Payload (New-TestPayload -TranscriptPath "" -Fallback "HTTPS policy") -WorkerOverride $WorkerPath | Out-Null
    Assert-That (Wait-Until { @(Get-ChildItem -LiteralPath (Join-Path $httpsRuntime "receipts") -Filter "*.json" -File -ErrorAction SilentlyContinue).Count -eq 1 } 10) "HTTPS policy worker did not write receipt"
    $httpsReceipt = Get-ChildItem -LiteralPath (Join-Path $httpsRuntime "receipts") -Filter "*.json" -File | Select-Object -Last 1 | Get-Content -Raw | ConvertFrom-Json
    Assert-That ($httpsReceipt.error_code -eq "CONFIG_URL_HTTPS_REQUIRED") "HTTPS enforcement changed"
    $existingBehaviorResult = "PASS"

    # G. Installer upgrades the exact owned hook once, preserves unrelated
    # hooks, migrates its legacy notify declaration, and remains idempotent.
    $installerCodex = Join-Path $TestRoot "installer-codex"
    Write-TestText $phasePath "installer_idempotence"
    New-Item -ItemType Directory -Force $installerCodex | Out-Null
    $escapedInstallerCodex = $installerCodex
    Write-TestText (Join-Path $installerCodex "config.toml") @"
notify = [
  'powershell.exe',
  '-File',
  '$escapedInstallerCodex\notify-ntfy.ps1',
  '-CodexDir',
  '$escapedInstallerCodex',
]

[features]
apps = true
"@
    $initialHooks = [ordered]@{
        hooks = [ordered]@{
            Stop = @(
                [ordered]@{ hooks = @([ordered]@{ type = "command"; command = "cmd.exe /c `"$installerCodex\notify-ntfy.cmd`""; timeout = 30 }) },
                [ordered]@{ hooks = @([ordered]@{ type = "command"; command = "tabbeacon.exe hook codex"; timeout = 1; async = $true }) }
            )
            UserPromptSubmit = @([ordered]@{ hooks = @([ordered]@{ type = "command"; command = "wt-agent-hooks.exe prompt"; timeout = 1 }) })
        }
    }
    Write-TestText (Join-Path $installerCodex "hooks.json") (($initialHooks | ConvertTo-Json -Depth 10) + "`n")
    $installerPassword = ConvertTo-SecureString "test-only-password" -AsPlainText -Force
    & $InstallerPath -NtfyUrl "https://example.invalid" -Topic "test-topic" -User "test-user" -Password $installerPassword -CodexDir $installerCodex | Out-Null
    & $InstallerPath -NtfyUrl "https://example.invalid" -Topic "test-topic" -User "test-user" -Password $installerPassword -CodexDir $installerCodex | Out-Null
    Assert-That (Test-Path -LiteralPath (Join-Path $installerCodex "notify-ntfy-worker.ps1")) "Installer did not copy worker"
    $installedHooks = Get-Content -LiteralPath (Join-Path $installerCodex "hooks.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $installedStopHooks = @($installedHooks.hooks.Stop | ForEach-Object { @($_.hooks) })
    $ownedHooks = @($installedStopHooks | Where-Object { $_.command -match '(?i)notify-ntfy\.ps1' })
    Assert-That ($ownedHooks.Count -eq 1) "Installer duplicated the owned Stop hook"
    Assert-That ($ownedHooks[0].timeout -eq 5 -and $ownedHooks[0].statusMessage -eq "Queueing phone notification") "Installed hook contract is wrong"
    Assert-That (@($installedStopHooks | Where-Object { $_.command -eq "tabbeacon.exe hook codex" }).Count -eq 1) "TabBeacon hook was not preserved"
    Assert-That (@($installedHooks.hooks.UserPromptSubmit[0].hooks | Where-Object { $_.command -eq "wt-agent-hooks.exe prompt" }).Count -eq 1) "Unrelated hook was not preserved"
    $installedConfig = Get-Content -LiteralPath (Join-Path $installerCodex "config.toml") -Raw -Encoding UTF8
    Assert-That ($installedConfig -notmatch '(?m)^\s*notify\s*=') "Exact owned legacy notify declaration was not migrated"
    Assert-That ($installedConfig -match '(?m)^hooks\s*=\s*true') "Installer did not enable Hooks"
    Assert-That (@(Get-ChildItem -LiteralPath (Join-Path $installerCodex "backups") -Directory -ErrorAction SilentlyContinue).Count -ge 1) "Installer did not create backup"
    $installerIdempotenceResult = "PASS"
    $unrelatedHooksResult = "PASS"

    Write-Host "PAYLOAD_CAPTURE_TEST=$payloadCaptureResult"
    Write-Host "TARGET_INGRESS_P95_LT_MS=1000 ACTUAL_INGRESS_P95_MS=$ingressP95"
    Write-Host "INGRESS_FAST_RETURN_TEST=$fastReturnResult"
    Write-Host "DETACHED_WORKER_TEST=$detachedWorkerResult"
    Write-Host "LOOPBACK_DELIVERY_TEST=$loopbackDeliveryResult"
    Write-Host "NETWORK_FAILURE_ISOLATION_TEST=$networkFailureResult"
    Write-Host "EXISTING_BEHAVIOR_TEST=$existingBehaviorResult"
    Write-Host "INSTALLER_IDEMPOTENCE=$installerIdempotenceResult"
    Write-Host "UNRELATED_HOOKS_PRESERVED=$unrelatedHooksResult"
    Write-Host "LOCAL_VALIDATION=PASS"
} finally {
    foreach ($name in $originalEnvironment.Keys) {
        if ($null -eq $originalEnvironment[$name]) {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name])
        }
    }
    if ($null -ne $loopbackJob) {
        Stop-Job -Job $loopbackJob -ErrorAction SilentlyContinue
        Remove-Job -Job $loopbackJob -Force -ErrorAction SilentlyContinue
    }
    if (-not $KeepArtifacts -and (Test-Path -LiteralPath $TestRoot)) {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force
    } elseif ($KeepArtifacts) {
        Write-Host "TEST_ARTIFACT_ROOT=$TestRoot"
    }
}

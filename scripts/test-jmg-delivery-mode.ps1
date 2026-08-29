param(
    [switch]$KeepArtifacts,
    [string]$TestRoot
)

# Isolated local contract test: synthetic envelopes only, no real provider.
$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$IngressPath = Join-Path $RepoRoot "templates\notify-ntfy.ps1"
$WorkerPath = Join-Path $RepoRoot "templates\notify-ntfy-worker.ps1"
$InstallerPath = Join-Path $PSScriptRoot "install-codex-ntfy.ps1"
if ([string]::IsNullOrWhiteSpace($TestRoot)) {
    $TestRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-ntfy-jmg-mode-test-" + [guid]::NewGuid().ToString("N"))
}
$Utf8NoBom = [Text.UTF8Encoding]::new($false)

function Assert-That {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "assertion_failed:$Message" }
}

function Write-TestText {
    param([string]$Path, [string]$Text)
    New-Item -ItemType Directory -Force (Split-Path -Parent $Path) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function New-TestPayload {
    return ([ordered]@{
        hook_event_name = "Stop"
        session_id = "synthetic-session"
        turn_id = "synthetic-turn"
        cwd = "V:\synthetic"
        model = "synthetic-model"
        transcript_path = ""
        last_assistant_message = "synthetic message"
    } | ConvertTo-Json -Compress)
}

function Invoke-TestIngress {
    param([string]$CodexDir, [string]$RuntimeRoot, [string]$WorkerOverride, [string]$Payload)

    $argumentValues = @(
        "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", $IngressPath,
        "-CodexDir", $CodexDir,
        "-RuntimeRoot", $RuntimeRoot,
        "-WorkerPath", $WorkerOverride
    )
    $quotedArguments = $argumentValues | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command powershell.exe).Source
    $startInfo.Arguments = $quotedArguments -join " "
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($startInfo)
    try {
        $bytes = $Utf8NoBom.GetBytes($Payload)
        $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $process.StandardInput.BaseStream.Dispose()
        $null = $process.StandardOutput.ReadToEnd()
        $null = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        Assert-That ($process.ExitCode -eq 0) "ingress returned a nonzero exit code"
    } finally {
        $process.Dispose()
    }
}

function Invoke-DirectWorker {
    param([string]$EnvelopePath, [string]$RuntimeRoot, [string]$CodexDir)
    $output = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $WorkerPath -EnvelopePath $EnvelopePath -RuntimeRoot $RuntimeRoot -CodexDir $CodexDir 2>&1)
    Assert-That ($LASTEXITCODE -eq 0) "jmg-mode direct worker did not exit cleanly"
    $null = $output
}

function Wait-Until {
    param([scriptblock]$Condition, [int]$TimeoutSec = 5)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return (& $Condition)
}

try {
    New-Item -ItemType Directory -Force $TestRoot | Out-Null

    $jmgCodex = Join-Path $TestRoot "jmg-codex"
    $jmgRuntime = Join-Path $TestRoot "jmg-runtime"
    $jmgPending = Join-Path $jmgRuntime "spool\pending"
    $jmgProcessing = Join-Path $jmgRuntime "spool\processing"
    $jmgProbeWorker = Join-Path $TestRoot "jmg-probe-worker.ps1"
    $jmgProbeMarker = Join-Path $jmgRuntime "jmg-probe-marker.txt"
    Write-TestText (Join-Path $jmgCodex "delivery-mode.txt") "jmg`n"
    Write-TestText $jmgProbeWorker @'
param([string]$EnvelopePath, [string]$RuntimeRoot, [string]$CodexDir)
[IO.File]::WriteAllText((Join-Path $RuntimeRoot "jmg-probe-marker.txt"), "started")
'@

    Invoke-TestIngress -CodexDir $jmgCodex -RuntimeRoot $jmgRuntime -WorkerOverride $jmgProbeWorker -Payload (New-TestPayload)
    $jmgEnvelope = @(Get-ChildItem -LiteralPath $jmgPending -Filter "*.json" -File)
    Assert-That ($jmgEnvelope.Count -eq 1) "jmg mode did not leave exactly one pending envelope"
    Assert-That (-not (Test-Path -LiteralPath $jmgProbeMarker)) "jmg mode launched the direct worker"
    Assert-That (@(Get-ChildItem -LiteralPath $jmgProcessing -Filter "*.json" -File -ErrorAction SilentlyContinue).Count -eq 0) "jmg mode moved an envelope before adapter claim"

    Invoke-DirectWorker -EnvelopePath $jmgEnvelope[0].FullName -RuntimeRoot $jmgRuntime -CodexDir $jmgCodex
    Assert-That (Test-Path -LiteralPath $jmgEnvelope[0].FullName) "jmg-mode direct worker consumed the pending envelope"
    Assert-That (@(Get-ChildItem -LiteralPath $jmgProcessing -Filter "*.json" -File -ErrorAction SilentlyContinue).Count -eq 0) "jmg-mode direct worker claimed an envelope"
    Assert-That (@(Get-ChildItem -LiteralPath (Join-Path $jmgRuntime "receipts") -Filter "*.json" -File -ErrorAction SilentlyContinue).Count -eq 0) "jmg-mode direct worker wrote a delivery receipt"

    $adapterClaims = Join-Path $jmgRuntime "jmg-adapter-claims"
    New-Item -ItemType Directory -Force $adapterClaims | Out-Null
    $claimPath = Join-Path $adapterClaims $jmgEnvelope[0].Name
    [IO.File]::Move($jmgEnvelope[0].FullName, $claimPath)
    Invoke-DirectWorker -EnvelopePath $jmgEnvelope[0].FullName -RuntimeRoot $jmgRuntime -CodexDir $jmgCodex
    Assert-That (Test-Path -LiteralPath $claimPath) "direct worker raced a JMG adapter claim"
    Assert-That (@(Get-ChildItem -LiteralPath $jmgPending -Filter "*.json" -File -ErrorAction SilentlyContinue).Count -eq 0) "adapter claim was not exclusive"

    $legacyCodex = Join-Path $TestRoot "legacy-codex"
    $legacyRuntime = Join-Path $TestRoot "legacy-runtime"
    $legacyProbeWorker = Join-Path $TestRoot "legacy-probe-worker.ps1"
    $legacyProbeMarker = Join-Path $legacyRuntime "legacy-probe-marker.txt"
    Write-TestText (Join-Path $legacyCodex "delivery-mode.txt") "legacy-direct`n"
    Write-TestText $legacyProbeWorker @'
param([string]$EnvelopePath, [string]$RuntimeRoot, [string]$CodexDir)
[IO.File]::WriteAllText((Join-Path $RuntimeRoot "legacy-probe-marker.txt"), "started")
'@

    Invoke-TestIngress -CodexDir $legacyCodex -RuntimeRoot $legacyRuntime -WorkerOverride $legacyProbeWorker -Payload (New-TestPayload)
    Assert-That (Wait-Until { Test-Path -LiteralPath $legacyProbeMarker }) "legacy-direct rollback did not launch its worker"
    Assert-That (@(Get-ChildItem -LiteralPath (Join-Path $legacyRuntime "spool\pending") -Filter "*.json" -File -ErrorAction SilentlyContinue).Count -eq 1) "legacy-direct ingress did not preserve the envelope"

    $installerCodex = Join-Path $TestRoot "installer-codex"
    $syntheticPassword = ConvertTo-SecureString "synthetic-only" -AsPlainText -Force
    & $InstallerPath -NtfyUrl "https://example.invalid" -Topic "synthetic" -User "synthetic" -Password $syntheticPassword -CodexDir $installerCodex -NoBackup -DeliveryMode jmg | Out-Null
    Assert-That ((Get-Content -LiteralPath (Join-Path $installerCodex "delivery-mode.txt") -Raw -Encoding UTF8).Trim() -eq "jmg") "installer did not persist jmg mode"
    & $InstallerPath -NtfyUrl "https://example.invalid" -Topic "synthetic" -User "synthetic" -Password $syntheticPassword -CodexDir $installerCodex -NoBackup -DeliveryMode legacy-direct | Out-Null
    Assert-That ((Get-Content -LiteralPath (Join-Path $installerCodex "delivery-mode.txt") -Raw -Encoding UTF8).Trim() -eq "legacy-direct") "installer rollback did not persist legacy-direct"

    Write-Host "JMG_DELIVERY_MODE_TEST=PASS"
    Write-Host "JMG_MODE_ENVELOPE_PENDING=PASS"
    Write-Host "JMG_MODE_DIRECT_WORKER_INACTIVE=PASS"
    Write-Host "JMG_MODE_LEGACY_DIRECT_ROLLBACK=PASS"
    Write-Host "JMG_MODE_REAL_PROVIDER_CONTACTED=false"
} finally {
    if (-not $KeepArtifacts -and (Test-Path -LiteralPath $TestRoot)) {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force
    }
}

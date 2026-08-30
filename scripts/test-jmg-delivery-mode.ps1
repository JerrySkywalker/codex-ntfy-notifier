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
    $installerBackup = Join-Path $TestRoot "installer-backups"
    $installerSharedIngress = Join-Path $TestRoot "shared runtime\ingress\codex-ntfy"
    & $InstallerPath -CodexDir $installerCodex -NoBackup -DeliveryMode jmg -JmgRuntimeRoot $installerSharedIngress | Out-Null
    Assert-That ((Get-Content -LiteralPath (Join-Path $installerCodex "delivery-mode.txt") -Raw -Encoding UTF8).Trim() -eq "jmg") "installer did not persist jmg mode"
    Assert-That ((Get-Content -LiteralPath (Join-Path $installerCodex "jmg-runtime-root.txt") -Raw -Encoding UTF8).Trim() -eq $installerSharedIngress) "installer did not persist canonical JMG ingress root"
    $freshCredentialWriteCount = @(@("ntfy-url.txt", "ntfy-topic.txt", "ntfy-user.txt", "ntfy-pass.dpapi") | Where-Object { Test-Path -LiteralPath (Join-Path $installerCodex $_) }).Count
    Assert-That ($freshCredentialWriteCount -eq 0) "fresh jmg install wrote ntfy credentials"
    $installedJmgHooks = Get-Content -LiteralPath (Join-Path $installerCodex "hooks.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $installedJmgCommands = @($installedJmgHooks.hooks.Stop | ForEach-Object { @($_.hooks) } | ForEach-Object { [string]$_.command } | Where-Object { $_ -match '(?i)notify-ntfy\.ps1' })
    Assert-That ($installedJmgCommands.Count -eq 1 -and $installedJmgCommands[0].Contains("-RuntimeRoot `"$installerSharedIngress`"")) "jmg hook does not pass the quoted shared ingress root"
    Assert-That ($installedJmgCommands[0] -notmatch '(?i)ntfy-(url|topic|user|pass)') "jmg hook exposes credential configuration"
    Invoke-TestIngress -CodexDir $installerCodex -RuntimeRoot $installerSharedIngress -WorkerOverride $jmgProbeWorker -Payload (New-TestPayload)
    Assert-That (@(Get-ChildItem -LiteralPath (Join-Path $installerSharedIngress "spool\pending") -Filter "*.json" -File).Count -eq 1) "jmg installer selection did not enqueue to the shared spool"
    & $InstallerPath -CodexDir $installerCodex -NoBackup -DeliveryMode jmg | Out-Null
    Assert-That ((Get-Content -LiteralPath (Join-Path $installerCodex "jmg-runtime-root.txt") -Raw -Encoding UTF8).Trim() -eq $installerSharedIngress) "routine jmg upgrade did not preserve selected root"

    $relativeRootRejected = $false
    $relativeCodex = Join-Path $TestRoot "relative-root-codex"
    try { & $InstallerPath -CodexDir $relativeCodex -NoBackup -DeliveryMode jmg -JmgRuntimeRoot "relative-root" | Out-Null } catch { $relativeRootRejected = $_.Exception.Message -eq "JMG_RUNTIME_ROOT_MUST_BE_ABSOLUTE" }
    Assert-That ($relativeRootRejected -and -not (Test-Path -LiteralPath $relativeCodex)) "relative jmg runtime root was not rejected before mutation"
    $traversalRootRejected = $false
    $traversalCodex = Join-Path $TestRoot "traversal-root-codex"
    $traversalRoot = Join-Path $TestRoot "shared runtime\ingress\codex-ntfy\..\escape"
    try { & $InstallerPath -CodexDir $traversalCodex -NoBackup -DeliveryMode jmg -JmgRuntimeRoot $traversalRoot | Out-Null } catch { $traversalRootRejected = $_.Exception.Message -eq "JMG_RUNTIME_ROOT_TRAVERSAL_REJECTED" }
    Assert-That ($traversalRootRejected -and -not (Test-Path -LiteralPath $traversalCodex)) "traversal jmg runtime root was not rejected before mutation"
    $unsafeQuoteRejected = $false
    try { & $InstallerPath -CodexDir (Join-Path $TestRoot "quoted-root-codex") -NoBackup -DeliveryMode jmg -JmgRuntimeRoot ($installerSharedIngress + '"') | Out-Null } catch { $unsafeQuoteRejected = $_.Exception.Message -eq "JMG_RUNTIME_ROOT_UNSAFE_CHARACTERS" }
    Assert-That $unsafeQuoteRejected "quoted jmg runtime root was not rejected"
    $reparseCodex = Join-Path $TestRoot "reparse-root-codex"
    $reparseParent = Join-Path $TestRoot "reparse runtime\ingress"
    $reparseTarget = Join-Path $TestRoot "reparse-target"
    New-Item -ItemType Directory -Force -Path $reparseParent, $reparseTarget | Out-Null
    $reparseIngress = Join-Path $reparseParent "codex-ntfy"
    New-Item -ItemType Junction -Path $reparseIngress -Target $reparseTarget | Out-Null
    $reparseRootRejected = $false
    try { & $InstallerPath -CodexDir $reparseCodex -NoBackup -DeliveryMode jmg -JmgRuntimeRoot $reparseIngress | Out-Null } catch { $reparseRootRejected = $_.Exception.Message -eq "JMG_RUNTIME_ROOT_REPARSE_REJECTED" }
    Assert-That ($reparseRootRejected -and -not (Test-Path -LiteralPath $reparseCodex)) "reparse jmg runtime root was not rejected before mutation"

    $syntheticPassword = ConvertTo-SecureString "synthetic-only" -AsPlainText -Force
    & $InstallerPath -NtfyUrl "https://example.invalid" -Topic "synthetic" -User "synthetic" -Password $syntheticPassword -CodexDir $installerCodex -BackupRoot $installerBackup -DeliveryMode legacy-direct | Out-Null
    Assert-That ((Get-Content -LiteralPath (Join-Path $installerCodex "delivery-mode.txt") -Raw -Encoding UTF8).Trim() -eq "legacy-direct") "installer rollback did not persist legacy-direct"
    Assert-That ((Get-Content -LiteralPath (Join-Path $installerCodex "jmg-runtime-root.txt") -Raw -Encoding UTF8).Trim() -eq $installerSharedIngress) "legacy rollback did not preserve selected JMG root"
    $legacyHooks = Get-Content -LiteralPath (Join-Path $installerCodex "hooks.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $legacyCommands = @($legacyHooks.hooks.Stop | ForEach-Object { @($_.hooks) } | ForEach-Object { [string]$_.command } | Where-Object { $_ -match '(?i)notify-ntfy\.ps1' })
    Assert-That ($legacyCommands.Count -eq 1 -and $legacyCommands[0] -notmatch '(?i)\s-RuntimeRoot\s') "legacy-direct hook retained JMG runtime root"
    $selectionBackup = @(Get-ChildItem -LiteralPath $installerBackup -Directory | Sort-Object Name -Descending | Select-Object -First 1)[0]
    Assert-That ($null -ne $selectionBackup -and (Test-Path -LiteralPath (Join-Path $selectionBackup.FullName "delivery-mode.txt")) -and (Test-Path -LiteralPath (Join-Path $selectionBackup.FullName "jmg-runtime-root.txt"))) "backup omitted delivery selection"

    Write-Host "JMG_DELIVERY_MODE_TEST=PASS"
    Write-Host "JMG_MODE_ENVELOPE_PENDING=PASS"
    Write-Host "JMG_MODE_DIRECT_WORKER_INACTIVE=PASS"
    Write-Host "JMG_MODE_LEGACY_DIRECT_ROLLBACK=PASS"
    Write-Host "JMG_MODE_SHARED_RUNTIME_ROOT_CONTRACT=PASS"
    Write-Host "JMG_MODE_FRESH_INSTALL_NTFY_CREDENTIAL_WRITES=false"
    Write-Host "JMG_MODE_REAL_PROVIDER_CONTACTED=false"
} finally {
    if (-not $KeepArtifacts -and (Test-Path -LiteralPath $TestRoot)) {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force
    }
}

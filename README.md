# codex-ntfy-notifier

Send Codex completion notifications to an Android ntfy app without putting the
network on Codex's Stop-hook critical path.

```text
Codex Stop Hook
  -> synchronous local enqueue
  -> %LOCALAPPDATA%\CodexNtfyNotifier\spool\pending
  -> detached worker
  -> self-hosted HTTPS ntfy
  -> Android
```

The Stop hook performs local JSON normalization, an atomic envelope write, and
worker launch only. It does **not** resolve DNS, negotiate TLS, call ntfy, or
retry a network request. The installed Hook uses the visible status message
`Queueing phone notification` and a 5-second local-handoff timeout; normal
ingress is expected to be far below that bound.

## What is installed

The installer copies these runtime files to the selected user Codex directory
(normally `%USERPROFILE%\.codex`):

- `notify-ntfy.ps1` — synchronous local-only Hook ingress
- `notify-ntfy-worker.ps1` — detached transcript/DPAPI/Markdown/ntfy sender
- `notify-ntfy.cmd` — compatibility wrapper for legacy/manual invocation

The password remains a Windows DPAPI value in `ntfy-pass.dpapi`; it is neither
copied to this repository nor passed to the worker command line. Existing
`NTFY_CODEX_URL`, `NTFY_CODEX_TOPIC`, `NTFY_CODEX_USER`, and `NTFY_CODEX_PASS`
environment overrides still take precedence over the corresponding files.

## Install or upgrade

Run from a clone of this repository on each Windows machine:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-codex-ntfy.ps1
```

For a fresh install, the script asks for URL, topic, user, and password. On an
existing installation it preserves existing non-secret settings and the DPAPI
password unless explicitly replaced:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-codex-ntfy.ps1 `
  -NtfyUrl "https://ntfy.example.com" `
  -Topic "codex-topic" `
  -User "codex_notify"
```

Before mutation, the installer backs up `config.toml`, `hooks.json`, current
notifier scripts, and local notifier configuration under
`%USERPROFILE%\.codex\backups`. It enables Codex Hooks and updates only a
provably repository-owned `notify-ntfy` Stop hook. All unrelated hooks,
including TabBeacon and `wt-agent-hooks`, remain in place.

After installation, complete the normal Codex trust review:

```text
Codex /hooks -> review/trust the changed notifier Hook
```

The installer never bypasses that review and does not run a real Codex turn on
your behalf.

## Legacy `notify` migration

Current Codex installs use `hooks.json`; do not add the historical
`notify = [...]` template as well, because that can duplicate phone alerts.

If the installer finds the repository's exact old `notify-ntfy.ps1` declaration
in user `config.toml`, it backs it up and removes it as part of the Hook
migration. An unrelated or custom `notify` declaration is preserved and
reported as `LEGACY_NOTIFY_DISPOSITION=CONFLICT_PRESERVED` for owner review.

`templates/codex-config-snippet.toml` is intentionally a migration note, not a
second integration recipe.

## Local envelope and spool

Ingress writes one bounded, atomic JSON envelope. Version 1 has only:

```text
schema_version, id, created_at, source, event, session_id, turn_id,
cwd, model, transcript_path, fallback_message
```

`source` is `codex`; `event` preserves Stop and compatible manual-test events.
The envelope never contains the raw Hook payload, credentials, authorization
headers, or tool input/output. `fallback_message` is bounded to 8 KiB. The
worker reads the transcript only after Codex has completed, so transcript
parsing and assistant-output extraction remain off the Hook path.

Runtime state is outside the repository:

```text
%LOCALAPPDATA%\CodexNtfyNotifier\
  spool\pending
  spool\processing
  spool\failed
  receipts
  ingress.log
  worker.log
```

An envelope is first written to a temporary local file and then renamed into
`pending`, so workers never consume a partial write. Active and failed queues
are capped at 100 items; sanitized receipts are retained up to 200 items.
Failed delivery does not retry forever: the envelope remains recoverable in
`spool\failed` (or stays pending if that failed queue is full), and the receipt
records a generic failure code without endpoint or credential data.

The queued fallback message and transcript path are local user data. Protect
the user profile accordingly and delete failed items only after diagnosis.

## Test

Run the isolated suite before installing an update:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\scripts\test-codex-ntfy.ps1
```

It uses a temporary Codex directory plus an explicit loopback-only HTTP server.
It validates safe payload capture, fast ingress return, detached lifetime,
Markdown/transcript delivery, network-failure isolation, HTTPS enforcement,
DPAPI/config behavior, and installer idempotence. It does not read the owner's
real password or call an external ntfy server.

## Future JMG seam

`schema_version = 1` is an internal local notification-envelope contract, not
a JMG API. A future `jerry-message-gateway` adapter may consume the same queued
envelope in place of `notify-ntfy-worker.ps1`; the Codex ingress does not need
to change. JMG is not installed, called, copied, or required by this project.

## Repository boundaries

This repository contains templates, installer scripts, tests, and docs. It
must never contain DPAPI material, ntfy passwords, private topics, raw Hook
payloads, transcript contents, or runtime spool/receipt files. See
[docs/SECURITY.md](docs/SECURITY.md) for the security boundary.

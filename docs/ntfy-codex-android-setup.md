# ntfy + Codex Android Notification Setup

This document describes a generic setup for sending Codex hook notifications to Android via a self-hosted ntfy server.

## Architecture

Codex hook -> notify script -> ntfy server -> Android ntfy app

## Example values

- ntfy URL: https://ntfy.example.com
- topic: codex-topic
- user: codex_notify
- server IP: 203.0.113.10

Do not commit real passwords, API keys, DPAPI files, SSH keys, or machine-specific runtime files.

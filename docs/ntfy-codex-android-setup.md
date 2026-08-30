# ntfy + Codex Android Notification Setup

> **Historical/non-authoritative:** retained as evidence for the temporary
> `legacy-direct` setup. It is not the JMG v1 product architecture. Start with
> the [current documentation index](README.md) and
> [JMG adapter boundary](JMG_ADAPTER_BOUNDARY.md).

This document describes a generic setup for sending Codex hook notifications to Android via a self-hosted ntfy server.

## Architecture

Codex hook -> notify script -> ntfy server -> Android ntfy app

This direct path is a rollback capability. JMG is the future authoritative
message/history store; ntfy is only an external presentation transport and is
not an authoritative message store.

## Example values

- ntfy URL: https://ntfy.example.com
- topic: codex-topic
- user: codex_notify
- server IP: 203.0.113.10

Do not commit real passwords, API keys, DPAPI files, SSH keys, or machine-specific runtime files.

# Security Notes

- Do not commit `%USERPROFILE%\.codex\ntfy-pass.dpapi`.
- Do not commit server-side `/opt/ntfy/credentials.txt`.
- Do not commit SSH private keys, API keys, tokens, or `.env` files.
- Store SSH private keys outside this repository, with strict local filesystem permissions.
- Use an HTTPS ntfy URL. The notifier rejects non-HTTPS URLs except an explicitly enabled loopback-only validation endpoint.
- Default backups stay under the selected Codex directory rather than this repository; treat any backup containing DPAPI material as local secret data.
- If a secret is accidentally committed, rotate it immediately.


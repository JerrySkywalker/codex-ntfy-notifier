# Security Notes

- Do not commit `%USERPROFILE%\.codex\ntfy-pass.dpapi`.
- Do not commit server-side `/opt/ntfy/credentials.txt`.
- Do not commit SSH private keys, API keys, tokens, or `.env` files.
- Store SSH private keys under `C:\Dev\secrets\ssh` with strict NTFS permissions.
- If a secret is accidentally committed, rotate it immediately.

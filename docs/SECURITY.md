# Security Notes

- Never commit `%USERPROFILE%\.codex\ntfy-pass.dpapi`, ntfy passwords, private
  topics, API keys, SSH keys, tokens, or `.env` files.
- The worker loads the password from DPAPI (or the explicit process-local
  `NTFY_CODEX_PASS` override). It never receives a password, authorization
  header, or raw Hook JSON as a command-line argument.
- The local v1 envelope contains only bounded routing/display fields. It never
  persists the complete Hook payload or tool input/output. Its fallback text
  and transcript path are still private local user data.
- Runtime spool files, worker receipts, ingress logs, and worker logs belong
  under `%LOCALAPPDATA%\CodexNtfyNotifier`, never under this repository. Logs
  and receipts use generic/sanitized status codes rather than raw payloads,
  endpoints, or credentials.
- The worker rejects non-HTTPS ntfy endpoints. `http://` is accepted only for
  an explicit loopback test with `NTFY_CODEX_ALLOW_INSECURE_LOOPBACK=1`.
- Installer backups stay under the selected Codex directory. They can contain
  DPAPI material and must be treated as local secret data.
- If a secret is accidentally committed, revoke or rotate it immediately and
  follow the repository's incident process.

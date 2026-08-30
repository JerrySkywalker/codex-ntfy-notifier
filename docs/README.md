# Notifier documentation

This index separates the current notifier implementation from the approved JMG
v1 target. Status labels have the meanings established by the JMG architecture
freeze.

## Start here

- [JMG producer/capture-adapter boundary](JMG_ADAPTER_BOUNDARY.md) — canonical
  ownership, current-versus-target status, privacy, and authorization limits.
- [JMG delivery mode](jmg-delivery-mode.md) — currently implemented local
  delivery-ownership and rollback seam.
- [Security notes](SECURITY.md) — current repository and local-runtime boundary.
- [ntfy + Codex Android setup](ntfy-codex-android-setup.md) — retained
  historical guidance for the temporary `legacy-direct` path; non-authoritative
  for JMG v1 architecture.

The JMG repository owns the product, MessageEnvelope, routing, delivery,
privacy, and recovery contracts. This repository must not redefine those
contracts.

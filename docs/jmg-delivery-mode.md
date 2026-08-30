# JMG delivery mode

The notifier keeps its existing envelope-v1 spool and Stop Hook ingress. Its
delivery owner is selected by one explicit file in the selected Codex runtime:
`delivery-mode.txt`.

- `legacy-direct` is the default when the file is absent. The local ingress
  atomically publishes the envelope and starts the existing detached direct
  worker. This is the rollback path.
- `jmg` atomically publishes the same envelope but never starts the direct
  worker. The pending item remains for a JMG-owned adapter to claim.

The direct worker reads the same setting before it moves an item from pending.
For `jmg`, unreadable, or malformed settings it exits before claiming the
item. This prevents the direct sender and a JMG adapter from consuming the same
envelope. A missing setting is intentionally different: it preserves the
backward-compatible `legacy-direct` behavior of existing installs.

## Shared ingress-root selection

JMG-054B adds `-JmgRuntimeRoot` to the installer. In `jmg` mode it is required
for a fresh installation and must name the JMG-owned canonical ingress root:

```text
<JMG RuntimeRoot>\ingress\codex-ntfy
```

The installer rejects a relative path, a volume root, traversal, quotes/control
characters, malformed paths, and existing reparse components. It persists the
validated selection in `jmg-runtime-root.txt` and writes the same quoted
absolute value into only the repository-owned Stop Hook command. The existing
local ingress then publishes to that root's `spool\pending` directory.

This selection is local-only. It does not grant permissions, create the JMG
RuntimeRoot, apply ACLs, start JMG, contact a provider, or send a notification.
The JMG lifecycle contract owns the corresponding permission plan.

A fresh `jmg` install does not ask for, require, read, or write ntfy URL,
topic, user, password, or DPAPI files. `legacy-direct` retains its existing
credential requirement and `%LOCALAPPDATA%` default runtime behavior.

## Upgrade and rollback

Run the normal installer against an isolated or owner-approved Codex runtime
and specify `-DeliveryMode jmg` to hand delivery ownership to JMG. The
installer preserves a valid existing mode and shared-root selection when no
mode/root is supplied, so routine upgrades do not silently switch delivery
owners. An older JMG selection with no valid root must be repaired explicitly;
it is not silently mapped to a legacy path.

To roll back, run the same installer with `-DeliveryMode legacy-direct` and the
existing legacy-direct configuration. That changes the active local mode while
preserving the JMG root selection for an explicit later rollback. Backups now
include both selection files without exposing ntfy secret values. Envelopes
already pending in `jmg` mode remain recoverable for the JMG adapter and are
not sent by the direct worker.

No JMG endpoint, routing logic, provider client, scheduler, or real network
call is implemented by this repository. The isolated mode test uses synthetic
input only and proves that `jmg` leaves one pending envelope, that the direct
worker cannot claim it, and that `legacy-direct` remains selectable.

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

## Upgrade and rollback

Run the normal installer against an isolated or owner-approved Codex runtime
and specify `-DeliveryMode jmg` to hand delivery ownership to JMG. The
installer preserves a valid existing mode when no mode is supplied, so routine
upgrades do not silently switch delivery owners.

To roll back, run the same installer with `-DeliveryMode legacy-direct`.
That changes only the local mode file; envelopes already pending in `jmg` mode
remain recoverable for the JMG adapter and are not sent by the direct worker.

No JMG endpoint, routing logic, provider client, scheduler, or real network
call is implemented by this repository. The isolated mode test uses synthetic
input only and proves that `jmg` leaves one pending envelope, that the direct
worker cannot claim it, and that `legacy-direct` remains selectable.

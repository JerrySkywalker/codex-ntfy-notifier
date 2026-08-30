# JMG producer/capture-adapter boundary

## Authority

The JMG v1 documentation merged at
[`241b3bfc97f9d13629908df0e92cea083ebe77b1`](https://github.com/JerrySkywalker/jerry-message-gateway/blob/241b3bfc97f9d13629908df0e92cea083ebe77b1/docs/README.md)
is the authority for product scope, MessageEnvelope, routing, fanout, delivery,
privacy, recovery, and roadmap contracts. Pinning the documentation revision
records the reviewed authority; it does not claim that target-v1 behavior is
implemented.

This repository owns only its notifier-specific capture boundary and temporary
direct-delivery rollback implementation.

## Current and target status

| Status | Statement |
| --- | --- |
| `CURRENT_IMPLEMENTED` | The Stop Hook ingress normalizes a bounded local envelope, publishes it atomically, and uses one explicit delivery-owner mode. |
| `CURRENT_IMPLEMENTED` | `jmg` and `legacy-direct` are mutually exclusive modes. In `jmg`, the direct worker does not claim the pending item. |
| `CURRENT_NOT_PRODUCTION_VALIDATED` | The seam has isolated repository tests, but no production JMG adapter or real mode migration is validated by this documentation landing. |
| `TARGET_V1` | This notifier becomes JMG's first producer/capture adapter under an independently authorized P0-003 implementation goal. |
| `TARGET_V1` | The adapter sends structured metadata and a bounded producer summary; JMG never reads a complete Codex transcript. |
| `POST_V1` | Command Plane services, protocols, and trust decisions remain separate from this producer adapter and MessageEnvelope. |

P0-003 remains a dependency root parallel to P0-001 and remains future work.
TRAIN-01 may execute P0-001 first for bounded operational safety. This
documentation does not start TRAIN-01, install an adapter, change a real Hook,
or select a real delivery mode.

## Ownership contract

| Concern | Authority |
| --- | --- |
| Capture of a bounded Codex completion event | notifier producer adapter |
| Canonical message/history store | JMG |
| Recipient authorization and precedence | JMG routing authority |
| Provider target selection and delivery state | JMG |
| External wake/presentation | provider adapter; ntfy is non-authoritative |
| Remote commands | excluded from the Messaging Plane |

A producer may supply recipient or provider hints, but it cannot authorize its
own recipients or provider targets. JMG applies canonical policy and records
delivery truth. External delivery is at least once; presentation deduplication
reduces duplicates but cannot create an exactly-once guarantee.

MessageEnvelope carries message data and bounded presentation metadata. It must
not contain executable Command Plane actions. Any future Command Plane is a
separate service, protocol, and trust boundary.

## Content and privacy boundary

The adapter may derive a bounded summary after Codex completes. It must not
send, persist for JMG, or make JMG read a complete Codex transcript. Raw Hook
payloads, tool input/output, credentials, authorization headers, private
provider targets, and transcript contents do not belong in this repository.

Producer-supplied recipient or provider fields are untrusted inputs. They are
never an authorization grant.

## Transition contract

- `legacy-direct` is a temporary rollback path for the current notifier. It is
  not a parallel target architecture and ntfy is not a canonical store.
- `jmg` prevents the direct worker from claiming the same pending item. A later
  adapter implementation must preserve this single-owner behavior.
- Compatibility delivery precedes any optional opaque ntfy wake mechanism.
- Real Hook installation, notifier-mode migration, provider contact, and phone
  notification are outside this documentation goal.
- Any later Android or Access source change requires a separate audit against
  the then-current exact source head before implementation or acceptance.

The approved JMG Secret Provider abstraction governs provider credentials.
This adapter documentation does not prescribe plaintext environment, config,
or SQLite secret storage as a JMG backend.

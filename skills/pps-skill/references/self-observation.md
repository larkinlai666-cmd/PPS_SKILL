# PPS Self-Observation Protocol

PPS ships with a self-observation channel: when a PPS script notices an
anomaly in itself or its environment, it records one structured line in
`.pps/fault-log.md`. This document is the contract for that channel.

## Why this exists

The adversarial review loop finds defects by changing lenses. Field use finds
a different class: defects that only appear on a real machine, in a real
environment, under real intensity. Before this channel, those faults were
transient — a warning on stderr, a degraded fallback, then nothing. The
self-observation channel makes them persistent, structured, and reviewable,
so the field loop feeds the review loop.

## The contract

The channel is **strictly side-effect-free**:

- It never changes any PPS check, gate, stamp, or exit code.
- Every caller swallows its failure, so a logging problem can never change
  the behaviour of the script that logged it.
- It writes one line and exits. It is append-only: existing lines are never
  rewritten, and no line is ever deleted by PPS itself.

The log lives at `.pps/fault-log.md` (project-local, inside the gitignored
`.pps/` state directory). It does not participate in `validate_project` or
any acceptance floor; it is evidence for the PPS author, not for the project.

## Record format

One line per observation, five fields, ` | `-separated:

```
- <ISO-8601-UTC-seconds-Z> | <F-code> | script: <name> | engine: <bash|pwsh> | <message>
```

Example:

```
- 2026-08-26T14:03:11Z | F-ENV | script: session_begin | engine: bash | sha256 hashing unavailable; anchor digest degraded to unhashable
```

Both engines write byte-identical field structure; only the timestamp and the
`engine:` value differ. A line is machine-parseable by splitting on `" | "`.

## Fault codes

| Code | Meaning |
|------|---------|
| `F-ENV` | An environment assumption failed: a tool is missing, an external output was not in the expected shape. |
| `F-DEGRADED` | A degraded path was taken: a bounded fallback triggered (packet section dropped, digest degraded). |
| `F-PPS` | PPS noticed an internal surprise: a state it did not design for. Reserved; added when a real internal fault needs a home. |

Codes are a closed set. A new code is a protocol decision, not a runtime
decision: it is added here and to both `fault_log.*` scripts in the same
change, and pinned by a fixture.

## Wiring points

`fault_log.sh` / `fault_log.ps1` are called from a small, deliberate set of
wiring points. Adding a wiring point is cheap and safe (the channel is
side-effect-free), but each one must be pinned by a fixture or a wiring
assertion so it cannot silently detach:

- `session_begin.*`: the sha256 digest degraded to `unhashable` (F-ENV).
- `resume_packet.*`: the L0 packet dropped sections to fit the budget
  (F-DEGRADED).
- `init_project.*`: Git was not found and the project was created without a
  repository (F-ENV).

## The field-to-review loop

Between real-world runs, the PPS author reads `.pps/fault-log.md` and applies
the existing review discipline:

1. Cluster the lines by `F-code` and `script`. One line is an anecdote; a
   cluster is a defect class.
2. For each cluster, turn it into a review vector: can the fault be
   reproduced deterministically? Write a fixture that triggers it.
3. Fix the root cause or, where the degradation is by design, document the
   boundary so the next line can be recognized as known behaviour.
4. Repeat. The log is the field's contribution to the adversarial loop — the
   loop's tenth lens becomes "what did real use actually hit", replacing
   "what might an adversarial reviewer imagine".

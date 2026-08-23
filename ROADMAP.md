# Roadmap

## 0.1 — Public foundation

- [x] PPS/1.0 authority and workset protocol
- [x] `standard` and `evidence` profiles
- [x] PowerShell and Bash initialization
- [x] Structural coverage validation
- [x] Cross-platform smoke and negative tests
- [x] Open-source governance and CI

## 0.2 — Universal personal projects

- [x] Add a non-destructive legacy project audit command
- [x] Generate a proposed migration report without editing the target
- [x] Improve conflict diagnostics and exact source locations
- [x] Add fixture-based tests for superseded and frozen authority
- [x] Add `document`, `software`, and `hybrid` modes
- [x] Add stable component maps and bounded Read/Write/Verify worksets
- [x] Add source-free, 240-line-bounded resume packets
- [x] Add allowlisted, double-confirmed environment cold-start assistance
- [x] Preserve PPS/1.0 validation and audit compatibility
- [x] Test recovery isolation with a 200,001-line source file

## 0.3 — Material continuity and readiness

- [x] Add stable asset IDs and explicit core/supporting/reference priorities
- [x] Separate Git synchronization from device materialization
- [x] Add Git, Git LFS, cloud, and marker-only routing
- [x] Require non-secret rclone locators and durable-copy presence at handoff
- [x] Add size, SHA-256, LFS, aggregate-bloat, and 95 MiB safety gates
- [x] Add an explicit verification-attestation readiness gate
- [x] Extend environment declarations to document/media/cloud tooling
- [x] Harden legacy audit against false IDs and migration contamination

## 0.4 — Field distillation (PPS/1.2)

- [x] Relay handover protection: session-start `git status`, dirty-file overwrite prohibition, explicit handover
- [x] Verify gate with device-local execution evidence and readiness stamp checks
- [x] Behavioral end-to-end assertions and liveness probes as legitimate Verify members
- [x] `EVENTS.md` chronicle with fixed grammar, append scripts, and archive discipline
- [x] Coverage evidence cells replacing bare `Present`
- [x] Proposal aging with seven-day restatement discipline
- [x] Red-lines protocol position in `AGENTS.md`
- [x] Optional single-owner multitask layer: task registry, writer lease, typed merge receipts, checkpointed integration
- [x] Write-boundary enforcement against actual Git status (unclaimed-write gate)
- [x] Negative tests for every new gate on both platforms
- [x] PPS/1.0 and PPS/1.1 validation compatibility preserved

## 0.5 — Interoperability

- [ ] Define a stable export contract for software execution systems
- [ ] Add machine-readable validation output
- [x] Ship the in-project PPS/1.1-to-1.2 upgrade command (`migrate_project` dry-run / apply --confirm / rollback; the real 1.1 migration matrix landed in 0.5.1)
- [ ] Test installation and use across additional AI agent environments
- [ ] Add optional bounded symbol anchors without creating an index service

## 0.6 — Anti-drift reinforcement

- [x] Objective anchor: `session_begin` hashes the objective-bearing sections into `.pps/objective-anchor`; the verify gate fails a silent rewrite unless `EVENTS.md` records an `objective-revised`/`goal-revised` event, which refreshes the anchor
- [x] Anchor review ritual: every gate run re-surfaces the objective, red lines, and active decisions before stamping
- [x] Acceptance items in `CONTEXT.md`: non-bootstrap PPS/1.2 packages declare `A1, A2, ...` "done" criteria, each bound to a machine check the gate proves ran
- [x] Migrator parity: migrated 1.1 capsules gain a gate-bound A1 item
- [x] 051 anti-drift fixtures on both platforms (anchor write, silent-rewrite failure, recorded-revision pass, acceptance absence, unwired and wired acceptance)

## Long-term principles

- Keep Markdown and Git as the default substrate.
- Preserve deterministic recovery without requiring hosted infrastructure.
- Prefer explicit authority and scope over chronological memory.
- Keep semantic review separate from structural validation.
- Keep personal serial ownership explicit; do not grow team-process machinery.
- Keep recovery cost bounded without adding a database or mandatory generated cache.

# PPS/1.2 adversarial review

- Review date: 2026-08-19 (updated for 0.4.1 hardening round)
- Scope: skill 0.4.1, PPS/1.2 field distillation + external-review blocker fixes
- Method: first-principles threat model, strict-superset comparison, fault injection on every gate, replay of all five external-review bypass fixtures on both platforms, Bash/PowerShell parity, full regression
- Verdict: **PASS as a strict upgrade within the personal serial-project boundary**

## 0.4.1 hardening round

An independent external replacement review of 0.4.0 (commit `8e14d39`) proved four P0 and one P1 bypasses that this repository's own adversarial review had missed. The root cause of the miss is recorded here deliberately: the original fault injections were designed around the same mental model as the defenses, so they exercised expected failure shapes (exact canonical filenames, malformed receipts) but not grammar-level bypasses (`Write: .`), inverted-direction checks (task→receipt), or the gap between "gate exists" and "gate executes". 0.4.1 closes all five blockers plus the coupled secondary findings; every fix landed as a failing test first.

Replay results of the five original external bypass fixtures, both platforms, clean environments:

| External fixture | 0.4.0 behavior (confirmed) | 0.4.1 behavior (verified Bash + PowerShell) |
|---|---|---|
| REVIEW-P0-001: `Verify: exit 9` declaration | validate 0 / gate 0 + stamp / readiness 0 | validate 0 / gate 1, **no stamp** / readiness 4; a failing `project_verify.*` also blocks the stamp; unrouted free-form Verify declarations are rejected outright |
| REVIEW-P0-002: capsule `Write: .` + `Output Root: ../outside` | validate 0 | validate 1 with 12+ distinct diagnostics: full Workset grammar enforced on task capsules, path safety on Output Root, `local-task-output/` containment, overlap rejection |
| REVIEW-P0-003: `Status: integrated`, no `MERGES.md` | validate 0 | validate 1: terminal task states require exactly one status-matching receipt; receipts require all eleven fields, resolvable T-/PKG-/D- references, non-overlapping dispositions, resolvable Git checkpoints or explicit `lineage_incomplete` |
| REVIEW-P0-004: unclaimed canonical writes auto-claimed | boundary 0, `claimed:` | boundary 1, `unclaimed_write:`; claims derive only from the acting subject's Write set + Output Root; canonical identity grants nothing; `-AllowPreexisting` requires a recorded session baseline and never covers post-baseline changes |
| REVIEW-P1-005: Red Lines exists but not first | validate 0 | validate 1 with distinct diagnostics for missing / duplicated / misplaced |

Additional hardening verified by new negative tests: the verify stamp binds entry SHA-256, capsule SHA-256, and worktree identity, and readiness rejects a stamp whose entry or worktree changed afterwards; `append_event.*` inserts inside the `## Events` section even with trailing sections; proposal-aging warnings respect restatement in `Next`.

## Superset acceptance claims

Each claim was re-verified for 0.4.1:

1. **No legacy capability removed**: the inherited Bash and PowerShell smoke suites pass without deleting or weakening any assertion.
2. **PPS/1.0 and PPS/1.1 projects validate unchanged**: the PPS/1.0 downgrade fixture passes in both suites, and a synthesized PPS/1.1-era project (bare `Present` coverage, undated proposals, free-form Verify, no EVENTS/gate/red-lines files) validates and resumes cleanly under the 0.4.1 validator on both platforms. 1.2-only gates are keyed to the `Protocol:` declaration.
3. **Every new mechanism has a failing test**: all 0.4.0 negative tests plus the new 0.4.1 families (failing verify, unrouted verify, stale worktree stamp, capsule grammar, output-root escape/overlap, terminal-task receipts, receipt reference integrity, unclaimed canonical, baseline-gated preexisting, event placement) run on both platforms.
4. **New requirements cost nothing when unused**: single-task 1.2 projects and untouched 1.0/1.1 projects pay nothing; the multitask layer still activates only via `TASK_INDEX.md`.
5. **The no-auto-execution stance is preserved and now meaningful**: the structural validator still never executes manifest commands; execution belongs to the verify gate, which runs only the version-controlled `scripts/project_verify.*` entry, never free-form Markdown text.
6. **Bash and PowerShell expose one control surface**: every fixture above was replayed on both platforms with identical outcomes.
7. **Distribution integrity holds**: file lists, template tokens, links, VERSION/CHANGELOG agreement, and CI runner coverage all validate.

## Boundary review

Unchanged, deliberately:

- one human owner; serial canonical writes; no distributed lock, team backlog, role model, or concurrent merge authority.
- red-line *content* stays project-specific; the protocol fixes position and format only.
- mechanisms not exercised by the field campaigns (asset tiers, L1-L3, stages, evidence profile) are retained unchanged.
- the stamp proves the inspected gate ran on this device against this worktree state; a malicious hand-edited stamp remains within the single-owner trust model, though the worktree binding now makes accidental staleness detectable.
- boundary claims are subject-scoped but still declaration-based; diffing against per-task base checkpoints remains future work (0.5).

## Residual risks

- `project_verify.*` ships with real minimal assertions but the project owner can still hollow it out; the gate can enforce execution, not sincerity. The template states this explicitly.
- Event grammar validation checks shape, not truth.
- Proposal aging depends on validation actually running; closing requires it, so the gap is bounded.

Within the stated boundary, 0.4.1 is a strict capability superset of 0.4.0 and of 0.3.0/PPS/1.1: every legacy behavior is preserved and verified, every declared 1.2 protection is now machine-enforced with negative tests on both platforms, and all five externally proven bypasses are closed.


## Field-incident replay matrix

Each distilled mechanism is traced to the real incident that motivated it, and to the gate that would have caught it:

| Field incident (campaign evidence) | PPS/1.1 behavior | PPS/1.2 gate |
|---|---|---|
| Uncommitted hardening overwritten at agent handover (relay project, 3-day silent loss) | No rule covered the handover moment | Session-start `git status` + dirty-overwrite prohibition + explicit `Next` handover; relay rule is L0 step 1 |
| Known verification regimen never executed; encoding break shipped | Verify was a declarative line with no execution proof | Verify gate writes a device-local stamp; readiness fails on missing stamp (exit 4, `VERIFY EVIDENCE MISSING`) |
| Unit tests green while the wired system was dead; silent catch + graceful degradation hid it | "Structural coverage ≠ semantic correctness" was stated but had no operational answer | Behavioral end-to-end assertions and liveness probes are named, legitimate Verify members; stamp binds gate runs to the package |
| Three days spent fixing code that was never loaded | No "deployed vs loaded" distinction | Protocol self-knowledge line: deployed never proves loaded; liveness probes have a protocol position |
| Coverage table uniformly `Present` for 13 days—unfalsifiable | Bare `Present` was structurally valid | Evidence cell required; bare `Present` fails with a targeted diagnostic |
| Review proposal hung 6 days unnoticed | Proposals had no aging | `(opened date)` + 7-day restatement warning |
| Event log grew 397 lines with two diverging hand-written styles | Status events had no grammar, budget, or archive | `EVENTS.md` fixed grammar + append script + malformed-line failure + archive warning |
| 4 of 5 incidents were engineering-layer traps outside the authority system | Red lines had no protocol position | `## Red Lines` first section required, L0-read, packet-surfaced |
| Task state, merge lineage, and rejections lived only in host-app chat history (7 tasks, 1 worktree) | One capsule served as both project and task state | Opt-in task registry, per-task capsules, Writer lease, typed merge receipts |
| Derived PPT task's scratch polluted product linting | Write sets were declarative only | `boundary_check` classifies every change or fails it as `unclaimed_write`; scratch defaults to ignored `local-task-output/` |
| Dirty worktree made task contribution history unreconstructable | Fingerprints without checkpoints | `integrated` receipts require base + result checkpoints or explicit `lineage_incomplete` |
| "Task complete" conflated with "merged into project" | Single `complete` status | `handoff_ready` / `integrated` / `deferred` / `consume_only` split |

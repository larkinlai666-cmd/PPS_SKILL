# PPS/1.2 adversarial review

- Review date: 2026-08-21 (updated for the 0.4.6 core-duty round)
- Scope: skill 0.4.6, PPS/1.2 core duties DUTY-A..I plus the optional multitask layer
- Method: first-principles threat model, strict-superset comparison, fault injection on every gate, replay of every external bypass fixture (PKG-024/025/027 and the core-duty report) on both platforms, cross-platform stamp parity, full regression
- Verdict: **PASS as a strict upgrade within the personal serial-project boundary**

## Open / closed core defects (D-CORE series, core-duty report 2026-08-20)

| ID | Duty | Status in 0.4.6 |
|---|---|---|
| D-CORE-001 handover overwrite has no machine lock | DUTY-F | **Closed**: `session_begin.*` writes `.pps/session-snapshot` (porcelain -z + per-path content SHA); `boundary_check.*` fails with `protected_overwrite` when a path that carried uncommitted work at session start has changed, unless discarded explicitly with `--discard-handover` / `-DiscardHandover` |
| D-CORE-002 hollow `project_verify`, red lines not wired | DUTY-E/H | **Closed**: the gate refuses an echo-only or `exit 0` entry, and a red line annotated `(verify: path)` must be referenced by the gate entry (or by a manifest the entry reads) |
| D-CORE-003 coverage evidence was shape, not reference | DUTY-D | **Closed**: coverage evidence uses the receipt grammar — a PPS gate name, an existing in-repo check path, an EVENTS.md date that exists, or `manual: <reason>` only while the ID stays restated in Next |
| D-CORE-004 packet dropped handover detail and numbered red lines | DUTY-A | **Closed**: red lines are extracted by byte budget and keep numbering/bold; a `## Handover` section lists uncommitted paths, flags "dirty without explicit handover", and reports a missing session snapshot |
| D-CORE-005 "deployment is not loading" had no declaration slot | DUTY-E | **Closed**: optional `## Runtime Surfaces` table (`R-*`, repo path, environment VARIABLE name, probe); the probe must exist and be referenced by the gate entry; absolute paths stay illegal |
| D-CORE-006 behavioral assertion legal but not required | DUTY-E | **Closed**: software/hybrid packages must declare at least one check that is not the structural validator |
| D-CORE-007 proposal aging only warned | DUTY-B | **Closed**: on PPS/1.2 an aged proposal not restated in Next by ID is an error; `[abandoned]` / `[closed]` is an accepted terminal marker |
| D-CORE-008 zero-information events | DUTY-G | **Closed**: `verify: none` with `pending: none` fails unless the title is prefixed `note/chat/plan/abandoned`; `files:` entries must pass path safety |
| D-CORE-009 single writer never checked in tooling | DUTY-F | **Closed**: an unexpired snapshot forces `--takeover`, which must then be recorded as an event; deliberately not a lock |
| D-CORE-010 review text lagged the code | DUTY-I | **Closed**: `validate_skill` fails when `ADVERSARIAL_REVIEW.md` does not name the current VERSION in its opening lines |
| D-CORE-011 half-activated multitask layer | DUTY-A/I | **Partially closed**: an empty `TASK_INDEX.md` now fails with an explicit "delete the file to stay single-task" diagnostic. The 1.1→1.2 upgrade command remains on the 0.5 roadmap; field 1.1 projects must not be force-migrated yet |

Residual risk, stated plainly: the gate now refuses an empty verification entry and an unwired red line, but it still cannot prove a check is *sufficient*. A project owner can satisfy every structural requirement with weak assertions. The gate enforces execution and wiring, not sincerity.

## 0.4.2 hardening round

A second external review (PKG-025) accepted that 0.4.1 closed all five original bypasses, then advanced the adversary one semantic level: from "does the path set change" to "does the content behind an unchanged path set change", from "does a receipt exist" to "does the receipt carry real disposition evidence", from "are listed canonical files protected" to "is the Main content truth protected by role rather than by filename". Five new bypasses resulted. 0.4.2 closes all five, each landed as a failing test first.

Replay results of the five PKG-025 fixtures, both platforms, clean environments:

| External fixture | 0.4.1 behavior (confirmed) | 0.4.2 behavior (verified Bash + PowerShell) |
|---|---|---|
| REVIEW2-P0-001: dirty file changes again after stamp | readiness 0 | readiness 4, "worktree content changed"; stamp also binds capsule_sha256 and platform, and CONTEXT.md drift alone voids it |
| REVIEW2-P0-002: baselined path rewritten after baseline | boundary 0, preexisting | boundary 1, "baselined path changed again after the baseline" |
| REVIEW2-P0-003: worker declares `docs/MAIN.md` in Write | validate 0, boundary claims it | validate 1 at registration; boundary refuses the subject outright; Main/Coverage/Map/Environment are canonical by role |
| REVIEW2-P0-004: hollow integrated receipt (all evidence `none`, PKG-999, lineage_incomplete) | validate 0 | validate 1 with five distinct diagnostics: empty Accepted, missing Approval, missing Verification, phantom Target Package, lineage_incomplete without Lineage Note |
| REVIEW2-P1-005: capsule references M-404 / C-404 | validate 0 | validate 1: authority must be in the active block, component must exist in the map; sources/assets likewise; task budgets enforced |

A parity root cause surfaced during replay and is recorded deliberately: the PowerShell porcelain parser trimmed the leading status space, silently shifting the path slice so content hashes were computed for nonexistent files and never changed. The lesson generalizes the 0.4.1 one — an implementation can pass its own negative tests while measuring the wrong thing; fixtures must assert observable state transitions (same stamp accepted, then rejected after a content-only change), not just exit codes on static setups. Cross-platform stamp parity (Bash gate, PowerShell readiness) is now a tested invariant.

## Superset acceptance claims

Each claim was re-verified for 0.4.2:

1. **No legacy capability removed**: both inherited smoke suites pass without deleting or weakening any assertion; all ten prior negative fixtures still fail correctly.
2. **PPS/1.0 and PPS/1.1 projects validate unchanged**: the 1.0 downgrade fixture passes in both suites and a synthesized 1.1-era project validates and resumes with exit 0 on both platforms under the 0.4.2 validator.
3. **Every new mechanism has a failing test**: the 0.4.2 families (content-stamp staleness, capsule drift, baseline rewrite, worker Write escape, hollow receipts, phantom references) run on both platforms with positive controls.
4. **New requirements cost nothing when unused**: single-task 1.2 projects and untouched 1.0/1.1 projects pay nothing; the multitask layer still activates only via `TASK_INDEX.md`.
5. **The no-auto-execution stance is preserved**: the structural validator never executes manifest commands; execution belongs to the verify gate's version-controlled entry only.
6. **Bash and PowerShell expose one control surface**: every fixture replayed identically, and verify stamps are interchangeable across platforms.
7. **Distribution integrity holds**: file lists, template tokens, links, VERSION/CHANGELOG agreement, and CI runner coverage all validate.

## Boundary review

Unchanged, deliberately:

- one human owner; serial canonical writes; no distributed lock, team backlog, role model, or concurrent merge authority.
- red-line *content* stays project-specific; the protocol fixes position and format only.
- mechanisms not exercised by the field campaigns (asset tiers, L1-L3, stages, evidence profile) are retained unchanged.
- the stamp proves the inspected gate ran on this device against these exact bytes; a malicious hand-edited stamp remains within the single-owner trust model.
- boundary claims are subject-scoped and content-aware but still declaration-based; diffing against per-task base checkpoints remains future work (0.5).

## Residual risks

- `project_verify.*` ships with real minimal assertions but the project owner can still hollow it out; the gate enforces execution, not sincerity. The template states this explicitly.
- Approval/Verification receipt fields must resolve and be non-`none`, but the truth of the named evidence is not re-executed at validation time.
- Event grammar validation checks shape, not truth.

Within the stated boundary, 0.4.2 is a strict capability superset of 0.4.1, 0.4.0, and 0.3.0/PPS/1.1: every legacy behavior is preserved and verified, and all ten externally proven bypasses across two review rounds are closed with regression coverage on both platforms.


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

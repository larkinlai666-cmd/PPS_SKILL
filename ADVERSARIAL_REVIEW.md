# PPS/1.2 adversarial review

- Review date: 2026-08-22 (updated for the 0.5.0 execution-proof round)
- Scope: skill 0.5.0, PPS/1.2 core duties DUTY-A..I plus the optional multitask layer
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

### 0.5.0 execution-proof round (REVIEW49-P0-001..004, P1-005..008)

The 0.4.9 convergence audit pushed the axis to "did the fact really happen":
command execution, verification success, evidence belonging, Git lineage, and
recoverable terminal states. This round followed the audit's instruction:
machine-readable schema plus a single-source evidence engine, verifiers
rewritten on top, and a shared adversarial matrix on both platforms.

| ID | Status in 0.5.0 |
|---|---|
| P0-001 fake "test wired" proof | **Closed**: the gate executes a check manifest, records `.pps/verify-run.json`, binds the stamp to both hashes; exit-9 tests fail both gates with no stamp, print-only rows are not calls |
| P0-002 Verification can say failed / cite directories / escape root / borrow dates | **Closed**: typed `gate_result` / `file_evidence` / `event` judged by the shared engine |
| P0-003 checkpoint ids without lineage | **Closed**: ancestor direction, tree difference, and Accepted-inside-Result are enforced via Git |
| P0-004 ghost terminal states | **Closed**: deferred/rejected evidence must exist; handoff_ready requires a Base Checkpoint |
| P1-005 consumer / consumes_only contradiction | **Closed**: machine-read Role x Relation matrix; consumes_only + Accepted: none passes |
| P1-006 negative approvals/migrations | **Closed**: structured Decision polarity and negation detection |
| P1-007 task/package record syntax | **Closed**: Title required, capsules under task-contexts/, positive package events |
| P1-008 missing 1.1->1.2 upgrader | **Closed**: migrate_project with dry-run / apply --confirm / rollback; never guesses history, never flips Protocol itself |

Still deferred by agreement: Runtime Surfaces stays a warning; this repository
still does not switch to 1.2; the acceptance matrix (§9 of the audit) is
satisfied locally on both platforms and in CI.

### 0.4.9 self-collision round (F-048-01..03)

The 0.4.8 audit accepted the four 047 closures and then found the new machines can still be fooled: the automatic discard title trips the chronicle's own closing-verb rule, the live-line Contains still treats a string mention as a call, dead-branch dropping missed `if (0)` / `while ($false)`, and the "one parser" is three copies. All three closed:

| ID | Status in 0.4.9 |
|---|---|
| F-048-01 automatic discard title trips the closing-verb rule | **Closed**: renamed to `relay discard of protected paths`; the discard fixture now runs `validate_project` afterwards and requires exit 0 |
| F-048-02 "one parser" is three copies | **Closed**: smoke suites extract and diff the function bodies (Bash text diff; PowerShell body diff modulo function name), so a one-sided edit fails the build |
| F-048-03 live-line Contains still accepts mentions | **Closed**: after dead-code analysis, a live line must match a call shape (`check`/`bash`/`&`/dot-source/pipe/command substitution); string literals and bare assignments no longer count. Dead-branch dropping widened to `while false` (Bash) and `if (0)`, `if ($null)`, `while ($false)` (PowerShell) |

Deferred by agreement, still: Runtime Surfaces stays a warning, the 1.1→1.2 upgrader stays out of scope, and this repository does not switch to 1.2.

### 0.4.8 live-call round (F-047-01..04)

The 0.4.7 audit accepted the necessary-path weld and then moved the fight up one level: the machines on the path could still be satisfied by dead code, and the shipped floor probe was too low. All four follow-ups are closed:

| ID | Status in 0.4.8 |
|---|---|
| F-047-01 deleting boundary_check restored the no-lock path | **Closed**: software/hybrid gates fail on `Relay: BOUNDARY MISSING`, same as a missing snapshot |
| F-047-02 wiring parsers diverged and accepted dead code | **Closed**: one shared parser — comment-stripped, dead branches dropped, function bodies reachable only via closure from top-level calls; used by red-line tails, coverage evidence, and runtime probes on both platforms |
| F-047-03 Discard still relied on conscience | **Closed**: `--discard-handover` appends its own `relay discard released protected paths` event or fails (exit 4) |
| F-047-04 floor probe was true on the repository root | **Closed**: `e2e_probe.*` fails on `Main: .` or a directory; the template probe call captures its output so the check cannot be vacuously green |

Deferred by agreement, not forgotten: Runtime Surfaces stays a warning until a live I3 recurrence justifies an error, and the 1.1→1.2 upgrader stays out of scope.

### 0.4.7 necessary-path round (D-CORE-012..020)

The 0.4.6 re-review's verdict was "machine built, not yet welded in". All nine follow-ups are closed:

| ID | Status in 0.4.7 |
|---|---|
| D-CORE-012 handover lock off the completion path | **Closed**: the gate calls `boundary_check.*` before stamping; missing snapshot fails software/hybrid outright |
| D-CORE-013 wiring was a substring match | **Closed**: red-line tails, coverage paths, and probes must appear on an uncommented invocation line |
| D-CORE-014 coverage evidence need not be run | **Closed**: the named check must be called by `project_verify.*` or a read manifest; `manual:` capped at one third of rows |
| D-CORE-015 `note` laundered real closures | **Closed**: only `abandoned`/`chat` may be empty; informational prefixes may not claim closing actions |
| D-CORE-016 snapshot expired into silence | **Closed**: any snapshot age requires takeover; TTL 7 days and configurable; post-overwrite takeover reports the loss |
| D-CORE-017 takeover/discard left no trace | **Closed**: takeover appends its own relay event or fails |
| D-CORE-018 undeclared runtime surfaces | **Closed as a warning**: installer-shaped projects without an `R-*` row are flagged, deliberately not failed |
| D-CORE-019 behavioral check was lexical | **Closed**: the check must name a real project artifact; `{ $true }` fails; a runnable `e2e_probe.*` ships so honesty is the easy path |
| D-CORE-020 review body lagged the machines | **Closed**: replay matrix rewritten; CI fails on superseded phrases, not just a missing version |

Residual risk, stated plainly: the gate now refuses an empty verification entry, an unwired red line, an always-true behavioral check, and a stamp over overwritten handover work. It still cannot prove a check is *sufficient* — a project owner can satisfy every structural requirement with weak assertions, and the shipped `e2e_probe.*` is deliberately a floor, not a ceiling. The gate enforces execution, wiring, and non-destruction; not sincerity.

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

| Field incident (campaign evidence) | PPS/1.1 behavior | Machine in the current release |
|---|---|---|
| Uncommitted hardening overwritten at agent handover (relay project, 3-day silent loss) | No rule covered the handover moment | `session_begin.*` records `.pps/session-snapshot` with per-path content hashes; `verify_gate.*` calls `boundary_check.*` before stamping and fails on `protected_overwrite`; a missing snapshot fails the gate outright in software/hybrid mode; a snapshot never expires into silence — any age requires `--takeover`, which writes its own relay event |
| Known verification regimen never executed; encoding break shipped | Verify was a declarative line with no execution proof | Verify declarations route through `scripts/project_verify.*`; the gate refuses an `exit 0`/echo-only entry, and a red line carrying a `verify:` tail must be **called** (not merely mentioned) by that entry; readiness fails on a missing or stale stamp (exit 4) |
| Unit tests green while the wired system was dead; silent catch + graceful degradation hid it | "Structural coverage ≠ semantic correctness" was stated but had no operational answer | software/hybrid packages must declare a non-structural check whose line, script block, or helper names a **real project artifact**; an always-true assertion fails the gate |
| Three days spent fixing code that was never loaded | No "deployed vs loaded" distinction | Optional `## Runtime Surfaces` table (`R-*`, repo path, environment VARIABLE name, probe) with the probe required to exist and be called by the gate entry; a project that ships an installer but declares no surface gets a warning |
| Coverage table uniformly `Present` for 13 days—unfalsifiable | Bare `Present` was structurally valid | Coverage evidence must resolve: a PPS gate name, an in-repo check that the gate entry actually calls, a real `EVENTS.md` date, or `manual: <reason>` while the ID stays restated in `Next` — and at most one third of rows may be `manual:` |
| Review proposal hung 6 days unnoticed | Proposals had no aging | `(opened date)` + aged proposals are an **error** on PPS/1.2 unless restated in `Next` by ID or marked `[abandoned]`/`[closed]` |
| Event log grew 397 lines with two diverging hand-written styles | Status events had no grammar, budget, or archive | `EVENTS.md` fixed grammar + append script + malformed-line failure + archive warning; `verify: none` with `pending: none` is rejected, only `abandoned`/`chat` may be fully empty, and an informational prefix may not claim a closing action |
| 4 of 5 incidents were engineering-layer traps outside the authority system | Red lines had no protocol position | `## Red Lines` required as the first H2, L0-read, packet-surfaced by byte budget (numbered and bold entries survive); a red line may bind itself to its enforcing check with a `verify:` tail |
| Task state, merge lineage, and rejections lived only in host-app chat history (7 tasks, 1 worktree) | One capsule served as both project and task state | Opt-in task registry, per-task capsules, Writer lease, typed merge receipts; an empty registry is rejected outright |
| Derived PPT task's scratch polluted product linting | Write sets were declarative only | `boundary_check` classifies every change or fails it as `unclaimed_write`; scratch defaults to ignored `local-task-output/` |
| Dirty worktree made task contribution history unreconstructable | Fingerprints without checkpoints | `integrated` receipts require base + result checkpoints or explicit `lineage_incomplete` |
| "Task complete" conflated with "merged into project" | Single `complete` status | `handoff_ready` / `integrated` / `deferred` / `consume_only` split |

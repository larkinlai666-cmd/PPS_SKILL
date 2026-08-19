# PPS/1.2 adversarial review

- Review date: 2026-08-19
- Scope: skill 0.4.0, PPS/1.2 field distillation
- Method: first-principles threat model, strict-superset comparison against 0.3.0/PPS/1.1, fault injection on every new gate, Bash/PowerShell parity, full regression of the inherited suites
- Verdict: **PASS as a strict upgrade within the personal serial-project boundary**

## Superset acceptance claims

PPS/1.2 passes only if all claims below hold. Each was verified on this review date:

1. **No legacy capability removed**: every PPS/1.0 and PPS/1.1 validation rule, script, template token, and trigger phrase remains; the inherited Bash and PowerShell smoke suites pass without deleting or weakening any assertion (fixture protocol strings were updated only where they intentionally exercise the *current* template generation).
2. **PPS/1.0 and PPS/1.1 projects validate unchanged**: explicit downgrade fixtures pass in both suites; 1.2-only gates are keyed to the `Protocol:` declaration and cannot fire on older projects.
3. **Every new mechanism has a failing test**: missing `EVENTS.md`, malformed event lines, missing `## Red Lines`, bare-`Present` coverage, missing Writer lease, two active integrators, worker claiming canonical writes, integrated receipts without checkpoints, missing/stale verify stamps, separator-injection into events, and unclaimed writes all fail loudly with regression coverage on both platforms.
4. **New requirements cost nothing when unused**: the multitask layer activates only when `TASK_INDEX.md` exists; a fresh single-task project passes initialization + validation + gate + readiness end-to-end on both platforms.
5. **The no-auto-execution security stance is preserved**: the validator only checks that gate files exist and parses stamp text; it never runs `Verify`, the gate, or any manifest command. Readiness still requires explicit caller attestation *plus* the stamp.
6. **Bash and PowerShell expose one control surface**: all new scripts (`verify_gate`, `append_event`, `boundary_check`) and all new validator gates exist and behave identically on both platforms, verified by parallel fixtures.
7. **Distribution integrity holds**: `tools/validate_skill.py`, both installed-skill validators, template-token checks, link checks, VERSION/CHANGELOG agreement, and CI runner coverage all pass.

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

## Fault-injection results

All injections were executed, not reasoned about:

| Attack | Result |
|---|---|
| Delete `EVENTS.md` from a 1.2 project | fail: `PPS/1.2 is missing required file: EVENTS.md` |
| Append a free-form event line | fail: `Malformed event line in EVENTS.md` |
| Rename the `## Red Lines` section | fail: red-lines requirement names AGENTS.md |
| Downgrade a coverage evidence cell to `Present` | fail with the checked-vs-unchecked diagnostic |
| Register two active integrators | fail: exactly-one-integrator gate |
| Point Hot State `Writer` at a non-existent registry | fail: Writer/TASK_INDEX consistency gate |
| Worker capsule claims `DECISIONS.md` in Write | fail: canonical-write prohibition |
| Mark a merge receipt `integrated` with `none` checkpoints | fail: checkpoint requirement |
| Attest readiness without running the gate | exit 4 `VERIFY EVIDENCE MISSING` |
| Attest readiness with a stamp from another package | exit 4 `VERIFY EVIDENCE STALE` |
| Inject `|` into an event title | append refused; grammar preserved |
| Create an undeclared file and close | `boundary_check` fails it as `unclaimed_write` |
| Validate a PPS/1.0 and a PPS/1.1 fixture | both pass unchanged |
| Initialize + validate + gate + readiness a fresh project, both platforms | all pass |

## Boundary review

Unchanged, deliberately:

- one human owner; serial canonical writes; no distributed lock, team backlog, role model, or concurrent merge authority. The multitask layer is bookkeeping for serial integration, not concurrency.
- the validator never executes untrusted manifest commands; the stamp proves a gate ran, not that its checks are semantically sufficient.
- red-line *content* is project-specific and never enters PPS; only the position and format are protocol.
- mechanisms not exercised by the two campaigns (asset tiers, L1-L3 escalation, stages, evidence profile) are retained without change; absence of evidence is not evidence against design.
- `boundary_check` classifies changes against declared boundaries; it does not diff against per-task base checkpoints and does not attribute pre-existing dirt. Checkpoint-diff enforcement remains future work (0.5).
- Windows CI observation remains pending until the next remote run; local parity was verified with PowerShell 7.6 on macOS.

## Residual risks

- The verify-stamp proves the gate ran on this device for this package; a malicious actor editing the stamp by hand defeats it. The stamp is git-ignored and device-local, so this remains within the single-owner trust model.
- Event grammar validation checks shape, not truth; a fabricated event line passes structurally. The chronicle's value still depends on the discipline the append script encourages.
- Proposal aging uses the validator's run date; a project never validated never warns. This is acceptable because closing requires validation.

Within the stated boundary, PPS/1.2 (0.4.0) is a strict capability superset of 0.3.0/PPS/1.1: every legacy behavior is preserved and verified, and every addition is opt-in by protocol declaration or file presence, fail-loud, evidence-backed, and covered by negative tests on both platforms.

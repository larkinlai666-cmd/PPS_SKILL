# PPS/1.2 adversarial review

- Review date: 2026-08-25 (updated for the 0.6.0 feature-review repair round)
- Scope: skill 0.6.0, PPS/1.2 core duties DUTY-A..I plus the optional multitask layer
- Method: first-principles threat model, strict-superset comparison, fault injection on every gate, replay of every external bypass fixture (PKG-024/025/027 and the core-duty report) on both platforms, cross-platform stamp parity, full regression
- Verdict: **PASS as a strict upgrade within the personal serial-project boundary**

### 0.6.0 self-distillation round (D-060-A..E)

The 0.6.0 anti-drift release moved `EVENTS.md` to ISO-8601 stamps. A
self-distillation pass asked the only question that matters after a format
change: **who else reads this file by date?** Five defects surfaced, none of
which the release's own suite could see, because every new fixture was written
against the new grammar only.

| ID | Defect | Status in 0.6.0 |
|---|---|---|
| D-060-A coverage date evidence became fail-forever | The coverage table's "an existing EVENTS.md date" evidence anchored on `^- DATE:`, which no ISO-stamped line matches; every legitimate date attestation was rejected | **Closed**: both engines accept `DATE` and `DATE T…Z`; fixture 052-01 asserts a real stamped event resolves |
| D-060-B typed `event:<date>:<id>` evidence silently broke | `pps_evidence.py` split the token on the FIRST colon, so `2026-08-24T10:00:00Z:M-001` yielded merge id `00:00Z:M-001` and no receipt ever resolved | **Closed**: `rsplit(":", 1)`; fixture 052-02 asserts an ISO-stamped typed reference resolves |
| D-060-C anti-drift went blind on migrated projects | The gate only recognised ISO-stamped `objective-revised` lines; a migrated PPS/1.1 chronicle carries calendar-day lines, so a legitimate revision could not be recorded at all — the anti-drift machine failed *closed* into an unfixable state | **Closed**: both engines accept either grammar and compare on the shorter precision; fixture 052-03 proves a calendar-day revision refreshes the anchor |
| D-060-D the release broke its own append-only compatibility promise | `EVENTS.md` is append-only ("never rewrite past lines"), so every project written by an earlier release keeps calendar-day lines forever; tightening the validator to ISO-only meant **upgrading the skill retroactively invalidated every existing project**, contradicting "PPS/1.0 and PPS/1.1 projects validate unchanged" | **Closed**: all five chronicle readers (validator ×2, project_verify ×2, evidence engine) accept both grammars while writers always emit stamps; fixture 052-04 locks the promise |
| D-060-E widening the grammar widened it into nonsense | The compatibility fix accepted `T99:99:99Z` as a valid stamp | **Closed**: hour/minute/second range-bounded on both engines; fixture 052-05 rejects the impossible clock |

Two lessons recorded deliberately, because they generalise past this round.
First: **a format migration's blast radius is every reader, not every writer.**
The release updated the append path and the format check, then declared done;
the four readers that consume the chronicle *by date* were each a silent
green-forever or fail-forever hazard. Second: **an append-only artifact makes
every format tightening a breaking change by construction** — a validator may
only ever widen what it accepts for historical lines, while writers narrow to
the new grammar.

Anti-drift and anti-rot were then re-verified against live attacks rather than
fixtures: a silent objective rewrite fails the gate; a `note`-prefixed fake
revision cannot launder it; a real `objective-revised` event legitimizes the
change and refreshes the anchor; a missing anchor fails `software`/`hybrid`
outright; and the gate re-surfaces objective, red lines, and active decisions
before anything else on every run.

### 0.6.0 feature-review repair round (PPS-AUDIT-20260825-060F)

An external feature review scored the three new mechanisms separately instead
of as one release: anchor 6/10, `Acceptance` 5/10, gate printout 2/10, and
long-session anti-rot 3/10. Its central finding was structural rather than a
bypass: **the locks sit at both ends of a session while the drift happens in
the middle.** The repairs below take the report's own scope — §7 items 1–4 and
§8.4 R1–R3 — and add no fields.

| Item | Finding | Repair |
|---|---|---|
| R1 packet did not carry "done" | The L0 packet shipped only the one-line package `Goal`; `## Objective` and the multi-line `Acceptance` list were absent, because the single-line field reader cannot see a sub-list. A recovered or compacted session therefore could not see what closes the package | Both engines emit `## Objective` (800-byte budget, truncation noted) and the verbatim `A1…` list. Fixture 053-01 asserts both plus the unchanged 240-line / 32 KB budget |
| R2 the anchor was unreadable | `.pps/objective-anchor` held only a hash and a timestamp, so an agent that lost working memory could not "read the anchor" | The anchored objective is written below a `-- objective --` marker on both `session_begin` and gate refresh. The gate still compares only the hash; header parsing stops at the marker and keeps the first match, so a body containing `objective_sha256:` cannot forge the digest. Fixture 053-02 asserts readability and proves the forgery fails |
| §7-2 the acceptance floor was `any` | A package declaring `A1` on the structural gate plus `A2` on a real check failed. The floor punished the careful author and taught nothing | The floor fires only when *every* item is structural. Fixtures 053-03 (mixed passes the acceptance step) and 053-04 (all-structural still fails) pin both directions |
| §7-1 the migration trap was silent | `migrate_project.*` injects `A1: … (verify: validate_project)`, which passes under `bootstrap` and then fails the moment `Stage` advances, with no warning at migration time | The NOTICE now names the item, the condition, and the exact failure string. The floor diagnostic also points at the migrated `A1`. Fixtures 053-05 and 053-04 |
| §7-4 the printout was over-claimed | "Forced re-read" / "protocol-level answer to context rot" described a `Write-Host` call. stdout is not proof of reading, and the gate runs after the drift is already in the diff | The claim is retired from `SKILL.md`, `protocol.md`, `retrieval-and-gates.md`, `design-rationale.md`, and `CHANGELOG.md`; the printout is described as an operator log line. Fixture 053-06 keeps it from returning |
| R3 no mid-session recovery | The protocol required reading the packet only at startup, so a compacted session had no bounded way back to the goal | `SKILL.md` states a mid-session re-read invariant with four triggers, and declares the packet authoritative over earlier conversation |
| §7-3 same-day laundering | The short-precision comparison that keeps migrated calendar-day chronicles readable also means any same-day rewrite counts as recorded | Documented as a deliberate price in `retrieval-and-gates.md` rather than presented as equal strictness |

Two limits are now stated rather than advertised away. The gate cannot un-rot a
session, because it runs at close; and the objective anchor is a per-machine
session fact under `.pps/`, not a cross-device one. What the release does close
is the disk half: an objective rewritten without a recorded revision, and a
`done` that no check ever proved.

One regression was introduced and caught inside this round: the PowerShell
floor was rewritten against a variable name that did not exist
(`$acceptanceItems` instead of `$acceptanceLines`), so `$null.Count` silenced
the floor entirely on that engine while Bash still enforced it. Fixture 053-04
failed loudly and named it. The lesson matches D-060's: **a parity edit must be
re-verified on the engine it was not written on**, because a null-valued
condition in PowerShell fails open rather than erroring.

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
| D-CORE-011 half-activated multitask layer | DUTY-A/I | **Closed in 0.5.x**: an empty `TASK_INDEX.md` now fails with an explicit "delete the file to stay single-task" diagnostic; `migrate_project` exists with dry-run / apply --confirm / rollback (rollback restores the pre-apply file set, see the 0.5.1 round) |

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

### 0.5.1 field-consistency round (PPS-AUDIT-20260823-050, F-050-01..10)

A second review chain re-ran the frozen matrix on a real Windows PowerShell
5.1 field machine. Verdict: conditional pass; the execution-proof axis is the
right one, but several "Closed" claims did not hold in the field. This round
makes the execution layer field-truth on both platforms.

| ID | Status in 0.5.1 |
|---|---|
| F-050-01 default manifest hardcodes pwsh | **Closed**: the default manifest's powershell row is now `& ./scripts/project_verify.ps1 -Root .`, executed by the gate's own engine (`pwsh` else `powershell`); a 5.1 box with no pwsh runs the default list |
| F-050-02 python3 hard runtime declared Optional | **Closed**: discovery order `PPS_PYTHON` -> `python3` -> `python` -> `py -3` in gate and validator, both platforms; a missing interpreter is an explicit failure, not a CommandNotFound; ENVIRONMENT Required lists python; doctor probes py too |
| F-050-03 timeout_s never killed | **Closed**: the column is a real deadline now; on expiry the process tree is killed, the row fails, the run record gets `exit_code: timeout`, and no stamp is written; PS uses Start-Process + Wait-Process + taskkill/pkill, bash uses background + kill -0 polling |
| F-050-04 cwd not contained | **Closed**: absolute and escaping working directories (including via symlink) fail the row before spawn, both platforms |
| F-050-05 print-only rows counted as calls | **Closed**: `looks_like_call` now only accepts the command position (bare invocation, call operator, interpreter with flags); `echo PATH` and `Write-Host PATH` are argument positions and never wire a red line; both smoke suites carry the unquoted print-only row |
| F-050-06 migrator rollback/id unsafe | **Closed**: rollback restores the pre-apply file set and deletes files apply created (no backup entry); the manifest stays under `.pps/`; the decision id avoids existing `D-*` ids; PS 5.1 appends without BOM; the PS event line writes `YYYY-MM-DD:` with no space (matching the validator's event-line grammar); rollback fixtures on both platforms |
| F-050-07 two copies of the word lists | **Closed**: `pps_evidence.py` reads the word lists from `state-machine.json`; hardcoded lists are only a fallback for a missing schema |
| F-050-08 SKILL invariant contradicted the gate | **Closed**: SKILL.md now states the gate executes the project's own manifest and readiness never executes out-of-repo commands; the gate failure list names missing/failing/timing-out/escaping manifest rows |
| F-050-09 review table lagged the code | **Closed**: D-CORE-011 row and the F-047-03 title now match the code |
| F-050-10 substring word lists | **Residual by agreement**: `fail` still matches `failure-report`. Word-boundary work stays out of scope per the 049 stop-order; recorded here as residual, not a new round |

### 0.5.2 real-migration round (PPS-AUDIT-20260823-V3, P0-01 / P1-01..03 / P2-01)

A third review chain replayed REAL PPS/1.1 projects (initialized by the
actual 1.1 skill release) against the 0.5.1 migrator and the multitask
receipt rules, plus a legacy auditor replay on a complex existing project.
Verdict: the core design is a large improvement, but the full
"new + resume + migrate" delivery was only conditionally passing.

| ID | Status in 0.5.2 |
|---|---|
| P0-01 real 1.1 migration did not complete its claim | **Closed**: `migrate_project` is a core protocol upgrade (scripts, Red Lines, coverage evidence, proposal dates, active-block decision, EVENTS.md, manifest, .gitignore) that validates on both engines and gates on the current platform, rolling back byte-identically on failure; multitask is a separate opt-in and a single-task project never gains TASK_INDEX.md; the test matrix migrates four real-1.1 fixtures and asserts the final 1.2 state (valid + gated + ready + rollback byte identity) |
| P1-01 legacy auditor misclassified non-standard structure | **Closed**: candidates + evidence + confidence model; state/decisions/rules/risks/task-list/sources/coverage families; documents count outside docs/; code exists is separate from code is Main; empty targets report `unknown`, never `unstructured` |
| P1-02 migration tests proved reversibility, not semantics | **Closed**: the suites assert the migrated project validates, gates, and reaches readiness, and that rollback restores file set and hashes; the failing-migration fixture proves auto-rollback |
| P1-03 mixed dispositions masked by integrated | **Closed**: per-set Reason/Reactivate When on any receipt; `integrated` may not carry open dispositions; `partially_integrated` is the explicit partial state; task stays active until the remainder resolves; both platforms carry negative and positive fixtures |
| P2-01 self-description drift | **Closed**: template README says PPS/1.2, ROADMAP marks the upgrader shipped, the CONTEXT template fits the 60-line target, and the distribution validator reconciles template protocols, roadmap, and capsule size |

Still out of scope by agreement: same-workspace true multi-writer
concurrency (the multitask layer is a serial-integration ledger), semantic
business verification (the project's own Verify duty), and multi-owner team
features.

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
| F-047-03 Discard still relied on conscience | **Closed**: `--discard-handover` appends its own `relay discard of protected paths` event or fails (exit 4) |
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

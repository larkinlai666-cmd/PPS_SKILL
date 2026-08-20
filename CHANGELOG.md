# Changelog

All notable changes are documented here. The project follows Semantic Versioning.

## [Unreleased]

## [0.4.5] - 2026-08-20

Fifth review round. The reviewer switched to a full mutation matrix ("one legal field replaced at a time") instead of compound fixtures, which exposed that 0.4.4's evidence checks matched keywords rather than resolving references. Eight distinct misclassifications closed, plus two high-risk surfaces the earlier reports never touched.

### Fixed

- **Verification became a resolvable reference, not a keyword match**: exactly three accepted forms — `<gate> <outcome>` where the gate is a real PPS gate and the outcome is recorded, an existing `docs/` or `.pps/` evidence path, or an `EVENTS.md` reference whose date exists as an event line. A bare gate name (`verify_gate`), a nonexistent `docs/...` document, and prose all now fail with distinct diagnostics.
- **Accepted paths must belong to a Source Task**: an integrated receipt's Accepted entries must sit inside one of the named Source Tasks' Output Roots. A real but unrelated artifact (e.g. `PROJECT_MAP.md`) can no longer masquerade as absorbed task output.
- **Base and Result Checkpoints must differ**: identical checkpoints mean the tree never changed, so nothing was integrated.
- **lineage_incomplete eligibility no longer keyword-matched**: event-prose matching is removed entirely (a line saying "explicitly forbid adopt" satisfied the old check). Eligibility now requires the Lineage Note to cite an `active` `D-*` decision whose record explicitly authorizes migrating or adopting pre-layer history; citing an unrelated decision fails with its own diagnostic.
- **TASK_INDEX `Active Package` was completely unvalidated**: it must now be a well-formed `PKG-*` ID that is either the current package or recorded as a parsed EVENTS.md event line.
- **Duplicate fields are rejected in task records and receipts**: first-match parsing let a second, contradictory line (e.g. a second `Status:`) hide in plain sight. Every field must be declared exactly once, on both platforms.

### Added

- Mutation-style negative fixtures on both platforms, one per diagnostic: missing evidence document, bare gate name, unowned Accepted path, identical checkpoints, non-migration decision cited for lineage, malformed Active Package, duplicate Status in a task record, duplicate Status in a receipt.

## [0.4.4] - 2026-08-20

Fourth external-review round (PKG-027) accepted all fifteen previously closed bypasses, then advanced to receipt truthfulness and archived-state uniqueness. All four findings closed, each landed as failing field-level tests first on both platforms.

### Fixed

- **REVIEW3-P0-001 — receipts must bind to real evidence, not evidence-shaped text**: Target Package existence now requires a parsed EVENTS.md event line (`- YYYY-MM-DD: [PKG-*] ...`), not a substring in comments or prose; integrated Accepted paths must resolve to real artifacts in the worktree or inside the Result Checkpoint (`git cat-file -e result:path`); Approval must cite a decision whose status is `active` or `superseded` — citing a `[rejected]` decision is a forged grant and fails; Verification must be locatable evidence (gate/command with recorded result, stamp, event line, or in-repo evidence document), not arbitrary prose.
- **REVIEW3-P0-002 — archived tasks keep exactly one final disposition**: an archived task with zero terminal receipts, contradictory terminal receipts (e.g. both integrated and rejected), or duplicate same-status receipts now fails validation on both platforms.
- **REVIEW3-P1-003 — deferred/rejected receipts carry their own evidence**: deferred requires a non-empty Deferred set and a `Reactivate When` field; rejected requires a non-empty Rejected set and a `Reason` field; all terminal dispositions (not only integrated) require Approval and Verification.
- **REVIEW3-P1-004 — lineage_incomplete gets a migration eligibility gate**: on projects with normal Git history, the marker now requires an active `D-*` migration decision cited in the Lineage Note or a recorded migration/adoption event; a convenience note alone fails. Projects without Git remain exempt (they have no checkpoints to bind).

### Added

- Field-level negative fixtures on both platforms: phantom package via comment, rejected-decision approval, prose-only verification, ghost Accepted artifact, lineage_incomplete without migration eligibility, archived contradiction, empty deferred (two diagnostics), empty rejected (two diagnostics) — plus a fully-evidenced positive control.

### Fixed

- **Self-adversarial loop until convergence (three probe rounds, 14 vectors)**: round 1 hit 3 real gaps, now closed with negative tests on both platforms: (a) validator enforced task→receipt direction but not receipt→registry — a terminal-status receipt naming a still-`active` task passed; the two truth sources must now agree; (b) verify stamps with duplicated fields exploited first-match parsing so a prepended `result: pass` shadowed the real `result: fail`; readiness now rejects any stamp declaring a required field more than once; (c) `append_event.*` accepted multi-line segments — Bash awk failed silently while still reporting success, and forged chronicle lines or sections were possible; segments must now be single-line, enforced on both platforms. Rounds 2 and 3 (command-substitution injection via hot-state fields, dot-segment/trailing-slash path claims, concurrent gate runs, whitespace-only evidence cells, post-baseline self-granting capsule edits, archived-task escapes, cross-file package desync) scored zero hits: existing guards held.

### Fixed

- **Self-adversarial round (no external report)**: predicted the fourth attack layer from the escalation pattern of the three external rounds and probed four candidate vectors. Three were already blocked by existing guards (unrouted-but-plausible Verify wrapper declarations, symlinked Output Root, `|` injection in event fields). One was real and is now closed: a terminal-status task (`rejected`/`integrated`/`deferred`/`handoff_ready`) could still act as the boundary subject via `--task`/`-Task` and reclaim its old write authority — boundary_check now requires the acting subject to be `active` on both platforms, with negative tests.

## [0.4.3] - 2026-08-20

Third hardening round, driven by the reviewer's live layer-3 probing which found real misclassifications in 0.4.2's own fixes.

### Fixed

- **CJK / escaped-path blindness in content fingerprints**: `git status --porcelain` quotes and octal-escapes non-ASCII paths, so 0.4.2's fingerprint hashed nonexistent filenames and recorded them as `absent` — a CJK-named dirty file could change without voiding the stamp. All porcelain parsing (gate, readiness, boundary, both platforms) now uses `-z` NUL-separated records with rename-source skipping; PowerShell additionally forces UTF-8 console encoding around the probe. Cross-platform stamp parity with CJK paths is tested.
- **Stamp survives `.git` removal**: readiness treated a missing repository as "nothing to compare" and passed any stamp. A stamp whose worktree identity is Git-bound is now rejected when the directory is no longer a Git worktree (or git is unavailable), on both platforms.
- **Second Main-write channel via integrator capsules**: the validator only enforced full Workset grammar on worker/consumer capsules, so an integrator pointing at a separate, unvalidated capsule file got its Write claims trusted by boundary_check. Integrator tasks must now use `CONTEXT.md` itself as their capsule — enforced by both the validator and boundary_check.
- **Receipt disposition paths escape the project**: Accepted/Rejected/Deferred entries now pass the same path-safety validation as every other manifest path; `../outside/...` fails.

### Added

- Negative tests on both platforms: CJK dirty file changing after the stamp, `.git` removed after the stamp, integrator with a separate capsule, and receipt disposition path escape.

## [0.4.2] - 2026-08-19

Second hardening round closing all five blockers from the external upgrade review of 0.4.1 (REVIEW2-P0-001..004, REVIEW2-P1-005) plus the portability finding P2-006. The review's framing: 0.4.1 enforced that gates exist and run; 0.4.2 enforces that their evidence binds to content, not to shapes.

### Fixed

- **REVIEW2-P0-001 — verify stamps bind content, not porcelain text**: the worktree identity in `.pps/verify-stamp` is now HEAD plus a sorted digest of every changed path's status AND current byte SHA-256. An already-dirty file that changes again after the gate now voids the stamp. `readiness_check.*` additionally verifies every stamp field including `capsule_sha256` (CONTEXT.md drift voids the stamp) and `platform`, and the fingerprint is byte-identical across Bash and PowerShell so a stamp written by one platform verifies on the other.
- **REVIEW2-P0-002 — baselines bind content**: `--record-baseline`/`-RecordBaseline` records status + path + content SHA-256 per entry; `--allow-preexisting` exempts a change only when all three still match. A baselined path rewritten later fails with an explicit "baselined path changed again" diagnostic.
- **REVIEW2-P0-003 — worker Write is not a second grant channel**: worker/consumer Write paths must sit inside the task's own Output Root; the validator rejects violations at registration and `boundary_check.*` refuses to run for a subject whose declarations escape its root. The canonical file list is now dynamic: Hot State `Main`, `Coverage`, `Map`, and `Environment` targets are canonical by role, not by filename. `references/multitask.md` no longer says "Output Root **or** declared Write paths".
- **REVIEW2-P0-004 — hollow receipts fail**: `integrated` receipts require a non-empty `Accepted` set, an `Approval` naming a real `D-*` decision, and non-`none` `Verification`; the `Target Package` must be the current package or one recorded in `EVENTS.md`; Status and Relation must be compatible (deferred↔deferred, rejected↔rejected); and `lineage_incomplete` demands a `Lineage Note` explaining why pre-layer history is unavailable.
- **REVIEW2-P1-005 — task capsule IDs resolve, budgets apply**: task capsule Methods/Facts/Decisions must be in the DECISIONS.md active block, Components must exist in the project map, Sources in SOURCE_INDEX.md, Assets in ASSETS.md; the 30-path and 60-authority budgets now apply to task capsules.
- **REVIEW2-P2-006** — `tests/smoke.sh` uses the shasum/sha256sum fallback instead of hardcoding `shasum`.
- Root-cause fix for a silent parity bug found while replaying the review fixtures: PowerShell porcelain parsing had been trimming the leading status space, shifting the path slice and making content hashes constant. Both gate and readiness now parse raw porcelain lines.

### Added

- New negative test families on both platforms: already-dirty file changing after the stamp, capsule drift after the stamp, baselined path rewritten after the baseline, worker declaring `docs/MAIN.md` in Write, hollow integrated receipts (five distinct diagnostics), and task capsules referencing phantom `M-*`/`C-*` records — plus positive controls.

## [0.4.1] - 2026-08-19

Hardening release closing all five blockers from the external replacement review (REVIEW-P0-001..004, REVIEW-P1-005) plus the coupled secondary findings (P2-006..011). No protocol grammar changes; PPS/1.2 declarations gain enforcement.

### Fixed

- **REVIEW-P0-001 — verify gate now actually verifies**: `verify_gate.*` deletes any prior stamp first, requires the Workset `Verify` declaration to route through the gate, executes the mandatory non-placeholder `scripts/project_verify.*` entry, and writes a stamp only on success. The stamp now binds package, entry path, entry SHA-256, capsule SHA-256, platform, result, and worktree identity (HEAD + porcelain hash). `readiness_check.*` verifies every stamp field, rejects a changed entry or changed worktree, and never accepts attestation alone. Free-form Markdown is never passed to a shell; commands live in the version-controlled entry script.
- **REVIEW-P0-002 — task capsules enforce the full Workset grammar**: task capsules are validated with the same field, ID-typing, path-safety, and budget rules as `CONTEXT.md` (all eleven fields required, `.`/globs/`..`/absolute paths rejected, byte and line budgets applied). Output Roots must resolve inside the repository, live under `local-task-output/`, and may not overlap another task's root.
- **REVIEW-P0-003 — terminal task states require receipts**: `integrated`/`deferred`/`rejected` tasks must be named by exactly one merge receipt with a matching status. Receipts must carry all eleven fields; Source Tasks must resolve to registered `T-*` IDs, Approval to existing `D-*` records, Target Package to a `PKG-*` ID; Accepted/Rejected/Deferred sets may not overlap; `integrated` checkpoints must be resolvable Git commits or the explicit `lineage_incomplete` marker.
- **REVIEW-P0-004 — canonical identity no longer grants write permission**: `boundary_check.*` derives claims only from the acting subject (Hot State `Writer`, `--task`/`-Task`, or the canonical capsule in single-task projects) — its declared Write set plus its own Output Root. Canonical files are claimed like any other path; tasks cannot borrow each other's claims.
- **REVIEW-P1-005 — Red Lines must be the first H2**: the validator now distinguishes missing, duplicated, and misplaced `## Red Lines` sections in `AGENTS.md`.
- **P2-008** — `--allow-preexisting`/`-AllowPreexisting` requires a session baseline recorded via `--record-baseline`/`-RecordBaseline`; only baselined paths downgrade, and post-baseline changes still fail.
- **P2-009** — proposal-aging warnings are suppressed when the proposal is restated in hot-state `Next`, matching the documented discipline.
- **P2-010** — `append_event.*` inserts into the `## Events` section instead of the end of the file, so trailing sections cannot absorb events.

### Added

- Required `scripts/project_verify.*` templates with real minimal assertions (main artifact exists, chronicle non-empty) and explicit extension points.
- Negative tests on both platforms: failing project verification blocks stamp and readiness; unrouted Verify declarations are rejected; stale-worktree stamps are rejected; task capsules missing fields, root-escaping or overlapping Output Roots, terminal tasks without receipts, receipts referencing unknown tasks, unclaimed canonical writes, baseline-gated preexisting handling, and event placement with trailing sections.

## [0.4.0] - 2026-08-19

PPS/1.2: a field-driven distillation from two real campaigns—a 13-day multi-agent relay project (5 recorded incidents) and a single-owner multi-task content platform (8 confirmed defects). PPS/1.0 and PPS/1.1 projects continue to validate unchanged.

### Added

- **Relay handover protection**: rigid session-start `git status` rule, prohibition on wholesale-overwriting dirty files, and explicit session-end handover via hot-state `Next` (from the relay-overwrite incident where an uncommitted hardening silently vanished between two agent sessions).
- **Verify gate with execution evidence**: required `scripts/verify_gate.*` runs structural validation plus declared project checks and writes a device-local `.pps/verify-stamp`; `readiness_check.*` now rejects attestation when the stamp is missing or names another package (from the BOM incident where a known regimen was never run, and the splat incident where green unit tests coexisted with a dead system). Behavioral end-to-end assertions and liveness probes are explicit, legitimate Verify members.
- **Event chronicling**: required `EVENTS.md` with fixed grammar (`date: [PKG] title | files | verify | pending`), `scripts/append_event.*` to prevent format drift, malformed-line validation, and a 200-line archive warning (from the observation that status events were the only complete project narrative but had no format or budget).
- **Coverage evidence cells**: PPS/1.2 coverage rows must name the command, test, or inspection backing them; bare `Present` fails (from the 17-row table that stayed uniformly green for 13 days, indistinguishable from never checked). The standard profile may externalize coverage to `docs/coverage.md`.
- **Proposal aging**: proposals carry `(opened YYYY-MM-DD)`; pending past seven days warns until restated in `Next` (from the checklist that hung six days with zero pressure).
- **Red-lines protocol position**: `AGENTS.md` first section `## Red Lines` is required and L0-read before any edit; content stays project-specific (from four of five incidents being engineering-layer traps the authority system never covered).
- **Single-owner multitask layer (optional)**: stable `T-*` task IDs in `TASK_INDEX.md`, per-task capsules under `task-contexts/`, a `Writer:` lease naming the single active integrator, bounded worker/consumer output roots, typed merge receipts in `MERGES.md` (`absorbs`/`layers_on`/`consumes_only`/`deferred`/`supersedes`/`rejected`/`rollback_to`), and checkpoint requirements for `integrated` status. Activated only when `TASK_INDEX.md` exists; single-task projects pay nothing. New reference: `references/multitask.md`.
- **Write-boundary enforcement**: `scripts/boundary_check.*` classifies every worktree change as claimed by the canonical Write set, a task Write set, or a task output root—or fails it as `unclaimed_write`; pre-existing shared-worktree dirt is classified explicitly, never silently absorbed (from the derived PPT task whose scratch directory polluted product linting).
- Validator gates for all of the above on both platforms: missing events file, malformed event lines, missing red-lines section, bare-Present coverage, missing Writer lease, duplicate task IDs, two active integrators, workers claiming canonical writes, missing output roots, integrated receipts without checkpoints, and stale/missing verify stamps.
- Negative smoke tests for every new gate in both Bash and PowerShell.

### Changed

- `SKILL.md`, `protocol.md`, `retrieval-and-gates.md`, `git-sync.md`, and the project `AGENTS.md` template were rewritten around the distilled rules; the capsule is now explicitly a work note with coverage externalization, and human-language commands are documented as intent → action mappings rather than magic keywords.
- `resume_packet.*` now includes the Writer field, up to 12 red lines, and the last 5 events.
- PPS/1.2 requires an explicit `Assets:` workset field (PPS/1.1 keeps its compatibility warning).
- `design-rationale.md` records the field-campaign lessons and the "make doing the right thing cheaper" principle.
- `migration.md` adds the PPS/1.1 → 1.2 upgrade path; audits recognize PPS/1.2 projects.
- Templates ignore `.pps/` and `local-task-output/`; the coverage tables ship with evidence cells.

### Unchanged by design

- Single-owner, serial canonical writes; no locks, backlogs, roles, or concurrent merge authority.
- The validator never auto-executes untrusted manifest commands; evidence is checked, execution stays with the agent.
- Untriggered mechanisms (asset tiers, L1-L3, stages, evidence profile) are retained; two field samples not exercising a mechanism is not evidence against it.

## [0.3.0] - 2026-07-23

### Added

- Optional `ASSETS.md` registry with stable `A-*` IDs, `core`/`supporting`/`reference` priorities, and `git`/`git-lfs`/`cloud`/`local-marker` routing.
- Bash and PowerShell asset checks for local size/SHA-256 integrity, Git/LFS declarations, required materialization, durable rclone copy presence, and tracked non-LFS repository bloat.
- Explicit readiness gates that keep arbitrary project verification out of the validator and require caller attestation before a package can be reported ready.
- Environment capabilities for PowerShell, LibreOffice, Poppler, and rclone plus project dependency-manifest and environment-verification declarations.
- Negative tests for missing core assets, marker-only core assets, reference assets in the active Workset, secret-bearing cloud locators, absent durable cloud copies, unverified readiness, and files above the 95 MiB non-LFS safety ceiling.

### Changed

- Legacy audits now infer document/software/hybrid migration signals from real implementation files, prune common generated/dependency trees, count only strict authority tokens, identify free-form authority risk, and report machine/tool contamination and binary-asset candidates.
- Pre-commit snapshots include staged asset registries and both platform asset validators.
- Resume and status checks report Git state and asset materialization as separate dimensions.
- macOS validation instructions use `python3`; Windows instructions retain `python`.

### Fixed

- False authority detection where ordinary strings such as `UTF-8` were counted as `F-8`.
- Bash legacy-audit failure when a target had no `docs/` directory.
- A staged asset registry being validated without its staged-snapshot checker dependencies.

## [0.2.0] - 2026-07-23

### Added

- PPS/1.1 `document`, `software`, and `hybrid` project modes.
- Stable `PROJECT_MAP.md` component IDs and bounded `Components`, `Read`, `Write`, and `Verify` worksets.
- Bash and PowerShell resume packets with a 240-line hard limit and no source-body output.
- Bash and PowerShell environment doctors with allowlisted tools, read-only checks, install-plan preview, and explicit double-confirmed apply mode.
- Cross-platform 200,001-line source isolation tests, PPS/1.0 compatibility fixtures, and negative tests for missing maps, missing scripts, path escape, oversized worksets, duplicate components, and unknown tools.
- Read-only Bash and PowerShell legacy project audit commands with migration-system classification and proposed migration reports.
- Cross-platform smoke coverage proving that audits do not modify their targets and cannot write reports inside them.
- A legacy capability matrix, installed-skill health validators, asset-routing guidance, and project-local pre-commit gates.
- A repository-level adversarial review recording attack cases, acceptance evidence, and residual boundaries.
- Linux, macOS, and Windows validation jobs for both normal CI and tagged releases.
- Negative fixtures for malformed sections, manifests, authority lifecycles, package links, source rows, paths, timestamps, and staged-state bypass attempts.

### Changed

- Reframed PPS as Personal Project State for long-lived individual document, software, and hybrid projects.
- PPS/1.1 validators accept a file or directory `Main` according to mode while continuing to validate PPS/1.0 projects.
- Pre-commit snapshots now materialize PPS/1.1 map/environment controls plus bounded read and component anchors.
- Cold-start guidance now checks the declared environment before bounded recovery.
- Kept PPS self-contained: its runtime, protocol, migration rules, and documentation no longer depend on an external state workflow.
- Restored cross-device ergonomics from `plan-project-sync`: stable `main`, remote/upstream/ahead/behind status, optional fetch, human-language commands, cold-start GitHub paths, `docs/assets/prototypes`, and project-home compatibility.
- Validators now enforce canonical section placement, strict typed manifest lists, real UTC dates, safe project-relative paths, one active marker pair, globally unique authority records, package consistency, and exact coverage/source cardinality.
- Conflict diagnostics now include source line locations for duplicate authority, coverage, and source rows.
- Pre-commit validation now checks a minimal materialized snapshot of the Git index rather than the mutable worktree.

### Fixed

- Audit commands now recognize both PPS/1.0 and PPS/1.1 instead of misclassifying a valid upgraded project.
- macOS smoke-test compatibility by using a portable `sed -i.bak` invocation.
- Cross-platform PowerShell smoke-test cleanup by using the native directory separator.
- Bash validation state loss caused by command-substitution subshells.
- False mixed-system audit classification caused by treating an ordinary roadmap as a second state engine.
- Unsafe project names, missing Bash option values, PowerShell hook permissions, and symlink/reparse-point path escapes.

## [0.1.0] - 2026-07-23

### Added

- Initial public PPS/1.0 skill.
- Globally stable `M/F/D` authority IDs with separate `P/H` semantics.
- Explicit workset manifest and active authority block.
- Standard and evidence project profiles.
- PowerShell and Bash project initialization, status, and validation scripts.
- Constraint-coverage and inactive-decision failure gates.
- Migration, Git handoff, and design-rationale references.
- Cross-platform CI, smoke tests, and open-source governance.

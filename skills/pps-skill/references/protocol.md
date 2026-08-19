# PPS/1.2 protocol

## Purpose

PPS serves long-lived personal projects whose output may be a document, lightweight software, or both. It prevents memory drift and context overflow by making current authority, architecture navigation, target paths, verification, and progress explicit.

PPS/1.2 distills two field campaigns: a single-thread multi-agent relay project and a single-owner multi-task project. It adds relay protection, executable verification gates, event chronicling, coverage evidence, proposal aging, red-line placement, and an optional single-owner multitask layer. PPS/1.0 and PPS/1.1 projects continue to validate unchanged.

## Truth layers

| Layer | Canonical location | Meaning |
|---|---|---|
| Synchronized history | Git repository and configured remote | Recoverable sequence of changes |
| Current content | `Main` path in `PROJECT_STATE.md` | What the deliverable currently says |
| Architecture navigation | `PROJECT_MAP.md` | Stable components and entry boundaries, never a full file inventory |
| Workflow position | `PROJECT_STATE.md` | Current stage, package, blocker, next action |
| Active authority | marked active block in `DECISIONS.md` | Constraints binding current work |
| Event chronicle | `EVENTS.md` (PPS/1.2) or `DECISIONS.md` Status Events (older) | Ordered project history that later agents replay |
| Current workset | `CONTEXT.md` | Exact IDs and artifacts required for the active package |
| Task registry | optional `TASK_INDEX.md` + `task-contexts/T-*.md` | Per-task isolation, roles, and integration state |
| Merge lineage | optional `MERGES.md` | Typed relations between task outputs and packages |
| External evidence | `SOURCE_INDEX.md` and original sources | Provenance and limits of factual claims |
| Asset identity | optional `ASSETS.md` | Priority, sync backend, locator, expected size, and digest |
| Device materialization | `local-assets/`, Git, LFS, or declared cloud backend | Whether required bytes are available and verified on this device |
| Verification evidence | device-local `.pps/verify-stamp` | Proof that the declared gate actually ran on this device |
| Propagation proof | current coverage artifact | Where each required constraint is reflected, with evidence |
| Environment contract | `ENVIRONMENT.md` | Required capabilities and project commands |

No lower layer may override a higher semantic authority. Git history records old states; it does not make every historical statement currently valid. Two standing self-knowledge rules are load-bearing: **structural coverage never proves semantic correctness**, and **a synchronized Git repository never proves that assets are materialized or that the deployed system actually loaded the new code**.

## Authority classes

Use globally unique, stable IDs.

| Class | Meaning | Who may create or change it | Active index |
|---|---|---|---|
| `M-*` | Method, governance, or quality constraint | User or accepted project protocol | Yes |
| `F-*` | Authoritative product/external fact | User or cited authoritative source | Yes |
| `P-*` | Agent proposal awaiting approval | Agent | No |
| `H-*` | Reversible, local working assumption | Agent | No |
| `D-*` | User-approved design decision | User approval, recorded by agent | Yes |

Rules:

- Do not rewrite an `F-*` to make a proposal easier.
- Give a complete `P` recommendation instead of replacing design work with questions.
- Use `H` only when reversible, local, and non-blocking. State its expiry condition. A wrong `H` loses time, not order: supersede it fast and keep `D` records clean.
- Promote a proposal to `D-*` only after explicit approval.
- Supersede rather than renumber. Remove the old ID from the active block, preserve its record, and append an event.
- PPS/1.2 proposals carry an opened date: `- P-002 (opened 2026-08-19): ...`. A proposal pending longer than seven days must be explicitly re-stated in `Next` as kept, closed, or split; silence is treated as abandonment and the validator warns.

## Profiles

### Standard

Required files:

- `README.md`
- `AGENTS.md`
- `PROJECT_STATE.md`
- `DECISIONS.md`
- `CONTEXT.md`
- `EVENTS.md` (PPS/1.2)
- the main artifact named in state
- project-local status, validation, and verify-gate scripts

The constraint-coverage table lives in `CONTEXT.md`, or in `docs/coverage.md` when the capsule needs the room.

### Evidence

Adds:

- `SOURCE_INDEX.md`
- `docs/CURRENT_REVIEW_EVIDENCE.md`

The dedicated evidence file holds the current object/source/constraint coverage matrix. Raw sources remain in user-selected locations and are routed by stable source IDs.

## Modes

PPS/1.2 requires `Mode: document`, `software`, or `hybrid`. Profile controls evidence strength; mode controls output navigation. Read [project-modes.md](project-modes.md) before selecting a mode.

## Hot-state grammar

`PROJECT_STATE.md` must contain a `## Hot State` section with exact single-line fields:

```text
- Protocol: PPS/1.2
- Profile: standard
- Mode: software
- Stage: ...
- Main: .
- Map: PROJECT_MAP.md
- Environment: ENVIRONMENT.md
- Package: PKG-001
- Status: active
- Capsule: CONTEXT.md
- Coverage: CONTEXT.md
- Blockers: none
- Next: ...
- Updated: 2026-01-01T00:00:00Z
- Device: workstation-name
```

Allowed `Status` values are `active`, `review_pending`, `blocked`, and `complete`. `Main` must be a file for document mode and may be a file or directory for software/hybrid mode. `Map` and `Environment` must be project-relative files.
All listed fields must occur exactly once inside `## Hot State`; copies elsewhere do not satisfy the grammar.
`Package` must be a stable `PKG-*` ID. `Updated` must use UTC `YYYY-MM-DDTHH:MM:SSZ`.

When the multitask layer is active, hot state adds exactly one `- Writer: T-*` line naming the single task that currently holds canonical write authority.

Paths must be project-relative and must not escape the repository.
Use `/` separators. Canonical paths may not contain `..`, absolute prefixes, backslashes, or symbolic-link/reparse-point traversal.
New projects record `Device`. The validator continues to accept PPS/1.0 and PPS/1.1 with their original fields; migration is explicit and documented.

## Workset grammar

`CONTEXT.md` must contain:

```text
## Workset Manifest
- Methods: M-001
- Facts: F-001, F-002
- Decisions: D-001
- Sources: none
- Assets: none
- Components: C-APP
- Read: package.json, src/app.ts
- Write: src/app.ts, tests/app.test.ts
- Verify: npm test -- app
- Excluded: none
- Coverage: CONTEXT.md
```

Use `none` for an empty class. The parser intentionally fails when a non-empty manifest field contains no valid IDs.
Non-empty authority/source/asset fields must be strict typed comma-separated IDs. `Components` uses strict `C-*` IDs and `Assets` uses stable `A-*` IDs. `Read` and `Write` use non-empty comma-separated safe project-relative paths; `.` and glob syntax are forbidden because entries are exact files or bounded subdirectories. A directory entry is search scope, never permission to load every descendant. Combined path count above twelve warns and above thirty fails. Combined `M/F/D` IDs fail above sixty; source, asset, and component IDs fail above thirty. PPS/1.2 requires the `Assets` field explicitly; older PPS/1.1 capsules without it are treated as `none` with a compatibility warning. `Excluded` is required and uses `none` when empty.

`Verify` is an ordered declaration of one or more checks separated by ` ; `. PPS/1.2 recommends making the first step the project verify gate (`scripts/verify_gate.sh` / `scripts/verify_gate.ps1`) so that structural validation, project checks, and red-line checks run as one command. Verification may and should include behavioral assertions—user-visible end-to-end smoke checks—because unit-level green does not prove the wired system works, and deployment does not prove the new code was ever loaded. Structural validation never auto-executes `Verify`; execution evidence is separate (see the verify gate section).

All protocol-version fields must occur exactly once inside `## Workset Manifest`; copies elsewhere do not satisfy the grammar.

The package ID in `PROJECT_STATE.md`, `CONTEXT.md`, and the evidence artifact when present must match exactly.

Keep the capsule at or below 60 lines when practical and never above 80 lines or 32768 bytes. `PROJECT_STATE.md` also fails above 32768 bytes. The capsule is a work note, not a ledger: keep Workset, current package, pending feedback, proposals, assumptions, risks, and next action there; move the coverage table to `docs/coverage.md` and history to `EVENTS.md` when the capsule approaches its budget.

## Component-map grammar

Every workset `C-*` ID has exactly one row in `PROJECT_MAP.md` under `## Components`. Every component-shaped row must use the full five-column grammar, have a globally unique ID, and resolve to an existing contained Root—even when the component is not in the current workset. Component IDs are stable navigation handles, not authority. Their Root may be a file or directory and should represent an architecture boundary rather than an individual file.

`PROJECT_MAP.md` targets at most 160 lines and fails above 240 lines or 65536 bytes. It must not contain generated file trees, dependency dumps, source code, or chronological logs.

## Event grammar

`EVENTS.md` is required for PPS/1.2 projects and is the project's chronicle of record. Each event is one line under `## Events`, newest last:

```text
- 2026-08-19: [PKG-001] Hardened installer probing | files: scripts/install.ps1 | verify: verify_gate pass | pending: user retest
```

Grammar: `- YYYY-MM-DD: [PKG-*] title | files: ... | verify: ... | pending: ...`. The `files`, `verify`, and `pending` segments are required so that a later agent can reconstruct the scene; use `none` when empty. Append with `scripts/append_event.*` to prevent format drift. When the file exceeds 200 lines, archive older months to `docs/events-archive/YYYY-MM.md` and keep a pointer line. Older projects keeping Status Events inside `DECISIONS.md` remain valid; new events should move to `EVENTS.md` at the next natural checkpoint.

## Environment grammar

`ENVIRONMENT.md` contains exactly one `## Toolchain Manifest` with `Required`, `Optional`, `Package manager`, and `Install policy`, and fails above 16384 bytes. New projects also declare `Dependency manifests` and `Environment verify`; older files remain compatible. Tool lists use the allowlisted names defined in [environment-bootstrap.md](environment-bootstrap.md), and `Required` always includes `git`. The validator checks declarations only; system changes require the explicit doctor apply gate. Before clone, the installed skill's core doctor preset requires both `git` and `gh` without needing a project manifest.

## Asset grammar

`ASSETS.md` is optional until the first governed external or binary asset appears. It contains one row per stable `A-*` ID under `## Asset Manifest`:

```text
| ID | Priority | Sync | Materialize | Locator | SHA-256 | Bytes | Purpose |
```

Priorities are `core`, `supporting`, and `reference`. Sync backends are `git`, `git-lfs`, `cloud`, and `local-marker`.

- `core` may not use `local-marker`.
- all `core` rows and current Workset `supporting` rows must materialize before readiness;
- `reference` rows may be absent and may not enter the current Workset;
- cloud/local materializations live under ignored `local-assets/`;
- cloud rows require a non-secret `rclone:REMOTE:path` locator;
- size and SHA-256 describe expected content, not device-local availability.

Git synchronization and materialization are reported separately. Structural validation checks registry grammar. Quick resume checks existence and size. Full handoff checks local SHA-256, proves that a cloud locator contains exactly one object with the declared size, and rejects materially incomplete current assets. See [asset-management.md](asset-management.md).

## Verify gate and execution evidence

Declared verification is only useful when it runs. PPS/1.2 makes doing the right thing cheaper than skipping it:

- `scripts/verify_gate.sh` / `scripts/verify_gate.ps1` are required project files. The gate runs structural validation, then the project's own declared checks, in order, failing fast. Projects extend the gate rather than scattering checks.
- A successful gate writes `.pps/verify-stamp` (git-ignored, device-local) containing the UTC time and current package ID.
- `readiness_check.* --verified`/`-Verified` still requires the caller's attestation, and additionally rejects readiness when the stamp is missing or names a different package. The stamp proves the gate ran on this device for this package; it does not prove semantic correctness.
- The validator never auto-executes `Verify` or the gate; it only checks that the gate files exist. Execution stays under the agent's inspection and control.

## Active authority grammar

`DECISIONS.md` contains exactly one machine-readable active block, with exactly one begin marker and one end marker:

```text
<!-- PPS:ACTIVE:BEGIN -->
- `M-001`
- `F-001`
- `D-001`
<!-- PPS:ACTIVE:END -->
```

Every active ID has one canonical heading:

```text
### D-001 [active]
```

Permitted record statuses are `active`, `superseded`, `rejected`, and `frozen`. The active block contains only records whose status is `active`.
Every `M/F/D` ID has exactly one canonical record across all statuses. The active block and `[active]` records are a bijection: every block ID has one active record, and every active record appears exactly once in the block.

Every manifest-listed authority ID and source ID has exactly one row in its required coverage or source table. Duplicate rows are errors because they can hide conflicting propagation results. PPS/1.2 coverage rows carry an evidence column: a bare `Present` is the weakest acceptable form and the validator requires the evidence cell to name the command, test, or inspection that backs the row—otherwise the table cannot distinguish "checked and fine" from "never checked".

## Red lines

Engineering red lines—project-specific hard prohibitions born from real incidents (encoding rules, banned language constructs, forbidden silent error handling)—get a fixed protocol position: the first section of `AGENTS.md`, titled `## Red Lines`. L0 recovery reads it before any edit. The protocol defines the position, format (one imperative line per rule, with the incident or reason in parentheses), and reading order; the content itself is always project-specific and never part of PPS.

## Serial integration authority

PPS assumes one human owner. Canonical state is written serially, but PPS/1.2 recognizes two real execution shapes under that single owner:

**Relay (default).** Different agents and devices take turns; each session is a full owner of canonical state while it runs. The dangerous moment is the handover, and Git protects committed history only—nothing protects an uncommitted worktree between sessions. Relay rules are therefore rigid:

1. Every session starts with `git status`. If the worktree is dirty, read the diff and understand it before any edit; wholesale rewriting of a dirty file is forbidden.
2. Every session ends by either committing its work or recording an explicit handover in hot-state `Next` ("worktree holds my uncommitted X").
3. The mental model is shared-worktree serial sessions under one author intent, not independent writers. Uncommitted work left by the previous session is the previous session's message to you, not noise to overwrite.

**Multitask (optional layer).** When several long-lived tasks genuinely coexist—research threads, candidate generators, consumers—activate the task registry (see [multitask.md](multitask.md)). Exactly one task holds canonical write authority (`Writer:` in hot state); workers and consumers work in declared output roots and hand results to the integrator through typed merges. The layer activates only when `TASK_INDEX.md` is created; single-task projects pay nothing.

During any package, only the current canonical writer edits:

- `PROJECT_STATE.md`
- `DECISIONS.md`
- `CONTEXT.md`
- `EVENTS.md`, `TASK_INDEX.md`, `MERGES.md` when present
- current main artifact
- `PROJECT_MAP.md` when architecture changes
- current coverage artifact

Parallel research may inspect sources or draft isolated suggestions. It returns findings and exact locations; the canonical writer integrates them serially.

PPS is not a multi-user coordination protocol. It provides no distributed lock, team backlog, role model, or concurrent merge authority. Relay handles handover; the multitask layer handles single-owner task bookkeeping; neither is concurrency.

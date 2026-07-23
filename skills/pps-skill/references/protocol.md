# PPS/1.1 protocol

## Purpose

PPS serves long-lived personal projects whose output may be a document, lightweight software, or both. It prevents memory drift and context overflow by making current authority, architecture navigation, target paths, verification, and progress explicit.

## Truth layers

| Layer | Canonical location | Meaning |
|---|---|---|
| Synchronized history | Git repository and configured remote | Recoverable sequence of changes |
| Current content | `Main` path in `PROJECT_STATE.md` | What the deliverable currently says |
| Architecture navigation | `PROJECT_MAP.md` | Stable components and entry boundaries, never a full file inventory |
| Workflow position | `PROJECT_STATE.md` | Current stage, package, blocker, next action |
| Active authority | marked active block in `DECISIONS.md` | Constraints binding current work |
| Current workset | `CONTEXT.md` | Exact IDs and artifacts required for the active package |
| External evidence | `SOURCE_INDEX.md` and original sources | Provenance and limits of factual claims |
| Asset identity | optional `ASSETS.md` | Priority, sync backend, locator, expected size, and digest |
| Device materialization | `local-assets/`, Git, LFS, or declared cloud backend | Whether required bytes are available and verified on this device |
| Propagation proof | current coverage artifact | Where each required constraint is reflected |
| Environment contract | `ENVIRONMENT.md` | Required capabilities and project commands |

No lower layer may override a higher semantic authority. Git history records old states; it does not make every historical statement currently valid.

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
- Use `H` only when reversible, local, and non-blocking. State its expiry condition.
- Promote a proposal to `D-*` only after explicit approval.
- Supersede rather than renumber. Remove the old ID from the active block, preserve its record, and append a status event.

## Profiles

### Standard

Required files:

- `README.md`
- `AGENTS.md`
- `PROJECT_STATE.md`
- `DECISIONS.md`
- `CONTEXT.md`
- the main artifact named in state
- project-local status and validation scripts

The constraint-coverage table lives in `CONTEXT.md`.

### Evidence

Adds:

- `SOURCE_INDEX.md`
- `docs/CURRENT_REVIEW_EVIDENCE.md`

The dedicated evidence file holds the current object/source/constraint coverage matrix. Raw sources remain in user-selected locations and are routed by stable source IDs.

## Modes

PPS/1.1 requires `Mode: document`, `software`, or `hybrid`. Profile controls evidence strength; mode controls output navigation. Read [project-modes.md](project-modes.md) before selecting a mode.

## Hot-state grammar

`PROJECT_STATE.md` must contain a `## Hot State` section with exact single-line fields:

```text
- Protocol: PPS/1.1
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

Paths must be project-relative and must not escape the repository.
Use `/` separators. Canonical paths may not contain `..`, absolute prefixes, backslashes, or symbolic-link/reparse-point traversal.
New projects record `Device`. The validator continues to accept PPS/1.0 with its original fields; migration to 1.1 is explicit and documented.

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
Non-empty authority/source/asset fields must be strict typed comma-separated IDs. PPS/1.1 `Components` uses strict `C-*` IDs and `Assets` uses stable `A-*` IDs. `Read` and `Write` use non-empty comma-separated safe project-relative paths; `.` and glob syntax are forbidden because entries are exact files or bounded subdirectories. A directory entry is search scope, never permission to load every descendant. Combined path count above twelve warns and above thirty fails. Combined `M/F/D` IDs fail above sixty; source, asset, and component IDs fail above thirty. `Assets` is additive: older PPS/1.1 capsules without it are treated as `none` with a compatibility warning. `Verify` is a non-empty declaration and is never auto-executed by structural validation. `Excluded` is required and uses `none` when empty.
All protocol-version fields must occur exactly once inside `## Workset Manifest`; copies elsewhere do not satisfy the grammar.

The package ID in `PROJECT_STATE.md`, `CONTEXT.md`, and the evidence artifact when present must match exactly.

Keep the capsule at or below 60 lines when practical and never above 80 lines or 32768 bytes. `PROJECT_STATE.md` also fails above 32768 bytes. Move detail to the main artifact, evidence table, or canonical records; leave exact pointers in the capsule.

## Component-map grammar

Every workset `C-*` ID has exactly one row in `PROJECT_MAP.md` under `## Components`. Every component-shaped row must use the full five-column grammar, have a globally unique ID, and resolve to an existing contained Root—even when the component is not in the current workset. Component IDs are stable navigation handles, not authority. Their Root may be a file or directory and should represent an architecture boundary rather than an individual file.

`PROJECT_MAP.md` targets at most 160 lines and fails above 240 lines or 65536 bytes. It must not contain generated file trees, dependency dumps, source code, or chronological logs.

## Environment grammar

`ENVIRONMENT.md` contains exactly one `## Toolchain Manifest` with `Required`, `Optional`, `Package manager`, and `Install policy`, and fails above 16384 bytes. New projects also declare `Dependency manifests` and `Environment verify`; older PPS/1.1 files remain compatible. Tool lists use the allowlisted names defined in [environment-bootstrap.md](environment-bootstrap.md), and `Required` always includes `git`. The validator checks declarations only; system changes require the explicit doctor apply gate. Before clone, the installed skill's core doctor preset requires both `git` and `gh` without needing a project manifest.

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

Every manifest-listed authority ID and source ID has exactly one row in its required coverage or source table. Duplicate rows are errors because they can hide conflicting propagation results.

## Single-writer rule

Only the primary task edits these canonical files during the active package:

- `PROJECT_STATE.md`
- `DECISIONS.md`
- `CONTEXT.md`
- current main artifact
- `PROJECT_MAP.md` when architecture changes
- current coverage artifact

Parallel agents may inspect sources or draft isolated suggestions. They return findings and exact locations; the primary task integrates them serially.

PPS is not a multi-user coordination protocol. It provides no distributed lock, team backlog, role model, or concurrent merge authority.

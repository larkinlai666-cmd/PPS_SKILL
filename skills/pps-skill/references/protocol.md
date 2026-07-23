# PPS/1.0 protocol

## Purpose

PPS serves long-lived proposal projects whose deliverable is a reviewed artifact rather than executable code. Its primary failure to prevent is semantic drift: an approved constraint exists in history but is not retrieved, or is retrieved but not propagated into the current output.

## Truth layers

| Layer | Canonical location | Meaning |
|---|---|---|
| Synchronized history | Git repository and configured remote | Recoverable sequence of changes |
| Current content | `Main` path in `PROJECT_STATE.md` | What the deliverable currently says |
| Workflow position | `PROJECT_STATE.md` | Current stage, package, blocker, next action |
| Active authority | marked active block in `DECISIONS.md` | Constraints binding current work |
| Current workset | `CONTEXT.md` | Exact IDs and artifacts required for the active package |
| External evidence | `SOURCE_INDEX.md` and original sources | Provenance and limits of factual claims |
| Propagation proof | current coverage artifact | Where each required constraint is reflected |

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

## Hot-state grammar

`PROJECT_STATE.md` must contain a `## Hot State` section with exact single-line fields:

```text
- Protocol: PPS/1.0
- Profile: standard
- Stage: ...
- Main: docs/MAIN.md
- Package: PKG-001
- Status: active
- Capsule: CONTEXT.md
- Coverage: CONTEXT.md
- Blockers: none
- Next: ...
- Updated: 2026-01-01T00:00:00Z
- Device: workstation-name
```

Allowed `Status` values are `active`, `review_pending`, `blocked`, and `complete`.
All listed fields must occur exactly once inside `## Hot State`; copies elsewhere do not satisfy the grammar.
`Package` must be a stable `PKG-*` ID. `Updated` must use UTC `YYYY-MM-DDTHH:MM:SSZ`.

Paths must be project-relative and must not escape the repository.
Use `/` separators. Canonical paths may not contain `..`, absolute prefixes, backslashes, or symbolic-link/reparse-point traversal.
New projects record `Device`; migrated PPS/1.0 projects may add it on their next state update.

## Workset grammar

`CONTEXT.md` must contain:

```text
## Workset Manifest
- Methods: M-001
- Facts: F-001, F-002
- Decisions: D-001
- Sources: none
- Excluded: none
- Coverage: CONTEXT.md
```

Use `none` for an empty class. The parser intentionally fails when a non-empty manifest field contains no valid IDs.
Non-empty `Methods`, `Facts`, `Decisions`, and `Sources` fields must be strict comma-separated lists containing only IDs of the declared class; duplicates and extra text are errors. `Excluded` is required and must use `none` when empty.
All six fields must occur exactly once inside `## Workset Manifest`; copies elsewhere do not satisfy the grammar.

The package ID in `PROJECT_STATE.md`, `CONTEXT.md`, and the evidence artifact when present must match exactly.

Keep the capsule at or below 60 lines when practical and never above 80 lines. Move detail to the main artifact, evidence table, or canonical records; leave exact pointers in the capsule.

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
- current coverage artifact

Parallel agents may inspect sources or draft isolated suggestions. They return findings and exact locations; the primary task integrates them serially.

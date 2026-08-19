# Single-owner multitask layer

## When to activate

Most PPS projects never need this layer. Activate it only when several long-lived tasks genuinely coexist inside one project under one owner: a canonical integration thread plus research threads, candidate generators, derived-output consumers, or deferred feature tracks. Creating `TASK_INDEX.md` activates the layer; deleting no file is ever required to stay single-task. A single-task project pays zero cost.

This layer is bookkeeping for serial integration, not concurrency. It provides no lock, no team backlog, no role permissions, and no automatic merging.

## Task registry

`TASK_INDEX.md` contains one `## Task Index` section with one block per task:

```text
### T-001
- Title: Main feature integration
- Role: integrator
- Status: active
- Active Package: PKG-021
- Capsule: task-contexts/T-001.md
- Output Root: none
- External Locator: none
```

Grammar rules:

- Task IDs use stable `T-*` and are never reused or renumbered.
- `Role` is `integrator`, `worker`, or `consumer`.
- `Status` is `active`, `handoff_ready`, `integrated`, `rejected`, `deferred`, or `archived`.
- Exactly one task may hold `Role: integrator` with `Status: active` at any time. That task ID must equal the `Writer:` line in hot state.
- `Capsule` names a per-task file under `task-contexts/`; it must exist for every non-archived task.
- `Output Root` is required for `worker` and `consumer` tasks: a bounded project-relative directory (conventionally under `local-task-output/`, which is git-ignored) where all task writes land. `none` is valid only for the integrator.
- `External Locator` optionally records the host application's thread ID (for example `codex:<uuid>`) for evidence navigation. It is never authority and never a substitute for the `T-*` ID.

## Task capsules

`task-contexts/T-*.md` holds the task's own bounded state: its Read/Write/Verify workset, base checkpoint, candidates, blockers, and handoff note. The project `CONTEXT.md` continues to describe only the canonical integration package. Resuming the project restores the integration capsule; resuming a task restores its own capsule without reading other tasks.

A task capsule follows the same workset grammar and budgets as `CONTEXT.md`. A worker or consumer capsule must not list canonical state files (`PROJECT_STATE.md`, `DECISIONS.md`, `CONTEXT.md`, `EVENTS.md`, `TASK_INDEX.md`, `MERGES.md`, the coverage artifact) in its `Write` set; the validator fails this loudly.

## Writer lease

Hot state carries `- Writer: T-*` naming the current canonical writer. Rules:

- the named task exists in the registry, has `Role: integrator`, and is `active`;
- no second active integrator exists;
- workers and consumers never edit canonical files, even when they are the only session running;
- transferring the lease is an explicit event: update `Writer:`, both task blocks, and append an event in the same commit.

## Task completion semantics

`Status` deliberately splits meanings that field practice proved get confused:

- `handoff_ready`: the task's own work is done and its outputs carry a base checkpoint; nothing has entered the project yet.
- `integrated`: a merge receipt records how the outputs entered a package.
- `deferred`: complete in itself, deliberately not merged; the receipt records the reactivation condition.
- `rejected`: evidence retained, outputs excluded; rejection never deletes the record.
- A consumer task finishing (`consume-only`) never makes its outputs project truth.

"Task complete" therefore never implies "merged into the project"; only a receipt does.

## Merge receipts

`MERGES.md` contains one `## Merge Receipts` section with one block per receipt:

```text
### MERGE-001
- Target Package: PKG-017
- Source Tasks: T-003
- Relation: absorbs
- Accepted: app/generator
- Rejected: none
- Deferred: none
- Base Checkpoint: 4f2c9a1
- Result Checkpoint: 8d0b7e6
- Approval: D-033
- Verification: verify_gate pass 2026-08-18
- Status: integrated
```

Relations are typed so lineage is machine-readable instead of narrative:

| Relation | Meaning |
|---|---|
| `absorbs` | Target package includes the source outputs |
| `layers_on` | Target adds a layer without changing the base artifact bytes |
| `consumes_only` | Source read project truth to build a derived deliverable; nothing flows back |
| `deferred` | Outputs complete but deliberately not merged; receipt records the reactivation condition |
| `supersedes` | Target replaces an earlier package's contribution |
| `rejected` | Outputs evaluated and excluded, with reason retained |
| `rollback_to` | Target restores an earlier package state |

Receipt rules:

- `MERGE-*` IDs are stable and unique; the same source/target pair may have several receipts, each with its own ID.
- `Status: integrated` requires both a base checkpoint and a result checkpoint (Git commits, or an explicit `lineage_incomplete` marker when history predates the layer). Without checkpoints the receipt may exist but must not claim `integrated`.
- `Status: integrated` also requires real disposition evidence: a non-empty `Accepted` set, an `Approval` naming the authorizing `D-*` decision, and `Verification` naming the command, test, or inspection that checked the merged result. A receipt whose evidence fields are all `none` is a claim, not a receipt, and fails validation.
- The `Target Package` must be a real package: the current Hot State package or one recorded in `EVENTS.md`.
- `lineage_incomplete` is a migration escape hatch only: the receipt must carry a `Lineage Note` field explaining why pre-layer history is unavailable. Projects with normal Git history must use real checkpoints.
- Status and Relation must agree: `deferred` status requires the `deferred` relation, `rejected` requires `rejected`, and `integrated` is incompatible with both.
- Fingerprints alone are not lineage: knowing the final bytes does not reconstruct who contributed what. Checkpoints do.
- Receipts do not merge code. They record how a human-driven serial merge happened so it can be audited and selectively reconsidered later.

## Write-boundary enforcement

The declared `Write` set becomes enforceable when the layer is active:

- worker/consumer changes must land inside the task's `Output Root`; the task's declared `Write` paths must themselves sit inside that root — a Write declaration is never a second grant channel, and the validator and boundary check both reject Write paths outside the root;
- run `scripts/boundary_check.*` before closing a task or package: it classifies every worktree change as claimed (by the canonical Write set, a task Write set, or a task output root) or flags it as an `unclaimed_write` failure;
- pre-existing dirty files in a shared worktree belong to no current task and must not be claimed by one; classify them explicitly with `--allow-preexisting`/`-AllowPreexisting` instead of silently absorbing them;
- derived-task scratch directories default under git-ignored `local-task-output/` so product linting and tests never scan them.

## What this layer refuses

- Codex/host task titles as identifiers — they drift; only `T-*` is stable.
- Chat history as canonical state.
- Last-modified time as authority ordering.
- Automatic code merging or conflict resolution.
- Granting every worker write access to canonical files.
- One giant `CONTEXT.md` holding all tasks.
- Git branch count as a substitute for task, handoff, and receipt records.
- Any multi-user, multi-owner, or distributed-lock semantics.

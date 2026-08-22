# Migration without dual state

## First rule

Do not initialize PPS into a non-empty repository. Inspect the existing control system and designate one source of truth before writing.

## Audit before writing

Run the installed skill's audit command against the existing project:

```bash
bash <skill>/scripts/audit_legacy_project.sh --root <project>
```

```powershell
powershell -ExecutionPolicy Bypass -File <skill>\scripts\audit_legacy_project.ps1 `
  -Root <project>
```

The command classifies the repository as `pps`, `plan-project-sync`, `other-state-system`, `mixed`, or `unstructured`; recommends a provisional mode/profile; counts strict numeric `M/F/D` IDs; and reports free-form decisions, tool/environment contamination signals, dependency manifests, implementation/prototype code, and binary assets. Generated and dependency directories such as `node_modules`, virtual environments, `vendor`, `dist`, and `build` are pruned so they cannot determine project mode or make the audit unbounded. The audit does not validate semantic authority and does not activate the proposal. Counts and keyword hits are triage signals, not automatic promotion rules.

By default the report goes to standard output. `--output <file>` or `-OutputPath <file>` may save it only outside the target project. The command refuses to overwrite an existing report or write any report inside the audited project, so inspection cannot silently create a second state system.

## From enhanced plan-project-sync

If the repository already has `PROJECT_STATE.md`, `DECISIONS.md`, and `AGENTS.md`, treat it as a legacy plan-project-sync project. `CONTEXT.md` may or may not exist:

1. preserve any existing global IDs and never reuse them;
2. review free-form decisions with the user before assigning new `M/F/D` IDs;
3. keep proposals and hypotheses out of the active index;
4. add the marked active block without deleting historical records;
5. add `Protocol`, `Profile`, `Capsule`, and `Coverage` hot-state fields;
6. add a workset manifest to the current capsule;
7. place the standard coverage table in the capsule, or add evidence artifacts;
8. copy project-local status/validation scripts;
9. classify large assets as core/supporting/reference and create `ASSETS.md` only when required;
10. move machine-specific paths, proxies, and credentials out of workflow truth;
11. validate on a branch and inspect every reported mismatch;
12. switch `AGENTS.md` only after the new validator and readiness gate pass.

Existing project-specific rules may be stricter than PPS. Preserve the stricter rule unless it conflicts with user intent.

## From PPS/1.0 to PPS/1.1

PPS/1.1 is an additive upgrade. Do not reinitialize the repository or renumber authority records:

1. create a recoverable Git checkpoint;
2. choose `document`, `software`, or `hybrid` mode from the current deliverable;
3. add `Mode`, `Map`, and `Environment` to hot state;
4. add one bounded `PROJECT_MAP.md` with stable `C-*` component IDs;
5. add `Components`, `Read`, `Write`, and `Verify` to the current workset;
6. add `ENVIRONMENT.md` with the smallest required and optional tool sets;
7. copy the PPS/1.1 project-local resume, environment, status, and validation scripts;
8. run the environment doctor in check mode, then validate;
9. keep the project on PPS/1.0 if the upgrade cannot pass without changing its existing authority semantics.

The PPS/1.1 validator continues to recognize a valid PPS/1.0 project. Compatibility does not silently mutate it.

## From PPS/1.1 to PPS/1.2

PPS/1.2 is an additive upgrade distilled from two field campaigns. Do not reinitialize or renumber:

1. create a recoverable Git checkpoint;
2. add `EVENTS.md` with one `## Events` section; move future status events there (existing Status Events in `DECISIONS.md` stay valid as history);
3. add a `## Red Lines` first section to `AGENTS.md`; seed it from real incident lessons or leave the placeholder;
4. copy `scripts/verify_gate.*` and `scripts/append_event.*` from the skill; extend the gate with the project's declared checks;
5. add an explicit `Assets:` field to the workset (use `none`);
6. upgrade coverage rows to carry an evidence cell naming the command, test, or inspection; bare `Present` fails;
7. date existing proposals with `(opened YYYY-MM-DD)`;
8. optionally move the coverage table to `docs/coverage.md` and update both `Coverage:` fields together;
9. add `.pps/` and `local-task-output/` to `.gitignore`;
10. set `Protocol: PPS/1.2`, run the verify gate, then validate;
11. keep the project on PPS/1.1 if the upgrade cannot pass without changing its existing authority semantics.

Activate the multitask layer only when the project genuinely has coexisting tasks: create `TASK_INDEX.md` per [multitask.md](multitask.md); single-task projects should not create it.

## From another structured state system

If another structured state system is authoritative:

1. inventory its project, requirements, state, roadmap, plan, context, and summary files;
2. assign global IDs to only currently binding method constraints, facts, and approved decisions;
3. do not promote planner discretion or historical discussion into authority;
4. build one active index and record superseded/rejected outcomes;
5. select the current deliverable as the PPS main artifact;
6. convert current dependencies into the explicit workset manifest;
7. retain the old state files as migration history or archive them only with user approval;
8. stop running both state systems after cutover.

Legacy stage-local decision IDs may repeat. Create a mapping table before assigning global PPS IDs.

## From an unstructured repository

Audit first; do not run the initializer into an existing codebase.

1. identify the current deliverable;
2. distinguish authoritative user facts from historical AI suggestions;
3. extract only binding constraints into globally stable records;
4. mark uncertainty as `P` or `H`, not `D`;
5. choose a mode and define component boundaries rather than inventorying every file;
6. create a compact current package, path workset, environment manifest, and component map;
7. run a user review of the initial active index before treating it as authoritative.

## Migration acceptance

Migration is complete only when:

- one state system is authoritative;
- the active block contains no rejected or merely proposed item;
- current package retrieval uses exact IDs;
- PPS/1.1 retrieval uses stable component IDs and bounded paths;
- coverage is explicit;
- validation passes;
- every core/current supporting asset has a durable sync backend, verified materialization, and—when cloud-backed—a reachable rclone object with matching size;
- a Git checkpoint makes the pre-migration state recoverable.

## Automated migration tool

`scripts/migrate_project.sh` / `scripts/migrate_project.ps1` provide the
auditable upgrade path:

- `--dry-run` (default): prints the full plan — one bootstrap integrator
  task, an empty typed merge registry, a `Decision: approve` migration
  decision, one `migration_authorized` event, and the generated check
  manifest. Writes nothing.
- `--apply --confirm`: backs up every touched file under
  `.pps/migration-backup-<timestamp>/`, writes the new files, and appends the
  decision and event. It does NOT flip the `Protocol:` field — you flip it
  only after `validate_project` passes on both platforms.
- `--rollback <backup dir>`: restores the backup.

The upgrader never guesses historical merges into typed relations; pre-layer
history uses the `lineage_incomplete` escape hatch with an explicit decision.

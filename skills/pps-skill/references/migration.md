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

The command classifies the repository as `pps`, `plan-project-sync`, `other-state-system`, `mixed`, or `unstructured`, inventories control files, and prints a proposed migration report. It does not validate semantic authority and does not activate the proposal.

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
9. validate on a branch and inspect every reported mismatch;
10. switch `AGENTS.md` only after the new validator passes.

Existing project-specific rules may be stricter than PPS. Preserve the stricter rule unless it conflicts with user intent.

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

1. identify the current deliverable;
2. distinguish authoritative user facts from historical AI suggestions;
3. extract only binding constraints into globally stable records;
4. mark uncertainty as `P` or `H`, not `D`;
5. create a compact current package and manifest;
6. run a user review of the initial active index before treating it as authoritative.

## Migration acceptance

Migration is complete only when:

- one state system is authoritative;
- the active block contains no rejected or merely proposed item;
- current package retrieval uses exact IDs;
- coverage is explicit;
- validation passes;
- a Git checkpoint makes the pre-migration state recoverable.

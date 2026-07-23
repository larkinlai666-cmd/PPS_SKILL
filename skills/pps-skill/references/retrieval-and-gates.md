# Retrieval and coverage gates

## Recovery algorithm

Use deterministic retrieval in this order:

1. Run the project status script.
2. Read hot state and the referenced capsule.
3. Parse the workset manifest.
4. Search exact `M/F/D` IDs in `DECISIONS.md`.
5. Read the named main-artifact sections.
6. If source IDs exist, resolve them through `SOURCE_INDEX.md`, then read only the relevant original-source locations.
7. Read Git history only for conflict tracing, supersession, or recovery—not as ordinary context.

This model favors explicit dependency recall over chronological recall. “Recent” is insufficient because an old global decision may govern a new package, while a recent rejected proposal must not.

## Retrieval confidence

Treat retrieval as complete only when:

- each manifest ID appears exactly once in the active block;
- each manifest ID has an active canonical record;
- the requested artifact section is identifiable;
- source rows include provenance and limits when sources are required;
- no higher-authority record conflicts with the intended change.

If an ID is missing or malformed, stop the package write and repair state. Do not infer its text from memory.

## Constraint coverage gate

Before review and after approval, every required `M/F/D` ID must have a coverage row:

```markdown
| ID | Constraint | Artifact / section | Result |
|---|---|---|---|
| M-001 | Keep one package active | PROJECT_STATE / Hot State | One package named |
```

The validator checks structural coverage. The agent must also inspect semantic coverage:

- Does the artifact obey the constraint rather than merely mention it?
- Does any output contradict an active fact or decision?
- Has scope been silently reduced?
- Has a deferred or rejected item been reintroduced?
- Did an approved change propagate to every affected section?

Structural success is necessary, not sufficient.

## Review gate

A package is ready for user review only when it contains:

1. a concrete current-to-proposed output slice;
2. scope and non-goals;
3. a complete recommended design;
4. evidence and trade-offs;
5. the authority-to-output coverage map;
6. only the user decisions that genuinely require approval.

Questions cannot substitute for agent-owned design work. Use a reversible `H` default when safe.

## Close gate

User feedback is not closed until all applicable writes are complete:

- main artifact updated;
- approved `D-*` record active;
- superseded/rejected records preserved with status;
- active block reconciled;
- pending feedback removed or narrowed;
- capsule and next action updated;
- coverage updated;
- validator passes.

## Fail-loud conditions

Treat these as errors:

- a non-empty manifest line that yields no valid IDs;
- a required hot-state or workset field outside its canonical section, or a duplicate canonical section;
- a manifest containing a duplicate ID, an ID of the wrong class, or extra text;
- duplicate or missing active-block entries for required IDs;
- more or fewer than one active-block marker pair;
- an active record outside the active block, or more than one canonical record for an ID;
- required record missing or not `[active]`;
- required coverage or source row absent or duplicated;
- package IDs disagree across state, context, and evidence;
- malformed `PKG-*` package IDs or non-UTC `Updated` timestamps;
- evidence profile without source/evidence files;
- project-relative path escaping the repository or traversing a symbolic link/reparse point;
- capsule over 80 lines;
- malformed content inside the machine-readable active block.

Treat these as warnings:

- capsule over the 60-line target;
- hot state growing beyond its compact target;
- dirty Git worktree;
- active authority not currently in the workset.

Do not weaken a gate to make an invalid project pass. Repair the underlying record, manifest, or propagation.

## Audit levels

- `L0`: hot state, workset manifest, exact active records, current artifact slice.
- `L1`: L0 plus relevant highest-authority sources.
- `L2`: lifecycle or object-by-process coverage matrix for a stage/package audit.
- `L3`: all-source, all-decision, final-deliverable audit before freeze/export.

Escalate only when the current level cannot establish coverage or reveals conflict.

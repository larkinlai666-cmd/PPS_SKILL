# Retrieval and coverage gates

## Session-start relay gate

Before anything else—including the resume packet—run `git status`. This is the relay rule and it is rigid:

1. A dirty worktree means the previous session left work behind. Read the diff and understand it before any edit.
2. Wholesale overwriting of a dirty file is forbidden. Uncommitted changes are the previous session's message, not noise.
3. If hot-state `Next` declares a handover ("worktree holds uncommitted X"), treat those paths as protected until integrated or explicitly discarded with the user.
4. At session end, either commit or record an explicit handover in `Next`.

This gate exists because Git protects committed history only; the handover moment between two sessions is otherwise unguarded.

## Recovery algorithm

Use deterministic retrieval in this order:

1. Run the session-start relay gate above.
2. Run the project-local resume-packet script.
3. Read the `Red Lines` section of `AGENTS.md` before any edit.
4. Read hot state, the referenced capsule, and the named component-map rows.
5. Parse exact `Components`, `Read`, `Write`, and `Verify` entries.
6. Resolve current `A-*` assets and run the quick materialization check; missing core/current supporting bytes are explicit risks, not permission to ignore them.
7. Search exact `M/F/D` IDs in `DECISIONS.md`.
8. Read recent `EVENTS.md` entries for the current package to reconstruct the working scene.
9. Read only the declared `Read` paths and named main-artifact sections.
10. If source IDs exist, resolve them through `SOURCE_INDEX.md`, then read only the relevant original-source locations.
11. When the multitask layer is active and a task is named, restore that task's capsule instead of the integration capsule.
12. Read Git history only for conflict tracing, supersession, or recovery—not as ordinary context.

This model favors explicit dependency recall over chronological recall. “Recent” is insufficient because an old global decision may govern a new package, while a recent rejected proposal must not.

Repository size is not permission to bulk-read it. The map chooses components; the workset chooses paths; exact IDs choose authority. If the declared set is insufficient, amend it before reading more.

## Retrieval confidence

Treat retrieval as complete only when:

- each manifest ID appears exactly once in the active block;
- each manifest ID has an active canonical record;
- each component ID resolves to exactly one map row;
- each declared read path exists and is project-contained;
- each declared write path is project-contained;
- the requested artifact section is identifiable;
- source rows include provenance and limits when sources are required;
- each Workset asset has one valid row and every core/current supporting asset is materialized;
- no higher-authority record conflicts with the intended change;
- when the multitask layer is active: the writer lease resolves to exactly one active integrator, and the current task's capsule exists.

If an ID is missing or malformed, stop the package write and repair state. Do not infer its text from memory.

## Constraint coverage gate

Before review and after approval, every required `M/F/D` ID must have a coverage row with an evidence cell:

```markdown
| ID | Constraint | Artifact / section | Evidence |
|---|---|---|---|
| M-001 | Keep one package active | PROJECT_STATE / Hot State | verify_gate: hot-state single package check |
```

The evidence cell names the command, test, or inspection that backs the row. A bare `Present` is rejected because a table of unconditional `Present` rows cannot distinguish "checked and fine" from "never checked"—which makes the whole table maintenance cost without information. Older PPS/1.0 and PPS/1.1 projects keep the `Result` column and are validated under their original rules.

The validator checks structural coverage. The agent must also inspect semantic coverage:

- Does the artifact obey the constraint rather than merely mention it?
- Does any output contradict an active fact or decision?
- Has scope been silently reduced?
- Has a deferred or rejected item been reintroduced?
- Did an approved change propagate to every affected section?

Structural success is necessary, not sufficient.

## Verification gate

Declared verification runs through the project verify gate:

1. `Verify` in the workset is an ordered declaration; its first step should be `scripts/verify_gate.sh` / `.ps1`.
2. The gate runs structural validation, gate substance (for software/hybrid: a behavioral check that names a real, reachable project artifact), red-line wiring, the handover lock, then the project's declared checks, in order, failing fast.
3. Wiring is judged by LIVE calls, not mentions: a path counts only on an uncommented line that is actually reached — a top-level call, the body of a helper that a top-level `check` reaches, never an unused function or a dead branch (`if false`/`while false`, `if ($false)`/`if (0)`/`if ($null)`/`while ($false)`). A live line must also LOOK like a call (`check`, `bash`, `&`, dot-source, command substitution); a string literal that merely mentions the path proves nothing. The same parser serves red-line tails, coverage evidence, and runtime probes, and its copies in the gate and the validator are parity-tested so they cannot drift apart.
3. Include at least one behavioral assertion for software packages—a user-visible end-to-end check—because two field incidents proved that unit-green plus deploy-success can still mean a dead system: unit tests can bypass the changed call path, and a deployed file is not necessarily a loaded file. Liveness probes ("is the new code actually running?") are legitimate and encouraged `Verify` members.
4. A successful gate writes `.pps/verify-stamp` with UTC time and package ID. `readiness_check.* --verified` rejects readiness when the stamp is missing or names another package.
5. The gate refuses to stamp when the handover safety proof itself is absent: software/hybrid packages fail on a missing `.pps/session-snapshot` or a missing `scripts/boundary_check.*`, because a stamp written without them certifies a handover nobody checked.
5. Nothing auto-executes `Verify`. The agent inspects commands before running them; the stamp records that the inspected gate ran on this device.

Knowing the rule is not running the rule. The stamp turns "I should have verified" into a checkable artifact.

## Review gate

A package is ready for user review only when it contains:

1. a concrete current-to-proposed output slice;
2. scope and non-goals;
3. a complete recommended design;
4. evidence and trade-offs;
5. the authority-to-output coverage map;
6. only the user decisions that genuinely require approval.

Questions cannot substitute for agent-owned design work. Use a reversible `H` default when safe. For experiential qualities that automated assertions cannot cover—smoothness, feel, visual comfort—prefer small increments with early user testing over one large scheme built on an unverified mental model; a wrong `H` proven fast costs a day, not a direction.

## Proposal aging gate

Every `P-*` carries its opened date. A proposal pending past seven days must be explicitly re-stated in `Next` as kept, closed, or split. A hanging proposal exerts no pressure by itself; this gate makes silent rot visible. The validator warns on stale proposals; the decision remains the owner's.

## Close gate

User feedback is not closed until all applicable writes are complete:

- main artifact updated;
- approved `D-*` record active;
- superseded/rejected records preserved with status;
- active block reconciled;
- pending feedback removed or narrowed;
- capsule and next action updated;
- coverage updated with evidence cells;
- an event appended for the closure;
- validator passes;
- full asset handoff, durable cloud presence, and tracked-binary risk checks pass;
- the verify gate ran on this device for this package and the declared checks passed;
- when the multitask layer is active: task statuses and merge receipts agree with what actually happened.

Use `scripts/readiness_check.*` after running the declared checks. Without the explicit `--verified`/`-Verified` attestation plus a matching verify stamp it reports `VERIFY PENDING` and does not claim readiness. This is deliberately safer than executing arbitrary repository commands from an untrusted manifest.

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
- a PPS/1.2 coverage row without an evidence cell;
- package IDs disagree across state, context, and evidence;
- malformed `PKG-*` package IDs or non-UTC `Updated` timestamps;
- evidence profile without source/evidence files;
- PPS/1.1+ state without its project map, environment manifest, or project-local resume/environment scripts;
- PPS/1.2 state without `EVENTS.md`, verify-gate scripts, or a `Red Lines` section in `AGENTS.md`;
- a malformed event line in `EVENTS.md`;
- missing, duplicate, or malformed component-map rows referenced by the current workset;
- a combined `Read` and `Write` set larger than 30 paths;
- a repository-root or glob Read/Write entry;
- more than 60 combined authority IDs, 30 source IDs, or 30 component IDs;
- more than 30 asset IDs, a duplicate/missing asset row, a core `local-marker`, or a reference asset in the current Workset;
- an oversized control file or resume packet, including a single-line byte-budget bypass;
- a workset path that is absolute, uses `..`, uses a foreign path separator, or resolves outside the repository;
- an unknown environment tool or package-manager policy;
- project-relative path escaping the repository or traversing a symbolic link/reparse point;
- capsule over 80 lines;
- malformed content inside the machine-readable active block;
- multitask: a duplicate `T-*` ID, a missing task capsule, more than one active integrator, a `Writer:` naming a non-integrator or missing task, a worker/consumer whose capsule `Write` set includes canonical files, a worker/consumer without an `Output Root`, an `integrated` receipt without both checkpoints, or a malformed receipt relation.

Treat these as warnings:

- capsule over the 60-line target;
- project map over the 160-line target;
- a combined `Read` and `Write` set larger than 12 paths;
- hot state growing beyond its compact target;
- dirty Git worktree;
- active authority not currently in the workset;
- a `P-*` proposal older than seven days without re-statement;
- `EVENTS.md` over 200 lines without archive;
- missing non-current reference material or aggregate tracked-binary pressure below the hard push ceiling.

Do not weaken a gate to make an invalid project pass. Repair the underlying record, manifest, or propagation.

## Audit levels

- `L0`: bounded resume packet—hot state, capsule manifest, named map rows, exact active records, red lines, recent events, and Git risk.
- `L1`: L0 plus the declared `Read` paths and relevant highest-authority sources.
- `L2`: lifecycle or object-by-process coverage matrix for a stage/package audit.
- `L3`: all-source, all-decision, final-deliverable audit before freeze/export.

Escalate only when the current level cannot establish coverage or reveals conflict.

## Red line wiring (PPS/1.2)

A red line in `AGENTS.md` may name the check that enforces it by ending the
entry with a parenthesised tail: an opening parenthesis, the word `verify`, a
colon, the in-repo path of the check, then a closing parenthesis. Example
shape, with the path spelled out: `(verify:` followed by `tests/e2e-parity.sh`
and `)`.

When any red line carries such a tail, `scripts/verify_gate.*` extracts every
named path and refuses to write a verify stamp unless
`scripts/project_verify.*` references it — either directly, or by reading
`.pps/verify-manifest.txt` which lists it. A red line that names a check but is
not wired into the gate is a wish, not a rule.

Red lines about feel, judgement, or human review need no tail and are never
machine-checked.

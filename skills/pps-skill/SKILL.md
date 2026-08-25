---
name: pps-skill
description: Bootstrap, resume, audit, migrate, and synchronize long-lived personal AI projects with bounded Markdown context, stable authority/component/asset/task IDs, exact read/write worksets, relay-safe session handover, executable verify gates with device-local evidence, event chronicling, environment cold-start assistance, tiered large-asset materialization, optional single-owner multitask bookkeeping, validation gates, and Git handoff. Use for document plans, research, lightweight websites, small games, prototypes, scripts, utilities, hybrid document/code projects, or very large personal codebases where context pressure, memory drift, and incomplete cross-device asset sync must stay controlled across operating systems, devices, or AI agents. Triggers include “发起项目”, “个人项目状态管理”, “轻量网页开发”, “小游戏开发”, “大型代码库继续开发”, “跨设备同步项目”, “多端推进同一任务”, “换设备继续”, “同步并继续”, “保存并同步”, “接入GitHub”, “新设备冷启动”, “冷启动接入项目”, “新设备接入并继续”, “clone并继续”, “从GitHub接入并继续”, “跨agent协作”, “大文件素材同步”, and “这个定了”.
---

# PPS Skill

PPS is a Personal Project State protocol for one owner working serially across devices and agents. It keeps authority, architecture navigation, the current package, event history, and environment requirements explicit without loading the whole project. PPS/1.2 distills two field campaigns: relay handover protection, executable verification with device-local evidence, event chronicling, coverage evidence, proposal aging, red-line placement, and an optional single-owner multitask layer.

## Choose the operation

1. **Bootstrap a new project**: select `document`, `software`, or `hybrid`, then select `standard` or `evidence`; run the matching initializer.
2. **Resume a PPS project**: run `git status` first (relay rule), then generate a bounded `resume_packet` and work only from its IDs, components, red lines, recent events, and paths.
3. **Close a package**: update changed artifacts, authority, project map when architecture changed, workset, coverage with evidence, and hot state; append an event; run the verify gate, then readiness with the stamp.
4. **Audit or repair**: run `validate_project`; fix semantic state rather than weakening the validator.
5. **Migrate an existing project**: run the read-only `audit_legacy_project` command, then read [migration.md](references/migration.md) before writing. Never create a second competing state system.
6. **Synchronize across devices**: read [git-sync.md](references/git-sync.md). Pull before work and push only when the user asks to sync.
7. **Cold-start an environment**: before clone, run `environment_doctor --core`/`-Core` from the installed skill; after clone, use the project manifest. Read [environment-bootstrap.md](references/environment-bootstrap.md) and request one approval before any system install.
8. **Govern large assets**: classify files as `core`, `supporting`, or `reference`; keep metadata in `ASSETS.md`, external bytes under ignored `local-assets/`, and current dependencies in Workset `Assets`. Read [asset-management.md](references/asset-management.md).
9. **Track coexisting tasks**: when several long-lived tasks share one project, create `TASK_INDEX.md` to activate the single-owner multitask layer. Read [multitask.md](references/multitask.md). **A single-package relay project must not create `TASK_INDEX.md`** — a half-present registry activates multitask semantics with nothing declared and raises recovery cost for no benefit; the validator rejects an empty registry outright.

Map the user's short commands consistently as intent → action, and accept natural-language phrasings that carry the same intent: “同步并继续” (or "拉最新的接着做") means inspect and safely pull before resuming; “保存并同步” (or "存档推上去") means close the package, validate, commit, reconcile, and push; “这个定了” (or "就按这个来") means record an explicitly approved `D-*` decision and propagate it through the active write set. The intent governs, not the exact wording.

## Select mode and profile

- Use `document` when the current truth is a canonical artifact file.
- Use `software` for lightweight websites, small games, scripts, utilities, prototypes, and existing codebases.
- Use `hybrid` when a maintained specification and executable output are both first-class.
- Use `standard` for ordinary personal projects where approved decisions must survive long iteration.
- Use `evidence` when claims must be traced to external sources, audits span many documents, or review requires an explicit constraint-to-output matrix.
- Do not use PPS for a disposable one-session task or multi-owner concurrent delivery. PPS complements project tests; it never replaces them.

Read [project-modes.md](references/project-modes.md) for mode and large-repository worksets. Read [protocol.md](references/protocol.md) for the contract and [retrieval-and-gates.md](references/retrieval-and-gates.md) for recovery.

## Hard invariants

- Git is synchronized history; `Main` is current content truth; `PROJECT_STATE.md` is workflow truth; `DECISIONS.md` is authority truth; `PROJECT_MAP.md` is navigation truth; `EVENTS.md` is the chronicle of record.
- IDs are globally stable. Use `M-*` for method constraints, `F-*` for authoritative facts, and `D-*` for user-approved decisions.
- `P` is an unapproved proposal and `H` is a reversible local assumption. Neither belongs in the active authority index. Proposals carry an opened date and age out loudly after seven days.
- `CONTEXT.md` is a bounded workset, not a narrative memory dump. Retrieve exact IDs, `C-*` components, and Read/Write paths. Coverage may live in `docs/coverage.md` when the capsule needs room.
- Every session starts with `git status`; wholesale overwriting of a dirty file is forbidden; every session ends with a commit or an explicit handover in `Next`.
- One writer owns the canonical state files during a package. Under the multitask layer that writer is the single active integrator named in hot state; workers and consumers write only their bounded output roots.
- Every manifest-listed `M/F/D` ID must be active, have a canonical record, and appear in the current coverage artifact with an evidence cell naming its check.
- Every manifest-listed `C-*` ID must have one map row. Read/Write entries are exact and bounded: no repository root or globs, and no more than thirty combined paths.
- Git sync and asset materialization are separate. Every `core` and current `supporting` asset must have one `A-*` row and pass handoff verification; cloud rows use non-secret `rclone:REMOTE:path` locators and prove durable-object presence/size; references may remain marker-only.
- Structural coverage never proves semantic correctness; deployed never proves loaded; unit-green never proves the wired system works. Behavioral end-to-end assertions are legitimate Verify members.
- The verify gate writes a device-local stamp; readiness requires both the caller's attestation and a stamp matching the current package. The gate executes the project's own `.pps/verify-manifest.txt` and binds the run record hash into the stamp; readiness never executes out-of-repo commands.
- Every session anchors the objective: `session_begin` hashes the objective-bearing sections into `.pps/objective-anchor`. A mid-session objective change fails the gate unless `EVENTS.md` records an `objective-revised` event. The gate re-surfaces the objective, red lines, and active decisions on every run.
- Every non-bootstrap PPS/1.2 package declares `Acceptance` items (`A1, A2, ...`) in `CONTEXT.md`, each naming the machine check `(verify: ...)` that proves it; the gate fails any item whose check did not run successfully.
- Engineering red lines live in the first section of `AGENTS.md` and are read before any edit. Their content is project-specific; the protocol only fixes the position.
- Malformed decision-shaped text is an error. Do not silently treat it as absent.
- Never bulk-load a repository because it is large. Start from the resume packet and use targeted search.
- Do not add global language packages, a vector database, Wiki, graph store, RAG service, daemon, or team workflow unless explicitly authorized.

## Bootstrap

PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File <skill>/scripts/init_project.ps1 `
  -ProjectName <name> -Mode software -Profile standard -ParentDir <parent>
```

Bash:

```bash
bash <skill>/scripts/init_project.sh <name> --mode software --profile standard --parent <parent>
```

The default mode remains `document`. The initializer refuses a non-empty target, creates neutral state/map/environment/event files, initializes Git when available, and validates the result.

## Resume and retrieve

1. Run `git status`; understand any dirty state before touching it.
2. Run `scripts/resume_packet.ps1` on Windows or `scripts/resume_packet.sh` elsewhere.
3. Read the packet's Red Lines and Recent Events before editing.
4. Resolve exact `M/F/D` authority and `C-*` component rows from the packet.
5. Resolve `A-*` rows and materialize only required core/supporting assets; do not download marker-only references.
6. Inspect only `Read` paths, then use exact search for relevant symbols.
7. Change only the declared `Write` set unless the workset is updated first.
8. Inspect `Verify` before executing it; expand beyond the workset only when evidence shows it is incomplete.

The packet intentionally excludes source contents. Never substitute the whole tree or recent files for the manifest.

### Re-run the packet mid-session

Reading the packet once at startup does not survive a long session: a summarised or compacted conversation loses the goal, the red lines, and the `Write` set, and the verify gate only runs at close — after any drift is already in the diff. Re-run `resume_packet.*` when any of these is true, then treat only the packet as authoritative:

- Asked to continue, but no packet has been read in this session.
- The conversation was summarised or compacted.
- The objective feels unclear, or a package has been "almost done" for many turns.
- About to write outside the declared `Write` set.

After re-running, the packet's Goal, `Acceptance`, red lines, `Write` set, and IDs override anything stated earlier in the conversation. To recover only the session's original objective, read `.pps/objective-anchor`: everything below its `-- objective --` marker is the anchored objective in readable form. The gate's Step 0 printout is a log line for the operator, not a substitute for this step.

## Work and close

Keep one concrete package active. For code, lock component, entry point, interface, paths, and verification before editing. Distinguish:

- facts the agent cannot change;
- complete proposals the agent recommends;
- reversible assumptions used to continue;
- decisions that require explicit user approval.

When the user approves, rejects, or modifies:

0. **before writing anything**, run `scripts/session_begin.*` — it records which files already carry uncommitted handover work, and the verify gate refuses to stamp without that snapshot;
1. update the real artifact or code;
2. add or update the canonical `D-*` record and active block;
3. append an event for supersession or rejection;
4. remove absorbed feedback from the capsule;
5. update the project map only if an architecture boundary changed;
6. update coverage with evidence and the next action;
7. run `scripts/verify_gate.*` (objective anchor review, structural validation, gate substance, red-line wiring, acceptance wiring, handover lock, then the declared project checks; it writes the verify stamp);
8. run full asset handoff/risk checks, then `readiness_check.* --verified`/`-Verified`; readiness rejects a missing or stale stamp.

Changing the objective mid-package is a decision, not an edit: record it with
`scripts/append_event.* --title "objective-revised ..."` before the gate runs,
or the gate fails the anchor comparison. If the package is past bootstrap,
also update the `Acceptance` items so "done" still means something checkable.

The gate is the enforcement point, not a formality: it fails when the session
snapshot is missing, when a predecessor's uncommitted work was overwritten,
when `scripts/project_verify.*` is hollow, when a red line names a check no
manifest row ran successfully on this platform, when the check manifest is
missing or one of its declared checks fails, times out, or points outside
the project root, and — for software/hybrid packages — when the behavioral
check asserts nothing real.

Run the project-local validator before claiming closure. A clean prose summary is not proof of propagation.

## Resource map

- [protocol.md](references/protocol.md): truth layers, authority classes, profiles, artifact roles, relay and multitask authority.
- [project-modes.md](references/project-modes.md): document/software/hybrid selection and bounded large-repository worksets.
- [retrieval-and-gates.md](references/retrieval-and-gates.md): relay gate, exact retrieval, coverage evidence, verification gate, failure semantics.
- [multitask.md](references/multitask.md): optional single-owner task registry, writer lease, merge receipts, write-boundary enforcement.
- [environment-bootstrap.md](references/environment-bootstrap.md): read-only doctor, safe install planning, and apply boundary.
- [migration.md](references/migration.md): attach legacy plan-project-sync, PPS/1.0, PPS/1.1, or other existing repositories without dual state.
- [git-sync.md](references/git-sync.md): safe cross-device Git workflow and relay handover.
- [asset-management.md](references/asset-management.md): Git, LFS, and external-asset thresholds.
- [design-rationale.md](references/design-rationale.md): how PPS derives its local invariants and what it intentionally rejects.
- `assets/templates/`: files rendered by the initializer.
- `scripts/audit_legacy_project.ps1` and `.sh`: inspect an existing project and propose migration without modifying the target.
- `scripts/asset_check.ps1` and `.sh`: distinguish Git sync from required asset materialization; verify size/hash and tracked-binary risk.
- `scripts/verify_gate.ps1` and `.sh`: one entry for structural validation plus declared project checks; writes the device-local verify stamp.
- `scripts/append_event.ps1` and `.sh`: append a format-stable event line for the current package.
- `scripts/session_begin.ps1` and `.sh`: run this **before writing anything** in a session. It records `.pps/session-snapshot` (the dirty paths and their content hashes at session start), so a wholesale overwrite of a predecessor's uncommitted work becomes detectable, and writes `.pps/objective-anchor` (the hash of the objective-bearing sections), so a silently rewritten goal fails the gate. A second session over an unexpired snapshot needs `--takeover` / `-Takeover`, which must then be recorded as an event.
- `scripts/boundary_check.ps1` and `.sh`: classify every worktree change as claimed by a Write set / task output root, or flag it as an `unclaimed_write`. It also fails with `protected_overwrite` when a path that carried uncommitted work at session start has changed; discard that work deliberately with `--discard-handover PATH` / `-DiscardHandover PATH` and record the discard.
- `scripts/readiness_check.ps1` and `.sh`: combine structural, asset, verify-stamp, and caller-attested project verification without auto-executing untrusted commands.
- `scripts/validate_skill.ps1` and `.sh`: verify an installed skill bundle without repository tooling.
- `scripts/`: cross-platform initializer, status, bounded resume packet, environment doctor, audit, validators, and pre-commit gate.

---
name: pps-skill
description: Bootstrap, resume, audit, migrate, and synchronize long-lived personal AI projects with bounded Markdown context, stable authority/component/asset IDs, exact read/write worksets, environment cold-start assistance, tiered large-asset materialization, validation gates, and Git handoff. Use for document plans, research, lightweight websites, small games, prototypes, scripts, utilities, hybrid document/code projects, or very large personal codebases where context pressure, memory drift, and incomplete cross-device asset sync must stay controlled across operating systems, devices, or AI agents. Triggers include “发起项目”, “个人项目状态管理”, “轻量网页开发”, “小游戏开发”, “大型代码库继续开发”, “跨设备同步项目”, “多端推进同一任务”, “换设备继续”, “同步并继续”, “保存并同步”, “接入GitHub”, “新设备冷启动”, “冷启动接入项目”, “新设备接入并继续”, “clone并继续”, “从GitHub接入并继续”, “跨agent协作”, “大文件素材同步”, and “这个定了”.
---

# PPS Skill

PPS is a Personal Project State protocol for one owner working serially across devices and agents. It keeps authority, architecture navigation, the current package, and environment requirements explicit without loading the whole project.

## Choose the operation

1. **Bootstrap a new project**: select `document`, `software`, or `hybrid`, then select `standard` or `evidence`; run the matching initializer.
2. **Resume a PPS project**: generate a bounded `resume_packet`, then work only from its IDs, components, and paths.
3. **Close a package**: update changed artifacts, authority, project map when architecture changed, workset, coverage, and hot state; run structural and declared project verification.
4. **Audit or repair**: run `validate_project`; fix semantic state rather than weakening the validator.
5. **Migrate an existing project**: run the read-only `audit_legacy_project` command, then read [migration.md](references/migration.md) before writing. Never create a second competing state system.
6. **Synchronize across devices**: read [git-sync.md](references/git-sync.md). Pull before work and push only when the user asks to sync.
7. **Cold-start an environment**: before clone, run `environment_doctor --core`/`-Core` from the installed skill; after clone, use the project manifest. Read [environment-bootstrap.md](references/environment-bootstrap.md) and request one approval before any system install.
8. **Govern large assets**: classify files as `core`, `supporting`, or `reference`; keep metadata in `ASSETS.md`, external bytes under ignored `local-assets/`, and current dependencies in Workset `Assets`. Read [asset-management.md](references/asset-management.md).

Map the user's short commands consistently: “同步并继续” means inspect and safely pull before resuming; “保存并同步” means close the package, validate, commit, reconcile, and push; “这个定了” means record an explicitly approved `D-*` decision and propagate it through the active write set.

## Select mode and profile

- Use `document` when the current truth is a canonical artifact file.
- Use `software` for lightweight websites, small games, scripts, utilities, prototypes, and existing codebases.
- Use `hybrid` when a maintained specification and executable output are both first-class.
- Use `standard` for ordinary personal projects where approved decisions must survive long iteration.
- Use `evidence` when claims must be traced to external sources, audits span many documents, or review requires an explicit constraint-to-output matrix.
- Do not use PPS for a disposable one-session task or multi-owner concurrent delivery. PPS complements project tests; it never replaces them.

Read [project-modes.md](references/project-modes.md) for mode and large-repository worksets. Read [protocol.md](references/protocol.md) for the contract and [retrieval-and-gates.md](references/retrieval-and-gates.md) for recovery.

## Hard invariants

- Git is synchronized history; `Main` is current content truth; `PROJECT_STATE.md` is workflow truth; `DECISIONS.md` is authority truth; `PROJECT_MAP.md` is navigation truth.
- IDs are globally stable. Use `M-*` for method constraints, `F-*` for authoritative facts, and `D-*` for user-approved decisions.
- `P` is an unapproved proposal and `H` is a reversible local assumption. Neither belongs in the active authority index.
- `CONTEXT.md` is a bounded workset, not a narrative memory dump. Retrieve exact IDs, `C-*` components, and Read/Write paths.
- One writer owns the canonical state files during a package. Parallel research may return evidence, but must not edit state.
- Every manifest-listed `M/F/D` ID must be active, have a canonical record, and appear in the current coverage artifact.
- Every manifest-listed `C-*` ID must have one map row. Read/Write entries are exact and bounded: no repository root or globs, and no more than thirty combined paths.
- Git sync and asset materialization are separate. Every `core` and current `supporting` asset must have one `A-*` row and pass handoff verification; cloud rows use non-secret `rclone:REMOTE:path` locators and prove durable-object presence/size; references may remain marker-only.
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

The default mode remains `document`. The initializer refuses a non-empty target, creates neutral state/map/environment files, initializes Git when available, and validates the result.

## Resume and retrieve

1. Run `scripts/resume_packet.ps1` on Windows or `scripts/resume_packet.sh` elsewhere.
2. Resolve exact `M/F/D` authority and `C-*` component rows from the packet.
3. Resolve `A-*` rows and materialize only required core/supporting assets; do not download marker-only references.
4. Inspect only `Read` paths, then use exact search for relevant symbols.
5. Change only the declared `Write` set unless the workset is updated first.
6. Inspect `Verify` before executing it; expand beyond the workset only when evidence shows it is incomplete.

The packet intentionally excludes source contents. Never substitute the whole tree or recent files for the manifest.

## Work and close

Keep one concrete package active. For code, lock component, entry point, interface, paths, and verification before editing. Distinguish:

- facts the agent cannot change;
- complete proposals the agent recommends;
- reversible assumptions used to continue;
- decisions that require explicit user approval.

When the user approves, rejects, or modifies:

1. update the real artifact or code;
2. add or update the canonical `D-*` record and active block;
3. append a status event for supersession or rejection;
4. remove absorbed feedback from the capsule;
5. update the project map only if an architecture boundary changed;
6. update coverage and the next action;
7. run PPS validation and the inspected project verification.
8. run full asset handoff/risk checks, then `readiness_check.* --verified`/`-Verified` only after the declared environment and project checks pass.

Run the project-local validator before claiming closure. A clean prose summary is not proof of propagation.

## Resource map

- [protocol.md](references/protocol.md): truth layers, authority classes, profiles, artifact roles.
- [project-modes.md](references/project-modes.md): document/software/hybrid selection and bounded large-repository worksets.
- [retrieval-and-gates.md](references/retrieval-and-gates.md): exact retrieval, coverage gates, failure semantics.
- [environment-bootstrap.md](references/environment-bootstrap.md): read-only doctor, safe install planning, and apply boundary.
- [migration.md](references/migration.md): attach legacy plan-project-sync or other existing repositories without dual state.
- [git-sync.md](references/git-sync.md): safe cross-device Git workflow.
- [asset-management.md](references/asset-management.md): Git, LFS, and external-asset thresholds.
- [design-rationale.md](references/design-rationale.md): how PPS derives its local invariants and what it intentionally rejects.
- `assets/templates/`: files rendered by the initializer.
- `scripts/audit_legacy_project.ps1` and `.sh`: inspect an existing project and propose migration without modifying the target.
- `scripts/asset_check.ps1` and `.sh`: distinguish Git sync from required asset materialization; verify size/hash and tracked-binary risk.
- `scripts/readiness_check.ps1` and `.sh`: combine structural, asset, and caller-attested project verification without auto-executing untrusted commands.
- `scripts/validate_skill.ps1` and `.sh`: verify an installed skill bundle without repository tooling.
- `scripts/`: cross-platform initializer, status, bounded resume packet, environment doctor, audit, validators, and pre-commit gate.

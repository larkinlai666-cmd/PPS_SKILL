---
name: pps-skill
description: Bootstrap, resume, audit, migrate, and synchronize long-lived proposal or plan projects with durable Markdown context, globally stable authority IDs, explicit workset manifests, decision-coverage gates, evidence routing, and Git handoff. Use when the user asks to start or continue a 方案型项目, preserve context across devices or AI agents, retrieve historical decisions correctly, prevent approved constraints from being dropped, upgrade plan-project-sync, or adopt useful GSD-style validation without turning the project into a software execution framework.
---

# PPS Skill

PPS is a proposal-project state protocol. It keeps the user's authority model and long-range recall explicit, then adds deterministic parsing and fail-loud coverage checks inspired by GSD.

## Choose the operation

1. **Bootstrap a new project**: choose `standard` or `evidence`, then run the matching initializer in `scripts/`.
2. **Resume a PPS project**: run `status_check`, read the manifest-listed IDs and artifacts, then work only on the current package.
3. **Close a review decision**: update the main artifact, authority record, active index, workset capsule, coverage map, and hot state in one write set; run validation.
4. **Audit or repair**: run `validate_project`; fix semantic state rather than weakening the validator.
5. **Migrate an existing project**: read [migration.md](references/migration.md) before writing. Never create a second competing state system.
6. **Synchronize across devices**: read [git-sync.md](references/git-sync.md). Pull before work and push only when the user asks to sync.

## Select a profile

- Use `standard` for product plans, worldbuilding, naming, strategy, design documents, and other projects where approved decisions must survive long iteration.
- Use `evidence` when claims must be traced to external sources, audits span many documents, or review requires an explicit constraint-to-output matrix.
- Do not use PPS for a small one-session task. Prefer GSD or a software workflow when the primary output is code, plans can be independently executed, and automated tests are the main truth mechanism.

Read [protocol.md](references/protocol.md) for the authority and artifact contract. For context recovery or validation behavior, also read [retrieval-and-gates.md](references/retrieval-and-gates.md).

## Hard invariants

- Git is the synchronized history; the main artifact is current content truth; `PROJECT_STATE.md` is workflow truth; the active block in `DECISIONS.md` is authority truth.
- IDs are globally stable. Use `M-*` for method constraints, `F-*` for authoritative facts, and `D-*` for user-approved decisions.
- `P` is an unapproved proposal and `H` is a reversible local assumption. Neither belongs in the active authority index.
- `CONTEXT.md` is a derived workset manifest, not a narrative memory dump. Retrieve exact IDs, not merely the last few files.
- One writer owns the canonical state files during a package. Parallel research may return evidence, but must not edit state.
- Every manifest-listed `M/F/D` ID must be active, have a canonical record, and appear in the current coverage artifact.
- Malformed decision-shaped text is an error. Do not silently treat it as absent.
- Do not add a vector database, Wiki, graph store, RAG service, or daemon unless the user explicitly authorizes that architecture.

## Bootstrap

PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File <skill>/scripts/init_project.ps1 `
  -ProjectName <name> -Profile standard -ParentDir <parent>
```

Bash:

```bash
bash <skill>/scripts/init_project.sh <name> --profile standard --parent <parent>
```

Use `evidence` instead of `standard` when required. The initializer refuses a non-empty target, creates neutral project files, initializes Git when available, and validates the result. If global Git identity is intentionally unset, optionally pass `-GitName/-GitEmail` or `--git-name/--git-email`; these values are stored only in the new repository.

## Resume and retrieve

1. Run `scripts/status_check.ps1` on Windows or `scripts/status_check.sh` elsewhere.
2. Read `PROJECT_STATE.md` hot fields and the referenced capsule.
3. Parse `Methods`, `Facts`, `Decisions`, `Sources`, and `Coverage` from `CONTEXT.md`.
4. Use exact-ID search in `DECISIONS.md`; read only the named main-artifact sections and source rows.
5. Expand to a lifecycle matrix or full audit only when the package cannot be resolved from the explicit workset.

Never substitute “three most recent contexts” for the manifest. Recency is a fallback hint, not an authority rule.

## Work and close

Keep one concrete review package active. Before presenting it, show the real output delta and map each required authority ID to an artifact section. Distinguish:

- facts the agent cannot change;
- complete proposals the agent recommends;
- reversible assumptions used to continue;
- decisions that require explicit user approval.

When the user approves, rejects, or modifies:

1. update the main artifact;
2. add or update the canonical `D-*` record and active block;
3. append a status event for supersession or rejection;
4. remove absorbed feedback from the capsule;
5. update coverage and the next action;
6. run validation.

Run the project-local validator before claiming closure. A clean prose summary is not proof of propagation.

## Resource map

- [protocol.md](references/protocol.md): truth layers, authority classes, profiles, artifact roles.
- [retrieval-and-gates.md](references/retrieval-and-gates.md): exact retrieval, coverage gates, failure semantics.
- [migration.md](references/migration.md): attach legacy PPS or GSD repositories without dual state.
- [git-sync.md](references/git-sync.md): safe cross-device Git workflow.
- [design-rationale.md](references/design-rationale.md): what PPS keeps, borrows, and intentionally rejects.
- `assets/templates/`: files rendered by the initializer.
- `scripts/`: cross-platform initializer, status check, and validator.

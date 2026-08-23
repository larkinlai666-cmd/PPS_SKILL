# Current Context

## Workset Manifest

- Methods: M-001, M-002
- Facts: none
- Decisions: none
- Sources: none
- Assets: none
- Components: C-ROOT
- Read: {{READ_SET}}
- Write: {{WRITE_SET}}
- Verify: Run scripts/verify_gate.* (structural validation plus declared project checks); extend the gate with stack-specific checks after bootstrap.
- Excluded: none
- Coverage: {{COVERAGE_ARTIFACT}}

## Current Package

- ID: PKG-001
- Goal: Convert the bootstrap placeholder into the first concrete review package.
- Acceptance:
  - A1: Objective and acceptance criteria are explicit and machine-checkable (verify: validate_project).
- Output anchor: `{{MAIN_ARTIFACT}}`
- Allowed change: Objective, scope, and initial artifact structure.
- Forbidden change: Active authority without an explicit status update.

## Pending Feedback

- none

## Proposals

- P-001 (opened {{DATE}}): Begin with one reviewable end-to-end slice of the deliverable.

## Working Assumptions

- H-001: The first package can be defined without global infrastructure. Expires when project-specific evidence shows otherwise.

## Current Risks

- The bootstrap objective is still generic.

## Constraint Coverage

| ID | Constraint | Artifact / section | Evidence |
|---|---|---|---|
| M-001 | Stable IDs and explicit workset retrieval | `CONTEXT.md` / Workset Manifest | verify_gate: structural validation checks manifest IDs |
| M-002 | Close only after propagation and validation | `AGENTS.md` / 写入与并发 | verify_gate: close requires gate pass and verify stamp |

## Runtime Surfaces

<!-- Optional (PPS/1.2). Declare where the product runs outside this repository: environment VARIABLE NAME only, never an absolute path, each probe referenced by scripts/project_verify.* or it never runs. Delete this section if the product lives entirely inside the repository.

| ID | Repo path | Runtime path env | Probe |
| R-001 | live-workbench/ | WEZTERM_CONFIG_DIR | scripts/runtime_probe.sh |
-->

## Next Action

Replace the placeholder objective with a concrete deliverable and prepare PKG-001 for review.

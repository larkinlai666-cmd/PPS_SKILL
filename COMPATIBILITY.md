# plan-project-sync compatibility and PPS/1.1 upgrade

PPS must be a capability superset of the legacy `plan-project-sync` workflow unless this file records an intentional replacement.

| Legacy capability | PPS implementation | Acceptance evidence |
|---|---|---|
| Neutral Markdown and Git handoff | `PROJECT_STATE.md`, `DECISIONS.md`, `CONTEXT.md`, `README.md`, `AGENTS.md` | Generated-project smoke tests |
| Cross-device recovery | Explicit hot state, bounded resume packet, workset manifest, exact authority retrieval | Bash and PowerShell recovery tests |
| Human commands | “同步并继续”, “保存并同步”, “这个定了”, “冷启动接入项目” | Skill metadata, project README, AGENTS |
| GitHub cold start | `references/git-sync.md` with gh, HTTPS, and SSH decision order | Distribution validation |
| Remote and upstream risk check | Status reports remotes, upstream, ahead, and behind; optional `--fetch` | Bash and PowerShell Git smoke tests |
| Stable `main` branch | Initializers request `main` with an old-Git fallback | Bash and PowerShell Git smoke tests |
| Default project-home override | `PPS_PROJECT_HOME` with legacy `PLAN_PROJECT_HOME` fallback | Initializer implementation and review |
| Non-empty target refusal | Both initializers refuse existing non-empty targets | Negative initialization tests |
| Optional close reminder | Installable pre-commit validation hook plus manual PowerShell check | Hook-blocking smoke tests |
| `docs/`, `assets/`, `prototypes/` structure | Both initializers create all three directories | Generated-project smoke tests |
| Large-asset routing | Stable `A-*` priorities, Git/LFS/rclone/marker routing, ignored materialization, and durable-copy checks | Cross-platform positive and negative asset tests |
| Existing-project attachment | Read-only audit plus reviewed migration instructions | Audit fingerprint and classification tests |
| GitHub setup and cold-start fallbacks | gh first, then HTTPS, then verified SSH | `references/git-sync.md` and skill health warnings |
| Cross-platform behavior | Bash and PowerShell implementations share one invariant suite | Linux, macOS, and Windows CI |
| Post-install skill health check | Distributable Bash and PowerShell skill validators | Both validators run in smoke tests |
| Text-plan continuation | `document` mode retains a canonical main artifact and coverage workflow | Standard/evidence initialization tests |
| Personal software projects | `software` mode permits a project directory as `Main` and keeps native verification | Bash and PowerShell mode tests |
| Document/code projects | `hybrid` mode keeps both an executable root and maintained specification | Bash and PowerShell mode tests |
| Large-repository recovery | Stable `C-*` component map plus bounded Read/Write paths; packet excludes source bodies | 200,001-line source isolation tests |
| Memory-drift resistance | Exact authority IDs, component IDs, package agreement, path limits, and fail-loud cardinality | Positive and negative validator suites |
| New-device environment diagnosis | Declarative allowlisted tools and read-only check/plan modes | Environment-doctor smoke and unknown-tool rejection |
| Explicit environment installation | Double-confirmed apply mode; no package-manager bootstrap or optional-tool auto-install | Bash/PowerShell implementation and safety references |
| PPS/1.0 continuity | Validators and audit commands accept PPS/1.0 and PPS/1.1 | Explicit PPS/1.0 compatibility fixtures |
| Complete handoff claims | Git state, local materialization, durable cloud presence, and project Verify are separate gates | Missing-cloud, missing-core, and unverified-readiness tests |

PPS intentionally replaces free-form decision memory with globally stable authority records, an explicit current workset, strict coverage gates, and project-local validation. PPS/1.1 adds modes, component navigation, bounded paths, recovery packets, and environment manifests without changing the authority or single-writer model.

PPS intentionally does not preserve placeholder Git identities; when identity is missing, initialization leaves files staged or accepts an explicit repository-local identity. This is a safety upgrade, not a missing capability, because it avoids silently falsifying commit authorship.

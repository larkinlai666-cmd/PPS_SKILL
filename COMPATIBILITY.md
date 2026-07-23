# plan-project-sync compatibility

PPS must be a capability superset of the legacy `plan-project-sync` workflow unless this file records an intentional replacement.

| Legacy capability | PPS implementation | Acceptance evidence |
|---|---|---|
| Neutral Markdown and Git handoff | `PROJECT_STATE.md`, `DECISIONS.md`, `CONTEXT.md`, `README.md`, `AGENTS.md` | Generated-project smoke tests |
| Cross-device recovery | Explicit hot state, workset manifest, exact authority retrieval | Project validator and status tests |
| Human commands | “同步并继续”, “保存并同步”, “这个定了”, “冷启动接入项目” | Skill metadata, project README, AGENTS |
| GitHub cold start | `references/git-sync.md` with gh, HTTPS, and SSH decision order | Distribution validation |
| Remote and upstream risk check | Status reports remotes, upstream, ahead, and behind; optional `--fetch` | Bash and PowerShell Git smoke tests |
| Stable `main` branch | Initializers request `main` with an old-Git fallback | Bash and PowerShell Git smoke tests |
| Default project-home override | `PPS_PROJECT_HOME` with legacy `PLAN_PROJECT_HOME` fallback | Initializer implementation and review |
| Non-empty target refusal | Both initializers refuse existing non-empty targets | Negative initialization tests |
| Optional close reminder | Installable pre-commit validation hook plus manual PowerShell check | Hook-blocking smoke tests |
| `docs/`, `assets/`, `prototypes/` structure | Both initializers create all three directories | Generated-project smoke tests |
| Large-asset routing | `references/asset-management.md` and conservative ignore defaults | Distribution validation |
| Existing-project attachment | Read-only audit plus reviewed migration instructions | Audit fingerprint and classification tests |
| GitHub setup and cold-start fallbacks | gh first, then HTTPS, then verified SSH | `references/git-sync.md` and skill health warnings |
| Cross-platform behavior | Bash and PowerShell implementations share one invariant suite | Linux, macOS, and Windows CI |
| Post-install skill health check | Distributable Bash and PowerShell skill validators | Both validators run in smoke tests |

PPS intentionally replaces free-form decision memory with globally stable authority records, an explicit current workset, strict coverage gates, and project-local validation. It intentionally does not preserve placeholder Git identities; when identity is missing, initialization leaves files staged or accepts an explicit repository-local identity. This is a safety upgrade, not a missing capability, because it avoids silently falsifying commit authorship.

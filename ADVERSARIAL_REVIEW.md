# PPS adversarial review

- Review date: 2026-07-23
- Scope: local `codex/pps-hardening` worktree
- Verdict: **PASS within the declared PPS boundary**

## Acceptance claims

PPS passes this review only if all of the following are true:

1. every useful `plan-project-sync` capability is preserved or intentionally replaced by a safer behavior;
2. the distributable skill has no runtime, state-directory, online-flow, or semantic dependency on another state workflow;
3. Bash and PowerShell enforce the same protocol invariants;
4. malformed or conflicting state fails loudly;
5. new-device, Git status, initialization, installed-skill health, and pre-commit paths remain operational;
6. audit and migration do not mutate an existing project before reviewed cutover.

The capability evidence is mapped in [COMPATIBILITY.md](COMPATIBILITY.md).

## Adversarial findings and repairs

| Attack or regression | Earlier behavior | Hardened behavior |
|---|---|---|
| Error recorded inside Bash command substitution | Error array update was lost in a subshell | Functions return through explicit shared state; invalid fixtures fail |
| Field moved outside its canonical section | Global search could still accept it | Hot-state and workset fields are section-scoped |
| Duplicate active block or reversed markers | Marker cardinality/order was incomplete | Exactly one ordered marker pair is required |
| Duplicate canonical authority or orphan active record | Conflicting records could remain ambiguous | Global uniqueness and active-block/record bijection are enforced |
| Wrong-class, duplicate, or whitespace-merged manifest IDs | Permissive extraction could normalize bad input | Strict typed comma grammar rejects extra or merged text |
| Missing/duplicate coverage or source rows | Presence-only checks could hide conflicts | Exact cardinality is required and conflicting line numbers are reported |
| Package drift across state/context/evidence | Files could describe different review packages | Package IDs must match and use the `PKG-*` grammar |
| Impossible or non-UTC update time | Shape-only matching accepted false dates | Real calendar validation plus UTC format is required |
| Absolute, parent, backslash, symlink, or reparse traversal | Referenced artifacts could escape the project | Cross-platform safe project-relative paths are enforced |
| Invalid content staged while worktree is repaired | Worktree-only hook could accept a bad commit | Hook validates a minimal materialized Git-index snapshot |
| Ordinary roadmap in a legacy project | Audit could report a false mixed-state conflict | Only dedicated generic state-control files trigger that classification |
| Fetch failure followed by valid local structure | Status could finish with a success code | Requested fetch failure returns non-zero independently of validation |
| Non-portable or contradictory initialization input | Some failures occurred late or ambiguously | Portable names, option arity, and Git-option consistency fail early |

## Upgrade evidence

- Both initializers create `docs/`, `assets/`, `prototypes/`, local status/validation/pre-commit scripts, and an explicit `main` branch with an old-Git fallback.
- Status reports dirty state, remotes, upstream, ahead/behind, and optional all-remote fetch results.
- Cold start preserves gh, HTTPS, and verified-SSH choices without coupling the protocol to a hosted service.
- Installed-skill health checks now exist in Bash and PowerShell.
- Read-only migration audit fingerprints prove the target is unchanged and reports cannot be written inside it.
- The old free-form memory model is strengthened by stable authority IDs, explicit worksets, package consistency, evidence routing, and propagation coverage.

## Verification evidence

The local review runs:

- dependency-free distribution validation;
- Bash and PowerShell installed-skill health validation;
- Bash parser checks and PowerShell parser checks;
- Bash and PowerShell smoke suites;
- 19 named invalid-project mutations per implementation, plus initialization, hook, fetch, audit, and skill-health failure guards;
- valid standard/evidence initialization, lifecycle history, Git remote divergence, and hook flows;
- YAML parsing for CI, release, and agent metadata;
- whitespace/error checks and a zero-result scan for prohibited external-workflow coupling.

CI is configured to repeat the relevant suites on Linux, macOS, and Windows, and the release workflow requires all three before packaging.

## Residual boundary

PPS is structurally reliable, not omniscient:

- structural coverage cannot prove that prose semantically obeys a constraint;
- single-writer discipline is a protocol rule, not a distributed lock;
- remote authentication and provider availability remain external conditions;
- migration audit proposes a cutover but does not decide authority for the user;
- Windows CI is configured but cannot be claimed as executed until the branch is pushed and Actions runs.

These are declared boundaries rather than hidden dependencies. Within them, the reviewed PPS is a capability superset and a safety upgrade over `plan-project-sync`.

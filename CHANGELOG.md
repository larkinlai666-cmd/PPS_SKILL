# Changelog

All notable changes are documented here. The project follows Semantic Versioning.

## [Unreleased]

## [0.3.0] - 2026-07-23

### Added

- Optional `ASSETS.md` registry with stable `A-*` IDs, `core`/`supporting`/`reference` priorities, and `git`/`git-lfs`/`cloud`/`local-marker` routing.
- Bash and PowerShell asset checks for local size/SHA-256 integrity, Git/LFS declarations, required materialization, durable rclone copy presence, and tracked non-LFS repository bloat.
- Explicit readiness gates that keep arbitrary project verification out of the validator and require caller attestation before a package can be reported ready.
- Environment capabilities for PowerShell, LibreOffice, Poppler, and rclone plus project dependency-manifest and environment-verification declarations.
- Negative tests for missing core assets, marker-only core assets, reference assets in the active Workset, secret-bearing cloud locators, absent durable cloud copies, unverified readiness, and files above the 95 MiB non-LFS safety ceiling.

### Changed

- Legacy audits now infer document/software/hybrid migration signals from real implementation files, prune common generated/dependency trees, count only strict authority tokens, identify free-form authority risk, and report machine/tool contamination and binary-asset candidates.
- Pre-commit snapshots include staged asset registries and both platform asset validators.
- Resume and status checks report Git state and asset materialization as separate dimensions.
- macOS validation instructions use `python3`; Windows instructions retain `python`.

### Fixed

- False authority detection where ordinary strings such as `UTF-8` were counted as `F-8`.
- Bash legacy-audit failure when a target had no `docs/` directory.
- A staged asset registry being validated without its staged-snapshot checker dependencies.

## [0.2.0] - 2026-07-23

### Added

- PPS/1.1 `document`, `software`, and `hybrid` project modes.
- Stable `PROJECT_MAP.md` component IDs and bounded `Components`, `Read`, `Write`, and `Verify` worksets.
- Bash and PowerShell resume packets with a 240-line hard limit and no source-body output.
- Bash and PowerShell environment doctors with allowlisted tools, read-only checks, install-plan preview, and explicit double-confirmed apply mode.
- Cross-platform 200,001-line source isolation tests, PPS/1.0 compatibility fixtures, and negative tests for missing maps, missing scripts, path escape, oversized worksets, duplicate components, and unknown tools.
- Read-only Bash and PowerShell legacy project audit commands with migration-system classification and proposed migration reports.
- Cross-platform smoke coverage proving that audits do not modify their targets and cannot write reports inside them.
- A legacy capability matrix, installed-skill health validators, asset-routing guidance, and project-local pre-commit gates.
- A repository-level adversarial review recording attack cases, acceptance evidence, and residual boundaries.
- Linux, macOS, and Windows validation jobs for both normal CI and tagged releases.
- Negative fixtures for malformed sections, manifests, authority lifecycles, package links, source rows, paths, timestamps, and staged-state bypass attempts.

### Changed

- Reframed PPS as Personal Project State for long-lived individual document, software, and hybrid projects.
- PPS/1.1 validators accept a file or directory `Main` according to mode while continuing to validate PPS/1.0 projects.
- Pre-commit snapshots now materialize PPS/1.1 map/environment controls plus bounded read and component anchors.
- Cold-start guidance now checks the declared environment before bounded recovery.
- Kept PPS self-contained: its runtime, protocol, migration rules, and documentation no longer depend on an external state workflow.
- Restored cross-device ergonomics from `plan-project-sync`: stable `main`, remote/upstream/ahead/behind status, optional fetch, human-language commands, cold-start GitHub paths, `docs/assets/prototypes`, and project-home compatibility.
- Validators now enforce canonical section placement, strict typed manifest lists, real UTC dates, safe project-relative paths, one active marker pair, globally unique authority records, package consistency, and exact coverage/source cardinality.
- Conflict diagnostics now include source line locations for duplicate authority, coverage, and source rows.
- Pre-commit validation now checks a minimal materialized snapshot of the Git index rather than the mutable worktree.

### Fixed

- Audit commands now recognize both PPS/1.0 and PPS/1.1 instead of misclassifying a valid upgraded project.
- macOS smoke-test compatibility by using a portable `sed -i.bak` invocation.
- Cross-platform PowerShell smoke-test cleanup by using the native directory separator.
- Bash validation state loss caused by command-substitution subshells.
- False mixed-system audit classification caused by treating an ordinary roadmap as a second state engine.
- Unsafe project names, missing Bash option values, PowerShell hook permissions, and symlink/reparse-point path escapes.

## [0.1.0] - 2026-07-23

### Added

- Initial public PPS/1.0 skill.
- Globally stable `M/F/D` authority IDs with separate `P/H` semantics.
- Explicit workset manifest and active authority block.
- Standard and evidence project profiles.
- PowerShell and Bash project initialization, status, and validation scripts.
- Constraint-coverage and inactive-decision failure gates.
- Migration, Git handoff, and design-rationale references.
- Cross-platform CI, smoke tests, and open-source governance.

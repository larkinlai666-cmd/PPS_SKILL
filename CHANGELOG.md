# Changelog

All notable changes are documented here. The project follows Semantic Versioning.

## [Unreleased]

### Added

- Read-only Bash and PowerShell legacy project audit commands with migration-system classification and proposed migration reports.
- Cross-platform smoke coverage proving that audits do not modify their targets and cannot write reports inside them.
- A legacy capability matrix, installed-skill health validators, asset-routing guidance, and project-local pre-commit gates.
- A repository-level adversarial review recording attack cases, acceptance evidence, and residual boundaries.
- Linux, macOS, and Windows validation jobs for both normal CI and tagged releases.
- Negative fixtures for malformed sections, manifests, authority lifecycles, package links, source rows, paths, timestamps, and staged-state bypass attempts.

### Changed

- Kept PPS self-contained: its runtime, protocol, migration rules, and documentation no longer depend on an external state workflow.
- Restored cross-device ergonomics from `plan-project-sync`: stable `main`, remote/upstream/ahead/behind status, optional fetch, human-language commands, cold-start GitHub paths, `docs/assets/prototypes`, and project-home compatibility.
- Validators now enforce canonical section placement, strict typed manifest lists, real UTC dates, safe project-relative paths, one active marker pair, globally unique authority records, package consistency, and exact coverage/source cardinality.
- Conflict diagnostics now include source line locations for duplicate authority, coverage, and source rows.
- Pre-commit validation now checks a minimal materialized snapshot of the Git index rather than the mutable worktree.

### Fixed

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

# PPS/1.1 adversarial review

- Review date: 2026-07-23
- Scope: `codex/pps-universal-projects`
- Method: first-principles threat model, capability comparison, fault injection, Bash/PowerShell parity, large-source isolation
- Verdict: **PASS within the personal serial-project boundary**

## Acceptance claims

PPS/1.1 passes only if all claims below hold:

1. it remains a capability superset of `plan-project-sync`;
2. the PPS/1.0 authority, active-block, coverage, and single-writer semantics remain valid;
3. text, software, and hybrid projects use one protocol rather than parallel state systems;
4. routine recovery cost is bounded independently of source-line count;
5. malformed component, path, environment, asset, package, authority, and coverage state fails loudly;
6. Bash and PowerShell expose the same control surface;
7. environment installation is never an implicit consequence of resuming;
8. no external workflow name, command, online artifact, state directory, or release is required at runtime;
9. multi-owner collaboration remains explicitly out of scope.

The legacy comparison is recorded in [COMPATIBILITY.md](COMPATIBILITY.md).

## First-principles model

The minimum durable personal-project state is:

- **what is true**: stable `M/F/D` authority;
- **where the project is**: hot state and one active package;
- **where to look**: stable `C-*` component boundaries;
- **what may enter context now**: bounded `Read` paths;
- **what may change now**: bounded `Write` paths;
- **how closure is tested**: declared `Verify` plus structural gates;
- **what the device needs**: an allowlisted environment manifest;
- **which non-Git bytes matter**: stable `A-*` identity, priority, locator, size, and SHA-256;
- **how history is recovered**: Git.

PPS/1.1 adds the missing navigation, environment, and optional materialization layers. It does not replace the PPS/1.0 authority model. Therefore the iteration is an additive protocol upgrade, not an architecture rewrite.

## Adversarial findings and repairs

| Attack or regression | Risk | PPS/1.1 behavior |
|---|---|---|
| Treat project root as `Main` | File-only validation rejects software projects | `software`/`hybrid` accept a contained file or directory; `document` still requires a file |
| Resume a 200,001-line codebase | Agent bulk-loads source to reconstruct context | Packet reads only control metadata and selected map rows; output is capped at 240 lines and 32768 bytes |
| Hide a sentinel in unlisted source | Recovery leaks implementation content | Bash and PowerShell tests assert the sentinel never appears |
| Reference a missing component | Agent invents architecture from memory | Every current `C-*` must resolve to exactly one map row |
| Duplicate a component ID | Navigation becomes ambiguous | Global duplicate component rows fail |
| Escape with absolute, parent, foreign-separator, symlink, or reparse paths | Workset crosses project trust boundary | Cross-platform path guards fail validation |
| Inflate current workset | “Bounded” context becomes nominal | Target is 12 paths; more than 30 fails |
| Declare `Read: .`, a glob, or one huge line | Count/line limits are bypassed | Exact-path grammar plus per-file and packet byte budgets fail |
| Delete map, environment, or recovery scripts | Upgraded project silently degrades | PPS/1.1 requires all controls and reports the exact omission |
| Add an arbitrary environment tool | Manifest becomes a command-injection surface | Only twelve stable capability names are accepted |
| Resume on a new device | Tool setup mutates the machine without review | Doctor defaults to check; apply needs two explicit flags |
| Mark optional tools | Convenience list triggers unnecessary installs | Optional tools are reported but never auto-installed |
| Use a machine without a supported package manager | Bootstrap downloads another installer | Doctor stops and requests manual installation |
| Audit a valid PPS/1.1 project | Old detector misclassifies it | Audit recognizes both PPS/1.0 and PPS/1.1 |
| Audit a text project containing `node_modules` | Generated dependency code causes a false software/hybrid migration | Common generated/dependency directories are pruned; root implementation code still informs mode |
| Validate a legacy PPS/1.0 project | Upgrade becomes forced migration | Explicit PPS/1.0 fixtures still pass |
| Validate staged state with component directories | Hook materializes a whole code tree | Snapshot creates directory anchors and exports only bounded control/read files |
| Stage `ASSETS.md` while repairing the worktree checker | Hook validates the wrong asset state or misses dependencies | Snapshot exports the staged registry and both platform asset checkers |
| Call a 4K video “reference” while the package depends on it | Missing material silently changes results | References cannot enter the active Workset; promote to supporting/core first |
| Mark a core asset `local-marker` | Git looks complete while the project cannot continue elsewhere | Core marker-only rows fail structurally |
| Put a signed URL or token in a cloud locator | Secret leaks through Git and soon expires | Only non-secret `rclone:REMOTE:path` syntax is accepted |
| Declare a cloud locator without uploading the object | Handoff falsely claims material completeness | Full handoff requires one reachable remote object with the declared byte size |
| Track a 100 MiB-class video outside LFS | Remote push fails or repository history bloats | Non-LFS binary audit warns above 50 MiB/100 MiB aggregate and fails above 95 MiB per file |
| Pass structure and assets but never run project tests | “Validated” is confused with “works” | Readiness remains `VERIFY PENDING` until explicit verification attestation |
| Move canonical fields or duplicate authority | Parser normalizes invalid state | Section scope, marker bijection, global IDs, and exact cardinality fail loudly |

The new suite also exposed two audit defects: `UTF-8` could be misread as `F-8`, and Bash failed when a legacy target had no `docs/` directory. Both now have regression coverage.

## Large-project claim

The test creates a source file with 200,001 lines, validates a software-mode project, and generates both Bash and PowerShell resume packets. The packets remain below 240 lines and 32768 bytes and exclude a unique source sentinel.

This supports one precise claim: **routine PPS recovery does not scale its context output with source size**.

It does not prove:

- that a component map is semantically complete;
- that an Agent can understand arbitrary 200,000-line code without targeted search;
- that project-native build or test commands are correct;
- that structural coverage proves semantic compliance.

Those remain explicit human/agent verification responsibilities.

## Legacy upgrade assessment

PPS/1.1 retains every mapped legacy capability: neutral Markdown/Git handoff, human-language commands, cross-device continuation, GitHub cold start, stable main branch, remote risk reporting, safe non-empty refusal, asset/prototype directories, installed-skill checks, migration audit, and cross-platform scripts.

It strengthens the old workflow with:

- stable typed authority instead of free-form memory;
- exact coverage and lifecycle gates;
- modes for documents, software, and hybrid projects;
- stable component navigation;
- bounded read/write sets;
- a source-free recovery packet;
- declarative environment diagnosis;
- tiered, content-identified asset routing and durable cloud-copy checks;
- explicit separation of structural validation from project verification attestation;
- staged-index validation;
- explicit PPS/1.0 compatibility.

No useful legacy capability is removed. Placeholder Git identities remain intentionally rejected because fabricated authorship is unsafe.

## Boundary review

PPS is sufficiently reliable for its declared scope, not universally omniscient:

- it assumes one human owner and serial canonical writes;
- it is not a distributed lock or team planner;
- it does not replace build, test, preview, deployment, or code search;
- it does not execute the declarative `Verify` line automatically;
- routine cloud proof checks remote object count and bytes, while a fresh byte-for-byte remote download remains an explicit archival audit;
- rclone credentials, provider availability, quota, and account recovery remain external user-owned conditions;
- installation still depends on the operating system's existing package manager and permissions;
- configured Windows CI is not the same as observing a future remote run.

Changing any of those boundaries—especially multi-owner authority, parallel canonical writers, or an automatic software-delivery engine—would require a fresh architecture decision rather than an incremental PPS/1.1 patch.

Within the stated boundary, PPS/1.1 is a comprehensive upgrade over both PPS/1.0 and `plan-project-sync`.

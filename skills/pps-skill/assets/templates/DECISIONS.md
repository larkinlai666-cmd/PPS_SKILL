# Authority and Decisions

## Active Authority Index

<!-- PPS:ACTIVE:BEGIN -->
- `M-001`
- `M-002`
<!-- PPS:ACTIVE:END -->

## Authority Records

### M-001 [active]

- Summary: Use globally stable authority IDs and retrieve the active package by its explicit workset manifest.
- Source: PPS/1.0 bootstrap.
- Scope: Entire project.
- Supersedes: none.
- Affects: State, context recovery, decisions, review packages.

### M-002 [active]

- Summary: A package cannot close until its main artifact, authority records, current capsule, hot state, and constraint coverage agree and validation passes.
- Source: PPS/1.0 bootstrap.
- Scope: Every package close.
- Supersedes: none.
- Affects: Review, approval, handoff, finalization.

## Status Events

- {{DATE}}: Initialized `M-001` and `M-002` as active project method constraints.

## Next ID Hints

- Method: `M-003`
- Fact: `F-001`
- Decision: `D-001`

These hints are conveniences, not authority. Search before allocating an ID.

# Asset Registry

## Asset Manifest

| ID | Priority | Sync | Materialize | Locator | SHA-256 | Bytes | Purpose |
|---|---|---|---|---|---|---:|---|

## Rules

- `core`: required for project continuity; use `git`, `git-lfs`, or `cloud`, never `local-marker`.
- `supporting`: required only when listed in the current Workset `Assets`.
- `reference`: marker-only context; absence never proves the project incomplete and it cannot enter the current Workset.
- `cloud` locators use `rclone:REMOTE:path`; credentials and rclone configuration stay outside Git.
- A cloud handoff proves that exactly one remote object exists at the locator with the declared byte size. Local SHA-256 remains authoritative for materialized bytes.
- External materializations live under ignored `local-assets/`. Every row records the expected byte size and SHA-256.

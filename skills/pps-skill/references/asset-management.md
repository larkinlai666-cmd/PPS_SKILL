# Asset materialization and sync

Git synchronization and asset materialization are separate states. Never report a complete handoff merely because Markdown and Git history are current.

## Priority classes

| Priority | Meaning | Missing on another device |
|---|---|---|
| `core` | Required to reproduce, edit, verify, or deliver the project | Blocks readiness and handoff |
| `supporting` | Required only by packages that explicitly list its `A-*` ID | Blocks that package, not unrelated work |
| `reference` | Helpful context that does not determine the current output | Does not block; keep a marker and do not list it in the Workset |

Promote a reference to `supporting` or `core` before using it as authoritative input. Do not downgrade an asset merely to make a handoff pass.

## Sync backends

| Sync | Use | Rules |
|---|---|---|
| `git` | Small, mergeable or infrequently changed core files | File must be Git tracked |
| `git-lfs` | Medium binary assets when every active device has LFS and quota | File must be tracked with the LFS filter |
| `cloud` | Very large core/supporting files such as source video or design bundles | Use a non-secret `rclone:REMOTE:path`; materialize under `local-assets/` |
| `local-marker` | Non-core reference or temporary supporting material | Never valid for `core`; current-package handoff fails |

Use an already configured user-owned `rclone` remote backed by the user's cloud or object storage. PPS does not own credentials. Never commit tokens, signed expiring URLs, cookie state, local cloud configuration, or provider account IDs that are themselves sensitive.

Cloud operations are explicit one-file copy operations. Do not run an implicit two-way mirror, delete remote files, or overwrite a different object. A safe upload shape is `rclone copyto LOCAL REMOTE:path --immutable`; inspect it before execution because it changes external state. Prefer a content-addressed remote path containing the `A-*` ID and a SHA-256 prefix.

Full handoff runs `rclone size ... --json` and requires exactly one remote object with the declared byte size. This proves presence and size, not a fresh byte-for-byte cloud download. Local materialization is SHA-256 checked; every downloaded copy is checked again. For archival bit-rot audits, run an explicit provider-appropriate `rclone checksum ... --download` outside the routine handoff path.

## Registry

Create `ASSETS.md` only when the first off-Git asset or explicitly governed binary appears. Use the bundled template and one stable `A-*` row per logical asset:

```markdown
| ID | Priority | Sync | Materialize | Locator | SHA-256 | Bytes | Purpose |
|---|---|---|---|---|---|---:|---|
| A-VIDEO-001 | core | cloud | local-assets/source/demo-4k.mp4 | rclone:mydrive:PPS/demo-4k.mp4 | 64-hex-digest | 12884901888 | Canonical combat reference video |
| A-REF-002 | reference | local-marker | local-assets/reference/moodboard.mov | local-only | 64-hex-digest | 524288000 | Optional visual mood reference |
```

`Materialize` is always project-relative. External files live under ignored `local-assets/`; the registry and hashes live in Git. `Locator` identifies where an authorized device can obtain the bytes, uses a restricted ASCII `rclone:REMOTE:path` without parent segments, queries, fragments, or credentials, and contains no secret.

The current `CONTEXT.md` lists only the `core` or `supporting` assets required by the package:

```text
- Assets: A-VIDEO-001
```

All `core` rows are checked even when not listed. A `reference` row cannot enter the Workset.

## Checks

Use the quick check during ordinary resume. It verifies registry structure, materialization, and byte size without hashing multi-gigabyte files:

```bash
bash scripts/asset_check.sh . --quick
```

Use the full handoff check before claiming cross-device completeness. It verifies local SHA-256, rejects current `local-marker` dependencies, proves cloud object presence/size through rclone, checks Git/LFS declarations, and audits tracked binary risk:

```bash
bash scripts/asset_check.sh . --handoff --risk
```

PowerShell uses `asset_check.ps1 -Quick` and `-Handoff -Risk`.

The risk audit warns when non-LFS binary candidates exceed 50 MiB individually or 100 MiB in aggregate and fails above a conservative 95 MiB single-file push ceiling. These are safety gates, not provider quota guarantees.

## Registration workflow

1. Decide whether the file is `core`, `supporting`, or `reference`.
2. Choose `git`, `git-lfs`, `cloud`, or `local-marker`.
3. For cloud/local files, place the materialization under `local-assets/`.
4. For cloud, select an existing rclone remote and a non-secret immutable destination path.
5. Record stable ID, locator, byte size, SHA-256, and purpose.
6. Upload explicitly with a non-deleting copy operation; never hide this external mutation inside ordinary Git sync.
7. Add current `core/supporting` IDs to the Workset.
8. Run the quick check locally.
9. Before save-and-sync or device handoff, run full readiness and resolve every missing, unreachable, mismatched, or local-only current asset.

If no durable remote copy exists for a core asset, the project may continue locally but its material handoff state is incomplete. Record that blocker instead of claiming successful synchronization.

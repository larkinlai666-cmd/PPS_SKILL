# Asset management

Keep the repository portable without turning it into a binary archive.

| Asset | Default handling |
|---|---|
| Text and images below 1 MB | Store under `assets/` and reference with project-relative paths. |
| Files from 1 MB through 50 MB | Store in Git only when version history is useful; recommend Git LFS for repeatedly edited binary formats. |
| Files above 50 MB, video, archives, or source-design bundles | Store externally and create `ASSETS.md` when the first such asset appears. |

`ASSETS.md` is created only when needed. Use columns for asset name, version, type, external location, updated date, and notes. Do not scatter external links across main artifacts.

Recommend Git LFS only after confirming it is available on every device that must clone the project. Record adoption as a project decision.

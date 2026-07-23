# Project modes and bounded worksets

## Mode selection

| Mode | Use for | `Main` |
|---|---|---|
| `document` | plans, reports, design, worldbuilding, research | canonical artifact file |
| `software` | scripts, lightweight websites, small games, utilities, existing codebases | project root or product directory |
| `hybrid` | a maintained specification plus executable prototype/product | project root or product directory |

Profile and mode are orthogonal. `evidence` adds source provenance; it does not imply a document-only project.

## Large-repository rule

Repository size never authorizes bulk context loading. For repositories beyond the context window:

1. load the bounded resume packet;
2. resolve `C-*` rows in `PROJECT_MAP.md`;
3. inspect only the manifest `Read` paths; a directory is a targeted search scope, not a request to load all descendants;
4. use exact symbol or text search inside those roots;
5. edit only the declared `Write` set;
6. run the declared `Verify` command after inspecting it.

The map contains architecture boundaries, not every file. The workset contains only the current package. Git history is consulted only for conflict or provenance.

## Workset design

- `Components`: stable `C-*` IDs needed now.
- `Read`: existing project-relative files needed to reason.
- `Write`: files expected to change. During bootstrap, name the state/map files that define the first slice rather than using `none`.
- `Verify`: a concise human-readable command or check declaration. It is never auto-executed by the validator.
- `Assets`: stable `A-*` IDs for core/supporting material required now; omit non-blocking references by using `none`.
- `Excluded`: important nearby scope intentionally excluded.

Target twelve or fewer combined Read/Write paths. Thirty is the hard limit, and `.` or glob patterns are invalid workset paths. Split the package if the hard limit would be exceeded.

## Personal-only boundary

PPS assumes one human owner and serial canonical writes across devices or agents. It does not provide role permissions, distributed locks, sprint planning, shared queues, merge ownership, or multi-user conflict resolution.

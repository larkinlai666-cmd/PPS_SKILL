# Safe Git synchronization

## Before work

1. Inspect branch, remotes, and worktree status.
2. If a remote exists and synchronization is requested, fetch and fast-forward or rebase according to the repository's established policy.
3. Never overwrite uncommitted user work.
4. Run the status script after updating the working tree.

The initializer accepts an optional repository-local Git name and email. Prefer that option when global identity is unset and the user does not want a machine-wide configuration change.

## During work

- Keep canonical state changes in the same logical commit as the artifact changes they describe.
- Do not let parallel agents commit competing edits to state files.
- Prefer small package-close checkpoints over narrative snapshot commits.
- Do not commit secrets, local caches, temporary exports, or unrelated user files.

## On “save”

Update state, artifact, authority records, capsule, and coverage; validate. Commit only if the user's instruction or repository protocol authorizes it.

## On “sync”

Validate, inspect the exact diff, commit intentionally, fetch, reconcile safely, and push the current branch. Never force-push unless the user explicitly requests it and the exact consequence is understood.

## On a new device

Clone the repository, inspect local instructions, run status, and resume from the manifest. Do not reconstruct state from chat memory.

## Conflict handling

Resolve semantic conflicts in this order:

1. explicit current user instruction;
2. active `F/D/M` authority and its scope;
3. current main artifact;
4. current workset;
5. older Git history.

If two same-authority records conflict and no supersession is recorded, stop and ask the user with a recommended resolution.

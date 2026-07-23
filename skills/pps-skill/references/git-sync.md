# Safe Git synchronization

## Before work

1. Inspect branch, remotes, and worktree status.
2. If synchronization is requested, run status with `--fetch`, then fast-forward or rebase according to the repository's established policy.
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

1. Check `git --version`; prefer `gh --version` for an agent-contained GitHub flow.
2. Check `gh auth status`. If authentication is missing, start one web/device authorization and ask the user only to complete that external authorization.
3. Prefer `gh repo clone <owner>/<repo> <target>`. Use HTTPS `git clone` when gh is unavailable. Use SSH only after confirming an SSH key works.
4. Open the cloned directory as the workspace, inspect `AGENTS.md`, and run project-local status.
5. Resume from the manifest. Do not reconstruct state from chat memory.

For a new remote, prefer:

```bash
gh repo create <name> --private --source=. --remote=origin --push
```

When adding a remote manually, keep its protocol consistent with the authenticated Git transport. Never assume gh authentication proves an SSH key exists.

## Human-language commands

- “同步并继续”: inspect dirty state and upstream, fetch/pull safely, validate, then report the current package and next action.
- “保存并同步”: update the complete canonical write set, validate, inspect the diff, commit, fetch/reconcile, and push.
- “这个定了”: record explicit approval as a `D-*` decision and propagate it before commit.
- “冷启动接入项目”: perform the new-device sequence above.

## Conflict handling

Resolve semantic conflicts in this order:

1. explicit current user instruction;
2. active `F/D/M` authority and its scope;
3. current main artifact;
4. current workset;
5. older Git history.

If two same-authority records conflict and no supersession is recorded, stop and ask the user with a recommended resolution.

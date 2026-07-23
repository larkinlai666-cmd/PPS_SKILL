# Safe Git synchronization

## Before work

1. Inspect branch, remotes, and worktree status.
2. If synchronization is requested, run status with `--fetch`, then fast-forward or rebase according to the repository's established policy.
3. Never overwrite uncommitted user work.
4. Run the environment doctor in check mode and then the resume-packet script after updating the working tree.
5. Treat Git state and asset materialization as separate. A clean/pushed repository is not a complete handoff while required `core` or current `supporting` assets are missing or mismatched.

The initializer accepts an optional repository-local Git name and email. Prefer that option when global identity is unset and the user does not want a machine-wide configuration change.

## During work

- Keep canonical state changes in the same logical commit as the artifact changes they describe.
- Do not let parallel agents commit competing edits to state files.
- Prefer small package-close checkpoints over narrative snapshot commits.
- Do not commit secrets, local caches, temporary exports, or unrelated user files.

## On “save”

Update state, artifact, authority records, capsule, asset registry, and coverage; validate. Run the full asset handoff check and the declared environment/project verification before marking readiness. Commit only if the user's instruction or repository protocol authorizes it.

## On “sync”

Validate, inspect the exact diff, run `readiness_check.*` after the declared verification passes, commit intentionally, fetch, reconcile safely, and push the current branch. Never force-push unless the user explicitly requests it and the exact consequence is understood.

For cloud-backed assets, upload/download is a separate explicit one-file operation through the declared rclone locator. Never infer that `git push` transferred external bytes. Never run an automatic two-way cloud mirror or delete remote material during project sync. Full asset handoff must prove that the remote object exists with the declared size.

## On a new device

1. Run the installed skill's environment doctor in core mode; it checks `git` and `gh` before a project exists.
2. Check `gh auth status`. If authentication is missing, start one web/device authorization and ask the user only to complete that external authorization.
3. Prefer `gh repo clone <owner>/<repo> <target>`. Use HTTPS `git clone` when gh is unavailable. Use SSH only after confirming an SSH key works.
4. Open the cloned directory as the workspace and inspect `AGENTS.md`.
5. Run the project-local environment doctor in check mode. Use plan mode to preview missing-tool actions; install only with explicit user authorization.
6. Run the project-local resume-packet script and resume from its bounded manifest. Do not reconstruct state from chat memory.
7. If asset readiness is incomplete, retrieve only the required `core` and current `supporting` assets through their non-secret locators, verify SHA-256, and keep optional references absent.

For a new remote, prefer:

```bash
gh repo create <name> --private --source=. --remote=origin --push
```

When adding a remote manually, keep its protocol consistent with the authenticated Git transport. Never assume gh authentication proves an SSH key exists.

## Human-language commands

- “同步并继续”: inspect dirty state and upstream, fetch/pull safely, check the environment, validate, then report both bounded state recovery and asset materialization.
- “保存并同步”: update the complete canonical write set, validate, verify required assets and declared checks, inspect the diff, commit, fetch/reconcile, and push. Report Git sync and material sync separately.
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

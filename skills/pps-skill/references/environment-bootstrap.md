# Environment bootstrap

## Safety model

Environment setup is manifest-driven and idempotent:

1. before clone, run the installed skill's doctor with `--core` or `-Core` to check Git and GitHub CLI;
2. after clone, run the project-local `environment_doctor` in check mode;
3. inspect one consolidated install plan;
4. request one explicit approval for system changes;
5. apply with `--apply --yes` or `-Apply -Yes`;
6. rerun check mode and record project-specific setup/verify commands.

Check mode is read-only. Apply mode installs only allowlisted tools named in `ENVIRONMENT.md`.

Pre-clone examples:

```bash
bash <skill>/scripts/environment_doctor.sh --core
```

```powershell
powershell -ExecutionPolicy Bypass -File <skill>\scripts\environment_doctor.ps1 -Core
```

Core mode requires `git` and `gh` and does not need a project manifest. It exists only for a new device that cannot clone yet.

## Tool policy

Supported capability names are `git`, `gh`, `rg`, `node`, `python`, `powershell`, `imagemagick`, `ffmpeg`, `pandoc`, `libreoffice`, `poppler`, and `rclone`.

- `powershell` accepts either `pwsh` or `powershell`.
- `libreoffice` accepts `libreoffice`, `soffice`, or the standard macOS application binary.
- `poppler` requires both `pdftotext` and `pdftoppm`.
- `rclone` is optional until a `cloud` asset exists; a cloud handoff requires it to prove durable-object presence. PPS never stores its credentials.

- Prefer an already installed tool.
- Prefer lockfile-based project dependencies over global language packages.
- Declare project-local lockfiles or requirements under `Dependency manifests`; use `Environment verify` to check imports such as `openpyxl` without treating the Python executable alone as sufficient.
- Use Homebrew on macOS, winget on Windows, or an existing supported Linux package manager.
- Do not bootstrap a package manager, change shell profiles, pipe remote scripts to a shell, install editor extensions, or start background services.
- If no supported manager is available, report exact missing capabilities and stop.
- If a capability has no safe mapping for the selected manager, report a manual install boundary instead of guessing a package name or adding a third-party repository.

`Optional` tools never make check mode fail. Promote a tool to `Required` only after the project actually depends on it.

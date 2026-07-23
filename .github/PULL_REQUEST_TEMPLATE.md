## What changed

<!-- Describe the behavior or documentation change. -->

## Why

<!-- Describe the user scenario or failure mode. -->

## Compatibility

<!-- State whether existing PPS projects require migration. -->

## Validation

- [ ] `python tools/validate_skill.py`
- [ ] `bash tests/smoke.sh`
- [ ] `powershell -ExecutionPolicy Bypass -File tests/smoke.ps1` when applicable

## Protocol checklist

- [ ] Active authority semantics remain explicit.
- [ ] Windows and Bash behavior agree.
- [ ] New validation behavior includes a negative test.
- [ ] No credentials or user project content are included.

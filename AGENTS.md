# AGENTS.md — PPS Skill repository

The distributable skill lives only in `skills/pps-skill/`. Repository-level files document, test, and release that artifact.

## Change workflow

1. Read `skills/pps-skill/SKILL.md` and only the references relevant to the change.
2. Preserve the invariant that skill frontmatter contains only `name` and `description`.
3. Keep repository governance files outside the skill directory.
4. Treat PowerShell and Bash behavior as one compatibility surface.
5. Add a negative test when fixing a validation omission.
6. Run `python3 tools/validate_skill.py` on macOS/Linux (`python` on Windows) and the applicable smoke tests.

## Protocol compatibility

- Do not reuse or renumber global authority IDs.
- Do not make proposals or assumptions active authority.
- Do not replace explicit worksets with recent-file heuristics.
- Do not weaken fail-loud parsing or coverage gates.
- Document migration for any incompatible grammar change.

## Release

Update `VERSION` and `CHANGELOG.md` together. A `v*` tag publishes a ZIP containing `skills/pps-skill`.

Do not commit user projects, test-generated directories, credentials, or local Codex configuration.

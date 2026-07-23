# Project Map

This is a compact navigation map, not a generated inventory. Keep stable architecture boundaries here and keep file-level work in `CONTEXT.md`.

## Project Shape

- Mode: {{MODE}}
- Root truth: {{MAIN_ARTIFACT}}
- Scale policy: retrieve the current package, component rows, and exact target paths before reading implementation content.

## Components

| ID | Root | Responsibility | Interfaces | Verification anchor |
|---|---|---|---|---|
| C-ROOT | {{MAIN_ARTIFACT}} | Current project deliverable and bootstrap boundary | Replace with stable entry points | `scripts/validate_project.*` |

## Navigation Rules

- Add one stable `C-*` row per architecture boundary, not per file.
- Keep IDs stable when files move; update the Root column.
- Put current file/symbol targets in `CONTEXT.md`, not here.
- Do not paste source code, generated trees, dependency listings, or Git history into this map.

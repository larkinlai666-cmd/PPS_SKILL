#!/usr/bin/env python3
"""Validate the public PPS Skill distribution without third-party packages."""

from __future__ import annotations

import re
import sys
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
SKILL = REPO / "skills" / "pps-skill"
ERRORS: list[str] = []


def error(message: str) -> None:
    ERRORS.append(message)


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        error(f"Cannot read {path.relative_to(REPO)} as UTF-8: {exc}")
        return ""


required = [
    "SKILL.md",
    "agents/openai.yaml",
    "assets/templates/AGENTS.md",
    "assets/templates/CONTEXT.md",
    "assets/templates/CURRENT_REVIEW_EVIDENCE.md",
    "assets/templates/DECISIONS.md",
    "assets/templates/MAIN.md",
    "assets/templates/PROJECT_README.md",
    "assets/templates/PROJECT_STATE.md",
    "assets/templates/SOURCE_INDEX.md",
    "assets/templates/gitattributes.template",
    "assets/templates/gitignore.template",
    "references/design-rationale.md",
    "references/git-sync.md",
    "references/migration.md",
    "references/protocol.md",
    "references/retrieval-and-gates.md",
    "scripts/init_project.ps1",
    "scripts/init_project.sh",
    "scripts/status_check.ps1",
    "scripts/status_check.sh",
    "scripts/validate_project.ps1",
    "scripts/validate_project.sh",
]

for relative in required:
    if not (SKILL / relative).is_file():
        error(f"Missing required skill file: {relative}")

for forbidden in ("README.md", "CHANGELOG.md", "CONTRIBUTING.md", "LICENSE"):
    if (SKILL / forbidden).exists():
        error(f"Repository-level file must not be inside the skill: {forbidden}")

skill_md = read(SKILL / "SKILL.md")
frontmatter = re.match(r"\A---\r?\n(.*?)\r?\n---\r?\n", skill_md, re.DOTALL)
if not frontmatter:
    error("SKILL.md must begin with YAML frontmatter.")
else:
    fields: dict[str, str] = {}
    for line in frontmatter.group(1).splitlines():
        if not line.strip():
            continue
        match = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if not match:
            error(f"Malformed SKILL.md frontmatter line: {line}")
            continue
        fields[match.group(1)] = match.group(2).strip()
    if set(fields) != {"name", "description"}:
        error(
            "SKILL.md frontmatter must contain only name and description; "
            f"found {sorted(fields)}"
        )
    if fields.get("name") != "pps-skill":
        error("SKILL.md name must be pps-skill.")
    description = fields.get("description", "")
    if len(description) < 80 or "方案型项目" not in description:
        error("SKILL.md description must explain capability and Chinese trigger context.")

for link in re.findall(r"\[[^\]]+\]\(([^)]+)\)", skill_md):
    if "://" in link or link.startswith("#"):
        continue
    target = (SKILL / link.split("#", 1)[0]).resolve()
    if not target.exists():
        error(f"Broken local link in SKILL.md: {link}")

openai_yaml = read(SKILL / "agents" / "openai.yaml")
for key in ("display_name:", "short_description:", "default_prompt:"):
    if key not in openai_yaml:
        error(f"agents/openai.yaml is missing {key}")
if "$pps-skill" not in openai_yaml:
    error("agents/openai.yaml default_prompt must mention $pps-skill.")

all_skill_text = ""
for path in SKILL.rglob("*"):
    if path.is_file() and path.suffix.lower() in {".md", ".ps1", ".sh", ".yaml", ".template"}:
        all_skill_text += read(path)
if re.search(r"\bTODO\b|\[TODO", all_skill_text, re.IGNORECASE):
    error("Skill distribution contains TODO markers.")

version = read(REPO / "VERSION").strip()
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    error(f"VERSION is not semantic: {version!r}")
if f"## [{version}]" not in read(REPO / "CHANGELOG.md"):
    error(f"CHANGELOG.md has no section for VERSION {version}.")

if ERRORS:
    print(f"PPS distribution validation: FAILED ({len(ERRORS)} error(s))")
    for item in ERRORS:
        print(f"ERROR: {item}")
    sys.exit(1)

print("PPS distribution validation: OK")
print(f"Version: {version}")
print(f"Skill files: {sum(1 for path in SKILL.rglob('*') if path.is_file())}")

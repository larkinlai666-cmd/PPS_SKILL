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
    "assets/templates/ASSETS.md",
    "assets/templates/CONTEXT.md",
    "assets/templates/CURRENT_REVIEW_EVIDENCE.md",
    "assets/templates/DECISIONS.md",
    "assets/templates/EVENTS.md",
    "assets/templates/MAIN.md",
    "assets/templates/ENVIRONMENT.md",
    "assets/templates/PROJECT_MAP.md",
    "assets/templates/PROJECT_README.md",
    "assets/templates/PROJECT_STATE.md",
    "assets/templates/SOURCE_INDEX.md",
    "assets/templates/gitattributes.template",
    "assets/templates/gitignore.template",
    "references/design-rationale.md",
    "references/environment-bootstrap.md",
    "references/asset-management.md",
    "references/git-sync.md",
    "references/migration.md",
    "references/multitask.md",
    "references/protocol.md",
    "references/project-modes.md",
    "references/retrieval-and-gates.md",
    "scripts/audit_legacy_project.ps1",
    "scripts/audit_legacy_project.sh",
    "scripts/asset_check.ps1",
    "scripts/asset_check.sh",
    "scripts/init_project.ps1",
    "scripts/init_project.sh",
    "scripts/environment_doctor.ps1",
    "scripts/environment_doctor.sh",
    "scripts/pre-commit",
    "scripts/pre-commit.ps1",
    "scripts/readiness_check.ps1",
    "scripts/readiness_check.sh",
    "scripts/resume_packet.ps1",
    "scripts/resume_packet.sh",
    "scripts/status_check.ps1",
    "scripts/status_check.sh",
    "scripts/validate_project.ps1",
    "scripts/validate_project.sh",
    "scripts/validate_skill.ps1",
    "scripts/validate_skill.sh",
    "scripts/verify_gate.ps1",
    "scripts/verify_gate.sh",
    "scripts/append_event.ps1",
    "scripts/append_event.sh",
    "scripts/boundary_check.ps1",
    "scripts/boundary_check.sh",
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
    if len(description) < 80 or "个人项目状态管理" not in description:
        error("SKILL.md description must explain universal personal-project capability and Chinese trigger context.")
    for trigger in (
        "发起项目",
        "个人项目状态管理",
        "轻量网页开发",
        "小游戏开发",
        "大型代码库继续开发",
        "跨设备同步项目",
        "多端推进同一任务",
        "换设备继续",
        "同步并继续",
        "保存并同步",
        "接入GitHub",
        "新设备冷启动",
        "冷启动接入项目",
        "新设备接入并继续",
        "clone并继续",
        "从GitHub接入并继续",
        "跨agent协作",
        "大文件素材同步",
        "这个定了",
    ):
        if trigger not in description:
            error(f"SKILL.md description is missing compatibility trigger: {trigger}")

for markdown_path in SKILL.rglob("*.md"):
    markdown_text = read(markdown_path)
    for link in re.findall(r"\[[^\]]+\]\(([^)]+)\)", markdown_text):
        if "://" in link or link.startswith("#") or link.startswith("mailto:"):
            continue
        relative_target = link.split("#", 1)[0]
        target = (markdown_path.parent / relative_target).resolve()
        source = markdown_path.relative_to(REPO)
        try:
            target.relative_to(SKILL.resolve())
        except ValueError:
            error(f"Local link escapes the distributable skill in {source}: {link}")
        if not target.exists():
            error(f"Broken local link in {source}: {link}")

openai_yaml = read(SKILL / "agents" / "openai.yaml")
for key in ("display_name:", "short_description:", "default_prompt:"):
    if key not in openai_yaml:
        error(f"agents/openai.yaml is missing {key}")
if "$pps-skill" not in openai_yaml:
    error("agents/openai.yaml default_prompt must mention $pps-skill.")

all_skill_text = ""
for path in SKILL.rglob("*"):
    if path.is_file() and (
        path.suffix.lower() in {".md", ".ps1", ".sh", ".yaml", ".template"}
        or path.name == "pre-commit"
    ):
        all_skill_text += read(path)
if re.search(r"\bTODO\b|\[TODO", all_skill_text, re.IGNORECASE):
    error("Skill distribution contains TODO markers.")
external_token = "g" + "sd"
state_dir_token = "." + "planning"
external_patterns = (
    rf"\b{external_token}\b",
    f"open-{external_token}",
    f"{external_token}-core",
    re.escape(state_dir_token),
)
if re.search("|".join(external_patterns), all_skill_text, re.IGNORECASE):
    error("PPS core contains an external state-system name or dedicated state-directory coupling.")

if not (REPO / "COMPATIBILITY.md").is_file():
    error("Repository is missing COMPATIBILITY.md for legacy capability tracking.")
if not (REPO / "ADVERSARIAL_REVIEW.md").is_file():
    error("Repository is missing ADVERSARIAL_REVIEW.md for hardening evidence.")
validate_workflow = read(REPO / ".github" / "workflows" / "validate.yml")
for runner in ("ubuntu-latest", "macos-latest", "windows-latest"):
    if runner not in validate_workflow:
        error(f"Validation workflow is missing runner: {runner}")

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

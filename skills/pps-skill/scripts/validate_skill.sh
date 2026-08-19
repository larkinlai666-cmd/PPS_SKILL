#!/usr/bin/env bash
set -uo pipefail

skill_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
errors=()
warnings=()

add_error() {
  errors+=("$1")
}

add_warning() {
  warnings+=("$1")
}

if [[ ! -d "$skill_root" ]]; then
  echo "PPS skill validation: FAILED"
  echo "ERROR: Skill root is not a directory: $skill_root"
  exit 1
fi
skill_root="$(cd "$skill_root" && pwd -P)"

required=(
  SKILL.md
  agents/openai.yaml
  assets/templates/AGENTS.md
  assets/templates/ASSETS.md
  assets/templates/CONTEXT.md
  assets/templates/CURRENT_REVIEW_EVIDENCE.md
  assets/templates/DECISIONS.md
  assets/templates/EVENTS.md
  assets/templates/MAIN.md
  assets/templates/ENVIRONMENT.md
  assets/templates/PROJECT_MAP.md
  assets/templates/PROJECT_README.md
  assets/templates/PROJECT_STATE.md
  assets/templates/SOURCE_INDEX.md
  assets/templates/gitattributes.template
  assets/templates/gitignore.template
  references/asset-management.md
  references/design-rationale.md
  references/environment-bootstrap.md
  references/git-sync.md
  references/migration.md
  references/multitask.md
  references/protocol.md
  references/project-modes.md
  references/retrieval-and-gates.md
  scripts/audit_legacy_project.ps1
  scripts/audit_legacy_project.sh
  scripts/asset_check.ps1
  scripts/asset_check.sh
  scripts/init_project.ps1
  scripts/init_project.sh
  scripts/environment_doctor.ps1
  scripts/environment_doctor.sh
  scripts/pre-commit
  scripts/pre-commit.ps1
  scripts/readiness_check.ps1
  scripts/readiness_check.sh
  scripts/resume_packet.ps1
  scripts/resume_packet.sh
  scripts/status_check.ps1
  scripts/status_check.sh
  scripts/validate_project.ps1
  scripts/validate_project.sh
  scripts/validate_skill.ps1
  scripts/validate_skill.sh
  scripts/verify_gate.ps1
  scripts/verify_gate.sh
  scripts/append_event.ps1
  scripts/append_event.sh
  scripts/boundary_check.ps1
  scripts/boundary_check.sh
)

for relative in "${required[@]}"; do
  [[ -f "$skill_root/$relative" ]] ||
    add_error "Missing required skill file: $relative"
done

if [[ -f "$skill_root/SKILL.md" ]]; then
  first_line="$(sed -n '1p' "$skill_root/SKILL.md")"
  name_count="$(grep -Ec '^name:[[:space:]]+pps-skill[[:space:]]*$' "$skill_root/SKILL.md" || true)"
  description_count="$(grep -Ec '^description:[[:space:]]+.+$' "$skill_root/SKILL.md" || true)"
  [[ "$first_line" == "---" ]] ||
    add_error "SKILL.md must begin with YAML frontmatter."
  [[ "$name_count" == "1" ]] ||
    add_error "SKILL.md must declare name: pps-skill exactly once."
  [[ "$description_count" == "1" ]] ||
    add_error "SKILL.md must declare one non-empty description."
fi

for script in "$skill_root/scripts/"*.sh "$skill_root/scripts/pre-commit"; do
  [[ -f "$script" ]] || continue
  bash -n "$script" ||
    add_error "Bash parser rejected: ${script#$skill_root/}"
done

for token in \
  '{{PROJECT_NAME}}' '{{PROFILE}}' '{{MODE}}' '{{TIMESTAMP}}' '{{DATE}}' \
  '{{DEVICE}}' '{{MAIN_ARTIFACT}}' '{{COVERAGE_ARTIFACT}}' \
  '{{READ_SET}}' '{{WRITE_SET}}' '{{OPTIONAL_TOOLS}}'; do
  if ! grep -RqsF "$token" "$skill_root/assets/templates"; then
    add_error "Templates are missing required token: $token"
  fi
done

command -v git >/dev/null 2>&1 ||
  add_warning "git is unavailable; project initialization cannot create synchronized history."
command -v gh >/dev/null 2>&1 ||
  add_warning "gh is unavailable; GitHub setup must use HTTPS/SSH fallback."
if ! command -v pwsh >/dev/null 2>&1 &&
    ! command -v powershell >/dev/null 2>&1; then
  add_warning "PowerShell is unavailable; PowerShell parity cannot be checked on this device."
fi

if [[ ${#warnings[@]} -gt 0 ]]; then
  for message in "${warnings[@]}"; do
    echo "WARNING: $message"
  done
fi
if [[ ${#errors[@]} -gt 0 ]]; then
  echo "PPS skill validation: FAILED (${#errors[@]} error(s))"
  for message in "${errors[@]}"; do
    echo "ERROR: $message"
  done
  exit 1
fi

echo "PPS skill validation: OK"
echo "Skill root: $skill_root"

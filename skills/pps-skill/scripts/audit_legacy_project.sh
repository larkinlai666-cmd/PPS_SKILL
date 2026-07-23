#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: audit_legacy_project.sh [--root DIR] [--output FILE]"
}

root="$(pwd)"
output=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ $# -ge 2 ]] || {
        usage >&2
        exit 2
      }
      root="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || {
        usage >&2
        exit 2
      }
      output="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

[[ -d "$root" ]] || {
  echo "Audit root is not a directory: $root" >&2
  exit 1
}
root="$(cd "$root" && pwd -P)"

file_status() {
  if [[ -f "$root/$1" ]]; then
    printf 'present'
  else
    printf 'missing'
  fi
}

state="$root/PROJECT_STATE.md"
state_text=""
if [[ -f "$state" ]]; then
  state_text="$(cat "$state")"
fi
hot_state_text="$(
  printf '%s\n' "$state_text" |
    awk '
      $0 ~ "^##[[:space:]]+Hot State[[:space:]]*$" {inside=1; next}
      inside && /^##[[:space:]]/ {exit}
      inside {print}
    '
)"

state_value() {
  printf '%s\n' "$hot_state_text" |
    sed -n "s/^-[[:space:]]*$1:[[:space:]]*//p" |
    head -n 1
}

protocol="$(state_value Protocol)"
profile="$(state_value Profile)"
main_artifact="$(state_value Main)"

has_state=0
has_decisions=0
has_context=0
has_agents=0
has_plan_control=0
has_pps_protocol=0
has_other_state=0

[[ -f "$root/PROJECT_STATE.md" ]] && has_state=1
[[ -f "$root/DECISIONS.md" ]] && has_decisions=1
[[ -f "$root/CONTEXT.md" ]] && has_context=1
[[ -f "$root/AGENTS.md" ]] && has_agents=1
if (( has_state == 1 && has_decisions == 1 && has_agents == 1 )); then
  has_plan_control=1
fi
if [[ "$protocol" == "PPS/1.0" ]] &&
  (( has_state == 1 && has_decisions == 1 && has_context == 1 && has_agents == 1 )); then
  has_pps_protocol=1
fi
other_state_candidates="$(
  find "$root" \
    -path "$root/.git" -prune -o \
    -type f \( \
      -name 'STATE.md' -o \
      -name 'CURRENT_STATE.md' -o \
      -name 'WORKFLOW_STATE.md' \
    \) -print
)"
other_state_count="$(
  printf '%s\n' "$other_state_candidates" |
    sed '/^$/d' |
    wc -l |
    tr -d ' '
)"
(( other_state_count > 0 )) && has_other_state=1

if (( has_pps_protocol == 1 )); then
  detected="pps"
elif (( has_plan_control == 1 && has_other_state == 1 )); then
  detected="mixed"
elif (( has_plan_control == 1 )); then
  detected="plan-project-sync"
elif (( has_other_state == 1 )); then
  detected="other-state-system"
else
  detected="unstructured"
fi

recommended_profile="standard (provisional)"
if [[ -f "$root/SOURCE_INDEX.md" ||
  -f "$root/docs/CURRENT_REVIEW_EVIDENCE.md" ]]; then
  recommended_profile="evidence"
fi

markdown_count="$(
  find "$root" \
    -path "$root/.git" -prune -o \
    -type f -name '*.md' -print |
    wc -l |
    tr -d ' '
)"

authority_ids="$(
  find "$root" \
    -path "$root/.git" -prune -o \
    -type f -name '*.md' \
    -exec grep -hoE '[MFD]-[A-Za-z0-9][A-Za-z0-9_-]*' {} + 2>/dev/null |
    sort -u || true
)"
authority_count="$(
  printf '%s\n' "$authority_ids" |
    sed '/^$/d' |
    wc -l |
    tr -d ' '
)"

git_status="not detected"
if command -v git >/dev/null 2>&1 &&
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_status="present"
fi

render_report() {
  printf '# PPS Legacy Project Audit\n\n'
  printf -- '- Target: `%s`\n' "$root"
  printf -- '- Generated: `%s`\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf -- '- Audit mode: read-only\n'
  printf -- '- Detected system: `%s`\n' "$detected"
  printf -- '- Recommended profile: `%s`\n\n' "$recommended_profile"

  printf '## Inventory\n\n'
  printf '| Signal | Status |\n'
  printf '|---|---|\n'
  printf '| Git repository | %s |\n' "$git_status"
  printf '| README.md | %s |\n' "$(file_status README.md)"
  printf '| AGENTS.md | %s |\n' "$(file_status AGENTS.md)"
  printf '| PROJECT_STATE.md | %s |\n' "$(file_status PROJECT_STATE.md)"
  printf '| DECISIONS.md | %s |\n' "$(file_status DECISIONS.md)"
  printf '| CONTEXT.md | %s |\n' "$(file_status CONTEXT.md)"
  printf '| SOURCE_INDEX.md | %s |\n' "$(file_status SOURCE_INDEX.md)"
  printf '| Other state candidates | %s |\n' "$other_state_count"
  printf '| Markdown files | %s |\n' "$markdown_count"
  printf '| Unique M/F/D-shaped IDs | %s |\n\n' "$authority_count"

  printf '## Existing declarations\n\n'
  printf -- '- Protocol: `%s`\n' "${protocol:-not declared}"
  printf -- '- Profile: `%s`\n' "${profile:-not declared}"
  printf -- '- Main artifact: `%s`\n\n' "${main_artifact:-not declared}"

  printf '## Proposed migration\n\n'
  case "$detected" in
    pps)
      printf 'This repository already declares PPS/1.0 and has the core control files.\n\n'
      printf '1. Run the project-local validator.\n'
      printf '2. Resolve every reported mismatch without weakening validation.\n'
      printf '3. Do not create a second state system.\n'
      ;;
    plan-project-sync)
      printf 'Reuse the existing project state and decision history; do not reinitialize the repository.\n\n'
      printf '1. Preserve existing IDs and historical records.\n'
      printf '2. Add PPS hot-state fields and one explicit workset manifest.\n'
      printf '3. Add an active authority block without promoting proposals or assumptions.\n'
      printf '4. Add coverage and project-local validation scripts on a branch.\n'
      printf '5. Switch AGENTS.md only after validation passes.\n'
      ;;
    other-state-system)
      printf 'Treat the existing state system as authoritative until an explicit cutover is approved.\n\n'
      printf '1. Inventory current project, requirements, state, roadmap, context, plan, and summary files.\n'
      printf '2. Map only binding M/F/D authority and resolve repeated stage-local IDs.\n'
      printf '3. Select the current deliverable and build one explicit workset.\n'
      printf '4. Validate the proposed PPS state before stopping the legacy state system.\n'
      ;;
    mixed)
      printf 'Multiple state systems are present. Do not write until one authority is selected.\n\n'
      printf '1. Identify which system currently controls workflow and decisions.\n'
      printf '2. Preserve the other system as migration history until user-approved cutover.\n'
      printf '3. Build and validate one proposed PPS authority index and workset.\n'
      printf '4. Stop running both state machines after cutover.\n'
      ;;
    unstructured)
      printf 'No supported state system was detected. User review is required before authority is created.\n\n'
      printf '1. Identify the current deliverable and authoritative user facts.\n'
      printf '2. Separate binding constraints from historical AI suggestions.\n'
      printf '3. Mark uncertainty as proposals or assumptions, not decisions.\n'
      printf '4. Review the initial active index with the user before cutover.\n'
      ;;
  esac

  printf '\n## Safety result\n\n'
  printf 'The target was inspected without modification. This report is a proposal, not an active migration.\n'
}

if [[ -z "$output" ]]; then
  render_report
  exit 0
fi

output_parent_input="$(dirname "$output")"
[[ -d "$output_parent_input" ]] || {
  echo "Output parent does not exist: $output_parent_input" >&2
  exit 1
}
output_parent="$(cd "$output_parent_input" && pwd -P)"
output_full="$output_parent/$(basename "$output")"

if [[ "$root" == "/" || "$output_full" == "$root" || "$output_full" == "$root/"* ]]; then
  echo "Refusing to write the audit report inside the target project: $output_full" >&2
  exit 1
fi
[[ ! -e "$output_full" ]] || {
  echo "Refusing to overwrite an existing report: $output_full" >&2
  exit 1
}

render_report >"$output_full"
echo "PPS legacy audit report written: $output_full"

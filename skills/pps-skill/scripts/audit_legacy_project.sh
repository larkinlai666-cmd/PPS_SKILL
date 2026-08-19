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

project_find() {
  find "$root" -mindepth 1 \
    \( \
      -type d \( \
        -name '.git' -o \
        -name 'node_modules' -o \
        -name '.venv' -o \
        -name 'venv' -o \
        -name 'vendor' -o \
        -name 'dist' -o \
        -name 'build' -o \
        -name '.next' -o \
        -name 'coverage' \
      \) \
    \) -prune -o "$@"
}

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
declared_mode="$(state_value Mode)"
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
if [[ "$protocol" == "PPS/1.0" || "$protocol" == "PPS/1.1" || "$protocol" == "PPS/1.2" ]] &&
  (( has_state == 1 && has_decisions == 1 && has_context == 1 && has_agents == 1 )); then
  has_pps_protocol=1
fi
other_state_candidates="$(
  project_find \
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

implementation_code_count="$(
  project_find \
    -type f \
    ! -path "$root/scripts/*" \
    \( \
      -name '*.html' -o -name '*.css' -o -name '*.js' -o \
      -name '*.jsx' -o -name '*.mjs' -o -name '*.cjs' -o \
      -name '*.ts' -o -name '*.tsx' -o -name '*.vue' -o \
      -name '*.svelte' -o -name '*.py' -o -name '*.rb' -o \
      -name '*.php' -o -name '*.go' -o -name '*.rs' -o \
      -name '*.java' -o -name '*.kt' -o -name '*.swift' -o \
      -name '*.cs' -o -name '*.c' -o -name '*.cc' -o \
      -name '*.cpp' -o -name '*.h' -o -name '*.lua' -o \
      -name '*.sh' -o -name '*.ps1' \
    \) -print |
    wc -l |
    tr -d ' '
)"
software_signal_count="$(
  project_find \
    ! -path "$root/scripts/*" \
    -type f \( \
      -name 'package.json' -o -name 'pyproject.toml' -o \
      -name 'Cargo.toml' -o -name 'go.mod' \
    \) -print |
    wc -l |
    tr -d ' '
)"
document_signal_count="$(
  project_find \
    -path "$root/docs/*" -type f -name '*.md' -print |
    wc -l |
    tr -d ' '
)"
dependency_manifest_count="$(
  project_find \
    -type f \( \
      -name 'requirements*.txt' -o -name 'pyproject.toml' -o \
      -name 'package-lock.json' -o -name 'pnpm-lock.yaml' -o \
      -name 'yarn.lock' -o -name 'uv.lock' -o -name 'poetry.lock' \
    \) -print |
    wc -l |
    tr -d ' '
)"
binary_candidate_count="$(
  project_find \
    -type f \( \
      -iname '*.mp4' -o -iname '*.mov' -o -iname '*.mkv' -o \
      -iname '*.gif' -o -iname '*.png' -o -iname '*.jpg' -o \
      -iname '*.jpeg' -o -iname '*.xlsx' -o -iname '*.docx' -o \
      -iname '*.pptx' -o -iname '*.pdf' -o -iname '*.zip' \
    \) -print |
    wc -l |
    tr -d ' '
)"
if [[ "$declared_mode" == "document" ||
  "$declared_mode" == "software" ||
  "$declared_mode" == "hybrid" ]]; then
  recommended_mode="$declared_mode (declared)"
elif (( implementation_code_count > 0 && document_signal_count > 0 )); then
  recommended_mode="hybrid"
elif (( implementation_code_count > 0 || software_signal_count > 0 )); then
  recommended_mode="software"
else
  recommended_mode="document"
fi

markdown_count="$(
  project_find \
    -type f -name '*.md' -print |
    wc -l |
    tr -d ' '
)"

authority_ids="$(
  project_find \
    -type f -name '*.md' \
    -exec grep -hoE '[A-Za-z0-9_-]+' {} + 2>/dev/null |
    grep -E '^[MFD]-[0-9]+[a-z]*$' |
    sort -u || true
)"
authority_count="$(
  printf '%s\n' "$authority_ids" |
    sed '/^$/d' |
    wc -l |
    tr -d ' '
)"

decision_sections=0
decision_bytes=0
canonical_record_count=0
if [[ -f "$root/DECISIONS.md" ]]; then
  decision_sections="$(grep -Ec '^##[[:space:]]+' "$root/DECISIONS.md" || true)"
  decision_bytes="$(wc -c < "$root/DECISIONS.md" | tr -d ' ')"
  canonical_record_count="$(
    grep -Ec '^###[[:space:]]+[MFD]-[0-9]+[a-z]*[[:space:]]+\[(active|superseded|rejected|frozen)\][[:space:]]*$' \
      "$root/DECISIONS.md" || true
  )"
fi

tooling_term_hits=0
machine_specific_hits=0
control_files=()
for control_file in README.md AGENTS.md PROJECT_STATE.md DECISIONS.md; do
  [[ -f "$root/$control_file" ]] && control_files+=("$root/$control_file")
done
if (( ${#control_files[@]} > 0 )); then
  tooling_term_hits="$(
    grep -Eio \
      'plan-project-sync|skill|github cli|gh cli|winget|workbuddy|powershell' \
      "${control_files[@]}" 2>/dev/null |
      wc -l |
      tr -d ' ' || true
  )"
  machine_specific_hits="$(
    grep -Eio \
      '127\.0\.0\.1:[0-9]+|[A-Za-z]:\\|/Users/|/home/|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY' \
      "${control_files[@]}" 2>/dev/null |
      wc -l |
      tr -d ' ' || true
  )"
fi

if (( authority_count > 100 || decision_bytes > 100000 )); then
  authority_review_risk="high"
elif (( decision_sections > 0 && canonical_record_count < decision_sections )); then
  authority_review_risk="medium"
else
  authority_review_risk="low"
fi

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
  printf -- '- Recommended mode: `%s`\n' "$recommended_mode"
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
  printf '| Strict M/F/D IDs | %s |\n' "$authority_count"
  printf '| Free-form decision sections | %s |\n' "$decision_sections"
  printf '| Canonical PPS decision records | %s |\n' "$canonical_record_count"
  printf '| Implementation/prototype code files | %s |\n\n' "$implementation_code_count"

  printf '## Existing declarations\n\n'
  printf -- '- Protocol: `%s`\n' "${protocol:-not declared}"
  printf -- '- Profile: `%s`\n' "${profile:-not declared}"
  printf -- '- Mode: `%s`\n' "${declared_mode:-not declared}"
  printf -- '- Main artifact: `%s`\n\n' "${main_artifact:-not declared}"

  printf '## Migration review signals\n\n'
  printf '| Signal | Result |\n'
  printf '|---|---|\n'
  printf '| Authority canonicalization risk | %s |\n' "$authority_review_risk"
  printf '| Tooling/environment term hits in control files | %s |\n' "$tooling_term_hits"
  printf '| Machine-specific path/proxy hits in control files | %s |\n' "$machine_specific_hits"
  printf '| CONTEXT workset | %s |\n' "$(file_status CONTEXT.md)"
  printf '| PROJECT_MAP navigation | %s |\n' "$(file_status PROJECT_MAP.md)"
  printf '| ENVIRONMENT contract | %s |\n' "$(file_status ENVIRONMENT.md)"
  printf '| Dependency manifests detected | %s |\n' "$dependency_manifest_count"
  printf '| Binary asset candidates | %s |\n' "$binary_candidate_count"
  printf '| External asset registry | %s |\n\n' "$(file_status ASSETS.md)"
  printf 'These signals are migration triage only. Tooling terms, paths, and free-form sections require human classification before any M/F/D authority is activated.\n\n'

  printf '## Proposed migration\n\n'
  case "$detected" in
    pps)
      printf 'This repository already declares a supported PPS protocol and has the core control files.\n\n'
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

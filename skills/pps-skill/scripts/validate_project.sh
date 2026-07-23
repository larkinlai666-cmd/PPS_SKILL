#!/usr/bin/env bash
set -u

root="${1:-$(pwd)}"
quiet="${2:-}"
errors=()
warnings=()

add_error() {
  errors+=("$1")
}

add_warning() {
  warnings+=("$1")
}

field_value() {
  local file="$1"
  local name="$2"
  sed -n "s/^-[[:space:]]*${name}:[[:space:]]*//p" "$file"
}

require_single_field() {
  local file="$1"
  local name="$2"
  local values
  local count
  values="$(field_value "$file" "$name")"
  count="$(printf '%s\n' "$values" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [[ "$count" != "1" ]]; then
    add_error "Expected exactly one '$name' field, found $count."
    printf ''
    return
  fi
  printf '%s' "$values"
}

safe_project_path() {
  local rel="$1"
  local label="$2"
  if [[ -z "$rel" || "$rel" == /* || "$rel" =~ ^[A-Za-z]:[\\/]|(^|[\\/])\.\.([\\/]|$) ]]; then
    add_error "$label must be a safe project-relative path: $rel"
    printf ''
    return
  fi
  printf '%s/%s' "${root%/}" "$rel"
}

extract_ids() {
  local value="$1"
  local prefix="$2"
  printf '%s\n' "$value" |
    grep -Eo "${prefix}-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?" |
    awk '!seen[$0]++' || true
}

manifest_ids() {
  local value="$1"
  local prefix="$2"
  local label="$3"
  local lowered
  local ids
  lowered="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  case "$lowered" in
    none|n/a|na|empty|'')
      printf ''
      return
      ;;
  esac
  ids="$(extract_ids "$value" "$prefix")"
  if [[ -z "$ids" ]]; then
    add_error "$label is non-empty but contains no parseable $prefix IDs: $value"
  fi
  printf '%s' "$ids"
}

required=(
  README.md
  AGENTS.md
  PROJECT_STATE.md
  DECISIONS.md
  CONTEXT.md
  scripts/status_check.ps1
  scripts/status_check.sh
  scripts/validate_project.ps1
  scripts/validate_project.sh
)
for rel in "${required[@]}"; do
  [[ -f "$root/$rel" ]] || add_error "Missing required file: $rel"
done

state="$root/PROJECT_STATE.md"
decisions="$root/DECISIONS.md"
context="$root/CONTEXT.md"
if [[ ! -f "$state" || ! -f "$decisions" || ! -f "$context" ]]; then
  echo "PPS validation: FAILED"
  for message in "${errors[@]}"; do echo "ERROR: $message"; done
  exit 1
fi

protocol="$(require_single_field "$state" Protocol)"
profile="$(require_single_field "$state" Profile)"
stage="$(require_single_field "$state" Stage)"
main_rel="$(require_single_field "$state" Main)"
package="$(require_single_field "$state" Package)"
status="$(require_single_field "$state" Status)"
capsule_rel="$(require_single_field "$state" Capsule)"
coverage_rel="$(require_single_field "$state" Coverage)"
blockers="$(require_single_field "$state" Blockers)"
next="$(require_single_field "$state" Next)"
updated="$(require_single_field "$state" Updated)"

[[ "$protocol" == "PPS/1.0" ]] || add_error "Protocol must be PPS/1.0, found '$protocol'."
[[ "$profile" == "standard" || "$profile" == "evidence" ]] ||
  add_error "Profile must be standard or evidence, found '$profile'."
case "$status" in
  active|review_pending|blocked|complete) ;;
  *) add_error "Unsupported Status '$status'." ;;
esac
[[ -n "$stage" ]] || add_error "Stage cannot be empty."
[[ -n "$package" ]] || add_error "Package cannot be empty."
[[ -n "$blockers" ]] || add_error "Blockers cannot be empty."
[[ -n "$next" ]] || add_error "Next cannot be empty."
[[ -n "$updated" ]] || add_error "Updated cannot be empty."

main_path="$(safe_project_path "$main_rel" Main)"
capsule_path="$(safe_project_path "$capsule_rel" Capsule)"
coverage_path="$(safe_project_path "$coverage_rel" Coverage)"
[[ -n "$main_path" && -f "$main_path" ]] || add_error "Main file does not exist: $main_rel"
[[ -n "$capsule_path" && -f "$capsule_path" ]] || add_error "Capsule file does not exist: $capsule_rel"
[[ -n "$coverage_path" && -f "$coverage_path" ]] || add_error "Coverage file does not exist: $coverage_rel"

[[ "$capsule_rel" == "CONTEXT.md" ]] || add_error "PPS/1.0 requires Capsule: CONTEXT.md."
if [[ "$profile" == "standard" ]]; then
  [[ "$coverage_rel" == "CONTEXT.md" ]] ||
    add_error "The standard profile requires Coverage: CONTEXT.md."
fi
if [[ "$profile" == "evidence" ]]; then
  [[ "$coverage_rel" == "docs/CURRENT_REVIEW_EVIDENCE.md" ]] ||
    add_error "The evidence profile requires Coverage: docs/CURRENT_REVIEW_EVIDENCE.md."
  [[ -f "$root/SOURCE_INDEX.md" ]] || add_error "Evidence profile is missing: SOURCE_INDEX.md"
  [[ -f "$root/docs/CURRENT_REVIEW_EVIDENCE.md" ]] ||
    add_error "Evidence profile is missing: docs/CURRENT_REVIEW_EVIDENCE.md"
fi

state_lines="$(wc -l < "$state" | tr -d ' ')"
context_lines="$(wc -l < "$context" | tr -d ' ')"
if (( state_lines > 120 )); then
  add_error "PROJECT_STATE.md has $state_lines lines; hard limit is 120."
elif (( state_lines > 80 )); then
  add_warning "PROJECT_STATE.md has $state_lines lines; compact target is 80."
fi
if (( context_lines > 80 )); then
  add_error "CONTEXT.md has $context_lines lines; hard limit is 80."
elif (( context_lines > 60 )); then
  add_warning "CONTEXT.md has $context_lines lines; compact target is 60."
fi

methods_value="$(require_single_field "$context" Methods)"
facts_value="$(require_single_field "$context" Facts)"
decisions_value="$(require_single_field "$context" Decisions)"
sources_value="$(require_single_field "$context" Sources)"
manifest_coverage="$(require_single_field "$context" Coverage)"

methods="$(manifest_ids "$methods_value" M Methods)"
facts="$(manifest_ids "$facts_value" F Facts)"
decision_ids="$(manifest_ids "$decisions_value" D Decisions)"
source_ids="$(manifest_ids "$sources_value" SRC Sources)"
required_ids="$(printf '%s\n%s\n%s\n' "$methods" "$facts" "$decision_ids" | sed '/^$/d' | awk '!seen[$0]++')"

[[ "$manifest_coverage" == "$coverage_rel" ]] ||
  add_error "CONTEXT Coverage '$manifest_coverage' does not match PROJECT_STATE Coverage '$coverage_rel'."

active_block="$(awk '
  /<!-- PPS:ACTIVE:BEGIN -->/ {inside=1; next}
  /<!-- PPS:ACTIVE:END -->/ {inside=0; found_end=1; next}
  inside {print}
  END {if (!found_end) exit 2}
' "$decisions" 2>/dev/null)"
active_status=$?
if [[ $active_status -ne 0 ]] || ! grep -q '<!-- PPS:ACTIVE:BEGIN -->' "$decisions"; then
  add_error "DECISIONS.md is missing the marked active authority block."
fi

active_ids=""
while IFS= read -r line; do
  [[ -z "${line//[[:space:]]/}" ]] && continue
  if ! printf '%s\n' "$line" |
      grep -Eq '^[[:space:]]*-[[:space:]]+`[MFD]-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?`[[:space:]]*$'; then
    add_error "Malformed active-block line: $line"
    continue
  fi
  parsed="$(printf '%s\n' "$line" |
    grep -Eo '[MFD]-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?')"
  active_ids="${active_ids}${parsed}"$'\n'
done <<< "$active_block"
active_ids="$(printf '%s' "$active_ids" | sed '/^$/d')"

duplicates="$(printf '%s\n' "$active_ids" | sed '/^$/d' | sort | uniq -d)"
while IFS= read -r id; do
  [[ -z "$id" ]] || add_error "Active ID appears more than once: $id"
done <<< "$duplicates"

while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  count="$(grep -Ec "^###[[:space:]]+${id}[[:space:]]+\\[active\\][[:space:]]*$" "$decisions" || true)"
  [[ "$count" == "1" ]] ||
    add_error "Active ID $id must have exactly one [active] record, found $count."
done <<< "$(printf '%s\n' "$active_ids" | awk '!seen[$0]++')"

while IFS= read -r heading; do
  [[ -z "$heading" ]] && continue
  if ! printf '%s\n' "$heading" |
      grep -Eq '^###[[:space:]]+[MFD]-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?[[:space:]]+\[(active|superseded|rejected|frozen)\][[:space:]]*$'; then
    add_error "Malformed authority record heading: $heading"
  fi
done <<< "$(grep -E '^###[[:space:]]+[MFD]-' "$decisions" || true)"

while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  active_count="$(printf '%s\n' "$active_ids" | grep -Fxc "$id" || true)"
  [[ "$active_count" == "1" ]] ||
    add_error "Manifest ID $id must appear exactly once in the active block, found $active_count."
  coverage_count=0
  if [[ -n "$coverage_path" && -f "$coverage_path" ]]; then
    coverage_count="$(grep -Ec "^\\|[[:space:]]*${id}[[:space:]]*\\|" "$coverage_path" || true)"
  fi
  (( coverage_count >= 1 )) || add_error "Manifest ID $id has no row in $coverage_rel."
done <<< "$required_ids"

if [[ -n "$source_ids" ]]; then
  source_index="$root/SOURCE_INDEX.md"
  if [[ ! -f "$source_index" ]]; then
    add_error "Source IDs are listed but SOURCE_INDEX.md is missing."
  else
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      source_count="$(grep -Ec "^\\|[[:space:]]*${id}[[:space:]]*\\|" "$source_index" || true)"
      (( source_count >= 1 )) || add_error "Source ID $id has no row in SOURCE_INDEX.md."
    done <<< "$source_ids"
  fi
fi

if [[ ${#warnings[@]} -gt 0 && "$quiet" != "--quiet" ]]; then
  for message in "${warnings[@]}"; do echo "WARNING: $message"; done
fi

if [[ ${#errors[@]} -gt 0 ]]; then
  echo "PPS validation: FAILED (${#errors[@]} error(s))"
  for message in "${errors[@]}"; do echo "ERROR: $message"; done
  exit 1
fi

if [[ "$quiet" != "--quiet" ]]; then
  required_count="$(printf '%s\n' "$required_ids" | sed '/^$/d' | wc -l | tr -d ' ')"
  source_count="$(printf '%s\n' "$source_ids" | sed '/^$/d' | wc -l | tr -d ' ')"
  echo "PPS validation: OK"
  echo "Profile: $profile"
  echo "Package: $package"
  echo "Required authority IDs: $required_count"
  echo "Required source IDs: $source_count"
fi

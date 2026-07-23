#!/usr/bin/env bash
set -uo pipefail

root="$(pwd)"
quiet=""
root_seen=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet)
      quiet="--quiet"
      shift
      ;;
    -*)
      echo "Usage: validate_project.sh [ROOT] [--quiet]" >&2
      exit 2
      ;;
    *)
      if (( root_seen == 1 )); then
        echo "Usage: validate_project.sh [ROOT] [--quiet]" >&2
        exit 2
      fi
      root="$1"
      root_seen=1
      shift
      ;;
  esac
done
errors=()
warnings=()
result=""

if [[ ! -d "$root" ]]; then
  echo "PPS validation: FAILED"
  echo "ERROR: Project root is not a directory: $root"
  exit 1
fi
root="$(cd "$root" && pwd -P)"

add_error() {
  errors+=("$1")
}

add_warning() {
  warnings+=("$1")
}

matching_lines() {
  local file="$1"
  local pattern="$2"
  if [[ ! -f "$file" ]]; then
    result=""
    return
  fi
  result="$(grep -En "$pattern" "$file" 2>/dev/null |
    cut -d: -f1 | paste -sd, - || true)"
}

safe_project_path() {
  local rel="$1"
  local label="$2"
  local current
  local segment
  local parts=()
  if [[ -z "$rel" || "$rel" == /* || "$rel" == *\\* || "$rel" =~ ^[A-Za-z]:[\\/]|(^|/)\.\.(/|$) ]]; then
    add_error "$label must be a safe project-relative path: $rel"
    result=""
    return
  fi
  current="$root"
  IFS='/' read -r -a parts <<< "$rel"
  for segment in "${parts[@]}"; do
    [[ -n "$segment" && "$segment" != "." ]] || continue
    current="$current/$segment"
    if [[ -L "$current" ]]; then
      add_error "$label must not traverse a symbolic link: $rel"
      result=""
      return
    fi
  done
  result="$current"
}

section_text() {
  local file="$1"
  local title="$2"
  awk -v title="$title" '
    $0 ~ "^##[[:space:]]+" title "[[:space:]]*$" {inside=1; next}
    inside && /^##[[:space:]]/ {exit}
    inside {print}
  ' "$file"
}

require_single_section() {
  local file="$1"
  local title="$2"
  local section_count
  local section_locations
  section_count="$(grep -Ec "^##[[:space:]]+${title}[[:space:]]*$" "$file" || true)"
  if [[ "$section_count" != "1" ]]; then
    matching_lines "$file" "^##[[:space:]]+${title}[[:space:]]*$"
    section_locations="$result"
    if [[ -n "$section_locations" ]]; then
      add_error "Expected exactly one '$title' section, found $section_count (lines $section_locations in ${file#$root/})."
    else
      add_error "Expected exactly one '$title' section, found $section_count (${file#$root/})."
    fi
    result=""
    return
  fi
  result="$(section_text "$file" "$title")"
}

require_section_field() {
  local section="$1"
  local file="$2"
  local title="$3"
  local name="$4"
  local values
  local count
  local field_locations
  values="$(printf '%s\n' "$section" |
    sed -n "s/^-[[:space:]]*${name}:[[:space:]]*//p")"
  count="$(printf '%s\n' "$values" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [[ "$count" != "1" ]]; then
    matching_lines "$file" "^-[[:space:]]*${name}:[[:space:]]*"
    field_locations="$result"
    if [[ -n "$field_locations" ]]; then
      add_error "Expected exactly one '$name' field in '$title', found $count (candidate lines $field_locations in ${file#$root/})."
    else
      add_error "Expected exactly one '$name' field in '$title', found $count (${file#$root/})."
    fi
    result=""
    return
  fi
  result="$values"
}

valid_utc_timestamp() {
  local value="$1"
  local year month day hour minute second max_day
  [[ "$value" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z$ ]] ||
    return 1
  year=$((10#${BASH_REMATCH[1]}))
  month=$((10#${BASH_REMATCH[2]}))
  day=$((10#${BASH_REMATCH[3]}))
  hour=$((10#${BASH_REMATCH[4]}))
  minute=$((10#${BASH_REMATCH[5]}))
  second=$((10#${BASH_REMATCH[6]}))
  (( year >= 1 && month >= 1 && month <= 12 && hour <= 23 && minute <= 59 && second <= 59 )) ||
    return 1
  case "$month" in
    1|3|5|7|8|10|12) max_day=31 ;;
    4|6|9|11) max_day=30 ;;
    2)
      max_day=28
      if (( year % 400 == 0 || (year % 4 == 0 && year % 100 != 0) )); then
        max_day=29
      fi
      ;;
  esac
  (( day >= 1 && day <= max_day ))
}

manifest_ids() {
  local value="$1"
  local prefix="$2"
  local label="$3"
  local compact
  local duplicate
  local id_pattern
  local lowered
  local ids
  local trimmed
  trimmed="$(printf '%s' "$value" |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  lowered="$(printf '%s' "$trimmed" | tr '[:upper:]' '[:lower:]')"
  case "$lowered" in
    none|n/a|na|empty|'')
      result=""
      return
      ;;
  esac
  id_pattern="${prefix}-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?"
  if ! printf '%s\n' "$trimmed" |
      grep -Eq "^${id_pattern}[[:space:]]*(,[[:space:]]*${id_pattern}[[:space:]]*)*$"; then
    add_error "$label must be 'none' or a comma-separated list of only $prefix IDs: $value"
    result=""
    return
  fi
  compact="$(printf '%s' "$trimmed" | tr -d '[:space:]')"
  ids="$(printf '%s\n' "$compact" | tr ',' '\n')"
  duplicate="$(printf '%s\n' "$ids" | sort | uniq -d)"
  if [[ -n "$duplicate" ]]; then
    add_error "$label contains duplicate IDs: $(printf '%s' "$duplicate" | tr '\n' ' ')"
  fi
  result="$ids"
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

require_single_section "$state" "Hot State"; hot_state="$result"
require_section_field "$hot_state" "$state" "Hot State" Protocol; protocol="$result"
require_section_field "$hot_state" "$state" "Hot State" Profile; profile="$result"
require_section_field "$hot_state" "$state" "Hot State" Stage; stage="$result"
require_section_field "$hot_state" "$state" "Hot State" Main; main_rel="$result"
require_section_field "$hot_state" "$state" "Hot State" Package; package="$result"
require_section_field "$hot_state" "$state" "Hot State" Status; status="$result"
require_section_field "$hot_state" "$state" "Hot State" Capsule; capsule_rel="$result"
require_section_field "$hot_state" "$state" "Hot State" Coverage; coverage_rel="$result"
require_section_field "$hot_state" "$state" "Hot State" Blockers; blockers="$result"
require_section_field "$hot_state" "$state" "Hot State" Next; next="$result"
require_section_field "$hot_state" "$state" "Hot State" Updated; updated="$result"
device_value="$(printf '%s\n' "$hot_state" |
  sed -n 's/^-[[:space:]]*Device:[[:space:]]*//p' | head -n 1)"

[[ "$protocol" == "PPS/1.0" ]] || add_error "Protocol must be PPS/1.0, found '$protocol'."
[[ "$profile" == "standard" || "$profile" == "evidence" ]] ||
  add_error "Profile must be standard or evidence, found '$profile'."
case "$status" in
  active|review_pending|blocked|complete) ;;
  *) add_error "Unsupported Status '$status'." ;;
esac
[[ -n "$stage" ]] || add_error "Stage cannot be empty."
[[ -n "$package" ]] || add_error "Package cannot be empty."
[[ "$package" =~ ^PKG-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?$ ]] ||
  add_error "Package must use a PKG-* ID, found '$package'."
[[ -n "$blockers" ]] || add_error "Blockers cannot be empty."
[[ -n "$next" ]] || add_error "Next cannot be empty."
[[ -n "$updated" ]] || add_error "Updated cannot be empty."
valid_utc_timestamp "$updated" ||
  add_error "Updated must be a UTC timestamp like YYYY-MM-DDTHH:MM:SSZ, found '$updated'."
[[ -n "$device_value" ]] || add_warning "Device is missing; add it on the next state update."

safe_project_path "$main_rel" Main; main_path="$result"
safe_project_path "$capsule_rel" Capsule; capsule_path="$result"
safe_project_path "$coverage_rel" Coverage; coverage_path="$result"
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

require_single_section "$context" "Workset Manifest"; workset="$result"
require_section_field "$workset" "$context" "Workset Manifest" Methods; methods_value="$result"
require_section_field "$workset" "$context" "Workset Manifest" Facts; facts_value="$result"
require_section_field "$workset" "$context" "Workset Manifest" Decisions; decisions_value="$result"
require_section_field "$workset" "$context" "Workset Manifest" Sources; sources_value="$result"
require_section_field "$workset" "$context" "Workset Manifest" Excluded; excluded_value="$result"
require_section_field "$workset" "$context" "Workset Manifest" Coverage; manifest_coverage="$result"
require_single_section "$context" "Current Package"; current_package="$result"
require_section_field "$current_package" "$context" "Current Package" ID; context_package="$result"

manifest_ids "$methods_value" M Methods; methods="$result"
manifest_ids "$facts_value" F Facts; facts="$result"
manifest_ids "$decisions_value" D Decisions; decision_ids="$result"
manifest_ids "$sources_value" SRC Sources; source_ids="$result"
required_ids="$(printf '%s\n%s\n%s\n' "$methods" "$facts" "$decision_ids" | sed '/^$/d' | awk '!seen[$0]++')"

[[ "$manifest_coverage" == "$coverage_rel" ]] ||
  add_error "CONTEXT Coverage '$manifest_coverage' does not match PROJECT_STATE Coverage '$coverage_rel'."
[[ "$context_package" == "$package" ]] ||
  add_error "CONTEXT package '$context_package' does not match PROJECT_STATE Package '$package'."
[[ -n "$excluded_value" ]] || add_error "Excluded cannot be empty; use 'none' when nothing is excluded."

if [[ "$profile" == "evidence" && -f "$root/docs/CURRENT_REVIEW_EVIDENCE.md" ]]; then
  evidence_file="$root/docs/CURRENT_REVIEW_EVIDENCE.md"
  require_single_section "$evidence_file" Package; evidence_section="$result"
  require_section_field "$evidence_section" "$evidence_file" Package ID; evidence_package="$result"
  [[ "$evidence_package" == "$package" ]] ||
    add_error "Evidence package '$evidence_package' does not match PROJECT_STATE Package '$package'."
fi

active_begin_count="$(grep -Fxc '<!-- PPS:ACTIVE:BEGIN -->' "$decisions" || true)"
active_end_count="$(grep -Fxc '<!-- PPS:ACTIVE:END -->' "$decisions" || true)"
active_block=""
if [[ "$active_begin_count" != "1" || "$active_end_count" != "1" ]]; then
  add_error "DECISIONS.md must contain exactly one active authority block; found $active_begin_count begin marker(s) and $active_end_count end marker(s)."
else
  active_begin_line="$(grep -Fn '<!-- PPS:ACTIVE:BEGIN -->' "$decisions" | cut -d: -f1)"
  active_end_line="$(grep -Fn '<!-- PPS:ACTIVE:END -->' "$decisions" | cut -d: -f1)"
  if (( active_begin_line >= active_end_line )); then
    add_error "DECISIONS.md active authority markers are out of order."
  fi
  active_block="$(awk '
    /<!-- PPS:ACTIVE:BEGIN -->/ {inside=1; next}
    /<!-- PPS:ACTIVE:END -->/ {inside=0; next}
    inside {print}
  ' "$decisions")"
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

record_ids=""
active_record_ids=""
while IFS= read -r heading; do
  [[ -z "$heading" ]] && continue
  if printf '%s\n' "$heading" |
      grep -Eq '^###[[:space:]]+[MFD]-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?[[:space:]]+\[(active|superseded|rejected|frozen)\][[:space:]]*$'; then
    record_id="$(printf '%s\n' "$heading" |
      grep -Eo '[MFD]-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?')"
    record_ids="${record_ids}${record_id}"$'\n'
    if printf '%s\n' "$heading" | grep -Eq '\[active\][[:space:]]*$'; then
      active_record_ids="${active_record_ids}${record_id}"$'\n'
    fi
  fi
done <<< "$(grep -E '^###[[:space:]]+[MFD]-' "$decisions" || true)"
record_ids="$(printf '%s' "$record_ids" | sed '/^$/d')"
active_record_ids="$(printf '%s' "$active_record_ids" | sed '/^$/d')"

duplicate_record_ids="$(printf '%s\n' "$record_ids" | sed '/^$/d' | sort | uniq -d)"
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  matching_lines "$decisions" "^###[[:space:]]+${id}[[:space:]]+"
  add_error "Authority ID has more than one canonical record: $id (DECISIONS.md lines $result)."
done <<< "$duplicate_record_ids"

while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  block_count="$(printf '%s\n' "$active_ids" | grep -Fxc "$id" || true)"
  [[ "$block_count" == "1" ]] ||
    add_error "Active record $id must appear exactly once in the active block, found $block_count."
done <<< "$(printf '%s\n' "$active_record_ids" | awk '!seen[$0]++')"

while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  required_count="$(printf '%s\n' "$required_ids" | grep -Fxc "$id" || true)"
  [[ "$required_count" == "1" ]] ||
    add_warning "Active authority $id is not in the current workset."
done <<< "$(printf '%s\n' "$active_ids" | awk '!seen[$0]++')"

while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  active_count="$(printf '%s\n' "$active_ids" | grep -Fxc "$id" || true)"
  [[ "$active_count" == "1" ]] ||
    add_error "Manifest ID $id must appear exactly once in the active block, found $active_count."
  coverage_count=0
  if [[ -n "$coverage_path" && -f "$coverage_path" ]]; then
    coverage_count="$(grep -Ec "^\\|[[:space:]]*${id}[[:space:]]*\\|" "$coverage_path" || true)"
  fi
  [[ "$coverage_count" == "1" ]] ||
    {
      matching_lines "$coverage_path" "^\\|[[:space:]]*${id}[[:space:]]*\\|"
      coverage_locations="${result:-none}"
      add_error "Manifest ID $id must have exactly one row in $coverage_rel, found $coverage_count (lines $coverage_locations)."
    }
done <<< "$required_ids"

if [[ -n "$source_ids" ]]; then
  source_index="$root/SOURCE_INDEX.md"
  if [[ ! -f "$source_index" ]]; then
    add_error "Source IDs are listed but SOURCE_INDEX.md is missing."
  else
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      source_count="$(grep -Ec "^\\|[[:space:]]*${id}[[:space:]]*\\|" "$source_index" || true)"
      [[ "$source_count" == "1" ]] ||
        {
          matching_lines "$source_index" "^\\|[[:space:]]*${id}[[:space:]]*\\|"
          source_locations="${result:-none}"
          add_error "Source ID $id must have exactly one row in SOURCE_INDEX.md, found $source_count (lines $source_locations)."
        }
    done <<< "$source_ids"
  fi
fi

if [[ -f "$root/SOURCE_INDEX.md" ]]; then
  all_source_ids="$(grep -E '^\|[[:space:]]*SRC-[A-Za-z0-9]' "$root/SOURCE_INDEX.md" |
    grep -Eo 'SRC-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?' || true)"
  duplicate_source_ids="$(printf '%s\n' "$all_source_ids" | sed '/^$/d' | sort | uniq -d)"
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    matching_lines "$root/SOURCE_INDEX.md" "^\\|[[:space:]]*${id}[[:space:]]*\\|"
    add_error "SOURCE_INDEX.md contains duplicate source rows for $id (lines $result)."
  done <<< "$duplicate_source_ids"
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

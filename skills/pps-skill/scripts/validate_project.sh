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

path_manifest() {
  local value="$1"
  local label="$2"
  local must_exist="$3"
  local trimmed
  local lowered
  local duplicate
  local resolved_paths=""
  local resolved_path
  trimmed="$(printf '%s' "$value" |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  lowered="$(printf '%s' "$trimmed" | tr '[:upper:]' '[:lower:]')"
  case "$lowered" in
    none|'')
      result=""
      return
      ;;
  esac
  if [[ "$trimmed" == *",,"* || "$trimmed" == ,* || "$trimmed" == *, ]]; then
    add_error "$label must be 'none' or a comma-separated list of project-relative paths: $value"
    result=""
    return
  fi
  while IFS= read -r rel; do
    rel="$(printf '%s' "$rel" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ -z "$rel" ]]; then
      add_error "$label contains an empty path entry."
      continue
    fi
    if [[ "$rel" == "." || "$rel" == *[\*\?\[\]\{\}]* ]]; then
      add_error "$label path must name an exact file or bounded subdirectory, not '.' or a glob: $rel"
      continue
    fi
    if (( ${#rel} > 240 )); then
      add_error "$label path exceeds the 240-character limit: $rel"
      continue
    fi
    safe_project_path "$rel" "$label path"
    resolved_path="$result"
    if [[ -n "$resolved_path" ]]; then
      if [[ "$must_exist" == "yes" && ! -e "$resolved_path" ]]; then
        add_error "$label path does not exist: $rel"
      fi
      resolved_paths="${resolved_paths}${rel}"$'\n'
    fi
  done < <(printf '%s\n' "$trimmed" | tr ',' '\n')
  duplicate="$(printf '%s' "$resolved_paths" | sed '/^$/d' | sort | uniq -d)"
  if [[ -n "$duplicate" ]]; then
    add_error "$label contains duplicate paths: $(printf '%s' "$duplicate" | tr '\n' ' ')"
  fi
  result="$(printf '%s' "$resolved_paths" | sed '/^$/d')"
}

tool_manifest() {
  local value="$1"
  local label="$2"
  local trimmed
  local lowered
  local tools=""
  local duplicate
  trimmed="$(printf '%s' "$value" |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  lowered="$(printf '%s' "$trimmed" | tr '[:upper:]' '[:lower:]')"
  case "$lowered" in
    none|'')
      result=""
      return
      ;;
  esac
  if [[ "$trimmed" == ,* || "$trimmed" == *, ||
      "$trimmed" =~ ,[[:space:]]*, ]]; then
    add_error "$label contains an empty tool entry."
    result=""
    return
  fi
  while IFS= read -r tool; do
    tool="$(printf '%s' "$tool" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    case "$tool" in
      git|gh|rg|node|python|powershell|imagemagick|ffmpeg|pandoc|libreoffice|poppler|rclone)
        tools="${tools}${tool}"$'\n'
        ;;
      *)
        add_error "$label contains unsupported tool '$tool'."
        ;;
    esac
  done < <(printf '%s\n' "$trimmed" | tr ',' '\n')
  duplicate="$(printf '%s' "$tools" | sed '/^$/d' | sort | uniq -d)"
  if [[ -n "$duplicate" ]]; then
    add_error "$label contains duplicate tools: $(printf '%s' "$duplicate" | tr '\n' ' ')"
  fi
  result="$(printf '%s' "$tools" | sed '/^$/d')"
}

validate_task_capsule() {
  local capsule_file="$1"
  local capsule_task_id="$2"
  local capsule_task_role="$3"
  local capsule_rel="${capsule_file#$root/}"
  local capsule_section
  local capsule_field_value
  local capsule_bytes
  local capsule_lines
  task_capsule_write_paths=""
  task_capsule_read_paths=""
  task_capsule_authority_ids=""
  task_capsule_source_ids=""
  task_capsule_asset_ids=""
  task_capsule_component_ids=""

  capsule_bytes="$(wc -c < "$capsule_file" | tr -d ' ')"
  (( capsule_bytes <= 32768 )) ||
    add_error "Task $capsule_task_id capsule $capsule_rel has $capsule_bytes bytes; hard limit is 32768."
  capsule_lines="$(wc -l < "$capsule_file" | tr -d ' ')"
  if (( capsule_lines > 80 )); then
    add_error "Task $capsule_task_id capsule $capsule_rel has $capsule_lines lines; hard limit is 80."
  elif (( capsule_lines > 60 )); then
    add_warning "Task $capsule_task_id capsule $capsule_rel has $capsule_lines lines; compact target is 60."
  fi

  capsule_section_count="$(grep -Ec '^##[[:space:]]+Workset Manifest[[:space:]]*$' "$capsule_file" || true)"
  if [[ "$capsule_section_count" != "1" ]]; then
    add_error "Task $capsule_task_id capsule $capsule_rel must contain exactly one 'Workset Manifest' section, found $capsule_section_count."
    return
  fi
  capsule_section="$(section_text "$capsule_file" "Workset Manifest")"

  local field_name
  for field_name in Methods Facts Decisions Sources Assets Components Read Write Verify Excluded Coverage; do
    capsule_field_count="$(printf '%s\n' "$capsule_section" |
      grep -Ec "^-[[:space:]]*${field_name}:[[:space:]]*" || true)"
    if [[ "$capsule_field_count" != "1" ]]; then
      add_error "Task $capsule_task_id capsule $capsule_rel must declare exactly one '$field_name' field (use 'none' when empty), found $capsule_field_count."
      continue
    fi
    capsule_field_value="$(printf '%s\n' "$capsule_section" |
      sed -n "s/^-[[:space:]]*${field_name}:[[:space:]]*//p" | head -n 1)"
    case "$field_name" in
      Methods)
        manifest_ids "$capsule_field_value" M "Task $capsule_task_id Methods"
        task_capsule_authority_ids="${task_capsule_authority_ids}${result}"$'\n'
        ;;
      Facts)
        manifest_ids "$capsule_field_value" F "Task $capsule_task_id Facts"
        task_capsule_authority_ids="${task_capsule_authority_ids}${result}"$'\n'
        ;;
      Decisions)
        manifest_ids "$capsule_field_value" D "Task $capsule_task_id Decisions"
        task_capsule_authority_ids="${task_capsule_authority_ids}${result}"$'\n'
        ;;
      Sources)
        manifest_ids "$capsule_field_value" SRC "Task $capsule_task_id Sources"
        task_capsule_source_ids="${task_capsule_source_ids}${result}"$'\n'
        ;;
      Assets)
        manifest_ids "$capsule_field_value" A "Task $capsule_task_id Assets"
        task_capsule_asset_ids="${task_capsule_asset_ids}${result}"$'\n'
        ;;
      Components)
        manifest_ids "$capsule_field_value" C "Task $capsule_task_id Components"
        task_capsule_component_ids="${task_capsule_component_ids}${result}"$'\n'
        ;;
      Read)
        path_manifest "$capsule_field_value" "Task $capsule_task_id Read" yes
        task_capsule_read_paths="$result"
        ;;
      Write)
        path_manifest "$capsule_field_value" "Task $capsule_task_id Write" no
        task_capsule_write_paths="$result"
        [[ -n "$task_capsule_write_paths" ]] ||
          add_error "Task $capsule_task_id capsule Write cannot be empty or 'none'; declare the bounded output paths."
        ;;
      Verify)
        [[ -n "$capsule_field_value" && "$capsule_field_value" != "none" ]] ||
          add_error "Task $capsule_task_id capsule Verify cannot be empty or 'none'."
        ;;
      Excluded)
        [[ -n "$capsule_field_value" ]] ||
          add_error "Task $capsule_task_id capsule Excluded cannot be empty; use 'none'."
        ;;
      Coverage)
        [[ -n "$capsule_field_value" ]] ||
          add_error "Task $capsule_task_id capsule Coverage cannot be empty."
        ;;
    esac
  done

  local capsule_path_count
  capsule_path_count="$(printf '%s\n%s\n' "$task_capsule_read_paths" "$task_capsule_write_paths" |
    sed '/^$/d' | wc -l | tr -d ' ')"
  (( capsule_path_count <= 30 )) ||
    add_error "Task $capsule_task_id Read and Write contain $capsule_path_count paths; hard limit is 30."
  local capsule_authority_count
  capsule_authority_count="$(printf '%s' "$task_capsule_authority_ids" | sed '/^$/d' | wc -l | tr -d ' ')"
  (( capsule_authority_count <= 60 )) ||
    add_error "Task $capsule_task_id Methods, Facts, and Decisions contain $capsule_authority_count IDs; hard limit is 60."
}

checkpoint_ok() {
  local checkpoint_value="$1"
  [[ -n "$checkpoint_value" && "$checkpoint_value" != "none" ]] || return 1
  if [[ "$checkpoint_value" == "lineage_incomplete" ]]; then
    return 0
  fi
  if command -v git >/dev/null 2>&1 &&
    git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$root" cat-file -e "${checkpoint_value}^{commit}" 2>/dev/null
    return $?
  fi
  # Without Git only the explicit migration marker is acceptable.
  return 1
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
state_bytes="$(wc -c < "$state" | tr -d ' ')"
context_bytes="$(wc -c < "$context" | tr -d ' ')"
(( state_bytes <= 32768 )) ||
  add_error "PROJECT_STATE.md has $state_bytes bytes; hard limit is 32768."
(( context_bytes <= 32768 )) ||
  add_error "CONTEXT.md has $context_bytes bytes; hard limit is 32768."

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

[[ "$protocol" == "PPS/1.0" || "$protocol" == "PPS/1.1" || "$protocol" == "PPS/1.2" ]] ||
  add_error "Protocol must be PPS/1.0, PPS/1.1, or PPS/1.2, found '$protocol'."
[[ "$profile" == "standard" || "$profile" == "evidence" ]] ||
  add_error "Profile must be standard or evidence, found '$profile'."
is_pps11_plus=0
if [[ "$protocol" == "PPS/1.1" || "$protocol" == "PPS/1.2" ]]; then
  is_pps11_plus=1
fi
is_pps12=0
if [[ "$protocol" == "PPS/1.2" ]]; then
  is_pps12=1
fi

mode=""
map_rel=""
environment_rel=""
if (( is_pps11_plus == 1 )); then
  require_section_field "$hot_state" "$state" "Hot State" Mode; mode="$result"
  require_section_field "$hot_state" "$state" "Hot State" Map; map_rel="$result"
  require_section_field "$hot_state" "$state" "Hot State" Environment; environment_rel="$result"
  [[ "$mode" == "document" || "$mode" == "software" || "$mode" == "hybrid" ]] ||
    add_error "Mode must be document, software, or hybrid, found '$mode'."
  for rel in \
    scripts/environment_doctor.ps1 scripts/environment_doctor.sh \
    scripts/resume_packet.ps1 scripts/resume_packet.sh; do
    [[ -f "$root/$rel" ]] || add_error "$protocol is missing required file: $rel"
  done
fi
if (( is_pps12 == 1 )); then
  for rel in \
    EVENTS.md \
    scripts/verify_gate.ps1 scripts/verify_gate.sh \
    scripts/project_verify.ps1 scripts/project_verify.sh \
    scripts/append_event.ps1 scripts/append_event.sh; do
    [[ -f "$root/$rel" ]] || add_error "PPS/1.2 is missing required file: $rel"
  done
fi
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
if (( is_pps11_plus == 1 )) && [[ "$mode" != "document" ]]; then
  [[ -n "$main_path" && -e "$main_path" ]] || add_error "Main path does not exist: $main_rel"
else
  [[ -n "$main_path" && -f "$main_path" ]] || add_error "Main file does not exist: $main_rel"
fi
[[ -n "$capsule_path" && -f "$capsule_path" ]] || add_error "Capsule file does not exist: $capsule_rel"
[[ -n "$coverage_path" && -f "$coverage_path" ]] || add_error "Coverage file does not exist: $coverage_rel"

[[ "$capsule_rel" == "CONTEXT.md" ]] || add_error "$protocol requires Capsule: CONTEXT.md."
if [[ "$profile" == "standard" ]]; then
  if (( is_pps12 == 1 )); then
    [[ "$coverage_rel" == "CONTEXT.md" || "$coverage_rel" == "docs/coverage.md" ]] ||
      add_error "The PPS/1.2 standard profile requires Coverage: CONTEXT.md or docs/coverage.md."
  else
    [[ "$coverage_rel" == "CONTEXT.md" ]] ||
      add_error "The standard profile requires Coverage: CONTEXT.md."
  fi
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
assets_field_count="$(printf '%s\n' "$workset" | grep -Ec '^-[[:space:]]*Assets:[[:space:]]*' || true)"
if [[ "$assets_field_count" == "0" ]]; then
  assets_value="none"
  if (( is_pps12 == 1 )); then
    add_error "PPS/1.2 requires an explicit Assets field in the Workset Manifest; use 'none' when empty."
  elif [[ "$protocol" == "PPS/1.1" ]]; then
    add_warning "Workset Manifest has no Assets field; treating it as 'none' for PPS/1.1 compatibility."
  fi
elif [[ "$assets_field_count" == "1" ]]; then
  require_section_field "$workset" "$context" "Workset Manifest" Assets; assets_value="$result"
else
  add_error "Expected at most one 'Assets' field in 'Workset Manifest', found $assets_field_count."
  assets_value="none"
fi
require_section_field "$workset" "$context" "Workset Manifest" Excluded; excluded_value="$result"
require_section_field "$workset" "$context" "Workset Manifest" Coverage; manifest_coverage="$result"
require_single_section "$context" "Current Package"; current_package="$result"
require_section_field "$current_package" "$context" "Current Package" ID; context_package="$result"

manifest_ids "$methods_value" M Methods; methods="$result"
manifest_ids "$facts_value" F Facts; facts="$result"
manifest_ids "$decisions_value" D Decisions; decision_ids="$result"
manifest_ids "$sources_value" SRC Sources; source_ids="$result"
manifest_ids "$assets_value" A Assets; asset_ids="$result"
required_ids="$(printf '%s\n%s\n%s\n' "$methods" "$facts" "$decision_ids" | sed '/^$/d' | awk '!seen[$0]++')"

components=""
read_paths=""
write_paths=""
if (( is_pps11_plus == 1 )); then
  require_section_field "$workset" "$context" "Workset Manifest" Components; components_value="$result"
  require_section_field "$workset" "$context" "Workset Manifest" Read; read_value="$result"
  require_section_field "$workset" "$context" "Workset Manifest" Write; write_value="$result"
  require_section_field "$workset" "$context" "Workset Manifest" Verify; verify_value="$result"
  manifest_ids "$components_value" C Components; components="$result"
  path_manifest "$read_value" Read yes; read_paths="$result"
  path_manifest "$write_value" Write no; write_paths="$result"
  [[ -n "$components" ]] || add_error "Components cannot be empty; name at least one C-* boundary."
  [[ -n "$read_paths" ]] || add_error "Read cannot be empty; declare the bounded input paths."
  [[ -n "$write_paths" ]] || add_error "Write cannot be empty; declare the bounded output paths."
  [[ -n "$verify_value" && "$verify_value" != "none" ]] ||
    add_error "Verify cannot be empty or 'none'."
  component_count="$(printf '%s\n' "$components" | sed '/^$/d' | wc -l | tr -d ' ')"
  authority_count="$(printf '%s\n%s\n%s\n' "$methods" "$facts" "$decision_ids" |
    sed '/^$/d' | wc -l | tr -d ' ')"
  source_id_count="$(printf '%s\n' "$source_ids" | sed '/^$/d' | wc -l | tr -d ' ')"
  asset_id_count="$(printf '%s\n' "$asset_ids" | sed '/^$/d' | wc -l | tr -d ' ')"
  path_count="$(printf '%s\n%s\n' "$read_paths" "$write_paths" | sed '/^$/d' | wc -l | tr -d ' ')"
  (( component_count <= 30 )) ||
    add_error "Components contains $component_count IDs; hard limit is 30."
  (( authority_count <= 60 )) ||
    add_error "Methods, Facts, and Decisions contain $authority_count IDs; hard limit is 60."
  (( source_id_count <= 30 )) ||
    add_error "Sources contains $source_id_count IDs; hard limit is 30."
  (( asset_id_count <= 30 )) ||
    add_error "Assets contains $asset_id_count IDs; hard limit is 30."
  if (( path_count > 30 )); then
    add_error "Read and Write contain $path_count paths; hard limit is 30."
  elif (( path_count > 12 )); then
    add_warning "Read and Write contain $path_count paths; compact target is 12."
  fi
fi

if [[ -n "$asset_ids" || -f "$root/ASSETS.md" ]]; then
  [[ -f "$root/ASSETS.md" ]] || add_error "Workset lists assets but ASSETS.md is missing."
  [[ -f "$root/scripts/asset_check.sh" ]] ||
    add_error "Asset registry requires scripts/asset_check.sh."
  [[ -f "$root/scripts/asset_check.ps1" ]] ||
    add_error "Asset registry requires scripts/asset_check.ps1."
  if [[ -f "$root/ASSETS.md" && -f "$root/scripts/asset_check.sh" ]]; then
    asset_structure_output=""
    if ! asset_structure_output="$(bash "$root/scripts/asset_check.sh" "$root" --structure 2>&1)"; then
      while IFS= read -r message; do
        [[ "$message" == ERROR:* ]] &&
          add_error "Asset registry: ${message#ERROR: }"
      done <<< "$asset_structure_output"
      [[ "$asset_structure_output" == *"ERROR:"* ]] ||
        add_error "Asset registry structural validation failed."
    fi
  fi
fi

[[ "$manifest_coverage" == "$coverage_rel" ]] ||
  add_error "CONTEXT Coverage '$manifest_coverage' does not match PROJECT_STATE Coverage '$coverage_rel'."
[[ "$context_package" == "$package" ]] ||
  add_error "CONTEXT package '$context_package' does not match PROJECT_STATE Package '$package'."
[[ -n "$excluded_value" ]] || add_error "Excluded cannot be empty; use 'none' when nothing is excluded."

if (( is_pps11_plus == 1 )); then
  safe_project_path "$map_rel" Map; map_path="$result"
  safe_project_path "$environment_rel" Environment; environment_path="$result"
  [[ -n "$map_path" && -f "$map_path" ]] || add_error "Project map file does not exist: $map_rel"
  [[ -n "$environment_path" && -f "$environment_path" ]] ||
    add_error "Environment manifest does not exist: $environment_rel"

  if [[ -n "$map_path" && -f "$map_path" ]]; then
    map_bytes="$(wc -c < "$map_path" | tr -d ' ')"
    (( map_bytes <= 65536 )) ||
      add_error "$map_rel has $map_bytes bytes; hard limit is 65536."
    map_lines="$(wc -l < "$map_path" | tr -d ' ')"
    if (( map_lines > 240 )); then
      add_error "$map_rel has $map_lines lines; hard limit is 240."
    elif (( map_lines > 160 )); then
      add_warning "$map_rel has $map_lines lines; compact target is 160."
    fi
    while IFS=: read -r line_number component_line; do
      [[ -n "$line_number" ]] || continue
      if ! printf '%s\n' "$component_line" |
          grep -Eq '^\|[[:space:]]*C-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?[[:space:]]*\|[^|]+\|[^|]+\|[^|]+\|[^|]+\|[[:space:]]*$' ||
          ! printf '%s\n' "$component_line" | awk -F'|' '
            function trim(value) {
              gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
              return value
            }
            { exit !(NF == 7 && trim($3) != "" && trim($4) != "" && trim($5) != "" && trim($6) != "") }
          '; then
        add_error "Malformed component row in $map_rel at line $line_number: $component_line"
      fi
    done < <(grep -En '^\|[[:space:]]*C-' "$map_path" || true)
    all_component_ids="$(grep -E '^\|[[:space:]]*C-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?[[:space:]]*\|' "$map_path" |
      sed -E 's/^\|[[:space:]]*(C-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?)[[:space:]]*\|.*/\1/' || true)"
    duplicate_component_ids="$(printf '%s\n' "$all_component_ids" | sed '/^$/d' | sort | uniq -d)"
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      matching_lines "$map_path" "^\\|[[:space:]]*${id}[[:space:]]*\\|"
      add_error "$map_rel contains duplicate component rows for $id (lines $result)."
    done <<< "$duplicate_component_ids"
    while IFS=$'\t' read -r component_id component_root; do
      [[ -n "$component_id" ]] || continue
      safe_project_path "$component_root" "Component $component_id Root"; component_root_path="$result"
      [[ -n "$component_root_path" && -e "$component_root_path" ]] ||
        add_error "Component $component_id Root does not exist: $component_root"
    done < <(awk -F'|' '
      function trim(value) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        return value
      }
      /^\|[[:space:]]*C-/ && trim($2) ~ /^C-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?$/ {
        print trim($2) "\t" trim($3)
      }
    ' "$map_path")
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      component_row_count="$(grep -Ec "^\\|[[:space:]]*${id}[[:space:]]*\\|" "$map_path" || true)"
      [[ "$component_row_count" == "1" ]] ||
        add_error "Component ID $id must have exactly one row in $map_rel, found $component_row_count."
    done <<< "$components"
  fi

  if [[ -n "$environment_path" && -f "$environment_path" ]]; then
    environment_bytes="$(wc -c < "$environment_path" | tr -d ' ')"
    (( environment_bytes <= 16384 )) ||
      add_error "$environment_rel has $environment_bytes bytes; hard limit is 16384."
    require_single_section "$environment_path" "Toolchain Manifest"; toolchain="$result"
    require_section_field "$toolchain" "$environment_path" "Toolchain Manifest" Required; required_tools_value="$result"
    require_section_field "$toolchain" "$environment_path" "Toolchain Manifest" Optional; optional_tools_value="$result"
    dependency_field_count="$(printf '%s\n' "$toolchain" | grep -Ec '^-[[:space:]]*Dependency manifests:[[:space:]]*' || true)"
    if [[ "$dependency_field_count" == "0" ]]; then
      dependency_manifests_value="none"
    elif [[ "$dependency_field_count" == "1" ]]; then
      require_section_field "$toolchain" "$environment_path" "Toolchain Manifest" "Dependency manifests"; dependency_manifests_value="$result"
    else
      add_error "Expected at most one 'Dependency manifests' field in 'Toolchain Manifest', found $dependency_field_count."
      dependency_manifests_value="none"
    fi
    require_section_field "$toolchain" "$environment_path" "Toolchain Manifest" "Package manager"; manager_value="$result"
    require_section_field "$toolchain" "$environment_path" "Toolchain Manifest" "Install policy"; install_policy="$result"
    tool_manifest "$required_tools_value" "Required tools"; required_tools="$result"
    tool_manifest "$optional_tools_value" "Optional tools"; optional_tools="$result"
    path_manifest "$dependency_manifests_value" "Dependency manifest" yes; dependency_manifests="$result"
    [[ -n "$required_tools" ]] || add_error "Required tools cannot be empty; include at least git."
    printf '%s\n' "$required_tools" | grep -Fxq git ||
      add_error "Required tools must include git."
    case "$manager_value" in
      auto|brew|winget|apt|dnf|pacman|manual) ;;
      *) add_error "Unsupported package manager policy '$manager_value'." ;;
    esac
    [[ "$install_policy" == "project-local-first" ]] ||
      add_error "Install policy must be project-local-first."
  fi
fi

if (( is_pps12 == 1 )); then
  agents_file="$root/AGENTS.md"
  if [[ -f "$agents_file" ]]; then
    red_lines_count="$(grep -Ec '^##[[:space:]]+Red Lines[[:space:]]*$' "$agents_file" || true)"
    first_h2="$(grep -E '^##[[:space:]]' "$agents_file" | head -n 1 |
      sed 's/^##[[:space:]]*//; s/[[:space:]]*$//')"
    if [[ "$red_lines_count" == "0" ]]; then
      add_error "PPS/1.2 requires a '## Red Lines' section in AGENTS.md."
    elif [[ "$red_lines_count" != "1" ]]; then
      add_error "AGENTS.md must contain exactly one '## Red Lines' section, found $red_lines_count."
    elif [[ "$first_h2" != "Red Lines" ]]; then
      add_error "The '## Red Lines' section exists but is not the first H2 section of AGENTS.md (found '## $first_h2' first); L0 must meet red lines before any other rule."
    fi
  fi

  events_file="$root/EVENTS.md"
  if [[ -f "$events_file" ]]; then
    grep -Eq '^##[[:space:]]+Events[[:space:]]*$' "$events_file" ||
      add_error "EVENTS.md must contain a '## Events' section."
    while IFS=: read -r line_number event_line; do
      [[ -n "$line_number" ]] || continue
      printf '%s\n' "$event_line" |
        grep -Eq '^- [0-9]{4}-[0-9]{2}-[0-9]{2}: \[PKG-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?\] [^|]+\| files: [^|]+\| verify: [^|]+\| pending: [^|]+$' ||
        add_error "Malformed event line in EVENTS.md at line $line_number: $event_line"
    done < <(awk '
      $0 ~ "^##[[:space:]]+Events[[:space:]]*$" { inside=1; next }
      inside && /^##[[:space:]]/ { inside=0 }
      inside && /^- / { printf "%d:%s\n", NR, $0 }
    ' "$events_file")
    events_lines="$(wc -l < "$events_file" | tr -d ' ')"
    (( events_lines <= 200 )) ||
      add_warning "EVENTS.md has $events_lines lines; archive older months to docs/events-archive/."
  fi

  today_jdn="$(date -u '+%Y %m %d' | awk '{
    a = int((14 - $2) / 12); y = $1 + 4800 - a; m = $2 + 12 * a - 3
    print $3 + int((153 * m + 2) / 5) + 365 * y + int(y / 4) - int(y / 100) + int(y / 400) - 32045
  }')"
  while IFS= read -r proposal_line; do
    [[ -n "$proposal_line" ]] || continue
    proposal_id="$(printf '%s\n' "$proposal_line" |
      grep -Eo 'P-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?' | head -n 1)"
    opened_date="$(printf '%s\n' "$proposal_line" |
      sed -n 's/.*(opened \([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)).*/\1/p')"
    if [[ -z "$opened_date" ]]; then
      add_warning "Proposal $proposal_id has no '(opened YYYY-MM-DD)' date; aging cannot be tracked."
      continue
    fi
    opened_jdn="$(printf '%s\n' "$opened_date" | awk -F- '{
      a = int((14 - $2) / 12); y = $1 + 4800 - a; m = $2 + 12 * a - 3
      print $3 + int((153 * m + 2) / 5) + 365 * y + int(y / 4) - int(y / 100) + int(y / 400) - 32045
    }')"
    if (( today_jdn - opened_jdn > 7 )); then
      if printf '%s' "$next" | grep -Fq "$proposal_id"; then
        : # restated in Next; aging discipline satisfied
      else
        add_warning "Proposal $proposal_id has been pending for more than 7 days and is not restated in Next; state kept, closed, or split."
      fi
    fi
  done < <(awk '
    $0 ~ "^##[[:space:]]+Proposals[[:space:]]*$" { inside=1; next }
    inside && /^##[[:space:]]/ { inside=0 }
    inside && /^- P-/ { print }
  ' "$context")

  writer_value="$(printf '%s\n' "$hot_state" |
    sed -n 's/^-[[:space:]]*Writer:[[:space:]]*//p' | head -n 1)"
  task_index="$root/TASK_INDEX.md"
  canonical_files="PROJECT_STATE.md DECISIONS.md CONTEXT.md EVENTS.md TASK_INDEX.md MERGES.md PROJECT_MAP.md ENVIRONMENT.md docs/coverage.md docs/CURRENT_REVIEW_EVIDENCE.md"
  # Canonical is a semantic role, not a fixed filename list: the Hot State
  # declarations decide where content truth actually lives.
  for hot_canonical in "$main_rel" "$coverage_rel" "$map_rel" "$environment_rel"; do
    [[ -n "$hot_canonical" && "$hot_canonical" != "none" ]] || continue
    case " $canonical_files " in
      *" $hot_canonical "*) ;;
      *) canonical_files="$canonical_files $hot_canonical" ;;
    esac
  done
  all_task_authority_refs=""
  all_task_component_refs=""
  all_task_source_refs=""
  all_task_asset_refs=""
  task_ids=""
  terminal_tasks=""
  output_roots=""
  if [[ -f "$task_index" ]]; then
    task_ids="$(grep -E '^###[[:space:]]+T-' "$task_index" |
      grep -Eo 'T-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?' || true)"
    duplicate_tasks="$(printf '%s\n' "$task_ids" | sed '/^$/d' | sort | uniq -d)"
    while IFS= read -r id; do
      [[ -z "$id" ]] || add_error "TASK_INDEX.md contains duplicate task blocks for $id."
    done <<< "$duplicate_tasks"
    active_integrators=""
    while IFS= read -r task_id; do
      [[ -n "$task_id" ]] || continue
      task_block="$(awk -v wanted="### $task_id" '
        index($0, wanted) == 1 { inside=1; next }
        inside && /^###[[:space:]]/ { exit }
        inside { print }
      ' "$task_index")"
      task_role="$(printf '%s\n' "$task_block" |
        sed -n 's/^-[[:space:]]*Role:[[:space:]]*//p' | head -n 1)"
      task_status="$(printf '%s\n' "$task_block" |
        sed -n 's/^-[[:space:]]*Status:[[:space:]]*//p' | head -n 1)"
      task_capsule="$(printf '%s\n' "$task_block" |
        sed -n 's/^-[[:space:]]*Capsule:[[:space:]]*//p' | head -n 1)"
      task_output_root="$(printf '%s\n' "$task_block" |
        sed -n 's/^-[[:space:]]*Output Root:[[:space:]]*//p' | head -n 1)"
      case "$task_role" in
        integrator|worker|consumer) ;;
        *) add_error "Task $task_id has invalid Role '$task_role'." ;;
      esac
      case "$task_status" in
        active|handoff_ready|integrated|rejected|deferred|archived) ;;
        *) add_error "Task $task_id has invalid Status '$task_status'." ;;
      esac
      case "$task_status" in
        integrated|deferred|rejected)
          terminal_tasks="${terminal_tasks}${task_id}:${task_status}"$'\n'
          ;;
      esac
      if [[ "$task_role" == "integrator" && "$task_status" == "active" ]]; then
        active_integrators="${active_integrators}${task_id}"$'\n'
      fi
      if [[ "$task_status" != "archived" ]]; then
        if [[ -z "$task_capsule" ]]; then
          add_error "Task $task_id has no Capsule field."
        else
          safe_project_path "$task_capsule" "Task $task_id Capsule"; task_capsule_path="$result"
          if [[ -z "$task_capsule_path" || ! -f "$task_capsule_path" ]]; then
            add_error "Task $task_id capsule does not exist: $task_capsule"
          elif [[ "$task_role" == "integrator" ]]; then
            # The integrator writes canonical truth, so its capsule IS the
            # canonical capsule. A separate integrator capsule would be a
            # second, unvalidated grant channel for Main and state files.
            [[ "$task_capsule" == "CONTEXT.md" ]] ||
              add_error "Task $task_id (integrator) capsule must be CONTEXT.md itself, found '$task_capsule'; a separate integrator capsule would bypass Workset validation."
          else
            validate_task_capsule "$task_capsule_path" "$task_id" "$task_role"
            all_task_authority_refs="${all_task_authority_refs}$(
              printf '%s' "$task_capsule_authority_ids" | sed '/^$/d' |
                awk -v task="$task_id" '{ print task ":" $0 }'
            )"$'\n'
            all_task_component_refs="${all_task_component_refs}$(
              printf '%s' "$task_capsule_component_ids" | sed '/^$/d' |
                awk -v task="$task_id" '{ print task ":" $0 }'
            )"$'\n'
            all_task_source_refs="${all_task_source_refs}$(
              printf '%s' "$task_capsule_source_ids" | sed '/^$/d' |
                awk -v task="$task_id" '{ print task ":" $0 }'
            )"$'\n'
            all_task_asset_refs="${all_task_asset_refs}$(
              printf '%s' "$task_capsule_asset_ids" | sed '/^$/d' |
                awk -v task="$task_id" '{ print task ":" $0 }'
            )"$'\n'
            while IFS= read -r write_rel; do
              [[ -n "$write_rel" ]] || continue
              for canonical in $canonical_files; do
                if [[ "$write_rel" == "$canonical" ]]; then
                  add_error "Task $task_id ($task_role) declares canonical file '$canonical' in its Write set."
                fi
              done
              # worker/consumer writes land only inside the task's own Output
              # Root; a Write declaration is not a second grant channel.
              if [[ -n "$task_output_root" && "$task_output_root" != "none" ]]; then
                case "$write_rel" in
                  "$task_output_root" | "$task_output_root"/*) ;;
                  *)
                    add_error "Task $task_id ($task_role) Write path '$write_rel' is outside its Output Root '$task_output_root'; worker and consumer tasks write only inside their own Output Root."
                    ;;
                esac
              fi
            done <<< "$task_capsule_write_paths"
          fi
        fi
        if [[ "$task_role" != "integrator" ]]; then
          if [[ -z "$task_output_root" || "$task_output_root" == "none" ]]; then
            add_error "Task $task_id ($task_role) requires a bounded Output Root."
          else
            safe_project_path "$task_output_root" "Task $task_id Output Root"
            if [[ -n "$result" ]]; then
              case "$task_output_root" in
                local-task-output/*) ;;
                *)
                  add_error "Task $task_id Output Root must live under local-task-output/, found '$task_output_root'."
                  ;;
              esac
              while IFS= read -r existing_root_entry; do
                [[ -n "$existing_root_entry" ]] || continue
                existing_task="${existing_root_entry%%:*}"
                existing_root="${existing_root_entry#*:}"
                if [[ "$task_output_root" == "$existing_root" ||
                  "$task_output_root" == "$existing_root"/* ||
                  "$existing_root" == "$task_output_root"/* ]]; then
                  add_error "Task $task_id Output Root '$task_output_root' overlaps Task $existing_task Output Root '$existing_root'."
                fi
              done <<< "$output_roots"
              output_roots="${output_roots}${task_id}:${task_output_root}"$'\n'
            fi
          fi
        fi
      fi
    done <<< "$(printf '%s\n' "$task_ids" | awk '!seen[$0]++')"
    active_integrators="$(printf '%s' "$active_integrators" | sed '/^$/d')"
    integrator_count="$(printf '%s\n' "$active_integrators" | sed '/^$/d' | wc -l | tr -d ' ')"
    [[ "$integrator_count" == "1" ]] ||
      add_error "TASK_INDEX.md must have exactly one active integrator, found $integrator_count."
    if [[ -z "$writer_value" ]]; then
      add_error "Multitask projects require a 'Writer:' field in Hot State."
    elif [[ "$integrator_count" == "1" && "$writer_value" != "$active_integrators" ]]; then
      add_error "Hot State Writer '$writer_value' does not match the active integrator '$active_integrators'."
    fi
  elif [[ -n "$writer_value" ]]; then
    add_error "Hot State declares Writer '$writer_value' but TASK_INDEX.md does not exist."
  fi

  merges_file="$root/MERGES.md"
  merge_ids=""
  if [[ -f "$merges_file" ]]; then
    [[ -f "$task_index" ]] ||
      add_error "MERGES.md exists but TASK_INDEX.md does not; merge receipts require the task registry."
    merge_ids="$(grep -E '^###[[:space:]]+MERGE-' "$merges_file" |
      grep -Eo 'MERGE-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?' || true)"
    duplicate_merges="$(printf '%s\n' "$merge_ids" | sed '/^$/d' | sort | uniq -d)"
    while IFS= read -r id; do
      [[ -z "$id" ]] || add_error "MERGES.md contains duplicate receipt blocks for $id."
    done <<< "$duplicate_merges"
    while IFS= read -r merge_id; do
      [[ -n "$merge_id" ]] || continue
      merge_block="$(awk -v wanted="### $merge_id" '
        index($0, wanted) == 1 { inside=1; next }
        inside && /^###[[:space:]]/ { exit }
        inside { print }
      ' "$merges_file")"
      merge_field() {
        printf '%s\n' "$merge_block" |
          sed -n "s/^-[[:space:]]*$1:[[:space:]]*//p" | head -n 1
      }
      merge_target="$(merge_field 'Target Package')"
      merge_sources="$(merge_field 'Source Tasks')"
      merge_relation="$(merge_field 'Relation')"
      merge_accepted="$(merge_field 'Accepted')"
      merge_rejected="$(merge_field 'Rejected')"
      merge_deferred="$(merge_field 'Deferred')"
      merge_base="$(merge_field 'Base Checkpoint')"
      merge_result="$(merge_field 'Result Checkpoint')"
      merge_approval="$(merge_field 'Approval')"
      merge_verification="$(merge_field 'Verification')"
      merge_status="$(merge_field 'Status')"
      for required_pair in \
        "Target Package:$merge_target" "Source Tasks:$merge_sources" \
        "Relation:$merge_relation" "Accepted:$merge_accepted" \
        "Rejected:$merge_rejected" "Deferred:$merge_deferred" \
        "Base Checkpoint:$merge_base" "Result Checkpoint:$merge_result" \
        "Approval:$merge_approval" "Verification:$merge_verification" \
        "Status:$merge_status"; do
        [[ -n "${required_pair#*:}" ]] ||
          add_error "Merge receipt $merge_id is missing the '${required_pair%%:*}' field."
      done
      case "$merge_relation" in
        absorbs|layers_on|consumes_only|deferred|supersedes|rejected|rollback_to) ;;
        *) add_error "Merge receipt $merge_id has invalid Relation '$merge_relation'." ;;
      esac
      case "$merge_status" in
        pending|integrated|deferred|rejected) ;;
        *) add_error "Merge receipt $merge_id has invalid Status '$merge_status'." ;;
      esac
      # Status and Relation must tell the same story.
      case "$merge_status" in
        integrated)
          case "$merge_relation" in
            absorbs|layers_on|consumes_only|supersedes|rollback_to) ;;
            *) add_error "Merge receipt $merge_id Status 'integrated' is incompatible with Relation '$merge_relation'." ;;
          esac
          ;;
        deferred)
          [[ "$merge_relation" == "deferred" ]] ||
            add_error "Merge receipt $merge_id Status 'deferred' requires Relation 'deferred', found '$merge_relation'."
          ;;
        rejected)
          [[ "$merge_relation" == "rejected" ]] ||
            add_error "Merge receipt $merge_id Status 'rejected' requires Relation 'rejected', found '$merge_relation'."
          ;;
      esac
      [[ "$merge_target" =~ ^PKG-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?$ ]] ||
        add_error "Merge receipt $merge_id Target Package must be a PKG-* ID, found '$merge_target'."
      # The Target Package must be a real package: the current one or one
      # recorded in the chronicle. A receipt into a phantom package is not
      # evidence of integration.
      if [[ "$merge_target" =~ ^PKG- && "$merge_target" != "$package" ]]; then
        if [[ ! -f "$root/EVENTS.md" ]] ||
          ! grep -Eq "\\[${merge_target}\\]" "$root/EVENTS.md"; then
          add_error "Merge receipt $merge_id Target Package '$merge_target' is neither the current package '$package' nor recorded in EVENTS.md."
        fi
      fi
      if [[ "$merge_status" == "integrated" ]]; then
        # An integration without accepted content, approval, or verification
        # is a claim, not a receipt.
        if [[ -z "$merge_accepted" || "$merge_accepted" == "none" ]]; then
          add_error "Merge receipt $merge_id is 'integrated' with an empty Accepted set; an integration that accepted nothing is not an integration."
        fi
        if [[ -z "$merge_approval" || "$merge_approval" == "none" ]]; then
          add_error "Merge receipt $merge_id is 'integrated' without an Approval decision; name the D-* record that authorized this merge."
        fi
        if [[ -z "$merge_verification" || "$merge_verification" == "none" ]]; then
          add_error "Merge receipt $merge_id is 'integrated' without Verification evidence; name the command, test, or inspection that checked the merged result."
        fi
      fi
      if [[ -n "$merge_sources" && "$merge_sources" != "none" ]]; then
        while IFS= read -r src_task; do
          src_task="$(printf '%s' "$src_task" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
          [[ -n "$src_task" ]] || continue
          if ! printf '%s\n' "$src_task" |
            grep -Eq '^T-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?$'; then
            add_error "Merge receipt $merge_id Source Tasks contains a non-T-* entry: '$src_task'."
          elif ! printf '%s\n' "$task_ids" | grep -Fxq "$src_task"; then
            add_error "Merge receipt $merge_id references unknown Source Task '$src_task'."
          else
            # Consistency must hold in both directions: a terminal receipt
            # about a task that the registry still lists as active means the
            # two truth sources disagree.
            case "$merge_status" in
              integrated|deferred|rejected)
                src_status="$(awk -v wanted="### $src_task" '
                  index($0, wanted) == 1 { inside=1; next }
                  inside && /^###[[:space:]]/ { exit }
                  inside && index($0, "- Status:") == 1 {
                    sub("^- Status:[[:space:]]*", "")
                    print
                    exit
                  }
                ' "$task_index")"
                [[ "$src_status" == "$merge_status" || "$src_status" == "archived" ]] ||
                  add_error "Merge receipt $merge_id says Task $src_task is '$merge_status' but TASK_INDEX.md records status '$src_status'; the registry and the receipt must agree."
                ;;
            esac
          fi
        done < <(printf '%s\n' "$merge_sources" | tr ',' '\n')
      else
        add_error "Merge receipt $merge_id must name at least one Source Task."
      fi
      if [[ -n "$merge_approval" && "$merge_approval" != "none" ]]; then
        while IFS= read -r approval_id; do
          approval_id="$(printf '%s' "$approval_id" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
          [[ -n "$approval_id" ]] || continue
          if ! printf '%s\n' "$approval_id" |
            grep -Eq '^D-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?$'; then
            add_error "Merge receipt $merge_id Approval contains a non-D-* entry: '$approval_id'."
          elif ! grep -Eq "^###[[:space:]]+${approval_id}[[:space:]]+\[" "$decisions"; then
            add_error "Merge receipt $merge_id Approval references unknown decision '$approval_id'."
          fi
        done < <(printf '%s\n' "$merge_approval" | tr ',' '\n')
      fi
      overlap_sets="$(
        for set_value in "$merge_accepted" "$merge_rejected" "$merge_deferred"; do
          [[ -n "$set_value" && "$set_value" != "none" ]] || continue
          printf '%s\n' "$set_value" | tr ',' '\n' |
            sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d'
        done | sort | uniq -d
      )"
      while IFS= read -r overlap_path; do
        [[ -z "$overlap_path" ]] ||
          add_error "Merge receipt $merge_id lists '$overlap_path' in more than one of Accepted/Rejected/Deferred."
      done <<< "$overlap_sets"
      for set_pair in "Accepted:$merge_accepted" "Rejected:$merge_rejected" "Deferred:$merge_deferred"; do
        set_name="${set_pair%%:*}"
        set_value="${set_pair#*:}"
        [[ -n "$set_value" && "$set_value" != "none" ]] || continue
        while IFS= read -r disposition_path; do
          disposition_path="$(printf '%s' "$disposition_path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
          [[ -n "$disposition_path" ]] || continue
          safe_project_path "$disposition_path" "Merge receipt $merge_id $set_name path" >/dev/null
        done < <(printf '%s\n' "$set_value" | tr ',' '\n')
      done
      if [[ "$merge_status" == "integrated" ]]; then
        checkpoint_ok "$merge_base" ||
          add_error "Merge receipt $merge_id Base Checkpoint '$merge_base' is not a resolvable Git object or the explicit lineage_incomplete marker."
        checkpoint_ok "$merge_result" ||
          add_error "Merge receipt $merge_id Result Checkpoint '$merge_result' is not a resolvable Git object or the explicit lineage_incomplete marker."
        if [[ "$merge_base" == "lineage_incomplete" || "$merge_result" == "lineage_incomplete" ]]; then
          # The migration escape hatch needs a reason on record; silent use
          # on a project with normal Git history is forbidden.
          merge_lineage_note="$(merge_field 'Lineage Note')"
          if [[ -z "$merge_lineage_note" || "$merge_lineage_note" == "none" ]]; then
            add_error "Merge receipt $merge_id uses lineage_incomplete without a 'Lineage Note' field explaining why pre-layer history is unavailable; new projects must use real checkpoints."
          fi
        fi
      fi
    done <<< "$(printf '%s\n' "$merge_ids" | awk '!seen[$0]++')"
  fi

  while IFS= read -r terminal_entry; do
    [[ -n "$terminal_entry" ]] || continue
    terminal_id="${terminal_entry%%:*}"
    terminal_status="${terminal_entry#*:}"
    matching_receipts=0
    if [[ -f "$merges_file" ]]; then
      while IFS= read -r merge_id; do
        [[ -n "$merge_id" ]] || continue
        merge_block="$(awk -v wanted="### $merge_id" '
          index($0, wanted) == 1 { inside=1; next }
          inside && /^###[[:space:]]/ { exit }
          inside { print }
        ' "$merges_file")"
        block_status="$(printf '%s\n' "$merge_block" |
          sed -n 's/^-[[:space:]]*Status:[[:space:]]*//p' | head -n 1)"
        block_sources="$(printf '%s\n' "$merge_block" |
          sed -n 's/^-[[:space:]]*Source Tasks:[[:space:]]*//p' | head -n 1)"
        if [[ "$block_status" == "$terminal_status" ]] &&
          printf '%s\n' "$block_sources" | tr ',' '\n' |
            sed 's/^[[:space:]]*//;s/[[:space:]]*$//' |
            grep -Fxq "$terminal_id"; then
          matching_receipts=$((matching_receipts + 1))
        fi
      done <<< "$(printf '%s\n' "$merge_ids" | awk '!seen[$0]++')"
    fi
    if [[ "$matching_receipts" == "0" ]]; then
      add_error "Task $terminal_id is '$terminal_status' but no merge receipt with matching status names it; only a receipt proves disposition."
    elif [[ "$matching_receipts" != "1" ]]; then
      add_error "Task $terminal_id has $matching_receipts '$terminal_status' receipts; exactly one final disposition receipt is required."
    fi
  done <<< "$(printf '%s' "$terminal_tasks" | sed '/^$/d')"
fi
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
  if (( is_pps12 == 1 )) && [[ "$coverage_count" == "1" ]]; then
    coverage_evidence="$(grep -E "^\\|[[:space:]]*${id}[[:space:]]*\\|" "$coverage_path" |
      head -n 1 | awk -F'|' '{
        value = $5
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        print value
      }')"
    if [[ -z "$coverage_evidence" || "$coverage_evidence" == "Present" || "$coverage_evidence" == "present" ]]; then
      add_error "Coverage row for $id needs an evidence cell naming the command, test, or inspection; bare 'Present' cannot distinguish checked from unchecked."
    fi
  fi
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

# Task capsule IDs must resolve against the same authorities as the main
# Workset: a structurally valid task that references phantom records would
# still drift at resume time.
if (( is_pps12 == 1 )); then
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    ref_task="${ref%%:*}"
    ref_id="${ref#*:}"
    active_count="$(printf '%s\n' "$active_ids" | grep -Fxc "$ref_id" || true)"
    [[ "$active_count" == "1" ]] ||
      add_error "Task $ref_task references authority $ref_id which is not in the DECISIONS.md active block."
  done <<< "$(printf '%s' "$all_task_authority_refs" | sed '/^$/d' | awk '!seen[$0]++')"
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    ref_task="${ref%%:*}"
    ref_id="${ref#*:}"
    if [[ -n "$map_path" && -f "$map_path" ]]; then
      component_count="$(grep -Ec "^\\|[[:space:]]*${ref_id}[[:space:]]*\\|" "$map_path" || true)"
      [[ "$component_count" == "1" ]] ||
        add_error "Task $ref_task references component $ref_id which does not exist in $map_rel."
    fi
  done <<< "$(printf '%s' "$all_task_component_refs" | sed '/^$/d' | awk '!seen[$0]++')"
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    ref_task="${ref%%:*}"
    ref_id="${ref#*:}"
    if [[ ! -f "$root/SOURCE_INDEX.md" ]] ||
      ! grep -Eq "^\\|[[:space:]]*${ref_id}[[:space:]]*\\|" "$root/SOURCE_INDEX.md"; then
      add_error "Task $ref_task references source $ref_id which does not exist in SOURCE_INDEX.md."
    fi
  done <<< "$(printf '%s' "$all_task_source_refs" | sed '/^$/d' | awk '!seen[$0]++')"
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    ref_task="${ref%%:*}"
    ref_id="${ref#*:}"
    if [[ ! -f "$root/ASSETS.md" ]] ||
      ! grep -Eq "^\\|[[:space:]]*${ref_id}[[:space:]]*\\|" "$root/ASSETS.md"; then
      add_error "Task $ref_task references asset $ref_id which does not exist in ASSETS.md."
    fi
  done <<< "$(printf '%s' "$all_task_asset_refs" | sed '/^$/d' | awk '!seen[$0]++')"
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
  asset_count="$(printf '%s\n' "$asset_ids" | sed '/^$/d' | wc -l | tr -d ' ')"
  echo "PPS validation: OK"
  echo "Protocol: $protocol"
  [[ -z "$mode" ]] || echo "Mode: $mode"
  echo "Profile: $profile"
  echo "Package: $package"
  echo "Required authority IDs: $required_count"
  echo "Required source IDs: $source_count"
  echo "Required asset IDs: $asset_count"
fi

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

[[ "$protocol" == "PPS/1.0" || "$protocol" == "PPS/1.1" ]] ||
  add_error "Protocol must be PPS/1.0 or PPS/1.1, found '$protocol'."
[[ "$profile" == "standard" || "$profile" == "evidence" ]] ||
  add_error "Profile must be standard or evidence, found '$profile'."

mode=""
map_rel=""
environment_rel=""
if [[ "$protocol" == "PPS/1.1" ]]; then
  require_section_field "$hot_state" "$state" "Hot State" Mode; mode="$result"
  require_section_field "$hot_state" "$state" "Hot State" Map; map_rel="$result"
  require_section_field "$hot_state" "$state" "Hot State" Environment; environment_rel="$result"
  [[ "$mode" == "document" || "$mode" == "software" || "$mode" == "hybrid" ]] ||
    add_error "Mode must be document, software, or hybrid, found '$mode'."
  for rel in \
    scripts/environment_doctor.ps1 scripts/environment_doctor.sh \
    scripts/resume_packet.ps1 scripts/resume_packet.sh; do
    [[ -f "$root/$rel" ]] || add_error "PPS/1.1 is missing required file: $rel"
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
if [[ "$protocol" == "PPS/1.1" && "$mode" != "document" ]]; then
  [[ -n "$main_path" && -e "$main_path" ]] || add_error "Main path does not exist: $main_rel"
else
  [[ -n "$main_path" && -f "$main_path" ]] || add_error "Main file does not exist: $main_rel"
fi
[[ -n "$capsule_path" && -f "$capsule_path" ]] || add_error "Capsule file does not exist: $capsule_rel"
[[ -n "$coverage_path" && -f "$coverage_path" ]] || add_error "Coverage file does not exist: $coverage_rel"

[[ "$capsule_rel" == "CONTEXT.md" ]] || add_error "$protocol requires Capsule: CONTEXT.md."
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
assets_field_count="$(printf '%s\n' "$workset" | grep -Ec '^-[[:space:]]*Assets:[[:space:]]*' || true)"
if [[ "$assets_field_count" == "0" ]]; then
  assets_value="none"
  if [[ "$protocol" == "PPS/1.1" ]]; then
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
if [[ "$protocol" == "PPS/1.1" ]]; then
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

if [[ "$protocol" == "PPS/1.1" ]]; then
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

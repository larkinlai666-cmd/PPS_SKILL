#!/usr/bin/env bash
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(pwd)"
quiet=""

# F-050-02: Python 3 interpreter discovery, shared shape with verify_gate.
# Order: PPS_PYTHON -> python3 -> python -> py -3. Missing interpreter is a
# hard failure: without the evidence engine, validation proves nothing.
resolve_python3() {
  local cand
  if [[ -n "${PPS_PYTHON:-}" ]] &&
    "$PPS_PYTHON" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
    printf '%s\n' "$PPS_PYTHON"
    return 0
  fi
  for cand in python3 python; do
    if command -v "$cand" >/dev/null 2>&1 &&
      "$cand" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  if command -v py >/dev/null 2>&1 &&
    py -3 -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
    printf '%s\n' "py -3"
    return 0
  fi
  return 1
}
if ! python3_bin="$(resolve_python3)"; then
  echo "ERROR: the PPS evidence engine requires Python 3. Tried: python3, python, py -3. Install Python 3 or set PPS_PYTHON to the interpreter path." >&2
  exit 1
fi
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

# Same rule as the gate's red-line wiring: a mention is not a call.
coverage_tally_manual="$(mktemp "${TMPDIR:-/tmp}/pps-cov-manual.XXXXXX")"
coverage_tally_rows="$(mktemp "${TMPDIR:-/tmp}/pps-cov-rows.XXXXXX")"
trap 'rm -f "$coverage_tally_manual" "$coverage_tally_rows"' EXIT

# Same live-call analysis as verify_gate.sh (identical text on both sides of
# the checks): a mention is not a call, a definition is not a call, an unused
# function proves nothing, and dead branches are dropped.
entry_live_lines() {
  local entry_file="$1"
  awk '
    function strip_comments(line,    hash) {
      if (line ~ /^[[:space:]]*#/) return ""
      hash = index(line, "#")
      if (hash > 0) line = substr(line, 1, hash - 1)
      sub(/[[:space:]]+$/, "", line)
      sub(/^[[:space:]]+/, "", line)
      return line
    }
    { raw[NR] = $0 }
    END {
      n = NR
      in_fn = 0
      for (i = 1; i <= n; i++) {
        line = strip_comments(raw[i])
        cleaned[i] = line
        is_fnline[i] = 0
        fn_name[i] = ""
        if (in_fn) {
          is_fnline[i] = 1
          fn_name[i] = cur_fn
          if (line ~ /^\}[[:space:]]*$/) { in_fn = 0; is_fnline[i] = 0 }
          continue
        }
        if (line ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/) {
          name = line
          sub(/\(\)[[:space:]]*\{.*$/, "", name)
          cur_fn = name
          is_fnline[i] = 1
          fn_name[i] = name
          if (line !~ /\}[[:space:]]*$/) in_fn = 1
          continue
        }
        if (line ~ /^function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\([[:space:]]*\)[[:space:]]*\{/) {
          name = line
          sub(/^function[[:space:]]+/, "", name)
          sub(/[[:space:]]*\(.*$/, "", name)
          cur_fn = name
          is_fnline[i] = 1
          fn_name[i] = name
          if (line !~ /\}[[:space:]]*$/) in_fn = 1
          continue
        }
      }
      in_dead = 0
      for (i = 1; i <= n; i++) {
        line = cleaned[i]
        if (line == "") continue
        if (line ~ /^if[[:space:]]+(false|!)[[:space:]]*([;:]|then|$)/ ||
          line ~ /^while[[:space:]]+false[[:space:]]*(;|do)/) {
          if (line !~ /;[[:space:]]*fi[[:space:]]*$/) in_dead = 1
          continue
        }
        if (in_dead) {
          if (line ~ /^fi[[:space:]]*$/) { in_dead = 0 }
          continue
        }
        if (is_fnline[i]) {
          body[fn_name[i]] = body[fn_name[i]] line "\n"
        } else {
          top_lines[ntop++] = line
        }
      }
      for (i = 0; i < ntop; i++) {
        l = top_lines[i]
        rest = l
        sub(/^.*check[[:space:]]+"[^"]*"/, "", rest)
        if (rest ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/) {
          sub(/^[[:space:]]*/, "", rest)
          sub(/[[:space:]]*$/, "", rest)
          queue[nq++] = rest
        }
        if (l ~ /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/) queue[nq++] = l
      }
      for (qi = 0; qi < nq; qi++) {
        f = queue[qi]
        if (seen[f]) continue
        seen[f] = 1
        if (!(f in body)) continue
        nlines = split(body[f], bl, "\n")
        for (k = 1; k <= nlines; k++) {
          b = bl[k]
          if (b == "") continue
          if (b ~ /^if[[:space:]]+(false|!)[[:space:]]*([;:]|then|$)/ ||
            b ~ /^while[[:space:]]+false[[:space:]]*(;|do)/) continue
          body_out[fno++] = "F " f " " b
          rest = b
          sub(/^.*check[[:space:]]+"[^"]*"/, "", rest)
          if (rest ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/) {
            sub(/^[[:space:]]*/, "", rest); sub(/[[:space:]]*$/, "", rest)
            queue[nq++] = rest
          }
          if (b ~ /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/) queue[nq++] = b
        }
      }
      for (i = 0; i < ntop; i++) print "T " top_lines[i]
      for (i = 0; i < fno; i++) print body_out[i]
    }
  ' "$entry_file"
}

entry_invokes_path() {
  local entry_file="$1"
  local wanted="$2"
  # The live analysis drops dead code; a live line must still look like a
  # CALL, not a mention. A string literal that names the path proves nothing.
  entry_live_lines "$entry_file" | grep -F -- "$wanted" |
    sed -E 's/^T //; s/^F [A-Za-z_][A-Za-z0-9_-]* //' |
    grep -Eq '(^|[^[:alnum:]_])(check|Invoke-Check|bash|sh|pwsh|powershell|python3?|node|npm|npx|source|\.)[[:space:]]|^&[[:space:]]|[|&;][[:space:]]*[^[:space:]]|\$\('
}


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

# Objective acceptance (PPS/1.2 anti goal-drift): the Current Package must
# declare what "done" means in checkable terms. A Goal with no acceptance
# items is drift with extra steps: the agent redefines "done" as it goes.
# Bootstrap packages are exempt because the objective is not confirmed yet;
# the template still ships one A1 item so the field shape is visible.
acceptance_field_count="$(printf '%s\n' "$current_package" | grep -Ec '^-[[:space:]]*Acceptance:[[:space:]]*$' || true)"
if (( is_pps12 == 1 )); then
  if [[ "$acceptance_field_count" == "0" ]]; then
    if [[ "$stage" != *"bootstrap"* ]]; then
      add_error "PPS/1.2 requires an 'Acceptance' field in Current Package; declare A-* acceptance items, each with a machine check '(verify: ...)', or return the package to bootstrap stage."
    fi
  elif [[ "$acceptance_field_count" == "1" ]]; then
    acceptance_items="$(printf '%s\n' "$current_package" |
      sed -n 's/^[[:space:]]*-[[:space:]]*\(A[0-9][0-9]*\):[[:space:]]*\(.*\)$/\1:\2/p')"
    acceptance_count="$(printf '%s\n' "$acceptance_items" | sed '/^$/d' | wc -l | tr -d ' ')"
    if [[ "$stage" != *"bootstrap"* ]]; then
      (( acceptance_count >= 1 )) ||
        add_error "Current Package Acceptance is empty; declare at least one A-* item naming what 'done' means and the check that proves it."
    fi
    expected_acceptance_seq="$(awk -v n="$acceptance_count" 'BEGIN { for (i = 1; i <= n; i++) print "A" i }')"
    actual_acceptance_seq="$(printf '%s\n' "$acceptance_items" | sed '/^$/d' | cut -d: -f1)"
    if [[ -n "$acceptance_items" ]] &&
      [[ "$actual_acceptance_seq" != "$expected_acceptance_seq" ]]; then
      add_error "Acceptance items must be numbered A1, A2, ... without gaps, found $(printf '%s' "$actual_acceptance_seq" | tr '\n' ' ')."
    fi
    while IFS= read -r acceptance_item; do
      [[ -n "$acceptance_item" ]] || continue
      acceptance_item_id="${acceptance_item%%:*}"
      acceptance_item_text="${acceptance_item#*:}"
      if [[ -z "$(printf '%s' "$acceptance_item_text" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" ]]; then
        add_error "Acceptance item $acceptance_item_id has no description; state what 'done' means for this item."
      fi
      if [[ "$stage" != *"bootstrap"* ]]; then
        if ! printf '%s\n' "$acceptance_item_text" | grep -Eq '\(verify:[[:space:]]*[^)]+\)'; then
          add_error "Acceptance item $acceptance_item_id has no '(verify: ...)' reference; an acceptance that names no machine check cannot be proved by the gate."
        fi
      fi
    done <<< "$acceptance_items"
  else
    add_error "Expected at most one 'Acceptance' field in 'Current Package', found $acceptance_field_count."
  fi
fi

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

  # --- Runtime surfaces (DUTY-E: deployment is not loading) ------------------
  # Git synchronization cannot prove a deployed system loaded the new bytes.
  # A project whose product lives partly outside the repository needs a legal
  # place to declare that surface plus the probe that checks it. Repo-relative
  # syntax stays intact: only an environment variable NAME may be recorded.
  if grep -Eq '^##[[:space:]]+Runtime Surfaces[[:space:]]*$' "$context"; then
    # Rows inside an HTML comment are template guidance, not declarations.
    # Scan every Runtime Surfaces section: the template ships one commented
    # example, and a real declaration may be appended in another.
    runtime_rows="$(awk '
      $0 ~ "^##[[:space:]]+Runtime Surfaces[[:space:]]*$" { inside=1; commented=0; next }
      inside && /^##[[:space:]]/ { inside=0 }
      inside && /<!--/ { commented=1 }
      inside && /-->/ { commented=0; next }
      inside && commented == 0 && /^\|/ { print }
    ' "$context")"
    while IFS= read -r runtime_row; do
      [[ -n "$runtime_row" ]] || continue
      runtime_id="$(printf '%s\n' "$runtime_row" | awk -F'|' '{ gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2 }')"
      case "$runtime_id" in
        "" | ID | ---* | :---* ) continue ;;
      esac
      printf '%s\n' "$runtime_id" | grep -Eq '^R-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?$' || {
        add_error "Runtime Surfaces row ID must be an R-* identifier, found '$runtime_id'."
        continue
      }
      runtime_repo="$(printf '%s\n' "$runtime_row" | awk -F'|' '{ gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3); print $3 }')"
      runtime_env="$(printf '%s\n' "$runtime_row" | awk -F'|' '{ gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4); print $4 }')"
      runtime_probe="$(printf '%s\n' "$runtime_row" | awk -F'|' '{ gsub(/^[[:space:]]+|[[:space:]]+$/, "", $5); print $5 }')"
      safe_project_path "$runtime_repo" "Runtime surface $runtime_id repo path" >/dev/null
      # An absolute path in Git is a machine-specific lie; only the variable
      # name is portable.
      printf '%s\n' "$runtime_env" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$' ||
        add_error "Runtime surface $runtime_id must name an environment VARIABLE (e.g. WEZTERM_CONFIG_DIR), not a path, found '$runtime_env'."
      if [[ -z "$runtime_probe" || "$runtime_probe" == "none" ]]; then
        add_error "Runtime surface $runtime_id has no Probe; a declared runtime surface without a probe cannot answer whether the deployed copy loaded."
      else
        safe_project_path "$runtime_probe" "Runtime surface $runtime_id probe" >/dev/null
        [[ -e "$root/$runtime_probe" ]] ||
          add_error "Runtime surface $runtime_id probe '$runtime_probe' does not exist."
        verify_entry_file="$root/scripts/project_verify.sh"
        [[ ! -f "$verify_entry_file" ]] || entry_invokes_path "$verify_entry_file" "$runtime_probe" ||
          add_error "Runtime surface $runtime_id probe '$runtime_probe' is not called by scripts/project_verify.sh; an unwired probe never runs."
      fi
    done <<< "$runtime_rows"
  fi

  # Declaring a runtime surface is optional (a pure library has none), but a
  # project that clearly installs itself somewhere and declares nothing keeps
  # the "deployment is not loading" duty as a slogan. Warn, do not fail: the
  # signal is heuristic and must not block honest projects.
  if [[ "$mode" == "software" || "$mode" == "hybrid" ]] &&
    ! printf '%s\n' "$runtime_rows" | grep -Eq '^\|[[:space:]]*R-'; then
    installer_signal=""
    write_decl="$(printf '%s\n' "$workset" |
      sed -n 's/^-[[:space:]]*Write:[[:space:]]*//p' | head -n 1)"
    if printf '%s\n' "$write_decl" | grep -Eq '(^|[,[:space:]])(live-|install|dist/|deploy)'; then
      installer_signal="Write set declares an install/live/dist path"
    elif ls "$root" 2>/dev/null | grep -Eq '^(Install|install|setup|Setup|deploy|Deploy).*\.(ps1|sh|bat|cmd|py)$'; then
      installer_signal="an installer script exists at the project root"
    fi
    if [[ -n "$installer_signal" ]]; then
      add_warning "This software project looks like it installs itself somewhere ($installer_signal) but declares no '## Runtime Surfaces' row; Git synchronization cannot prove the deployed copy loaded the new bytes."
    fi
  fi

  events_file="$root/EVENTS.md"
  if [[ -f "$events_file" ]]; then
    grep -Eq '^##[[:space:]]+Events[[:space:]]*$' "$events_file" ||
      add_error "EVENTS.md must contain a '## Events' section."
    while IFS=: read -r line_number event_line; do
      [[ -n "$line_number" ]] || continue
      printf '%s\n' "$event_line" |
        grep -Eq '^- [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z: \[PKG-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?\] [^|]+\| files: [^|]+\| verify: [^|]+\| pending: [^|]+$' ||
        add_error "Malformed event line in EVENTS.md at line $line_number: $event_line"
      if (( is_pps12 == 1 )); then
        event_files="$(printf '%s\n' "$event_line" | sed -n 's/.*| files:[[:space:]]*\(.*\)| verify:.*/\1/p' |
          sed 's/[[:space:]]*$//')"
        event_verify="$(printf '%s\n' "$event_line" | sed -n 's/.*| verify:[[:space:]]*\(.*\)| pending:.*/\1/p' |
          sed 's/[[:space:]]*$//')"
        event_pending="$(printf '%s\n' "$event_line" | sed -n 's/.*| pending:[[:space:]]*\(.*\)$/\1/p' |
          sed 's/[[:space:]]*$//')"
        event_title="$(printf '%s\n' "$event_line" |
          sed -nE 's/^- [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z: \[[^]]*\][[:space:]]*(.*)[[:space:]]*\|[[:space:]]files:.*/\1/p' |
          sed 's/[[:space:]]*$//')"
        if [[ -n "$event_files" && "$event_files" != "none" ]]; then
          while IFS= read -r event_path; do
            event_path="$(printf '%s' "$event_path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            [[ -n "$event_path" ]] || continue
            safe_project_path "$event_path" "EVENTS.md line $line_number files entry" >/dev/null
          done < <(printf '%s\n' "$event_files" | tr ',' '\n')
        fi
        if [[ "$event_verify" == "none" && "$event_pending" == "none" ]]; then
          # An event that verified nothing and left nothing pending records
          # nothing: this is how a chronicle rots into a changelog of noise.
          # Only two prefixes may be truly empty: abandonment (the decision IS
          # the content) and chat (no work claimed). note/plan/relay must at
          # least name files or keep something pending, otherwise the prefix
          # becomes laundry for real closures ("note shipped the fix").
          if printf '%s\n' "$event_title" | grep -Eiq '^(abandoned|chat)([[:space:]]|:|$)'; then
            :
          elif printf '%s\n' "$event_title" | grep -Eiq '^(note|plan|relay)([[:space:]]|:|$)'; then
            if [[ "$event_files" == "none" || -z "$event_files" ]]; then
              add_error "Event at EVENTS.md line $line_number is prefixed '$(printf '%s' "$event_title" | awk '{print $1}')' with files/verify/pending all 'none'; an informational entry must at least name its files, or use the 'abandoned'/'chat' prefix if nothing was touched."
            fi
          else
            add_error "Event at EVENTS.md line $line_number has 'verify: none' and 'pending: none'; a closing event must name its verification or keep something pending (only the 'abandoned' and 'chat' prefixes may be fully empty)."
          fi
          # A closing verb never belongs in an informational entry: that is how
          # a real landing gets recorded as a memo.
          if printf '%s\n' "$event_title" | grep -Eiq '^(note|plan|chat|relay)([[:space:]]|:)' &&
            printf '%s\n' "$event_title" | grep -Eiq '(^|[[:space:]])(shipped|shipping|closed|closing|landed|landing|released|releasing|fixed|merged|completed)([[:space:]]|$|\.|,)'; then
            add_error "Event at EVENTS.md line $line_number uses an informational prefix but claims a closing action ('$event_title'); record the real verification and pending state instead of filing a landing as a memo."
          fi
        fi
      fi
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
    if printf '%s\n' "$proposal_line" | grep -Eq '\[(abandoned|closed)\]'; then
      # An explicitly abandoned proposal has been decided; it no longer ages.
      continue
    fi
    if (( today_jdn - opened_jdn > 7 )); then
      if printf '%s' "$next" | grep -Fq "$proposal_id"; then
        : # restated in Next by ID; aging discipline satisfied
      elif (( is_pps12 == 1 )); then
        # "Silence means abandonment" has to cost something, or a proposal
        # rots forever behind a warning nobody reads. Restate it by ID, close
        # it, or mark it [abandoned].
        add_error "Proposal $proposal_id has been pending for more than 7 days and is not restated in Hot State Next by ID; restate it, close it, or mark it '[abandoned]'."
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
  archived_tasks=""
  output_roots=""
  if [[ -f "$task_index" ]] && ! grep -Eq '^###[[:space:]]+T-' "$task_index"; then
    # A half-present registry is the worst of both worlds: multitask semantics
    # activate but nothing is declared. Single-task projects must not have the
    # file at all. Report this alone: the cascade of "no integrator / no
    # Writer" errors would bury the actual cause.
    add_error "TASK_INDEX.md exists but registers no task: empty registry not allowed; delete the file to stay single-task, or register the tasks."
  elif [[ -f "$task_index" ]]; then
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
      # Duplicate fields make the record ambiguous: every parser picks one
      # line and the other silently becomes a lie.
      for task_field_name in Title Role Status "Active Package" Capsule "Output Root"; do
        task_field_count="$(printf '%s\n' "$task_block" |
          grep -Ec "^-[[:space:]]*${task_field_name}:" || true)"
        (( task_field_count <= 1 )) ||
          add_error "Task $task_id declares '$task_field_name' $task_field_count times; a task record must declare each field exactly once."
      done
      task_title="$(printf '%s\n' "$task_block" |
        sed -n 's/^-[[:space:]]*Title:[[:space:]]*//p' | head -n 1)"
      if [[ -z "$task_title" || "$task_title" == "none" ]]; then
        add_error "Task $task_id has no Title; a task record without a Title is a shell of a record."
      fi
      task_active_package="$(printf '%s\n' "$task_block" |
        sed -n 's/^-[[:space:]]*Active Package:[[:space:]]*//p' | head -n 1)"
      if [[ -z "$task_active_package" ]]; then
        add_error "Task $task_id has no Active Package field."
      elif ! printf '%s\n' "$task_active_package" |
        grep -Eq '^PKG-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?$'; then
        add_error "Task $task_id Active Package must be a PKG-* ID, found '$task_active_package'."
      elif [[ "$task_active_package" != "$package" ]] &&
        [[ "$($python3_bin "$script_dir/pps_evidence.py" event-positive "$root" "$task_active_package" 2>/dev/null)" != "ok" ]]; then
        add_error "Task $task_id Active Package '$task_active_package' is neither the current package '$package' nor recorded as a positive event line in EVENTS.md."
      fi
      case "$task_role" in
        integrator|worker|consumer) ;;
        *) add_error "Task $task_id has invalid Role '$task_role'." ;;
      esac
      case "$task_status" in
        active|handoff_ready|integrated|rejected|deferred|archived) ;;
        *) add_error "Task $task_id has invalid Status '$task_status'." ;;
      esac
      if [[ "$task_status" == "handoff_ready" ]]; then
        task_base_checkpoint="$(printf '%s\n' "$task_block" |
          sed -n 's/^-[[:space:]]*Base Checkpoint:[[:space:]]*//p' | head -n 1)"
        if [[ -z "$task_base_checkpoint" || "$task_base_checkpoint" == "none" ]]; then
          add_error "Task $task_id is 'handoff_ready' without a 'Base Checkpoint' field; the handoff must record where the work was frozen."
        elif [[ "$task_base_checkpoint" != "lineage_incomplete" ]] &&
          [[ "$($python3_bin "$script_dir/pps_evidence.py" resolve-commit "$root" "$task_base_checkpoint" 2>/dev/null)" != "commit" ]]; then
          add_error "Task $task_id Base Checkpoint '$task_base_checkpoint' is not a resolvable commit."
        fi
      fi
      case "$task_status" in
        integrated|deferred|rejected)
          terminal_tasks="${terminal_tasks}${task_id}:${task_status}"$'\n'
          ;;
        archived)
          archived_tasks="${archived_tasks}${task_id}"$'\n'
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
            [[ "$task_capsule" == task-contexts/* ]] ||
              add_error "Task $task_id ($task_role) capsule '$task_capsule' must live under task-contexts/."
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
      # Duplicate fields make the receipt ambiguous: first-match parsing lets
      # a second, contradictory line hide in plain sight.
      for merge_field_name in "Target Package" "Source Tasks" Relation Accepted \
        Rejected Deferred "Base Checkpoint" "Result Checkpoint" Approval \
        Verification Status "Lineage Note" "Reactivate When" Reason; do
        merge_field_count="$(printf '%s\n' "$merge_block" |
          grep -Ec "^-[[:space:]]*${merge_field_name}:" || true)"
        (( merge_field_count <= 1 )) ||
          add_error "Merge receipt $merge_id declares '$merge_field_name' $merge_field_count times; a receipt must declare each field exactly once."
      done
      case "$merge_relation" in
        absorbs|layers_on|consumes_only|deferred|supersedes|rejected|rollback_to) ;;
        *) add_error "Merge receipt $merge_id has invalid Relation '$merge_relation'." ;;
      esac
      case "$merge_status" in
        pending|integrated|partially_integrated|deferred|rejected) ;;
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
        partially_integrated)
          case "$merge_relation" in
            absorbs|layers_on|supersedes) ;;
            *) add_error "Merge receipt $merge_id Status 'partially_integrated' is incompatible with Relation '$merge_relation'; partial integration absorbs, layers, or supersedes the accepted subset." ;;
          esac
          ;;
      esac
      # P1-03: each non-empty disposition set carries its own evidence,
      # independent of the total Status. A rejection without a reason and a
      # deferral without a reactivation condition are silent abandonments.
      merge_reason="$(merge_field 'Reason')"
      merge_reactivate="$(merge_field 'Reactivate When')"
      if [[ -n "$merge_rejected" && "$merge_rejected" != "none" ]]; then
        [[ -n "$merge_reason" && "$merge_reason" != "none" ]] ||
          add_error "Merge receipt $merge_id lists a non-empty Rejected set without a 'Reason' field; the excluded outputs and the why must survive."
      fi
      if [[ -n "$merge_deferred" && "$merge_deferred" != "none" ]]; then
        [[ -n "$merge_reactivate" && "$merge_reactivate" != "none" ]] ||
          add_error "Merge receipt $merge_id lists a non-empty Deferred set without a 'Reactivate When' field; a deferral without a reactivation condition is a silent abandonment."
      fi
      [[ "$merge_target" =~ ^PKG-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?$ ]] ||
        add_error "Merge receipt $merge_id Target Package must be a PKG-* ID, found '$merge_target'."
      # The Target Package must be a real package: the current one or one
      # recorded in the chronicle as a parsed event line. A substring in a
      # comment, heading, or prose is not evidence a package ever existed.
      if [[ "$merge_target" =~ ^PKG- && "$merge_target" != "$package" ]] &&
        [[ "$($python3_bin "$script_dir/pps_evidence.py" event-positive "$root" "$merge_target" 2>/dev/null)" != "ok" ]]; then
        add_error "Merge receipt $merge_id Target Package '$merge_target' is neither the current package '$package' nor recorded as a positive event line in EVENTS.md."
      fi
      if [[ "$merge_status" == "integrated" ]]; then
        # An integration without accepted content, approval, or verification
        # is a claim, not a receipt — unless the relation is consumes_only,
        # whose whole point is that nothing flows back.
        if [[ "$merge_relation" != "consumes_only" ]] &&
          { [[ -z "$merge_accepted" || "$merge_accepted" == "none" ]]; }; then
          add_error "Merge receipt $merge_id is 'integrated' with an empty Accepted set; an integration that accepted nothing is not an integration."
        fi
        # P1-03: 'integrated' must not mask still-open dispositions. A task
        # that absorbed some paths and excluded others has not fully merged;
        # split the dispositions into separate receipts or say so with
        # Status 'partially_integrated'.
        if { [[ -n "$merge_rejected" && "$merge_rejected" != "none" ]] ||
          [[ -n "$merge_deferred" && "$merge_deferred" != "none" ]]; }; then
          add_error "Merge receipt $merge_id is 'integrated' but still lists Rejected or Deferred paths; split mixed dispositions into separate receipts or use Status 'partially_integrated'."
        fi
      elif [[ "$merge_status" == "partially_integrated" ]]; then
        # A partial integration must have absorbed something and left a
        # remainder explicit. The remainder's evidence is enforced above.
        if [[ -z "$merge_accepted" || "$merge_accepted" == "none" ]]; then
          add_error "Merge receipt $merge_id is 'partially_integrated' with an empty Accepted set; a partial integration that accepted nothing is not an integration."
        fi
        if { [[ -z "$merge_rejected" || "$merge_rejected" == "none" ]] &&
          [[ -z "$merge_deferred" || "$merge_deferred" == "none" ]]; }; then
          add_error "Merge receipt $merge_id is 'partially_integrated' but lists neither Rejected nor Deferred paths; a full integration uses Status 'integrated'."
        fi
      elif [[ "$merge_status" == "deferred" ]]; then
        # A deferral must record what was deferred and when to wake it up,
        # or the work intent is unrecoverable after archiving.
        if [[ -z "$merge_deferred" || "$merge_deferred" == "none" ]]; then
          add_error "Merge receipt $merge_id is 'deferred' with an empty Deferred set; a deferral that defers nothing records nothing."
        fi
        merge_reactivate="$(merge_field 'Reactivate When')"
        if [[ -z "$merge_reactivate" || "$merge_reactivate" == "none" ]]; then
          add_error "Merge receipt $merge_id is 'deferred' without a 'Reactivate When' field; a deferral without a reactivation condition is a silent abandonment."
        fi
      elif [[ "$merge_status" == "rejected" ]]; then
        # A rejection must record what was rejected and why; rejection never
        # deletes the record.
        if [[ -z "$merge_rejected" || "$merge_rejected" == "none" ]]; then
          add_error "Merge receipt $merge_id is 'rejected' with an empty Rejected set; a rejection that rejects nothing records nothing."
        fi
        merge_reason="$(merge_field 'Reason')"
        if [[ -z "$merge_reason" || "$merge_reason" == "none" ]]; then
          add_error "Merge receipt $merge_id is 'rejected' without a 'Reason' field; the excluded outputs and the why must survive."
        fi
      fi
      case "$merge_status" in
        integrated|partially_integrated|deferred|rejected)
          # Every terminal disposition needs authorization and checked
          # evidence, not only integrations.
          if [[ -z "$merge_approval" || "$merge_approval" == "none" ]]; then
            add_error "Merge receipt $merge_id is '$merge_status' without an Approval decision; name the D-* record that authorized this disposition."
          fi
          if [[ -z "$merge_verification" || "$merge_verification" == "none" ]]; then
            add_error "Merge receipt $merge_id is '$merge_status' without Verification evidence; name the command, test, or inspection that checked this disposition."
          fi
          ;;
      esac
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
              partially_integrated)
                src_status="$(awk -v wanted="### $src_task" '
                  index($0, wanted) == 1 { inside=1; next }
                  inside && /^###[[:space:]]/ { exit }
                  inside && index($0, "- Status:") == 1 {
                    sub("^- Status:[[:space:]]*", "")
                    print
                    exit
                  }
                ' "$task_index")"
                # A partially integrated task still has open dispositions and
                # must stay active/handoff_ready in the registry; marking it
                # integrated, deferred, rejected, or archived compresses the
                # remaining path lifecycles into one word.
                case "$src_status" in
                  active|handoff_ready) ;;
                  *) add_error "Merge receipt $merge_id is 'partially_integrated' but Task $src_task is recorded as '$src_status'; a task with still-pending disposition sets stays active until the remainder is resolved." ;;
                esac
                ;;
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
          else
            # A decision that was rejected never authorized anything; citing
            # it as approval is a forged grant, not a stale one.
            approval_status="$(grep -E "^###[[:space:]]+${approval_id}[[:space:]]+\[" "$decisions" |
              head -n 1 | sed -E 's/^###[[:space:]]+[^[]+\[([^]]+)\].*/\1/')"
            case "$approval_status" in
              active|superseded) ;;
              *)
                add_error "Merge receipt $merge_id Approval cites $approval_id whose status is '[$approval_status]'; a decision that never authorized the merge cannot approve it."
                ;;
            esac
            # Polarity: a decision whose body says it does NOT authorize this
            # merge is not a grant, whatever other keywords it contains.
            approval_block2="$(awk -v wanted="### $approval_id " '
              index($0, wanted) == 1 { inside=1; next }
              inside && /^###[[:space:]]/ { exit }
              inside { print }
            ' "$decisions")"
            decision_field2="$(printf '%s\n' "$approval_block2" |
              sed -n 's/^-[[:space:]]*Decision:[[:space:]]*//p' | head -n 1)"
            if [[ -n "$decision_field2" ]]; then
              if ! printf '%s\n' "$decision_field2" | grep -Eiq 'approve|authoriz'; then
                add_error "Merge receipt $merge_id Approval cites $approval_id whose Decision field ('$decision_field2') does not approve; only an approving decision can authorize a merge."
              fi
              subject_field2="$(printf '%s\n' "$approval_block2" |
                sed -n 's/^-[[:space:]]*Subject:[[:space:]]*//p' | head -n 1)"
              if [[ -n "$subject_field2" ]] &&
                ! printf '%s\n' "$subject_field2" | grep -Eiq '\ball\b|\bany\b|none' &&
                ! printf '%s\n' "$subject_field2" | grep -Fq "$merge_id"; then
                add_error "Merge receipt $merge_id Approval cites $approval_id whose Subject ('$subject_field2') does not include $merge_id."
              fi
            elif printf '%s\n' "$approval_block2" |
              grep -Eiq '\b(no|not|never|without|refuse|deny|decline)[[:space:]]+(authoriz|approve|grant|migrat|adopt|merge)'; then
              add_error "Merge receipt $merge_id Approval cites $approval_id whose body explicitly denies the authorization."
            fi
          fi
        done < <(printf '%s\n' "$merge_approval" | tr ',' '\n')
      fi
      # Role x Relation legal matrix (single source: state-machine.json). A
      # consumer never produces project truth, so consumes_only is its only
      # relation; consumes_only itself must declare no output and no result.
      while IFS= read -r src_task_id; do
        [[ -n "$src_task_id" ]] || continue
        src_role="$(awk -v wanted="### $src_task_id" '
          index($0, wanted) == 1 { inside=1; next }
          inside && /^###[[:space:]]/ { exit }
          inside && index($0, "- Role:") == 1 {
            sub("^- Role:[[:space:]]*", "")
            print
            exit
          }' "$task_index" 2>/dev/null)"
        [[ -n "$src_role" ]] || continue
        if [[ "$($python3_bin "$script_dir/pps_evidence.py" role-allows "$src_role" "$merge_relation" 2>/dev/null)" != "true" ]]; then
          add_error "Merge receipt $merge_id Relation '$merge_relation' is not allowed for Source Task $src_task_id whose Role is '$src_role' (see references/state-machine.json)."
        fi
      done < <(printf '%s\n' "$merge_sources" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d')
      if [[ "$merge_relation" == "consumes_only" ]]; then
        [[ -z "$merge_accepted" || "$merge_accepted" == "none" ]] ||
          add_error "Merge receipt $merge_id Relation 'consumes_only' must have Accepted: none; nothing flows back from consumption."
        [[ -z "$merge_deferred" || "$merge_deferred" == "none" ]] ||
          add_error "Merge receipt $merge_id Relation 'consumes_only' must have Deferred: none."
        [[ -z "$merge_rejected" || "$merge_rejected" == "none" ]] ||
          add_error "Merge receipt $merge_id Relation 'consumes_only' must have Rejected: none."
        if [[ -n "$merge_result" && "$merge_result" != "none" && "$merge_result" != "lineage_incomplete" ]]; then
          add_error "Merge receipt $merge_id Relation 'consumes_only' must not declare a Result Checkpoint; consumption produces no canonical change."
        fi
        if [[ -z "$merge_base" || "$merge_base" == "none" ]]; then
          add_error "Merge receipt $merge_id Relation 'consumes_only' must record a Base Checkpoint; consumption must say where it started from."
        fi
      fi
      if [[ -n "$merge_verification" && "$merge_verification" != "none" ]]; then
        # Verification must be TYPED evidence that the merge actually
        # succeeded, judged by the shared engine: gate_result (an executed
        # manifest check), file_evidence (an in-repo regular file), or event
        # (a positive, non-negated chronicle line naming this merge). Free
        # text — especially text containing fail/failed — proves nothing.
        verification_verdict="$($python3_bin "$script_dir/pps_evidence.py" verification-parse "$root" "$merge_verification" "$merge_id" 2>/dev/null)"
        if [[ "$verification_verdict" != ok* ]]; then
          add_error "Merge receipt $merge_id Verification '$merge_verification' is not evidence the merge succeeded ($verification_verdict). Use 'gate_result: <check id>', 'file_evidence: <existing in-repo file>', 'event: <mergeId>' (or 'event: <date>:<mergeId>'), or a named gate with a positive outcome."
        fi
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
          if [[ "$set_name" == "Deferred" || "$set_name" == "Rejected" ]]; then
            kept_real=0
            [[ -e "$root/$disposition_path" ]] && kept_real=1
            if (( kept_real == 0 )) && [[ "$merge_base" != "lineage_incomplete" && -n "$merge_base" ]] &&
              [[ "$($python3_bin "$script_dir/pps_evidence.py" in-commit "$root" "$merge_base" "$disposition_path" 2>/dev/null)" == "present" ]]; then
              kept_real=1
            fi
            (( kept_real == 1 )) ||
              add_error "Merge receipt $merge_id $set_name path '$disposition_path' does not exist in the worktree or in Base Checkpoint '$merge_base'; a terminal disposition must keep recoverable evidence."
          fi
          if [[ "$set_name" == "Accepted" && "$merge_status" == "integrated" ]]; then
            # An accepted artifact must be demonstrably real: present in the
            # worktree or resolvable inside the Result Checkpoint. A ghost
            # path proves nothing was merged.
            accepted_real=0
            if [[ "$merge_result" != "lineage_incomplete" && -n "$merge_result" ]]; then
              # The Result tree is the truth of what merged. A path that
              # exists only in a dirty worktree is pending, not merged.
              if [[ "$($python3_bin "$script_dir/pps_evidence.py" in-commit "$root" "$merge_result" "$disposition_path" 2>/dev/null)" == "present" ]]; then
                accepted_real=1
              fi
            elif [[ -e "$root/$disposition_path" ]]; then
              # Only without a usable Result Checkpoint may the worktree
              # stand in.
              accepted_real=1
            fi
            (( accepted_real == 1 )) ||
              add_error "Merge receipt $merge_id Accepted path '$disposition_path' is not present in Result Checkpoint '$merge_result'; an integration must point at artifacts inside the result commit, not at dirty worktree ghosts."
            # An integration absorbs SOURCE TASK output. An accepted path that
            # belongs to no named source task's Output Root cannot have come
            # from this merge.
            accepted_owned=0
            while IFS= read -r owning_task; do
              [[ -n "$owning_task" ]] || continue
              owning_root="$(awk -v wanted="### $owning_task" '
                index($0, wanted) == 1 { inside=1; next }
                inside && /^###[[:space:]]/ { exit }
                inside && index($0, "- Output Root:") == 1 {
                  sub("^- Output Root:[[:space:]]*", "")
                  print
                  exit
                }
              ' "$task_index")"
              [[ -n "$owning_root" && "$owning_root" != "none" ]] || continue
              case "$disposition_path" in
                "$owning_root" | "$owning_root"/*) accepted_owned=1; break ;;
              esac
            done < <(printf '%s\n' "$merge_sources" | tr ',' '\n' |
              sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d')
            if (( accepted_owned == 0 )); then
              add_error "Merge receipt $merge_id Accepted path '$disposition_path' is not inside any Source Task Output Root ($merge_sources); an integration must absorb output produced by the named tasks."
            fi
          fi
        done < <(printf '%s\n' "$set_value" | tr ',' '\n')
      done
      if [[ "$merge_status" == "integrated" ]]; then
        checkpoint_ok "$merge_base" ||
          add_error "Merge receipt $merge_id Base Checkpoint '$merge_base' is not a resolvable Git object or the explicit lineage_incomplete marker."
        checkpoint_ok "$merge_result" ||
          if [[ "$merge_relation" == "consumes_only" ]]; then
            true
          else
            add_error "Merge receipt $merge_id Result Checkpoint '$merge_result' is not a resolvable Git object or the explicit lineage_incomplete marker."
          fi
        # An integration moves the tree from one state to another. Identical
        # base and result checkpoints mean nothing was integrated.
        if [[ "$merge_base" != "lineage_incomplete" && "$merge_result" != "lineage_incomplete" &&
          -n "$merge_base" && "$merge_base" == "$merge_result" ]]; then
          add_error "Merge receipt $merge_id has identical Base and Result Checkpoints ('$merge_base'); an integration that changed nothing integrated nothing."
        fi
        if [[ "$merge_base" != "lineage_incomplete" && "$merge_result" != "lineage_incomplete" &&
          -n "$merge_base" && -n "$merge_result" ]]; then
          # Fingerprints are not lineage: two commits can share a tree, and a
          # reversed pair is a regression, not an integration.
          ancestor_verdict="$($python3_bin "$script_dir/pps_evidence.py" ancestor "$root" "$merge_base" "$merge_result" 2>/dev/null)"
          if [[ "$ancestor_verdict" == "unresolvable" ]]; then
            add_error "Merge receipt $merge_id Base/Result Checkpoints are not resolvable commits; lineage cannot be proven."
          elif [[ "$ancestor_verdict" == "not-ancestor" ]]; then
            add_error "Merge receipt $merge_id Result Checkpoint is not a descendant of its Base Checkpoint; reversed or forked lineage is not an integration."
          fi
          tree_verdict="$($python3_bin "$script_dir/pps_evidence.py" tree-diff "$root" "$merge_base" "$merge_result" 2>/dev/null)"
          if [[ "$tree_verdict" == "same" ]]; then
            add_error "Merge receipt $merge_id Base and Result Checkpoints carry the same tree; different commit ids with byte-identical content integrated nothing."
          fi
        fi
        if [[ "$merge_base" == "lineage_incomplete" || "$merge_result" == "lineage_incomplete" ]]; then
          # The migration escape hatch is for history that predates the
          # layer. A project whose Git history already exists must use real
          # checkpoints; a convenience note does not create eligibility.
          merge_lineage_note="$(merge_field 'Lineage Note')"
          if [[ -z "$merge_lineage_note" || "$merge_lineage_note" == "none" ]]; then
            add_error "Merge receipt $merge_id uses lineage_incomplete without a 'Lineage Note' field explaining why pre-layer history is unavailable; new projects must use real checkpoints."
          fi
          if command -v git >/dev/null 2>&1 &&
            git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
            git -C "$root" rev-parse HEAD >/dev/null 2>&1; then
            # Eligibility must come from an explicit, reviewable decision.
            # Keyword matching on event prose is not a gate: a line saying
            # "forbid adopt" contains the same keyword as one granting it.
            lineage_migration_ok=0
            if printf '%s\n' "$merge_lineage_note" | grep -Eq '(^|[[:space:]])D-[A-Za-z0-9]' &&
              [[ -f "$decisions" ]]; then
              lineage_note_decision="$(printf '%s\n' "$merge_lineage_note" |
                grep -Eo 'D-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?' | head -n 1)"
              if [[ -n "$lineage_note_decision" ]] &&
                grep -Eq "^###[[:space:]]+${lineage_note_decision}[[:space:]]+\[active\]" "$decisions"; then
                lineage_decision_block="$(awk -v wanted="### $lineage_note_decision " '
                  index($0, wanted) == 1 { inside=1; next }
                  inside && /^###[[:space:]]/ { exit }
                  inside { print }
                ' "$decisions")"
                # The cited decision must actually be about migrating or
                # adopting pre-layer history — and must not explicitly refuse
                # it: "do not migrate" is a negation, not an authorization.
                if printf '%s\n' "$lineage_decision_block" |
                  grep -Eiq '\b(no|not|never|without|refuse|deny)[[:space:]]+(migrat|adopt|authoriz)'; then
                  add_error "Merge receipt $merge_id Lineage Note cites $lineage_note_decision, but that decision explicitly refuses to migrate or adopt pre-layer history; a negation is not an authorization."
                elif printf '%s\n' "$lineage_decision_block" |
                  grep -Eiq 'migrat|adopt|pre-layer|predates'; then
                  lineage_migration_ok=1
                else
                  add_error "Merge receipt $merge_id Lineage Note cites $lineage_note_decision, but that decision does not authorize migrating or adopting pre-layer history."
                fi
              fi
            fi
            (( lineage_migration_ok == 1 )) ||
              add_error "Merge receipt $merge_id uses lineage_incomplete but this project has normal Git history: cite an active D-* decision that explicitly authorizes migrating or adopting pre-layer history, otherwise use real checkpoints."
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

  # Archiving compresses the active surface; it must never blur the final
  # disposition. An archived task keeps exactly one terminal receipt story.
  while IFS= read -r archived_id; do
    [[ -n "$archived_id" ]] || continue
    archived_statuses=""
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
        case "$block_status" in
          integrated|deferred|rejected)
            if printf '%s\n' "$block_sources" | tr ',' '\n' |
              sed 's/^[[:space:]]*//;s/[[:space:]]*$//' |
              grep -Fxq "$archived_id"; then
              archived_statuses="${archived_statuses}${block_status}"$'\n'
            fi
            ;;
        esac
      done <<< "$(printf '%s\n' "$merge_ids" | awk '!seen[$0]++')"
    fi
    archived_distinct="$(printf '%s' "$archived_statuses" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
    archived_total="$(printf '%s' "$archived_statuses" | sed '/^$/d' | wc -l | tr -d ' ')"
    if [[ "$archived_total" == "0" ]]; then
      add_error "Task $archived_id is 'archived' but no terminal receipt names it; archiving compresses history, it does not erase the final disposition."
    elif [[ "$archived_distinct" != "1" ]]; then
      add_error "Task $archived_id is 'archived' with contradictory terminal receipts ($(printf '%s' "$archived_statuses" | sed '/^$/d' | sort -u | tr '\n' ',' | sed 's/,$//')); an archived task keeps exactly one final disposition."
    elif [[ "$archived_total" != "1" ]]; then
      add_error "Task $archived_id is 'archived' with $archived_total terminal receipts of the same status; exactly one final disposition receipt is required."
    fi
  done <<< "$(printf '%s' "$archived_tasks" | sed '/^$/d' | awk '!seen[$0]++')"
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
    printf 'r\n' >>"$coverage_tally_rows"
    coverage_evidence="$(grep -E "^\\|[[:space:]]*${id}[[:space:]]*\\|" "$coverage_path" |
      head -n 1 | awk -F'|' '{
        value = $5
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        print value
      }')"
    if [[ -z "$coverage_evidence" || "$coverage_evidence" == "Present" || "$coverage_evidence" == "present" ]]; then
      add_error "Coverage row for $id needs an evidence cell naming the command, test, or inspection; bare 'Present' cannot distinguish checked from unchecked."
    else
      # Evidence must be a resolvable reference, not prose. A table of
      # unparseable sentences stays green forever and answers nothing. Same
      # semantics as merge receipt Verification: one evidence grammar only.
      coverage_evidence_ok=0
      coverage_evidence_reason=""
      if printf '%s\n' "$coverage_evidence" | grep -Eq \
        '(^|[[:space:]])(validate_project|verify_gate|readiness_check|asset_check|boundary_check)([[:space:]]|:|$)'; then
        coverage_evidence_ok=1
      elif printf '%s\n' "$coverage_evidence" | grep -Eq '^manual:[[:space:]]*[^[:space:]]'; then
        # A manual attestation is only honest while the item is still openly
        # pending; otherwise it is a way to paint the whole table green.
        coverage_pending="$next"
        if printf '%s\n' "$coverage_pending" | grep -Fq "$id"; then
          coverage_evidence_ok=1
          printf 'm\n' >>"$coverage_tally_manual"
        else
          coverage_evidence_reason="uses 'manual:' but $id is not restated in Hot State Next; a manual attestation must stay openly pending"
        fi
      elif printf '%s\n' "$coverage_evidence" | grep -Eq '(^|[[:space:]])[0-9]{4}-[0-9]{2}-[0-9]{2}([[:space:]]|$)'; then
        coverage_event_date="$(printf '%s\n' "$coverage_evidence" |
          grep -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -n 1)"
        if [[ -f "$root/EVENTS.md" ]] &&
          grep -Eq "^-[[:space:]]+${coverage_event_date}:" "$root/EVENTS.md"; then
          coverage_evidence_ok=1
        else
          coverage_evidence_reason="names date $coverage_event_date which is not an event line in EVENTS.md"
        fi
      else
        # Otherwise it must name a real in-repo check that the gate actually
        # runs. A file that exists but is never executed makes the table green
        # forever, which is the original "bare Present" defect with extra
        # syntax.
        coverage_ref="$(printf '%s\n' "$coverage_evidence" |
          grep -Eo '[A-Za-z0-9_./-]+\.(sh|ps1|py|js|ts|mjs|cjs|bat|cmd|exe|rb|go|rs|java|kt|php|pl|lua)' |
          head -n 1)"
        if [[ -z "$coverage_ref" ]]; then
          coverage_evidence_reason="is not a resolvable evidence reference"
        elif [[ ! -e "$root/$coverage_ref" ]]; then
          coverage_evidence_reason="names '$coverage_ref' which does not exist in the project"
        else
          # Execution is proven by the gate's run record, not by text shape
          # in the entry.
          if [[ "$($python3_bin "$script_dir/pps_evidence.py" run-has-path "$root" "$coverage_ref" 2>/dev/null)" == "ok" ]]; then
            coverage_evidence_ok=1
          else
            coverage_evidence_reason="names '$coverage_ref' which exists but no manifest check ran it successfully on this platform; evidence the gate did not run keeps the table green forever"
          fi
        fi
      fi
      (( coverage_evidence_ok == 1 )) ||
        add_error "Coverage row for $id has evidence '$coverage_evidence' that $coverage_evidence_reason; use a PPS gate name, an existing in-repo check path, an EVENTS.md date, or 'manual: <reason>' while the item stays in Next."
    fi
  fi
done <<< "$required_ids"

if (( is_pps12 == 1 )); then
  coverage_manual_count="$(wc -l <"$coverage_tally_manual" | tr -d '[:space:]')"
  coverage_row_count="$(wc -l <"$coverage_tally_rows" | tr -d '[:space:]')"
  # "manual:" is an honest escape hatch for one or two judgement calls. Used
  # broadly it turns Next into a parking lot and the coverage table back into a
  # wall of green with no machine behind it.
  if (( coverage_row_count >= 3 )) && (( coverage_manual_count * 3 > coverage_row_count )); then
    add_error "$coverage_manual_count of $coverage_row_count coverage rows use 'manual:' attestation; at most one third may be manual. Wire the rest to a real check or close them."
  fi
fi

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

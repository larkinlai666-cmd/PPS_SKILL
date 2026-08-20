#!/usr/bin/env bash
set -uo pipefail

usage() {
  echo "Usage: boundary_check.sh [ROOT] [--task T-ID] [--record-baseline] [--allow-preexisting]"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$script_dir/.." && pwd -P)"
allow_preexisting=0
record_baseline=0
task_arg=""
root_seen=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-preexisting) allow_preexisting=1; shift ;;
    --record-baseline) record_baseline=1; shift ;;
    --task)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      task_arg="$2"
      shift 2
      ;;
    -*)
      usage >&2
      exit 2
      ;;
    *)
      (( root_seen == 0 )) || { usage >&2; exit 2; }
      [[ -d "$1" ]] || {
        echo "ERROR: project root is not a directory: $1" >&2
        exit 1
      }
      root="$(cd "$1" && pwd -P)"
      root_seen=1
      shift
      ;;
  esac
done

command -v git >/dev/null 2>&1 || {
  echo "ERROR: git is unavailable; boundary check needs worktree status." >&2
  exit 1
}
git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "ERROR: not a Git repository: $root" >&2
  exit 1
}

baseline_file="$root/.pps/boundary-baseline"

sha256_of_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

changed_entries() {
  # Emits one record per change: "<status>\t<path>\t<content-hash>". Porcelain
  # is parsed in -z form so quoted/escaped paths (CJK, spaces, quotes) resolve
  # to real files. A path is only "the same preexisting change" if status AND
  # content still match.
  local entry entry_status entry_path content_hash skip_next
  skip_next=0
  while IFS= read -r -d '' entry; do
    if (( skip_next == 1 )); then
      skip_next=0
      continue
    fi
    [[ "${#entry}" -gt 3 ]] || continue
    entry_status="${entry:0:2}"
    entry_path="${entry:3}"
    case "$entry_status" in
      R*|C*) skip_next=1 ;;
    esac
    if [[ -f "$root/$entry_path" ]]; then
      content_hash="$(sha256_of_file "$root/$entry_path")"
    else
      content_hash="absent"
    fi
    printf '%s\t%s\t%s\n' "$entry_status" "$entry_path" "$content_hash"
  done < <(git -C "$root" status --porcelain -z --untracked-files=all 2>/dev/null)
}

changed_paths() {
  changed_entries | awk -F'\t' '{ print $2 }'
}

if (( record_baseline == 1 )); then
  mkdir -p "$root/.pps"
  changed_entries > "$baseline_file"
  baseline_count="$(sed -n '$=' "$baseline_file" 2>/dev/null || echo 0)"
  echo "Boundary baseline recorded: ${baseline_count:-0} pre-existing dirty path(s) with content fingerprints."
  echo "PPS boundary check: BASELINE RECORDED"
  exit 0
fi

section_field() {
  local file="$1"
  local section="$2"
  local field="$3"
  awk -v section="$section" -v field="$field" '
    $0 == "## " section { inside=1; next }
    inside && /^## / { exit }
    inside && index($0, "- " field ":") == 1 {
      sub("^- " field ":[[:space:]]*", "")
      print
      exit
    }
  ' "$file"
}

hot_field() {
  section_field "$root/PROJECT_STATE.md" "Hot State" "$1"
}

task_block_field() {
  local task_id="$1"
  local field="$2"
  awk -v wanted="### $task_id" -v prefix="- $field:" '
    index($0, wanted) == 1 { inside=1; next }
    inside && /^###[[:space:]]/ { exit }
    inside && index($0, prefix) == 1 {
      line = substr($0, length(prefix) + 1)
      sub(/^[[:space:]]+/, "", line)
      print line
      exit
    }
  ' "$root/TASK_INDEX.md"
}

# Resolve the acting subject. Claims come only from that subject's own
# declarations: canonical identity never grants automatic write permission.
task_index="$root/TASK_INDEX.md"
subject=""
subject_role=""
subject_capsule=""
subject_output_root=""
if [[ -f "$task_index" ]]; then
  if [[ -n "$task_arg" ]]; then
    subject="$task_arg"
  else
    subject="$(hot_field Writer)"
  fi
  if [[ -z "$subject" ]]; then
    echo "ERROR: multitask project but no acting task; pass --task T-ID or set Hot State Writer." >&2
    exit 1
  fi
  grep -Eq "^###[[:space:]]+${subject}[[:space:]]*$" "$task_index" || {
    echo "ERROR: acting task '$subject' is not registered in TASK_INDEX.md." >&2
    exit 1
  }
  subject_role="$(task_block_field "$subject" "Role")"
  subject_status="$(task_block_field "$subject" "Status")"
  subject_capsule="$(task_block_field "$subject" "Capsule")"
  subject_output_root="$(task_block_field "$subject" "Output Root")"
  case "$subject_status" in
    active) ;;
    *)
      echo "ERROR: acting task '$subject' has status '$subject_status'; only an active task holds write authority. A terminal or handoff task must not write again — reactivate it explicitly or act as the integrator." >&2
      exit 1
      ;;
  esac
  if [[ "$subject_role" == "integrator" && "$subject_capsule" != "CONTEXT.md" ]]; then
    echo "ERROR: integrator task '$subject' must use CONTEXT.md as its capsule, found '$subject_capsule'; a separate integrator capsule is an unvalidated grant channel." >&2
    exit 1
  fi
else
  if [[ -n "$task_arg" ]]; then
    echo "ERROR: --task was given but TASK_INDEX.md does not exist." >&2
    exit 1
  fi
  subject="canonical"
  subject_role="integrator"
  subject_capsule="CONTEXT.md"
fi

claims=""
add_claims() {
  local value="$1"
  local entry
  [[ -n "$value" && "$value" != "none" ]] || return 0
  while IFS= read -r entry; do
    entry="$(printf '%s' "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$entry" ]] && claims="${claims}${entry}"$'\n'
  done < <(printf '%s\n' "$value" | tr ',' '\n')
}

if [[ -n "$subject_capsule" && "$subject_capsule" != "none" && -f "$root/$subject_capsule" ]]; then
  if [[ "$subject_role" == "worker" || "$subject_role" == "consumer" ]]; then
    # worker/consumer claims must live inside their own Output Root; a Write
    # declaration outside it is not a grant, it is a violation.
    while IFS= read -r declared_write; do
      declared_write="$(printf '%s' "$declared_write" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -n "$declared_write" && "$declared_write" != "none" ]] || continue
      if [[ -n "$subject_output_root" && "$subject_output_root" != "none" ]]; then
        case "$declared_write" in
          "$subject_output_root" | "$subject_output_root"/*)
            claims="${claims}${declared_write}"$'\n'
            ;;
          *)
            echo "ERROR: acting task '$subject' ($subject_role) declares Write '$declared_write' outside its Output Root '$subject_output_root'; worker and consumer tasks write only inside their own Output Root." >&2
            exit 1
            ;;
        esac
      fi
    done < <(section_field "$root/$subject_capsule" "Workset Manifest" Write | tr ',' '\n')
  else
    add_claims "$(section_field "$root/$subject_capsule" "Workset Manifest" Write)"
  fi
fi
if [[ -n "$subject_output_root" && "$subject_output_root" != "none" ]]; then
  claims="${claims}${subject_output_root}"$'\n'
fi
# The verify stamp and boundary baseline are tool-owned local artifacts.
claims="${claims}.pps"$'\n'
claims="$(printf '%s' "$claims" | sed '/^$/d' | awk '!seen[$0]++')"

if [[ -z "$claims" ]]; then
  echo "ERROR: acting subject '$subject' has no usable Write claims; declare Write paths in its capsule first." >&2
  exit 1
fi

echo "Acting subject: $subject ($subject_role)"

is_claimed() {
  local path="$1"
  local claim
  while IFS= read -r claim; do
    [[ -n "$claim" ]] || continue
    if [[ "$path" == "$claim" || "$path" == "$claim"/* ]]; then
      return 0
    fi
  done <<< "$claims"
  return 1
}

in_baseline() {
  # A change is preexisting only if status, path, AND content hash all match
  # the recorded baseline entry. Any later write to the same path changes the
  # content hash and voids the exemption.
  local record="$1"
  [[ -f "$baseline_file" ]] || return 1
  grep -Fxq "$record" "$baseline_file"
}

unclaimed=0
all_changes="$(changed_entries)"
if [[ -z "$all_changes" ]]; then
  echo "Boundary check: worktree clean; nothing to classify."
  echo "PPS boundary check: OK"
  exit 0
fi
while IFS= read -r change_record; do
  [[ -n "$change_record" ]] || continue
  changed_path="$(printf '%s' "$change_record" | awk -F'\t' '{ print $2 }')"
  if is_claimed "$changed_path"; then
    echo "claimed: $changed_path"
  elif (( allow_preexisting == 1 )) && in_baseline "$change_record"; then
    echo "preexisting (baseline): $changed_path"
  else
    if (( allow_preexisting == 1 )) && [[ ! -f "$baseline_file" ]]; then
      echo "ERROR: --allow-preexisting requires a recorded baseline; run --record-baseline at session start." >&2
      exit 1
    fi
    if (( allow_preexisting == 1 )) && [[ -f "$baseline_file" ]] &&
      grep -q "	${changed_path}	" "$baseline_file"; then
      echo "unclaimed_write: $changed_path (baselined path changed again after the baseline)" >&2
    else
      echo "unclaimed_write: $changed_path" >&2
    fi
    unclaimed=$((unclaimed + 1))
  fi
done <<< "$all_changes"

if (( unclaimed > 0 )); then
  echo "PPS boundary check: FAILED ($unclaimed unclaimed change(s))" >&2
  echo "Claim each path in the acting subject's Write set or Output Root, revert it, or record it in the session baseline before starting work." >&2
  exit 1
fi
echo "PPS boundary check: OK"

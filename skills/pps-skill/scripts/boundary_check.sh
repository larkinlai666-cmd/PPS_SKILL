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

changed_paths() {
  git -C "$root" status --porcelain --untracked-files=all 2>/dev/null |
    sed 's/^...//' | sed 's/^"//;s/"$//' |
    awk '{ if (index($0, " -> ") > 0) { sub(/^.* -> /, "") } print }'
}

if (( record_baseline == 1 )); then
  mkdir -p "$root/.pps"
  changed_paths > "$baseline_file"
  baseline_count="$(sed -n '$=' "$baseline_file" 2>/dev/null || echo 0)"
  echo "Boundary baseline recorded: ${baseline_count:-0} pre-existing dirty path(s)."
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
  subject_capsule="$(task_block_field "$subject" "Capsule")"
  subject_output_root="$(task_block_field "$subject" "Output Root")"
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
  add_claims "$(section_field "$root/$subject_capsule" "Workset Manifest" Write)"
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
  local path="$1"
  [[ -f "$baseline_file" ]] || return 1
  grep -Fxq "$path" "$baseline_file"
}

unclaimed=0
all_changes="$(changed_paths)"
if [[ -z "$all_changes" ]]; then
  echo "Boundary check: worktree clean; nothing to classify."
  echo "PPS boundary check: OK"
  exit 0
fi
while IFS= read -r changed_path; do
  [[ -n "$changed_path" ]] || continue
  if is_claimed "$changed_path"; then
    echo "claimed: $changed_path"
  elif (( allow_preexisting == 1 )) && in_baseline "$changed_path"; then
    echo "preexisting (baseline): $changed_path"
  else
    if (( allow_preexisting == 1 )) && [[ ! -f "$baseline_file" ]]; then
      echo "ERROR: --allow-preexisting requires a recorded baseline; run --record-baseline at session start." >&2
      exit 1
    fi
    echo "unclaimed_write: $changed_path" >&2
    unclaimed=$((unclaimed + 1))
  fi
done <<< "$all_changes"

if (( unclaimed > 0 )); then
  echo "PPS boundary check: FAILED ($unclaimed unclaimed change(s))" >&2
  echo "Claim each path in the acting subject's Write set or Output Root, revert it, or record it in the session baseline before starting work." >&2
  exit 1
fi
echo "PPS boundary check: OK"

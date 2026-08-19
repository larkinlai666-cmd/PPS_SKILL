#!/usr/bin/env bash
set -uo pipefail

usage() {
  echo "Usage: boundary_check.sh [ROOT] [--allow-preexisting]"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$script_dir/.." && pwd -P)"
allow_preexisting=0
root_seen=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-preexisting) allow_preexisting=1; shift ;;
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

# Collect claimed boundaries: the canonical Write set plus, when the multitask
# layer is active, every non-archived task's Write set and Output Root.
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

add_claims "$(section_field "$root/CONTEXT.md" "Workset Manifest" Write)"
# Canonical state files are always legitimate targets for the canonical writer.
for canonical in PROJECT_STATE.md DECISIONS.md CONTEXT.md EVENTS.md \
  PROJECT_MAP.md ENVIRONMENT.md ASSETS.md SOURCE_INDEX.md TASK_INDEX.md \
  MERGES.md docs/coverage.md docs/CURRENT_REVIEW_EVIDENCE.md; do
  claims="${claims}${canonical}"$'\n'
done

if [[ -f "$root/TASK_INDEX.md" ]]; then
  while IFS= read -r task_id; do
    [[ -n "$task_id" ]] || continue
    task_block="$(awk -v wanted="### $task_id" '
      index($0, wanted) == 1 { inside=1; next }
      inside && /^###[[:space:]]/ { exit }
      inside { print }
    ' "$root/TASK_INDEX.md")"
    task_status="$(printf '%s\n' "$task_block" |
      sed -n 's/^-[[:space:]]*Status:[[:space:]]*//p' | head -n 1)"
    [[ "$task_status" == "archived" ]] && continue
    task_output_root="$(printf '%s\n' "$task_block" |
      sed -n 's/^-[[:space:]]*Output Root:[[:space:]]*//p' | head -n 1)"
    if [[ -n "$task_output_root" && "$task_output_root" != "none" ]]; then
      claims="${claims}${task_output_root}"$'\n'
    fi
    task_capsule="$(printf '%s\n' "$task_block" |
      sed -n 's/^-[[:space:]]*Capsule:[[:space:]]*//p' | head -n 1)"
    if [[ -n "$task_capsule" && -f "$root/$task_capsule" ]]; then
      claims="${claims}${task_capsule}"$'\n'
      add_claims "$(section_field "$root/$task_capsule" "Workset Manifest" Write)"
    fi
  done < <(grep -E '^###[[:space:]]+T-' "$root/TASK_INDEX.md" |
    grep -Eo 'T-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?' | awk '!seen[$0]++')
fi
claims="$(printf '%s' "$claims" | sed '/^$/d' | awk '!seen[$0]++')"

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

unclaimed=0
staged_or_dirty="$(git -C "$root" status --porcelain --untracked-files=all 2>/dev/null |
  sed 's/^...//' | sed 's/^"//;s/"$//')"
if [[ -z "$staged_or_dirty" ]]; then
  echo "Boundary check: worktree clean; nothing to classify."
  echo "PPS boundary check: OK"
  exit 0
fi
while IFS= read -r changed_path; do
  [[ -n "$changed_path" ]] || continue
  # Renames appear as "old -> new"; classify the destination.
  case "$changed_path" in
    *" -> "*) changed_path="${changed_path#* -> }" ;;
  esac
  if is_claimed "$changed_path"; then
    echo "claimed: $changed_path"
  else
    if (( allow_preexisting == 1 )); then
      echo "preexisting (unclassified): $changed_path"
    else
      echo "unclaimed_write: $changed_path" >&2
      unclaimed=$((unclaimed + 1))
    fi
  fi
done <<< "$staged_or_dirty"

if (( unclaimed > 0 )); then
  echo "PPS boundary check: FAILED ($unclaimed unclaimed change(s))" >&2
  echo "Claim each path in a Write set or task Output Root, revert it, or classify it explicitly with --allow-preexisting." >&2
  exit 1
fi
echo "PPS boundary check: OK"

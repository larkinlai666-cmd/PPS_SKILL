#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root_input="${1:-$(cd "$script_dir/.." && pwd -P)}"
root="$(cd "$root_input" && pwd -P)"
state="$root/PROJECT_STATE.md"
context="$root/CONTEXT.md"
decisions="$root/DECISIONS.md"
map_file="$root/PROJECT_MAP.md"
validator="$root/scripts/validate_project.sh"

[[ -x "$validator" || -f "$validator" ]] || {
  echo "ERROR: missing project validator: $validator" >&2
  exit 1
}
if ! validation_output="$(bash "$validator" "$root" --quiet 2>&1)"; then
  printf '%s\n' "$validation_output" | sed -n '1,200p' >&2
  echo "ERROR: resume packet refused because project validation failed." >&2
  exit 1
fi

field_in_section() {
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

tmp_file="$(mktemp "${TMPDIR:-/tmp}/pps-resume.XXXXXX")"
trap 'rm -f "$tmp_file"' EXIT
{
  echo "# PPS Resume Packet"
  echo
  echo "## Hot State"
  for field in Protocol Profile Mode Stage Main Map Environment Package Status Capsule Coverage Blockers Next Updated Device; do
    value="$(field_in_section "$state" "Hot State" "$field")"
    [[ -n "$value" ]] && printf -- '- %s: %s\n' "$field" "$value"
  done

  echo
  echo "## Workset"
  for field in Methods Facts Decisions Sources Assets Components Read Write Verify Excluded Coverage; do
    value="$(field_in_section "$context" "Workset Manifest" "$field")"
    [[ -n "$value" ]] && printf -- '- %s: %s\n' "$field" "$value"
  done

  echo
  echo "## Current Package"
  for field in ID Goal "Output anchor" "Allowed change" "Forbidden change"; do
    value="$(field_in_section "$context" "Current Package" "$field")"
    [[ -n "$value" ]] && printf -- '- %s: %s\n' "$field" "$value"
  done
  next_action="$(awk '
    /^## Next Action[[:space:]]*$/ { inside=1; next }
    inside && /^## / { exit }
    inside && NF { print; exit }
  ' "$context")"
  [[ -n "$next_action" ]] && printf -- '- Next action: %s\n' "$next_action"

  echo
  echo "## Component Rows"
  components="$(field_in_section "$context" "Workset Manifest" Components)"
  if [[ "$components" == "none" ]]; then
    echo "- none"
  else
    while IFS= read -r component; do
      [[ -n "$component" ]] || continue
      awk -F'|' -v wanted="$component" '
        function trim(value) {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
          return value
        }
        /^\|/ && trim($2) == wanted { print; exit }
      ' "$map_file"
    done < <(printf '%s\n' "$components" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  fi

  echo
  echo "## Active Authority Summaries"
  authority_ids="$(
    for field in Methods Facts Decisions; do
      field_in_section "$context" "Workset Manifest" "$field"
    done | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | awk '$0 != "" && $0 != "none"'
  )"
  if [[ -z "$authority_ids" ]]; then
    echo "- none"
  else
    while IFS= read -r authority_id; do
      awk -v wanted="$authority_id" '
        $0 ~ "^### " wanted "([[:space:]]|$)" { print; exit }
      ' "$decisions"
    done <<< "$authority_ids"
  fi

  echo
  echo "## Asset Readiness"
  asset_output=""
  if [[ -f "$root/scripts/asset_check.sh" ]]; then
    if asset_output="$(bash "$root/scripts/asset_check.sh" "$root" --quick 2>&1)"; then
      printf '%s\n' "$asset_output" | sed -n '1,80p'
    else
      printf '%s\n' "$asset_output" | sed -n '1,80p'
      echo "Materialization: incomplete; Git synchronization alone is not a complete project handoff."
    fi
  else
    echo "Asset checker: unavailable"
  fi

  echo
  echo "## Repository Risk"
  if command -v git >/dev/null 2>&1 && git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    branch="$(git -C "$root" branch --show-current 2>/dev/null || true)"
    [[ -n "$branch" ]] || branch="detached"
    if git -C "$root" diff --quiet --ignore-submodules -- &&
      git -C "$root" diff --cached --quiet --ignore-submodules -- &&
      [[ -z "$(git -C "$root" status --porcelain --untracked-files=normal 2>/dev/null | sed -n '1p')" ]]; then
      dirty="clean"
    else
      dirty="dirty"
    fi
    printf -- '- Branch: %s\n' "$branch"
    printf -- '- Worktree: %s\n' "$dirty"
  else
    echo "- Git: unavailable or not initialized"
  fi
  echo "- Validation: pass"
} > "$tmp_file"

line_count="$(wc -l < "$tmp_file" | tr -d '[:space:]')"
byte_count="$(wc -c < "$tmp_file" | tr -d '[:space:]')"
if (( line_count > 240 )); then
  echo "ERROR: resume packet would exceed the 240-line hard limit; narrow the workset." >&2
  exit 1
fi
if (( byte_count > 32768 )); then
  echo "ERROR: resume packet would exceed the 32768-byte hard limit; narrow the workset." >&2
  exit 1
fi
sed -n '1,240p' "$tmp_file"

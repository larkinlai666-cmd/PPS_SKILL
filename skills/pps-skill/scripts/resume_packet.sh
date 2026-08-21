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

next_value_for_handover="$(field_in_section "$state" "Hot State" "Next")"

tmp_file="$(mktemp "${TMPDIR:-/tmp}/pps-resume.XXXXXX")"
trap 'rm -f "$tmp_file"' EXIT
{
  echo "# PPS Resume Packet"
  echo
  echo "## Hot State"
  for field in Protocol Profile Mode Stage Main Map Environment Package Status Capsule Coverage Blockers Next Updated Device Writer; do
    value="$(field_in_section "$state" "Hot State" "$field")"
    [[ -n "$value" ]] && printf -- '- %s: %s\n' "$field" "$value"
  done

  if grep -Eq '^##[[:space:]]+Red Lines[[:space:]]*$' "$root/AGENTS.md" 2>/dev/null; then
    echo
    echo "## Red Lines"
    # Take every non-empty line in the section, not only "- " bullets:
    # numbered items and bold headers are red lines too, and dropping them
    # made the packet claim a project had no engineering red lines at all.
    # Budget by bytes so the shape of the list cannot silently truncate it.
    red_lines_body="$(
      awk '
        $0 ~ "^##[[:space:]]+Red Lines[[:space:]]*$" { inside=1; next }
        inside && /^##[[:space:]]/ { exit }
        inside && NF { print }
      ' "$root/AGENTS.md"
    )"
    red_lines_kept=""
    red_lines_budget=1500
    red_lines_used=0
    red_lines_truncated=0
    while IFS= read -r red_line; do
      [[ -n "$red_line" ]] || continue
      red_line_size=$(( ${#red_line} + 1 ))
      if (( red_lines_used + red_line_size > red_lines_budget )); then
        red_lines_truncated=1
        break
      fi
      red_lines_kept="${red_lines_kept}${red_line}"$'\n'
      red_lines_used=$(( red_lines_used + red_line_size ))
    done <<< "$red_lines_body"
    if [[ -n "$red_lines_kept" ]]; then
      printf '%s' "$red_lines_kept"
    else
      echo "- (section present but empty)"
    fi
    if (( red_lines_truncated == 1 )); then
      echo "- Red Lines truncated; read AGENTS.md for the full list."
    fi
  fi

  if [[ -f "$root/EVENTS.md" ]]; then
    echo
    echo "## Recent Events"
    awk '
      $0 ~ "^##[[:space:]]+Events[[:space:]]*$" { inside=1; next }
      inside && /^##[[:space:]]/ { inside=0 }
      inside && /^- / { print }
    ' "$root/EVENTS.md" | tail -n 5
  fi

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
  echo "## Handover"
  # A single word "dirty" tells the next agent nothing about WHICH files carry
  # the previous session's uncommitted work. Name them: that is the whole
  # point of a handover section.
  handover_paths=""
  if command -v git >/dev/null 2>&1 && git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    handover_skip=0
    while IFS= read -r -d '' handover_entry; do
      if (( handover_skip == 1 )); then
        handover_skip=0
        continue
      fi
      [[ "${#handover_entry}" -gt 3 ]] || continue
      handover_status="${handover_entry:0:2}"
      handover_path="${handover_entry:3}"
      case "$handover_status" in
        R* | C*) handover_skip=1 ;;
      esac
      handover_paths="${handover_paths}${handover_status}"$'\t'"${handover_path}"$'\n'
    done < <(git -C "$root" status --porcelain -z --untracked-files=all 2>/dev/null)
  fi
  handover_paths="$(printf '%s' "$handover_paths" | sed '/^$/d')"
  if [[ -z "$handover_paths" ]]; then
    echo "- Uncommitted paths: none"
  else
    handover_count="$(printf '%s\n' "$handover_paths" | wc -l | tr -d '[:space:]')"
    printf -- '- Uncommitted paths: %s\n' "$handover_count"
    printf '%s\n' "$handover_paths" | sed -n '1,20p' |
      awk -F'\t' '{ printf "- protected: %s (%s)\n", $2, $1 }'
    if (( handover_count > 20 )); then
      printf -- '- protected: ... %s more\n' "$(( handover_count - 20 ))"
    fi
    # Paths the outgoing Next line explicitly hands over are the ones the
    # incoming session is expected to touch; everything else dirty is a
    # landmine.
    declared_handover=""
    while IFS= read -r handover_candidate; do
      [[ -n "$handover_candidate" ]] || continue
      if printf '%s' "$next_value_for_handover" | grep -Fq "$handover_candidate"; then
        declared_handover="${declared_handover}${handover_candidate}, "
      fi
    done < <(printf '%s\n' "$handover_paths" | awk -F'\t' '{ print $2 }')
    if [[ -n "$declared_handover" ]]; then
      printf -- '- Declared in Next: %s\n' "${declared_handover%, }"
    else
      echo "- Declared in Next: none"
      echo "- WARNING: dirty worktree without explicit handover; do not overwrite the paths above wholesale."
    fi
  fi
  if [[ -f "$root/.pps/session-snapshot" ]]; then
    printf -- '- Session snapshot: present (%s)\n' \
      "$(sed -n 's/^started_at:[[:space:]]*//p' "$root/.pps/session-snapshot" | head -n 1)"
  else
    echo "- Relay: SNAPSHOT MISSING; run scripts/session_begin.* before writing."
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

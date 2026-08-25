#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# Small-context repair: the protocol has always described L0/L1/L2 retrieval,
# but this script only ever emitted one size. A mid-session agent that just
# needs to re-anchor had to swallow the whole packet or read nothing. --level
# emits SUBSETS of the same content: no new sections, no new state, and
# --level full is byte-identical to the previous behaviour.
packet_level="full"
root_input=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --level)
      [[ $# -ge 2 ]] || { echo "ERROR: --level needs a value (anchor|hot|full)." >&2; exit 2; }
      packet_level="$2"
      shift 2
      ;;
    --level=*)
      packet_level="${1#--level=}"
      shift
      ;;
    -h | --help)
      echo "Usage: resume_packet.sh [ROOT] [--level anchor|hot|full]"
      exit 0
      ;;
    -*)
      echo "ERROR: unknown option: $1" >&2
      exit 2
      ;;
    *)
      [[ -z "$root_input" ]] || { echo "ERROR: unexpected extra argument: $1" >&2; exit 2; }
      root_input="$1"
      shift
      ;;
  esac
done
case "$packet_level" in
  anchor | hot | full) ;;
  *)
    echo "ERROR: unknown --level '$packet_level'; use anchor, hot, or full." >&2
    exit 2
    ;;
esac
[[ -n "$root_input" ]] || root_input="$(cd "$script_dir/.." && pwd -P)"
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
  # anchor level keeps only the fields needed to re-anchor: who/where/what is
  # active. Everything else is recoverable by reading the state file.
  if [[ "$packet_level" == "anchor" ]]; then
    hot_fields=(Protocol Mode Stage Package Status Next)
  else
    hot_fields=(Protocol Profile Mode Stage Main Map Environment Package Status Capsule Coverage Blockers Next Updated Device Writer)
  fi
  for field in "${hot_fields[@]}"; do
    value="$(field_in_section "$state" "Hot State" "$field")"
    [[ -n "$value" ]] && printf -- '- %s: %s\n' "$field" "$value"
  done

  # R1: the packet is the authority after a context reset, so it must carry the
  # objective itself — not only the one-line package Goal. Bounded like the red
  # lines: truncate on a byte budget rather than dropping the section.
  objective_body="$(awk '
    $0 ~ "^##[[:space:]]+Objective[[:space:]]*$" { inside=1; next }
    inside && /^##[[:space:]]/ { exit }
    inside && NF { print }
  ' "$state")"
  if [[ -n "$objective_body" ]]; then
    echo
    echo "## Objective"
    objective_budget=800
    objective_used=0
    objective_truncated=0
    while IFS= read -r objective_line; do
      [[ -n "$objective_line" ]] || continue
      # ${#var} counts CHARACTERS in a UTF-8 locale while the PowerShell edition
      # counts BYTES; a non-ASCII objective then truncates differently on each
      # engine. Measure bytes on both sides.
      line_bytes=$(( $(printf '%s' "$objective_line" | wc -c | tr -d '[:space:]') + 1 ))
      if (( objective_used + line_bytes > objective_budget )); then
        objective_truncated=1
        break
      fi
      printf '%s\n' "$objective_line"
      objective_used=$(( objective_used + line_bytes ))
    done <<< "$objective_body"
    if (( objective_truncated == 1 )); then
      echo "- Objective truncated; read PROJECT_STATE.md for the full statement."
    fi
  fi

  if grep -Eq '^##[[:space:]]+Red Lines[[:space:]]*$' "$root/AGENTS.md" 2>/dev/null; then
    echo
    echo "## Red Lines"
    # Take every non-empty line in the section, not only "- " bullets:
    # numbered items and bold headers are red lines too, and dropping them
    # made the packet claim a project had no engineering red lines at all.
    # Budget by bytes so the shape of the list cannot silently truncate it.
    # Skip HTML comments: template guidance is not a red line, and letting it
    # consume the byte budget is how the real rules disappeared before.
    red_lines_body="$(
      awk '
        $0 ~ "^##[[:space:]]+Red Lines[[:space:]]*$" { inside=1; next }
        inside && /^##[[:space:]]/ { exit }
        inside && /<!--/ { commented=1 }
        inside && /-->/ { commented=0; next }
        inside && commented == 0 && NF { print }
      ' "$root/AGENTS.md"
    )"
    red_lines_kept=""
    # Red lines are a guardrail and are never dropped, but a re-anchor pull can
    # afford less of them than a cold start.
    if [[ "$packet_level" == "anchor" ]]; then
      red_lines_budget=600
    else
      red_lines_budget=1500
    fi
    red_lines_used=0
    red_lines_truncated=0
    while IFS= read -r red_line; do
      [[ -n "$red_line" ]] || continue
      red_line_size=$(( $(printf '%s' "$red_line" | wc -c | tr -d '[:space:]') + 1 ))
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

  if [[ -f "$root/EVENTS.md" && "$packet_level" != "anchor" ]]; then
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
  # anchor level keeps the write boundary and its verification: those are the
  # constraints an agent violates when its working memory has rotted. The rest
  # of the manifest is lookup material, not a guardrail.
  if [[ "$packet_level" == "anchor" ]]; then
    workset_fields=(Read Write Verify Excluded)
  else
    workset_fields=(Methods Facts Decisions Sources Assets Components Read Write Verify Excluded Coverage)
  fi
  for field in "${workset_fields[@]}"; do
    value="$(field_in_section "$context" "Workset Manifest" "$field")"
    [[ -n "$value" ]] && printf -- '- %s: %s\n' "$field" "$value"
  done

  echo
  echo "## Current Package"
  for field in ID Goal "Output anchor" "Allowed change" "Forbidden change"; do
    value="$(field_in_section "$context" "Current Package" "$field")"
    [[ -n "$value" ]] && printf -- '- %s: %s\n' "$field" "$value"
  done
  # R1: "done" must survive a context reset. The capsule carries Acceptance as a
  # multi-line sub-list, which the single-line field reader cannot see, so a
  # recovered agent used to get Goal without ever learning what closes the
  # package. Emit the items verbatim.
  acceptance_items="$(awk '
    $0 ~ "^##[[:space:]]+Current Package[[:space:]]*$" { inside=1; next }
    inside && /^##[[:space:]]/ { exit }
    inside && $0 ~ /^[[:space:]]*-[[:space:]]*A[0-9]+:/ { sub(/^[[:space:]]+/, ""); print }
  ' "$context")"
  if [[ -n "$acceptance_items" ]]; then
    echo "- Acceptance:"
    printf '%s\n' "$acceptance_items" | sed 's/^/  /'
  fi
  next_action="$(awk '
    /^## Next Action[[:space:]]*$/ { inside=1; next }
    inside && /^## / { exit }
    inside && NF { print; exit }
  ' "$context")"
  [[ -n "$next_action" ]] && printf -- '- Next action: %s\n' "$next_action"

  if [[ "$packet_level" != "anchor" ]]; then
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

  fi

  if [[ "$packet_level" == "full" ]]; then
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
  # Machine-readable trailer: lets the gate observe whether a packet was pulled
  # in this session, and tells a reader which subset it is holding.
  printf -- '- packet_level: %s\n' "$packet_level"
  printf -- '- generated_at: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$tmp_file"

line_count="$(wc -l < "$tmp_file" | tr -d '[:space:]')"
byte_count="$(wc -c < "$tmp_file" | tr -d '[:space:]')"
# A hard failure over budget hands a small-context model ZERO information and
# tells it to "narrow the workset" — which it cannot do mid-session. Degrade in
# a fixed order instead, and say out loud what was dropped. The goal, the red
# lines, the current package and the write boundary are never droppable: they
# are the anti-drift payload the packet exists to carry.
if (( line_count > 240 || byte_count > 32768 )); then
  droppable_sections=("Asset Readiness" "Component Rows" "Active Authority Summaries" "Recent Events" "Repository Risk")
  dropped_sections=""
  for droppable in "${droppable_sections[@]}"; do
    (( line_count > 240 || byte_count > 32768 )) || break
    awk -v target="## $droppable" '
      $0 == target { skipping = 1; next }
      skipping && /^## / { skipping = 0 }
      skipping { next }
      { print }
    ' "$tmp_file" > "$tmp_file.trim"
    mv "$tmp_file.trim" "$tmp_file"
    dropped_sections="${dropped_sections}${droppable}, "
    line_count="$(wc -l < "$tmp_file" | tr -d '[:space:]')"
    byte_count="$(wc -c < "$tmp_file" | tr -d '[:space:]')"
  done
  if [[ -n "$dropped_sections" ]]; then
    printf -- '- packet_degraded: dropped %s to fit the L0 budget; re-read the files for those sections.\n' \
      "${dropped_sections%, }" >> "$tmp_file"
    line_count="$(wc -l < "$tmp_file" | tr -d '[:space:]')"
    byte_count="$(wc -c < "$tmp_file" | tr -d '[:space:]')"
  fi
fi
if (( line_count > 240 || byte_count > 32768 )); then
  # Even after degrading, the undroppable core does not fit: that is a real
  # workset problem, not a context-size problem.
  echo "ERROR: resume packet exceeds the L0 budget even after dropping optional sections ($line_count lines / $byte_count bytes); narrow the workset." >&2
  exit 1
fi
if [[ -d "$root/.pps" ]]; then
  # The fingerprint lets a later write-time check verify that the packet
  # matches the DISK, not just a timestamp. See core_fingerprint.sh for why
  # the cost of faking it equals the benefit of compliance.
  core_fp=""
  if [[ -x "$root/scripts/core_fingerprint.sh" || -f "$root/scripts/core_fingerprint.sh" ]]; then
    core_fp="$(bash "$root/scripts/core_fingerprint.sh" "$root" 2>/dev/null || true)"
  fi
  {
    printf 'packet_level: %s\n' "$packet_level"
    printf 'generated_at: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    [[ -n "$core_fp" ]] && printf 'core_sha256: %s\n' "$core_fp"
  } > "$root/.pps/last-packet" 2>/dev/null || true
fi
sed -n '1,240p' "$tmp_file"

#!/usr/bin/env bash
set -uo pipefail

# Session begin: record the handover snapshot for this working session.
#
# Git only protects committed history. The dangerous moment in a single-writer
# relay project is the handover instant: the previous session may have left
# uncommitted work inside the very files the next session is allowed to write.
# This script turns "run git status first" from a sentence into an artifact.
#
# Usage: session_begin.sh [ROOT] [--takeover] [--agent NAME]

usage() {
  echo "Usage: session_begin.sh [ROOT] [--takeover] [--agent NAME]"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$script_dir/.." && pwd -P)"
takeover=0
agent_hint=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --takeover)
      takeover=1
      shift
      ;;
    --agent)
      [[ $# -ge 2 ]] || {
        usage >&2
        exit 2
      }
      agent_hint="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      usage >&2
      exit 2
      ;;
    *)
      [[ -d "$1" ]] || {
        echo "ERROR: project root is not a directory: $1" >&2
        exit 1
      }
      root="$(cd "$1" && pwd -P)"
      shift
      ;;
  esac
done

snapshot_dir="$root/.pps"
snapshot_file="$snapshot_dir/session-snapshot"
mkdir -p "$snapshot_dir"

sha256_of_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  else
    echo "unhashable"
  fi
}

sha256_of_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s' "$1" | openssl dgst -sha256 | awk '{print $NF}'
  else
    echo "unhashable"
  fi
}

# Anchor section extraction: identical shape on both sides of the anchor
# (session_begin writes it, verify_gate compares against it). The hashed text
# is the objective-bearing content only: PROJECT_STATE.md 'Objective' section
# plus CONTEXT.md 'Current Package' section, blank lines dropped.
anchor_section() {
  awk -v title="$1" '
    $0 ~ "^##[[:space:]]+" title "[[:space:]]*$" {inside=1; next}
    inside && /^##[[:space:]]/ {exit}
    inside {print}
  ' "$2"
}
anchor_text() {
  {
    anchor_section "Objective" "$root/PROJECT_STATE.md"
    anchor_section "Current Package" "$root/CONTEXT.md"
  } | sed '/^[[:space:]]*$/d'
}

now_epoch="$(date -u +%s)"
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# A prior snapshot means a previous session may still hold uncommitted work.
# Age does NOT dissolve that claim: an agent relay spans days, so a snapshot
# that "expired" overnight still describes work Git is not protecting. Require
# an explicit takeover whenever a snapshot exists at all, and report its age.
# TTL is configurable but never silently discards the predecessor's claim.
snapshot_ttl_seconds="${PPS_SNAPSHOT_TTL_SECONDS:-604800}"
if [[ -f "$snapshot_file" && "$takeover" != "1" ]]; then
  previous_epoch="$(sed -n 's/^started_epoch:[[:space:]]*//p' "$snapshot_file" | head -n 1)"
  previous_started="$(sed -n 's/^started_at:[[:space:]]*//p' "$snapshot_file" | head -n 1)"
  previous_device="$(sed -n 's/^device:[[:space:]]*//p' "$snapshot_file" | head -n 1)"
  previous_protected="$(sed -n '/^-- dirty --$/,$p' "$snapshot_file" | sed '1d' | sed '/^$/d' |
    awk -F'\t' '{ print $2 }' | sed -n '1,10p' | tr '\n' ',' | sed 's/,$//')"
  if [[ -n "$previous_epoch" ]]; then
    snapshot_age=$(( now_epoch - previous_epoch ))
    if (( snapshot_age < snapshot_ttl_seconds )); then
      echo "ERROR: an unexpired session snapshot already exists (started $previous_started on ${previous_device:-unknown})." >&2
    else
      echo "ERROR: a stale session snapshot exists (started $previous_started on ${previous_device:-unknown}, $(( snapshot_age / 86400 )) day(s) ago)." >&2
      echo "Age does not release the claim: an agent relay spans days, and Git still is not protecting that work." >&2
    fi
    [[ -z "$previous_protected" ]] ||
      echo "Protected paths recorded by that session: $previous_protected" >&2
    echo "Re-run with --takeover to claim the worktree; the takeover is recorded as a relay event automatically." >&2
    exit 3
  fi
fi

# A snapshot taken AFTER the overwrite records the overwriting bytes and can
# never detect the loss. Refuse to snapshot over a predecessor's dirty paths
# whose recorded content no longer matches, unless this is an explicit
# takeover that will be written to the chronicle.
if [[ -f "$snapshot_file" && "$takeover" == "1" ]]; then
  stale_overwrites=""
  while IFS= read -r previous_record; do
    [[ -n "$previous_record" ]] || continue
    previous_path="$(printf '%s' "$previous_record" | awk -F'\t' '{ print $2 }')"
    previous_hash="$(printf '%s' "$previous_record" | awk -F'\t' '{ print $3 }')"
    if [[ -f "$root/$previous_path" ]]; then
      current_previous_hash="$(sha256_of_file "$root/$previous_path")"
    else
      current_previous_hash="absent"
    fi
    [[ "$current_previous_hash" != "$previous_hash" ]] || continue
    stale_overwrites="${stale_overwrites}${previous_path}, "
  done < <(sed -n '/^-- dirty --$/,$p' "$snapshot_file" | sed '1d' | sed '/^$/d')
  if [[ -n "$stale_overwrites" ]]; then
    echo "NOTE: taking over after the following protected paths already changed: ${stale_overwrites%, }"
    echo "The relay event below records that the predecessor's uncommitted bytes are gone."
  fi
fi

device_name="$(hostname 2>/dev/null || echo unknown)"

{
  echo "started_at: $now_iso"
  echo "started_epoch: $now_epoch"
  echo "device: $device_name"
  echo "agent_hint: ${agent_hint:-unspecified}"
  echo "takeover: $takeover"
  if command -v git >/dev/null 2>&1 &&
    git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "head: $(git -C "$root" rev-parse HEAD 2>/dev/null || echo no-commit)"
    echo "git: available"
    echo "-- dirty --"
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
        R* | C*) skip_next=1 ;;
      esac
      if [[ -f "$root/$entry_path" ]]; then
        printf '%s\t%s\t%s\n' "$entry_status" "$entry_path" "$(sha256_of_file "$root/$entry_path")"
      else
        printf '%s\t%s\t%s\n' "$entry_status" "$entry_path" "absent"
      fi
    done < <(git -C "$root" status --porcelain -z --untracked-files=all 2>/dev/null)
  else
    echo "head: no-git"
    echo "git: unavailable"
    echo "-- dirty --"
  fi
} > "$snapshot_file"

dirty_count="$(sed -n '/^-- dirty --$/,$p' "$snapshot_file" | sed '1d' | sed '/^$/d' | wc -l | tr -d '[:space:]')"

# Objective anchor (anti goal-drift): hash the goal-bearing sections now so
# the verify gate can prove later that the objective was not silently
# rewritten mid-session. A goal change without a recorded 'objective-revised'
# event is drift, not progress.
{
  printf 'objective_sha256: %s\n' "$(sha256_of_text "$(anchor_text)")"
  printf 'anchored_at: %s\n' "$now_iso"
} > "$snapshot_dir/objective-anchor"
claimed_paths="$(sed -n '/^-- dirty --$/,$p' "$snapshot_file" | sed '1d' | sed '/^$/d' |
  awk -F'\t' '{ print $2 }')"

echo "== PPS session begin =="
echo "Snapshot: .pps/session-snapshot"
echo "Started: $now_iso on $device_name"
if (( takeover == 1 )); then
  echo "Takeover: yes (record it with scripts/append_event.sh so the relay is visible)"
fi
echo "Protected paths (uncommitted at session start): $dirty_count"
if (( dirty_count > 0 )); then
  sed -n '/^-- dirty --$/,$p' "$snapshot_file" | sed '1d' | sed '/^$/d' |
    awk -F'\t' '{printf "- %s (%s)\n", $2, $1}' | sed -n '1,20p'
  if (( dirty_count > 20 )); then
    echo "- ... $((dirty_count - 20)) more"
  fi
  echo
  echo "These files carry work that Git is not protecting yet."
  echo "Do not overwrite them wholesale; extend them, or discard explicitly with boundary_check --discard-handover PATH."
fi
# A takeover that leaves no trace is exactly the silent relay this lock exists
# to prevent. Write the event here rather than trusting the operator to
# remember; if the chronicle cannot be written, the takeover does not stand.
if (( takeover == 1 )); then
  if [[ -f "$root/scripts/append_event.sh" ]]; then
    takeover_files="$(printf '%s' "$claimed_paths" | sed '/^$/d' | sed -n '1,6p' |
      tr '\n' ',' | sed 's/,$//')"
    [[ -n "$takeover_files" ]] || takeover_files="none"
    if bash "$root/scripts/append_event.sh" "$root" \
      --title "relay takeover claimed the worktree" \
      --files "$takeover_files" \
      --verify "session_begin snapshot recorded" \
      --pending "preserve or discard the protected paths deliberately" >/dev/null 2>&1; then
      echo "Relay event recorded in EVENTS.md."
    else
      echo "ERROR: takeover could not be recorded in EVENTS.md; the relay must stay visible." >&2
      echo "Fix the chronicle (scripts/append_event.sh) and re-run --takeover." >&2
      rm -f "$snapshot_file"
      exit 4
    fi
  else
    echo "ERROR: takeover requires scripts/append_event.sh to record the relay event." >&2
    rm -f "$snapshot_file"
    exit 4
  fi
fi
echo "PPS session begin: OK"

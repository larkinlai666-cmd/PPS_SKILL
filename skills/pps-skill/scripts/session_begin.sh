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

now_epoch="$(date -u +%s)"
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# An unexpired snapshot means another session may still be mid-flight. Do not
# block (a stuck lock is worse than a warning), but require an explicit
# takeover so the handover is visible in the chronicle.
if [[ -f "$snapshot_file" && "$takeover" != "1" ]]; then
  previous_epoch="$(sed -n 's/^started_epoch:[[:space:]]*//p' "$snapshot_file" | head -n 1)"
  previous_started="$(sed -n 's/^started_at:[[:space:]]*//p' "$snapshot_file" | head -n 1)"
  previous_device="$(sed -n 's/^device:[[:space:]]*//p' "$snapshot_file" | head -n 1)"
  if [[ -n "$previous_epoch" ]] && (( now_epoch - previous_epoch < 43200 )); then
    echo "ERROR: an unexpired session snapshot already exists (started $previous_started on ${previous_device:-unknown})." >&2
    echo "Another session may still hold uncommitted work. Re-run with --takeover to claim the worktree;" >&2
    echo "the takeover must then be recorded with scripts/append_event.* so the relay stays visible." >&2
    exit 3
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
echo "PPS session begin: OK"

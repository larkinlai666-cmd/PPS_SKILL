#!/usr/bin/env bash
set -uo pipefail

usage() {
  echo "Usage: append_event.sh [ROOT] --title TEXT [--files LIST] [--verify TEXT] [--pending TEXT]"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$script_dir/.." && pwd -P)"
title=""
files_value="none"
verify_value="none"
pending_value="none"
root_seen=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      title="$2"
      shift 2
      ;;
    --files)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      files_value="$2"
      shift 2
      ;;
    --verify)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      verify_value="$2"
      shift 2
      ;;
    --pending)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      pending_value="$2"
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

[[ -n "$title" ]] || {
  echo "ERROR: --title is required." >&2
  usage >&2
  exit 2
}
case "$title$files_value$verify_value$pending_value" in
  *"|"*)
    echo "ERROR: event segments must not contain the '|' separator character." >&2
    exit 1
    ;;
esac
case "$title$files_value$verify_value$pending_value" in
  *$'\n'* | *$'\r'*)
    echo "ERROR: event segments must be single-line; newlines could forge extra chronicle lines or sections." >&2
    exit 1
    ;;
esac

events_file="$root/EVENTS.md"
[[ -f "$events_file" ]] || {
  echo "ERROR: EVENTS.md not found; this project may predate PPS/1.2." >&2
  exit 1
}
grep -Eq '^##[[:space:]]+Events[[:space:]]*$' "$events_file" || {
  echo "ERROR: EVENTS.md has no '## Events' section." >&2
  exit 1
}

package_id="$(
  awk '
    $0 ~ "^##[[:space:]]+Hot State[[:space:]]*$" { inside=1; next }
    inside && /^##[[:space:]]/ { exit }
    inside && index($0, "- Package:") == 1 {
      sub("^- Package:[[:space:]]*", "")
      print
      exit
    }
  ' "$root/PROJECT_STATE.md"
)"
[[ -n "$package_id" ]] || {
  echo "ERROR: cannot resolve current package from PROJECT_STATE.md." >&2
  exit 1
}

date_value="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
event_line="- ${date_value}: [${package_id}] ${title} | files: ${files_value} | verify: ${verify_value} | pending: ${pending_value}"

# Insert at the end of the '## Events' section, not the end of the file, so
# trailing sections can never silently absorb new events.
tmp_events="$(mktemp "${TMPDIR:-/tmp}/pps-events.XXXXXX")"
awk -v new_event="$event_line" '
  BEGIN { inside = 0; inserted = 0 }
  /^##[[:space:]]+Events[[:space:]]*$/ { inside = 1; print; next }
  inside == 1 && /^##[[:space:]]/ {
    print new_event
    inserted = 1
    inside = 0
  }
  { print }
  END {
    if (inserted == 0) { print new_event }
  }
' "$events_file" > "$tmp_events" && mv "$tmp_events" "$events_file"

line_count="$(wc -l < "$events_file" | tr -d '[:space:]')"
if (( line_count > 200 )); then
  echo "WARNING: EVENTS.md has $line_count lines; archive older months to docs/events-archive/." >&2
fi
echo "Event appended for $package_id."

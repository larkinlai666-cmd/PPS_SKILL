#!/usr/bin/env bash
set -uo pipefail

# Project verification entry. scripts/verify_gate.sh executes this file and
# refuses to write a verify stamp unless it exits 0.
#
# Replace and extend the checks below with the project's real verification:
# unit tests, builds, linters, and at least one behavioral end-to-end
# assertion for software packages. Every check must exit non-zero on failure.
# Keep checks deterministic and bounded. This file must stay a real
# verification entry: an unconditional `exit 0` defeats the gate.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$script_dir/.." && pwd -P)"
if [[ $# -ge 1 && -d "$1" ]]; then
  root="$(cd "$1" && pwd -P)"
fi

failures=0

check() {
  local label="$1"
  shift
  if "$@"; then
    echo "PASS project_verify: $label"
  else
    echo "FAIL project_verify: $label" >&2
    failures=$((failures + 1))
  fi
}

main_rel="$(
  awk '
    $0 ~ "^##[[:space:]]+Hot State[[:space:]]*$" { inside=1; next }
    inside && /^##[[:space:]]/ { exit }
    inside && index($0, "- Main:") == 1 {
      sub("^- Main:[[:space:]]*", "")
      print
      exit
    }
  ' "$root/PROJECT_STATE.md"
)"

main_exists() {
  [[ -n "$main_rel" && -e "$root/$main_rel" ]]
}
events_nonempty() {
  grep -Eq '^- [0-9]{4}-[0-9]{2}-[0-9]{2}: \[PKG-' "$root/EVENTS.md"
}

check "main artifact exists ($main_rel)" main_exists
check "EVENTS.md records at least one event" events_nonempty

# Add project-specific checks here, for example:
#   check "unit tests" npm test
#   check "e2e smoke" node scripts/e2e-smoke.js

if (( failures > 0 )); then
  echo "project_verify: FAILED ($failures check(s))" >&2
  exit 1
fi
echo "project_verify: OK"

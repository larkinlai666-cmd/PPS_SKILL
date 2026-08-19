#!/usr/bin/env bash
set -uo pipefail

usage() {
  echo "Usage: verify_gate.sh [ROOT]"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$script_dir/.." && pwd -P)"
if [[ $# -gt 1 ]]; then
  usage >&2
  exit 2
fi
if [[ $# -eq 1 ]]; then
  case "$1" in
    -*)
      usage >&2
      exit 2
      ;;
  esac
  [[ -d "$1" ]] || {
    echo "ERROR: project root is not a directory: $1" >&2
    exit 1
  }
  root="$(cd "$1" && pwd -P)"
fi

echo "== PPS verify gate =="

echo "-- Step 1/3: structural validation"
if ! bash "$root/scripts/validate_project.sh" "$root" --quiet; then
  echo "PPS verify gate: FAILED (structural validation)" >&2
  exit 1
fi
echo "structural validation: pass"

echo "-- Step 2/3: project checks"
# Add ordered project-specific checks below. Each check must exit non-zero on
# failure. Keep them deterministic and bounded. Include at least one
# behavioral assertion (user-visible end-to-end smoke check) for software
# packages: unit-green does not prove the wired system works, and a deployed
# file is not necessarily a loaded file.
#
# Example:
#   npm test -- app || exit 1
#   node scripts/e2e-smoke.js || exit 1
echo "project checks: none declared yet (extend this script)"

echo "-- Step 3/3: recording verify stamp"
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
if [[ -z "$package_id" ]]; then
  echo "PPS verify gate: FAILED (cannot resolve current package)" >&2
  exit 1
fi
mkdir -p "$root/.pps"
{
  printf 'package: %s\n' "$package_id"
  printf 'verified_at: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$root/.pps/verify-stamp"
echo "verify stamp: $package_id"
echo "PPS verify gate: OK"

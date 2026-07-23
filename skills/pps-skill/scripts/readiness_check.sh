#!/usr/bin/env bash
set -uo pipefail

usage() {
  echo "Usage: readiness_check.sh [ROOT] [--verified]"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$script_dir/.." && pwd -P)"
root_seen=0
verified=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verified) verified=1; shift ;;
    -*)
      usage >&2
      exit 2
      ;;
    *)
      (( root_seen == 0 )) || {
        usage >&2
        exit 2
      }
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

if ! bash "$root/scripts/validate_project.sh" "$root"; then
  echo "PPS readiness: STRUCTURE FAILED" >&2
  exit 1
fi
if ! bash "$root/scripts/asset_check.sh" "$root" --handoff --risk; then
  echo "PPS readiness: ASSET HANDOFF FAILED" >&2
  exit 1
fi

verify="$(
  awk '
    /^## Workset Manifest[[:space:]]*$/ { inside=1; next }
    inside && /^## / { exit }
    inside && /^-[[:space:]]*Verify:[[:space:]]*/ {
      sub("^-+[[:space:]]*Verify:[[:space:]]*", "")
      print
      exit
    }
  ' "$root/CONTEXT.md"
)"
environment_verify="$(
  awk '
    /^## Project Commands[[:space:]]*$/ { inside=1; next }
    inside && /^## / { exit }
    inside && /^-[[:space:]]*Environment verify:[[:space:]]*/ {
      sub("^-+[[:space:]]*Environment verify:[[:space:]]*", "")
      print
      exit
    }
  ' "$root/ENVIRONMENT.md"
)"
environment_verify="${environment_verify:-none}"
echo "Declared environment Verify: $environment_verify"
echo "Declared project Verify: $verify"
if (( verified == 0 )); then
  echo "PPS readiness: VERIFY PENDING"
  echo "Inspect and run the declared project verification, then rerun with --verified only after it passes."
  exit 3
fi
echo "Verification attestation: caller confirmed the declared environment and project checks passed."
echo "PPS readiness: OK"

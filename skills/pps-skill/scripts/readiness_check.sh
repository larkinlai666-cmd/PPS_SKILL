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
protocol="$(
  awk '
    /^## Hot State[[:space:]]*$/ { inside=1; next }
    inside && /^## / { exit }
    inside && /^-[[:space:]]*Protocol:[[:space:]]*/ {
      sub("^-+[[:space:]]*Protocol:[[:space:]]*", "")
      print
      exit
    }
  ' "$root/PROJECT_STATE.md"
)"
if [[ "$protocol" == "PPS/1.2" ]]; then
  package_id="$(
    awk '
      /^## Hot State[[:space:]]*$/ { inside=1; next }
      inside && /^## / { exit }
      inside && /^-[[:space:]]*Package:[[:space:]]*/ {
        sub("^-+[[:space:]]*Package:[[:space:]]*", "")
        print
        exit
      }
    ' "$root/PROJECT_STATE.md"
  )"
  stamp_file="$root/.pps/verify-stamp"
  if [[ ! -f "$stamp_file" ]]; then
    echo "PPS readiness: VERIFY EVIDENCE MISSING" >&2
    echo "No verify stamp found; run scripts/verify_gate.* on this device first." >&2
    exit 4
  fi
  stamp_package="$(sed -n 's/^package:[[:space:]]*//p' "$stamp_file" | head -n 1)"
  if [[ "$stamp_package" != "$package_id" ]]; then
    echo "PPS readiness: VERIFY EVIDENCE STALE" >&2
    echo "Verify stamp names '$stamp_package' but the current package is '$package_id'; rerun scripts/verify_gate.*." >&2
    exit 4
  fi
  echo "Verify stamp: $stamp_package ($(sed -n 's/^verified_at:[[:space:]]*//p' "$stamp_file" | head -n 1))"
fi
echo "Verification attestation: caller confirmed the declared environment and project checks passed."
echo "PPS readiness: OK"

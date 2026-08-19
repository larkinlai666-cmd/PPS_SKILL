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
  stamp_field() {
    sed -n "s/^$1:[[:space:]]*//p" "$stamp_file" | head -n 1
  }
  stamp_package="$(stamp_field package)"
  stamp_entry="$(stamp_field entry)"
  stamp_entry_sha="$(stamp_field entry_sha256)"
  stamp_result="$(stamp_field result)"
  stamp_worktree="$(stamp_field worktree)"
  stamp_time="$(stamp_field verified_at)"
  reject_stale() {
    echo "PPS readiness: VERIFY EVIDENCE STALE" >&2
    echo "$1" >&2
    echo "Rerun scripts/verify_gate.* on this device." >&2
    exit 4
  }
  [[ "$stamp_package" == "$package_id" ]] ||
    reject_stale "Verify stamp names '$stamp_package' but the current package is '$package_id'."
  [[ "$stamp_result" == "pass" ]] ||
    reject_stale "Verify stamp records result '$stamp_result', not 'pass'."
  [[ -n "$stamp_entry" && -f "$root/$stamp_entry" ]] ||
    reject_stale "Verify stamp names entry '$stamp_entry' which does not exist."
  if command -v shasum >/dev/null 2>&1; then
    current_entry_sha="$(shasum -a 256 "$root/$stamp_entry" | awk '{print $1}')"
  else
    current_entry_sha="$(sha256sum "$root/$stamp_entry" | awk '{print $1}')"
  fi
  [[ "$stamp_entry_sha" == "$current_entry_sha" ]] ||
    reject_stale "Verification entry '$stamp_entry' changed after the stamp was written."
  if command -v git >/dev/null 2>&1 &&
    git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    head_sha="$(git -C "$root" rev-parse HEAD 2>/dev/null || echo 'no-commit')"
    porcelain="$(git -C "$root" status --porcelain --untracked-files=all 2>/dev/null || true)"
    if command -v shasum >/dev/null 2>&1; then
      porcelain_sha="$(printf '%s' "$porcelain" | shasum -a 256 | awk '{print $1}')"
    else
      porcelain_sha="$(printf '%s' "$porcelain" | sha256sum | awk '{print $1}')"
    fi
    current_worktree="${head_sha}+${porcelain_sha}"
    [[ "$stamp_worktree" == "$current_worktree" ]] ||
      reject_stale "The worktree changed after the stamp was written; the verified state is not the current state."
  fi
  echo "Verify stamp: $stamp_package ($stamp_time, entry $stamp_entry)"
fi
echo "Verification attestation: caller confirmed the declared environment and project checks passed."
echo "PPS readiness: OK"

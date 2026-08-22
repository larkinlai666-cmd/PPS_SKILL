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
  for stamp_field_name in package entry entry_sha256 capsule_sha256 manifest_sha256 run_sha256 platform result worktree verified_at; do
    stamp_field_count="$(grep -c "^${stamp_field_name}:" "$stamp_file" || true)"
    if [[ "$stamp_field_count" != "1" ]]; then
      echo "PPS readiness: VERIFY EVIDENCE STALE" >&2
      echo "Verify stamp declares the '$stamp_field_name' field $stamp_field_count times; an ambiguous stamp is not evidence. Rerun scripts/verify_gate.* on this device." >&2
      exit 4
    fi
  done
  stamp_package="$(stamp_field package)"
  stamp_entry="$(stamp_field entry)"
  stamp_entry_sha="$(stamp_field entry_sha256)"
  stamp_capsule_sha="$(stamp_field capsule_sha256)"
  stamp_platform="$(stamp_field platform)"
  stamp_result="$(stamp_field result)"
  stamp_worktree="$(stamp_field worktree)"
  stamp_time="$(stamp_field verified_at)"
  reject_stale() {
    echo "PPS readiness: VERIFY EVIDENCE STALE" >&2
    echo "$1" >&2
    echo "Rerun scripts/verify_gate.* on this device." >&2
    exit 4
  }
  sha256_of_file() {
    if command -v shasum >/dev/null 2>&1; then
      shasum -a 256 "$1" | awk '{print $1}'
    else
      sha256sum "$1" | awk '{print $1}'
    fi
  }
  sha256_of_string() {
    if command -v shasum >/dev/null 2>&1; then
      printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
    else
      printf '%s' "$1" | sha256sum | awk '{print $1}'
    fi
  }
  for required_stamp_field in \
    "package:$stamp_package" "entry:$stamp_entry" \
    "entry_sha256:$stamp_entry_sha" "capsule_sha256:$stamp_capsule_sha" \
    "manifest_sha256:$(stamp_field manifest_sha256)" "run_sha256:$(stamp_field run_sha256)" \
    "platform:$stamp_platform" "result:$stamp_result" \
    "worktree:$stamp_worktree" "verified_at:$stamp_time"; do
    [[ -n "${required_stamp_field#*:}" ]] ||
      reject_stale "Verify stamp is missing the '${required_stamp_field%%:*}' field; only the current gate writes complete stamps."
  done
  [[ "$stamp_package" == "$package_id" ]] ||
    reject_stale "Verify stamp names '$stamp_package' but the current package is '$package_id'."
  [[ "$stamp_result" == "pass" ]] ||
    reject_stale "Verify stamp records result '$stamp_result', not 'pass'."
  case "$stamp_platform" in
    bash|powershell) ;;
    *) reject_stale "Verify stamp records unknown platform '$stamp_platform'." ;;
  esac
  [[ -n "$stamp_entry" && -f "$root/$stamp_entry" ]] ||
    reject_stale "Verify stamp names entry '$stamp_entry' which does not exist."
  current_entry_sha="$(sha256_of_file "$root/$stamp_entry")"
  [[ "$stamp_entry_sha" == "$current_entry_sha" ]] ||
    reject_stale "Verification entry '$stamp_entry' changed after the stamp was written."
  current_capsule_sha="$(sha256_of_file "$root/CONTEXT.md")"
  [[ "$stamp_capsule_sha" == "$current_capsule_sha" ]] ||
    reject_stale "CONTEXT.md changed after the stamp was written; the verified capsule is not the current capsule."
  if command -v git >/dev/null 2>&1 &&
    git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    head_sha="$(git -C "$root" rev-parse HEAD 2>/dev/null || echo 'no-commit')"
    worktree_entries=""
    skip_next=0
    while IFS= read -r -d '' status_entry; do
      if (( skip_next == 1 )); then
        skip_next=0
        continue
      fi
      [[ "${#status_entry}" -gt 3 ]] || continue
      entry_status="${status_entry:0:2}"
      entry_path="${status_entry:3}"
      case "$entry_status" in
        R*|C*) skip_next=1 ;;
      esac
      if [[ -f "$root/$entry_path" ]]; then
        content_hash="$(sha256_of_file "$root/$entry_path")"
      else
        content_hash="absent"
      fi
      worktree_entries="${worktree_entries}${entry_status}"$'\t'"${entry_path}"$'\t'"${content_hash}"$'\n'
    done < <(git -C "$root" status --porcelain -z --untracked-files=all 2>/dev/null)
    worktree_entries="$(printf '%s' "$worktree_entries" | LC_ALL=C sort)"
    current_worktree="${head_sha}+$(sha256_of_string "$worktree_entries")"
    [[ "$stamp_worktree" == "$current_worktree" ]] ||
      reject_stale "The worktree content changed after the stamp was written; the verified state is not the current state."
  else
    # A stamp minted inside a Git worktree is only meaningful inside that
    # worktree. Losing .git after stamping destroys the identity the stamp
    # was bound to.
    [[ "$stamp_worktree" == "no-git" ]] ||
      reject_stale "The stamp was written inside a Git worktree but this directory is no longer one; the stamped identity cannot be re-checked."
  fi
  echo "Verify stamp: $stamp_package ($stamp_time, entry $stamp_entry)"
fi
echo "Verification attestation: caller confirmed the declared environment and project checks passed."
echo "PPS readiness: OK"

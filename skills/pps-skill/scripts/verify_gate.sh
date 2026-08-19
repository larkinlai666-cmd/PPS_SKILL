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

# Any previous stamp is invalid the moment a new verification starts. A failed
# run must never leave behind a stamp that readiness could accept.
rm -f "$root/.pps/verify-stamp"

echo "-- Step 1/4: structural validation"
if ! bash "$root/scripts/validate_project.sh" "$root" --quiet; then
  echo "PPS verify gate: FAILED (structural validation)" >&2
  exit 1
fi
echo "structural validation: pass"

echo "-- Step 2/4: Verify declaration routing"
verify_decl="$(
  awk '
    $0 ~ "^##[[:space:]]+Workset Manifest[[:space:]]*$" { inside=1; next }
    inside && /^##[[:space:]]/ { exit }
    inside && index($0, "- Verify:") == 1 {
      sub("^- Verify:[[:space:]]*", "")
      print
      exit
    }
  ' "$root/CONTEXT.md"
)"
if ! printf '%s' "$verify_decl" | grep -Eq 'scripts/(verify_gate|project_verify)'; then
  echo "ERROR: the Workset Verify declaration must route through scripts/verify_gate.* (which executes scripts/project_verify.*)." >&2
  echo "Found unrouted declaration: $verify_decl" >&2
  echo "Put the actual commands into scripts/project_verify.*; the gate never passes free-form Markdown text to a shell." >&2
  echo "PPS verify gate: FAILED (unrouted Verify declaration)" >&2
  exit 1
fi
echo "Verify routing: declaration routes through the gate entry"

echo "-- Step 3/4: project verification entry"
entry_rel="scripts/project_verify.sh"
entry="$root/$entry_rel"
if [[ ! -f "$entry" ]]; then
  echo "ERROR: missing project verification entry: $entry_rel" >&2
  echo "PPS verify gate: FAILED (missing project_verify)" >&2
  exit 1
fi
if bash "$entry" "$root"; then
  echo "project verification: pass"
else
  entry_code=$?
  echo "project verification: FAILED (exit $entry_code)" >&2
  echo "PPS verify gate: FAILED (project verification)" >&2
  exit 1
fi

echo "-- Step 4/4: recording verify stamp"
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

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}
sha256_of_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

entry_sha="$(sha256_of "$entry")"
capsule_sha="$(sha256_of "$root/CONTEXT.md")"
if command -v git >/dev/null 2>&1 &&
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  head_sha="$(git -C "$root" rev-parse HEAD 2>/dev/null || echo 'no-commit')"
  porcelain="$(git -C "$root" status --porcelain --untracked-files=all 2>/dev/null || true)"
  worktree_id="${head_sha}+$(sha256_of_text "$porcelain")"
else
  worktree_id="no-git"
fi

mkdir -p "$root/.pps"
{
  printf 'package: %s\n' "$package_id"
  printf 'entry: %s\n' "$entry_rel"
  printf 'entry_sha256: %s\n' "$entry_sha"
  printf 'capsule_sha256: %s\n' "$capsule_sha"
  printf 'platform: bash\n'
  printf 'result: pass\n'
  printf 'worktree: %s\n' "$worktree_id"
  printf 'verified_at: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$root/.pps/verify-stamp"
echo "verify stamp: $package_id"
echo "PPS verify gate: OK"

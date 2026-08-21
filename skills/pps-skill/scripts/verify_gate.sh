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

echo "-- Step 2b/4: gate substance"
verify_entry="$root/scripts/project_verify.sh"
[[ -f "$verify_entry" ]] || {
  echo "ERROR: missing verification entry: scripts/project_verify.sh" >&2
  echo "PPS verify gate: FAILED (missing verification entry)" >&2
  exit 1
}
# A gate that executes an empty entry proves execution of nothing. Refuse the
# hollow entry outright: this is the "knowing is not doing" failure the stamp
# exists to prevent.
substantive_lines="$(grep -vE '^[[:space:]]*(#|$)' "$verify_entry" |
  grep -vE '^[[:space:]]*(exit[[:space:]]+0|true|:)[[:space:]]*$' |
  grep -vE '^[[:space:]]*echo[[:space:]]' | wc -l | tr -d '[:space:]')"
if ! grep -Eq '(^|[^[:alnum:]_])check[[:space:]]+"' "$verify_entry" ||
  (( substantive_lines < 5 )); then
  echo "ERROR: scripts/project_verify.sh has no real checks; an unconditional 'exit 0' or an echo-only entry defeats the gate." >&2
  echo "Declare at least one check that fails non-zero when the project is broken." >&2
  echo "PPS verify gate: FAILED (hollow verification entry)" >&2
  exit 1
fi
mode_value="$(
  awk '
    $0 ~ "^##[[:space:]]+Hot State[[:space:]]*$" { inside=1; next }
    inside && /^##[[:space:]]/ { exit }
    inside && index($0, "- Mode:") == 1 {
      sub("^- Mode:[[:space:]]*", "")
      print
      exit
    }
  ' "$root/PROJECT_STATE.md"
)"
case "$mode_value" in
  software | hybrid)
    # Unit tests can pass while the caller path is broken: a software package
    # needs at least one check that is not the structural validator itself.
    behavioral_checks="$(grep -E '(^|[^[:alnum:]_])check[[:space:]]+"' "$verify_entry" |
      grep -vE 'validate_project|validate_skill' | wc -l | tr -d '[:space:]')"
    if (( behavioral_checks < 1 )); then
      echo "ERROR: software package needs a behavioral check: scripts/project_verify.sh declares only structural validation." >&2
      echo "Add at least one check that exercises the product the way a user reaches it." >&2
      echo "PPS verify gate: FAILED (no behavioral check)" >&2
      exit 1
    fi
    ;;
esac
echo "gate substance: entry declares real checks"

echo "-- Step 2c/4: red line wiring"
# Red lines may name the check that enforces them: "(verify: path)". When a
# red line names one, the gate entry must actually reference that path, or the
# red line is a wish rather than a rule.
redline_targets=""
if [[ -f "$root/AGENTS.md" ]]; then
  redline_targets="$(
    awk '
      $0 ~ "^##[[:space:]]+Red Lines[[:space:]]*$" { inside=1; next }
      inside && /^##[[:space:]]/ { exit }
      inside { print }
    ' "$root/AGENTS.md" | grep -Eo '\(verify:[[:space:]]*[^)]+\)' |
      sed -E 's/^\(verify:[[:space:]]*//; s/\)$//' |
      sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d' | sort -u
  )"
fi
if [[ -n "$redline_targets" ]]; then
  manifest_file="$root/.pps/verify-manifest.txt"
  redline_unwired=0
  while IFS= read -r redline_target; do
    [[ -n "$redline_target" ]] || continue
    if grep -Fq "$redline_target" "$verify_entry"; then
      continue
    fi
    if [[ -f "$manifest_file" ]] && grep -Fq "$redline_target" "$manifest_file" &&
      grep -Fq "verify-manifest" "$verify_entry"; then
      continue
    fi
    echo "ERROR: red line names '(verify: $redline_target)' but scripts/project_verify.sh does not reference it." >&2
    redline_unwired=1
  done <<< "$redline_targets"
  if (( redline_unwired == 1 )); then
    echo "Wire the named check into the gate entry (or list it in .pps/verify-manifest.txt and read that manifest)." >&2
    echo "PPS verify gate: FAILED (red line not wired to the gate)" >&2
    exit 1
  fi
  echo "red line wiring: all named checks are wired into the gate entry"
else
  echo "red line wiring: no red line names a machine check (human-only red lines are allowed)"
fi

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

worktree_content_id() {
  # Content-level fingerprint: HEAD plus, for every changed path, its status
  # AND the SHA-256 of its current bytes. Porcelain is parsed in -z form so
  # quoted/escaped paths (CJK, spaces, quotes) resolve to real files instead
  # of silently hashing as absent.
  local head_sha entries entry entry_status entry_path content_hash skip_next
  head_sha="$(git -C "$root" rev-parse HEAD 2>/dev/null || echo 'no-commit')"
  entries=""
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
      R*|C*) skip_next=1 ;;
    esac
    if [[ -f "$root/$entry_path" ]]; then
      content_hash="$(sha256_of "$root/$entry_path")"
    else
      content_hash="absent"
    fi
    entries="${entries}${entry_status}"$'\t'"${entry_path}"$'\t'"${content_hash}"$'\n'
  done < <(git -C "$root" status --porcelain -z --untracked-files=all 2>/dev/null)
  entries="$(printf '%s' "$entries" | LC_ALL=C sort)"
  printf '%s+%s' "$head_sha" "$(sha256_of_text "$entries")"
}

if command -v git >/dev/null 2>&1 &&
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  worktree_id="$(worktree_content_id)"
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

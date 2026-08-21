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

# A mention is not a call. Grepping the whole file lets a comment satisfy the
# wiring requirement, which is the same "keyword matching pretends to be
# parsing" defect already closed in the receipt layer. Only uncommented lines
# that look like an invocation count.
entry_invokes_path() {
  local entry_file="$1"
  local wanted="$2"
  awk -v wanted="$wanted" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^#/) next
      # Strip a trailing comment so "cmd foo.sh # see bar.sh" cannot claim bar.
      hash = index(line, "#")
      if (hash > 0) line = substr(line, 1, hash - 1)
      if (index(line, wanted) == 0) next
      if (line ~ /(^|[^[:alnum:]_])(check|Invoke-Check|bash|sh|pwsh|powershell|python3?|node|npm|npx|source|\.)[[:space:]]/ ||
          line ~ /^&[[:space:]]/ || line ~ /[|&;][[:space:]]*[^[:space:]]/ ||
          line ~ /\$\(/ || line ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)/) {
        found = 1
        exit
      }
    }
    END { exit found ? 0 : 1 }
  ' "$entry_file"
}

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
    # An always-true script block satisfies a lexical "has a check" rule while
    # asserting nothing. Require the behavioral check to name a real artifact
    # in the project: a test file, a probe, or the product entry point.
    behavioral_paths="$(awk '
      {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        if (line ~ /^#/) next
        hash = index(line, "#")
        if (hash > 0) line = substr(line, 1, hash - 1)
        if (line !~ /(^|[^[:alnum:]_])check[[:space:]]/) next
        # The template ships structural self-checks (the state files exist,
        # the chronicle is non-empty). Those are PPS bookkeeping, not evidence
        # that the product works, so they never count as behavioral.
        if (line ~ /validate_project|validate_skill/) next
        if (line ~ /PROJECT_STATE|EVENTS\.md|DECISIONS|CONTEXT\.md|PROJECT_MAP|TASK_INDEX|MERGES|coverage/) next
        if (line ~ /main artifact exists/) next
        print line
      }
    ' "$verify_entry")"
    behavioral_real=0
    if [[ -n "$behavioral_paths" ]]; then
      while IFS= read -r behavioral_line; do
        [[ -n "$behavioral_line" ]] || continue
        # A path in the LABEL proves nothing: the label is documentation. Only
        # the executable part of the line (after the quoted label) and the body
        # of the helper it calls can carry the assertion.
        behavioral_exec="$(printf '%s\n' "$behavioral_line" |
          sed -E 's/^[^"]*"[^"]*"//')"
        while IFS= read -r behavioral_ref; do
          [[ -n "$behavioral_ref" ]] || continue
          if [[ -e "$root/$behavioral_ref" ]]; then
            behavioral_real=1
            break 2
          fi
        done < <(printf '%s\n' "$behavioral_exec" |
          grep -Eo '[A-Za-z0-9_][A-Za-z0-9_./-]*\.[A-Za-z0-9]+' | sed 's/^\.\///' |
          sed -E 's#^(root|rootFull|PSScriptRoot|projectRoot|repo|repoRoot)/##' |
          grep -vE '^(PROJECT_STATE|EVENTS|DECISIONS|CONTEXT|PROJECT_MAP|TASK_INDEX|MERGES|ASSETS|ENVIRONMENT|SOURCE_INDEX|AGENTS)\.md$')
        # A named helper function counts when its body references a real path.
        helper_name="$(printf '%s\n' "$behavioral_exec" |
          grep -Eo '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*' | tr -d '[:space:]')"
        if [[ -n "$helper_name" && "$helper_name" != "$behavioral_line" ]]; then
          # Helpers are written both ways: a one-liner (`fn() { cmd; }`) and a
          # multi-line block. Read the definition line itself plus any body.
          helper_body="$(awk -v fn="$helper_name" '
            index($0, fn "()") == 1 {
              print
              if ($0 ~ /\}[[:space:]]*$/) exit
              inside = 1
              next
            }
            inside && /^\}/ { exit }
            inside { print }
          ' "$verify_entry")"
          while IFS= read -r helper_ref; do
            [[ -n "$helper_ref" ]] || continue
            if [[ -e "$root/$helper_ref" ]]; then
              behavioral_real=1
              break 2
            fi
          done < <(printf '%s\n' "$helper_body" |
            grep -Eo '[A-Za-z0-9_][A-Za-z0-9_./-]*\.[A-Za-z0-9]+' | sed 's/^\.\///' |
            sed -E 's#^(root|rootFull|PSScriptRoot|projectRoot|repo|repoRoot)/##' |
          grep -vE '^(PROJECT_STATE|EVENTS|DECISIONS|CONTEXT|PROJECT_MAP|TASK_INDEX|MERGES|ASSETS|ENVIRONMENT|SOURCE_INDEX|AGENTS)\.md$')
        fi
      done <<< "$behavioral_paths"
    fi
    if [[ -z "$behavioral_paths" ]]; then
      echo "ERROR: software package needs a behavioral check: scripts/project_verify.sh declares only structural validation." >&2
      echo "Add at least one check that exercises the product the way a user reaches it." >&2
      echo "PPS verify gate: FAILED (no behavioral check)" >&2
      exit 1
    fi
    if (( behavioral_real == 0 )); then
      echo "ERROR: the behavioral check in scripts/project_verify.sh names no real project artifact; an always-true assertion checks nothing." >&2
      echo "Point the check at a test file, probe, or product entry point that exists in the project." >&2
      echo "PPS verify gate: FAILED (behavioral check asserts nothing)" >&2
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
    if entry_invokes_path "$verify_entry" "$redline_target"; then
      continue
    fi
    if [[ -f "$manifest_file" ]] && grep -Fq "$redline_target" "$manifest_file" &&
      entry_invokes_path "$verify_entry" "verify-manifest"; then
      continue
    fi
    echo "ERROR: red line names '(verify: $redline_target)' but scripts/project_verify.sh never calls it (a mention in a comment does not count)." >&2
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

echo "-- Step 2d/4: relay handover lock"
# The lock must be on the completion path, not in an optional script nobody
# runs. Close is "gate + readiness"; if the gate never consults the handover
# snapshot, the predecessor's uncommitted work can vanish silently and the
# stamp will still claim the package was verified.
snapshot_path="$root/.pps/session-snapshot"
if [[ ! -f "$snapshot_path" ]]; then
  case "$mode_value" in
    software | hybrid)
      echo "Relay: SNAPSHOT MISSING; run scripts/session_begin.sh before writing." >&2
      echo "Without a session snapshot the gate cannot prove this session did not overwrite uncommitted handover work." >&2
      echo "PPS verify gate: FAILED (Relay: SNAPSHOT MISSING)" >&2
      exit 1
      ;;
    *)
      echo "Relay: SNAPSHOT MISSING; run scripts/session_begin.sh before writing (warning in $mode_value mode)."
      ;;
  esac
fi
if [[ -f "$root/scripts/boundary_check.sh" ]]; then
  boundary_args=("$root")
  # A single-task project has one canonical subject; a multitask project
  # routes through the Hot State Writer.
  writer_task="$(
    awk '
      $0 ~ "^##[[:space:]]+Hot State[[:space:]]*$" { inside=1; next }
      inside && /^##[[:space:]]/ { exit }
      inside && index($0, "- Writer:") == 1 {
        sub("^- Writer:[[:space:]]*", "")
        print
        exit
      }
    ' "$root/PROJECT_STATE.md"
  )"
  if [[ -n "$writer_task" && "$writer_task" != "none" ]]; then
    boundary_args+=(--task "$writer_task")
  fi
  if [[ -f "$root/.pps/boundary-baseline" ]]; then
    boundary_args+=(--allow-preexisting)
  fi
  boundary_output="$(bash "$root/scripts/boundary_check.sh" "${boundary_args[@]}" 2>&1)"
  boundary_code=$?
  if printf '%s\n' "$boundary_output" | grep -q 'protected_overwrite:'; then
    printf '%s\n' "$boundary_output" | grep 'protected_overwrite:' >&2
    echo "PPS verify gate: FAILED (protected_overwrite: handover work was overwritten)" >&2
    exit 1
  fi
  if (( boundary_code != 0 )); then
    # Unclaimed writes are a boundary-discipline problem, not a handover loss.
    # Surface them, but keep the gate's hard failure scoped to the thing Git
    # cannot recover: a predecessor's overwritten uncommitted work. Widening
    # the gate into full boundary enforcement would make it unusable mid-work
    # and push agents back to skipping it.
    printf '%s\n' "$boundary_output" | grep -E 'unclaimed_write:' | sed -n '1,20p' >&2
    echo "WARNING: the worktree contains changes no Write set claims; run scripts/boundary_check.sh and claim or revert them." >&2
  fi
  echo "relay handover lock: no protected path was overwritten"
else
  echo "relay handover lock: boundary_check.sh unavailable; cannot verify handover safety" >&2
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

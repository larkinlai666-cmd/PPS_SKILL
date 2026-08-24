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

# F-050-02: Python 3 is a hard runtime for the evidence engine. Windows
# frequently has python/py but not python3, and the Store python3.exe stub is
# not an interpreter. Discovery order: PPS_PYTHON -> python3 -> python -> py -3.
resolve_python3() {
  local cand
  if [[ -n "${PPS_PYTHON:-}" ]] &&
    "$PPS_PYTHON" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
    printf '%s\n' "$PPS_PYTHON"
    return 0
  fi
  for cand in python3 python; do
    if command -v "$cand" >/dev/null 2>&1 &&
      "$cand" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  if command -v py >/dev/null 2>&1 &&
    py -3 -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
    printf '%s\n' "py -3"
    return 0
  fi
  return 1
}
if ! python3_bin="$(resolve_python3)"; then
  echo "ERROR: the PPS evidence engine requires Python 3. Tried: python3, python, py -3. Install Python 3 or set PPS_PYTHON to the interpreter path." >&2
  echo "PPS verify gate: FAILED (python 3 interpreter required)" >&2
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

# Any previous stamp is invalid the moment a new verification starts. A failed
# run must never leave behind a stamp that readiness could accept.
rm -f "$root/.pps/verify-stamp"

# Anchor section extraction: the same shape as session_begin's anchor so the
# two sides hash identical text. Objective + Current Package, blank lines
# dropped. A rewrite here is what the anti-drift comparison detects.
anchor_section() {
  awk -v title="$1" '
    $0 ~ "^##[[:space:]]+" title "[[:space:]]*$" {inside=1; next}
    inside && /^##[[:space:]]/ {exit}
    inside {print}
  ' "$2"
}
anchor_text_value="$(
  {
    anchor_section "Objective" "$root/PROJECT_STATE.md"
    anchor_section "Current Package" "$root/CONTEXT.md"
  } | sed '/^[[:space:]]*$/d'
)"
anchor_current_hash="$(sha256_of_text "$anchor_text_value")"

echo "-- Step 0/4: objective anchor review"
# The anchor review is the anti-drift ritual: every gate run re-surfaces the
# objective, the red lines, and the active decisions before anything is
# stamped. PPS is a protocol; its cure for context rot is a forced re-read
# at the only checkpoint that cannot be skipped: the gate.
echo "--- anchored objective ---"
printf '%s\n' "$anchor_text_value" | sed -n '1,12p'
if [[ -f "$root/AGENTS.md" ]]; then
  echo "--- red lines ---"
  anchor_section "Red Lines" "$root/AGENTS.md" | sed '/^[[:space:]]*$/d' | sed -n '1,12p'
fi
if [[ -f "$root/DECISIONS.md" ]]; then
  echo "--- active decisions ---"
  awk '
    /<!-- PPS:ACTIVE:BEGIN -->/ {inside=1; next}
    /<!-- PPS:ACTIVE:END -->/ {inside=0; next}
    inside {print}
  ' "$root/DECISIONS.md" | grep -Eo '[MFD]-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?' |
    sort -u | sed -n '1,12p'
fi

# Goal-drift comparison: the objective-bearing sections must match the
# session-start anchor. A change is legitimate only when the chronicle says
# so, because "the goal moved while nobody recorded it" is exactly the drift
# this anchor exists to catch.
anchor_mode_value="$(
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
stage_value="$(
  awk '
    $0 ~ "^##[[:space:]]+Hot State[[:space:]]*$" { inside=1; next }
    inside && /^##[[:space:]]/ { exit }
    inside && index($0, "- Stage:") == 1 {
      sub("^- Stage:[[:space:]]*", "")
      print
      exit
    }
  ' "$root/PROJECT_STATE.md"
)"
anchor_path="$root/.pps/objective-anchor"
if [[ -f "$anchor_path" ]]; then
  anchored_hash="$(sed -n 's/^objective_sha256:[[:space:]]*//p' "$anchor_path" | head -n 1)"
  anchored_at="$(sed -n 's/^anchored_at:[[:space:]]*//p' "$anchor_path" | head -n 1)"
  if [[ -n "$anchored_hash" && "$anchored_hash" != "$anchor_current_hash" ]]; then
    revised_events=""
    if [[ -f "$root/EVENTS.md" ]]; then
      revised_events="$(awk -v anchor="$anchored_at" '
        function stamp_of(line,    body, colon) {
          body = substr(line, 3)
          colon = index(body, ": ")
          if (colon == 0) return ""
          return substr(body, 1, colon - 1)
        }
        $0 ~ "^##[[:space:]]+Events[[:space:]]*$" { inside=1; next }
        inside && /^##[[:space:]]/ { exit }
        inside && /^- / {
          event_ts = stamp_of($0)
          if (event_ts == "") next
          # A migrated PPS/1.1 chronicle carries calendar-day lines while 1.2
          # writes full ISO stamps. Compare on the shorter precision so a
          # legitimate revision recorded in either grammar still counts.
          n = length(event_ts) < length(anchor) ? length(event_ts) : length(anchor)
          if (substr(event_ts, 1, n) >= substr(anchor, 1, n) &&
              $0 ~ /\[[^]]+\][[:space:]]+(objective-revised|goal-revised)[[:space:]]*([:|])/) print
        }
      ' "$root/EVENTS.md")"
    fi
    if [[ -n "$revised_events" ]]; then
      {
        printf 'objective_sha256: %s\n' "$anchor_current_hash"
        printf 'anchored_at: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      } > "$anchor_path"
      echo "objective anchor: revised via a recorded objective-revised event; anchor refreshed"
    else
      echo "ERROR: the objective-bearing sections changed since session_begin but no 'objective-revised' event records the change." >&2
      echo "Record the revision with scripts/append_event.sh --title 'objective-revised ...' or restore the anchored objective." >&2
      echo "PPS verify gate: FAILED (objective anchor mismatch)" >&2
      exit 1
    fi
  else
    echo "objective anchor: unchanged since session begin"
  fi
else
  case "$anchor_mode_value" in
    software | hybrid)
      echo "ERROR: .pps/objective-anchor is missing; run scripts/session_begin.sh before writing." >&2
      echo "Without the anchor the gate cannot prove the objective was not rewritten mid-session." >&2
      echo "PPS verify gate: FAILED (OBJECTIVE ANCHOR MISSING)" >&2
      exit 1
      ;;
    *)
      echo "objective anchor: missing; run scripts/session_begin.sh before writing (warning in $anchor_mode_value mode)."
      ;;
  esac
fi

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

# A mention is not a call, and a definition is not a call either. This is the
# ONE parser shared by the gate's wiring checks and validate_project's
# coverage/probe checks (an identical copy lives in validate_project.sh; the
# PowerShell scripts carry the same semantics). Rules:
#   1. comments (whole-line and trailing) are stripped before anything;
#   2. a path inside a function body counts only if that function is reached
#      from a top-level call (closure over `check "label" helper` and bare
#      helper calls) — an unused `never_used() { bash x.sh; }` proves nothing;
#   3. dead branches (`if false ...`, block or one-line) are dropped;
#   4. output lines are prefixed T (top level) or F <fnname> (reached body).
entry_live_lines() {
  local entry_file="$1"
  awk '
    function strip_comments(line,    hash) {
      if (line ~ /^[[:space:]]*#/) return ""
      hash = index(line, "#")
      if (hash > 0) line = substr(line, 1, hash - 1)
      sub(/[[:space:]]+$/, "", line)
      sub(/^[[:space:]]+/, "", line)
      return line
    }
    { raw[NR] = $0 }
    END {
      n = NR
      in_fn = 0
      for (i = 1; i <= n; i++) {
        line = strip_comments(raw[i])
        cleaned[i] = line
        is_fnline[i] = 0
        fn_name[i] = ""
        if (in_fn) {
          is_fnline[i] = 1
          fn_name[i] = cur_fn
          if (line ~ /^\}[[:space:]]*$/) { in_fn = 0; is_fnline[i] = 0 }
          continue
        }
        if (line ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/) {
          name = line
          sub(/\(\)[[:space:]]*\{.*$/, "", name)
          cur_fn = name
          is_fnline[i] = 1
          fn_name[i] = name
          if (line !~ /\}[[:space:]]*$/) in_fn = 1
          continue
        }
        if (line ~ /^function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\([[:space:]]*\)[[:space:]]*\{/) {
          name = line
          sub(/^function[[:space:]]+/, "", name)
          sub(/[[:space:]]*\(.*$/, "", name)
          cur_fn = name
          is_fnline[i] = 1
          fn_name[i] = name
          if (line !~ /\}[[:space:]]*$/) in_fn = 1
          continue
        }
      }
      in_dead = 0
      for (i = 1; i <= n; i++) {
        line = cleaned[i]
        if (line == "") continue
        if (line ~ /^if[[:space:]]+(false|!)[[:space:]]*([;:]|then|$)/ ||
          line ~ /^while[[:space:]]+false[[:space:]]*(;|do)/) {
          if (line !~ /;[[:space:]]*fi[[:space:]]*$/) in_dead = 1
          continue
        }
        if (in_dead) {
          if (line ~ /^fi[[:space:]]*$/) { in_dead = 0 }
          continue
        }
        if (is_fnline[i]) {
          body[fn_name[i]] = body[fn_name[i]] line "\n"
        } else {
          top_lines[ntop++] = line
        }
      }
      for (i = 0; i < ntop; i++) {
        l = top_lines[i]
        rest = l
        sub(/^.*check[[:space:]]+"[^"]*"/, "", rest)
        if (rest ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/) {
          sub(/^[[:space:]]*/, "", rest)
          sub(/[[:space:]]*$/, "", rest)
          queue[nq++] = rest
        }
        if (l ~ /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/) queue[nq++] = l
      }
      for (qi = 0; qi < nq; qi++) {
        f = queue[qi]
        if (seen[f]) continue
        seen[f] = 1
        if (!(f in body)) continue
        nlines = split(body[f], bl, "\n")
        for (k = 1; k <= nlines; k++) {
          b = bl[k]
          if (b == "") continue
          if (b ~ /^if[[:space:]]+(false|!)[[:space:]]*([;:]|then|$)/ ||
            b ~ /^while[[:space:]]+false[[:space:]]*(;|do)/) continue
          body_out[fno++] = "F " f " " b
          rest = b
          sub(/^.*check[[:space:]]+"[^"]*"/, "", rest)
          if (rest ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/) {
            sub(/^[[:space:]]*/, "", rest); sub(/[[:space:]]*$/, "", rest)
            queue[nq++] = rest
          }
          if (b ~ /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/) queue[nq++] = b
        }
      }
      for (i = 0; i < ntop; i++) print "T " top_lines[i]
      for (i = 0; i < fno; i++) print body_out[i]
    }
  ' "$entry_file"
}

entry_invokes_path() {
  local entry_file="$1"
  local wanted="$2"
  # The live analysis drops dead code; a live line must still look like a
  # CALL, not a mention. A string literal that names the path proves nothing.
  entry_live_lines "$entry_file" | grep -F -- "$wanted" |
    sed -E 's/^T //; s/^F [A-Za-z_][A-Za-z0-9_-]* //' |
    grep -Eq '(^|[^[:alnum:]_])(check|Invoke-Check|bash|sh|pwsh|powershell|python3?|node|npm|npx|source|\.)[[:space:]]|^&[[:space:]]|[|&;][[:space:]]*[^[:space:]]|\$\('
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
    behavioral_lines="$(awk '
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
        sub(/[[:space:]]+$/, "", line)
        print line
      }
    ' "$verify_entry")"
    behavioral_real=0
    if [[ -n "$behavioral_lines" ]]; then
      live_lines="$(entry_live_lines "$verify_entry")"
      live_top="$(printf '%s\n' "$live_lines" | sed -n 's/^T //p')"
      refs_of() {
        printf '%s\n' "$1" |
          grep -Eo '[A-Za-z0-9_][A-Za-z0-9_./-]*\.[A-Za-z0-9]+' | sed 's/^\.\///' |
          sed -E 's#^(root|rootFull|PSScriptRoot|projectRoot|repo|repoRoot)/##' |
          grep -vE '^(PROJECT_STATE|EVENTS|DECISIONS|CONTEXT|PROJECT_MAP|TASK_INDEX|MERGES|ASSETS|ENVIRONMENT|SOURCE_INDEX|AGENTS)\.md$'
      }
      while IFS= read -r behavioral_line; do
        [[ -n "$behavioral_line" ]] || continue
        # The behavioral line must itself be live: a check declared inside a
        # dead branch (`if false`) proves nothing.
        printf '%s\n' "$live_top" | grep -Fxq -- "$behavioral_line" || continue
        # The LABEL is documentation; only the executable part, the live block
        # body, and the body of the helper it reaches can carry the assertion.
        behavioral_exec="$(printf '%s\n' "$behavioral_line" |
          sed -E 's/^.*check[[:space:]]+"[^"]*"//')"
        behavioral_sources="$behavioral_exec"
        block_body="$(printf '%s\n' "$live_top" | awk -v line="$behavioral_line" '
          $0 == line { take = 1; next }
          take { if ($0 ~ /^\}[[:space:]]*$/) exit; print }
        ')"
        [[ -z "$block_body" ]] ||
          behavioral_sources="${behavioral_sources};${block_body}"
        helper_name="$(printf '%s\n' "$behavioral_exec" |
          grep -Eo '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*' | tr -d '[:space:]')"
        if [[ -n "$helper_name" ]]; then
          # The F lines are exactly the bodies the live analysis proved reachable.
          helper_live="$(printf '%s\n' "$live_lines" |
            grep "^F ${helper_name} " | sed "s/^F ${helper_name} //" | tr '\n' ';')"
          [[ -z "$helper_live" ]] ||
            behavioral_sources="${behavioral_sources};${helper_live}"
        fi
        while IFS= read -r behavioral_ref; do
          [[ -n "$behavioral_ref" ]] || continue
          if [[ -e "$root/$behavioral_ref" ]]; then
            behavioral_real=1
            break 2
          fi
        done < <(refs_of "$behavioral_sources")
      done <<< "$behavioral_lines"
    fi
    if [[ -z "$behavioral_lines" ]]; then
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
  case "$mode_value" in
    software | hybrid)
      # Deleting the checker must not restore the old "no lock at all" path:
      # the gate cannot honestly stamp when the handover safety proof itself
      # is absent. This is the same duty as SNAPSHOT MISSING.
      echo "Relay: BOUNDARY MISSING; scripts/boundary_check.sh is required on the completion path." >&2
      echo "Without it the gate cannot prove this session did not overwrite uncommitted handover work." >&2
      echo "PPS verify gate: FAILED (Relay: BOUNDARY MISSING)" >&2
      exit 1
      ;;
    *)
      echo "relay handover lock: boundary_check.sh unavailable; cannot verify handover safety (warning in $mode_value mode)." >&2
      ;;
  esac
fi



echo "-- Step 2e/4: structured check manifest execution"
# The check manifest is the executable truth: every row is a real command the
# gate runs on THIS platform, with the exit code compared to the expected one.
# Static text scanning of the entry is only a lint; it never satisfies
# red-line or coverage wiring on its own.
manifest_file="$root/.pps/verify-manifest.txt"
if [[ ! -f "$manifest_file" ]]; then
  echo "ERROR: missing .pps/verify-manifest.txt; the gate must run a declared check list, not trust prose." >&2
  echo "PPS verify gate: FAILED (missing check manifest)" >&2
  exit 1
fi
run_tsv="$root/.pps/.verify-run.tsv"
: > "$run_tsv"
run_failed=0
run_relevant=0
while IFS=$'\t' read -r check_id check_platform check_cwd check_timeout check_expected check_command check_note; do
  [[ -n "$check_id" ]] || continue
  case "$check_id" in '#'*) continue;; esac
  case "$check_platform" in any|bash) ;; *) continue;; esac
  if [[ ! "$check_id" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    echo "ERROR: invalid check id '$check_id'." >&2
    echo "PPS verify gate: FAILED (malformed check manifest)" >&2
    exit 1
  fi
  run_relevant=$((run_relevant + 1))
  item_cwd="$root"
  if [[ -n "$check_cwd" && "$check_cwd" != "." ]]; then
    # F-050-04: the working directory must live inside the project root.
    # Absolute paths and escapes (including via symlinks) fail the row.
    case "$check_cwd" in
      /*|*:*) echo "ERROR: manifest check $check_id cwd '$check_cwd' is absolute; a check working directory must live inside the project root." >&2; run_failed=1; continue ;;
    esac
    if ! cwd_abs="$(cd "$root/$check_cwd" 2>/dev/null && pwd -P)"; then
      echo "ERROR: manifest check $check_id cwd '$check_cwd' does not exist." >&2
      run_failed=1
      continue
    fi
    case "$cwd_abs/" in
      "$root/"*) item_cwd="$cwd_abs" ;;
      *) echo "ERROR: manifest check $check_id cwd '$check_cwd' escapes the project root." >&2; run_failed=1; continue ;;
    esac
  fi
  echo "check $check_id : $check_command"
  item_started="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  item_expected=0
  [[ "$check_expected" =~ ^[0-9]+$ ]] && item_expected="$check_expected"
  item_code=-1
  item_timed_out=0
  if [[ "$check_timeout" =~ ^[0-9]+$ ]] && (( check_timeout > 0 )); then
    # F-050-03: the timeout column is a real deadline. On expiry the whole
    # process tree is killed and the row fails.
    ( cd "$item_cwd" && bash -c "$check_command" ) &
    item_pid=$!
    waited=0
    while kill -0 "$item_pid" 2>/dev/null; do
      sleep 1
      waited=$((waited + 1))
      if (( waited >= check_timeout )); then
        item_timed_out=1
        kill "$item_pid" 2>/dev/null
        pkill -TERM -P "$item_pid" 2>/dev/null
        sleep 1
        kill -9 "$item_pid" 2>/dev/null
        pkill -KILL -P "$item_pid" 2>/dev/null
        break
      fi
    done
    wait "$item_pid" 2>/dev/null
    item_code=$?
    (( item_timed_out == 1 )) && item_code="timeout"
  else
    ( cd "$item_cwd" && bash -c "$check_command" )
    item_code=$?
  fi
  if (( item_timed_out == 1 )); then
    item_ok="false"
    run_failed=1
    echo "check $check_id : FAIL (timed out after ${check_timeout}s)"
  elif [[ "$item_code" == "$item_expected" ]]; then
    item_ok="true"
    echo "check $check_id : pass (exit $item_code, expected $item_expected)"
  else
    item_ok="false"
    run_failed=1
    echo "check $check_id : FAIL (exit $item_code, expected $item_expected)"
  fi
  [[ -n "$check_note" ]] && echo "  note: $check_note"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$check_id" "$check_platform" "$check_cwd" "$check_timeout" "$check_expected" \
    "$check_command" "$item_code" "$item_ok" "$item_started" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$run_tsv"
done < "$manifest_file"
if (( run_relevant == 0 )); then
  echo "ERROR: the check manifest declares no check for the bash platform." >&2
  run_failed=1
fi
write_run_out="$($python3_bin "$script_dir/pps_evidence.py" write-run "$root" 'bash' "$run_tsv" 2>&1)"
if [[ "$write_run_out" != "ok" && "$write_run_out" != "fail" ]]; then
  echo "ERROR: run record generation failed: $write_run_out" >&2
  echo "PPS verify gate: FAILED (run record generation)" >&2
  exit 1
fi
if (( run_failed == 1 )) || [[ "$write_run_out" != "ok" ]]; then
  echo "PPS verify gate: FAILED (check manifest execution)" >&2
  exit 1
fi
echo "check manifest execution: all declared checks passed"

echo "-- Step 2f/4: acceptance verification wiring"
# Acceptance items declare what "done" means; the gate proves each one was
# actually checked. A verify reference is satisfied by a PPS gate name, by a
# manifest check id that ran successfully on this platform, by a path the run
# record proves was executed, or by 'manual' while the item stays in Next.
acceptance_items="$(awk '
  $0 ~ "^##[[:space:]]+Current Package[[:space:]]*$" { inside=1; next }
  inside && /^##[[:space:]]/ { exit }
  inside && $0 ~ /^[[:space:]]*-[[:space:]]*A[0-9]+:/ { print }
' "$root/CONTEXT.md")"
if [[ -n "$acceptance_items" ]]; then
  acceptance_unwired=0
  acceptance_structural_only=""
  while IFS= read -r acceptance_line; do
    [[ -n "$acceptance_line" ]] || continue
    acceptance_id="$(printf '%s\n' "$acceptance_line" |
      sed -n 's/^[[:space:]]*-[[:space:]]*\(A[0-9][0-9]*\):.*/\1/p')"
    acceptance_token="$(printf '%s\n' "$acceptance_line" |
      sed -n 's/.*(verify:[[:space:]]*\([^)]*\)[[:space:]]*).*/\1/p')"
    if [[ -z "$acceptance_token" ]]; then
      echo "ERROR: acceptance item $acceptance_id has no '(verify: ...)' reference." >&2
      acceptance_unwired=1
      continue
    fi
    acceptance_token="$(printf '%s' "$acceptance_token" |
      sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    case "$acceptance_token" in
      validate_project | verify_gate | readiness_check | boundary_check | asset_check)
        acceptance_structural_only="${acceptance_structural_only}${acceptance_id} "
        continue
        ;;
      manual)
        next_value="$(
          awk '
            $0 ~ "^##[[:space:]]+Hot State[[:space:]]*$" { inside=1; next }
            inside && /^##[[:space:]]/ { exit }
            inside && index($0, "- Next:") == 1 {
              sub("^- Next:[[:space:]]*", "")
              print
              exit
            }
          ' "$root/PROJECT_STATE.md"
        )"
        if printf '%s' "$next_value" | grep -Eq "(^|[^[:alnum:]])${acceptance_id}([^[:alnum:]]|\$)"; then
          continue
        fi
        echo "ERROR: acceptance item $acceptance_id uses 'manual' but is not restated in Hot State Next; a manual acceptance must stay openly pending." >&2
        acceptance_unwired=1
        continue
        ;;
    esac
    if awk -F'\t' -v wanted="$acceptance_token" \
      '$1 == wanted && $8 == "true" {found=1} END {exit !found}' "$run_tsv"; then
      continue
    fi
    if [[ "$($python3_bin "$script_dir/pps_evidence.py" run-has-path "$root" "$acceptance_token" 2>/dev/null)" == "ok" ]]; then
      continue
    fi
    echo "ERROR: acceptance item $acceptance_id names '(verify: $acceptance_token)' but no manifest check ran it successfully on this platform." >&2
    acceptance_unwired=1
  done <<< "$acceptance_items"
  if (( acceptance_unwired == 1 )); then
    echo "Add a check row for the named check to .pps/verify-manifest.txt and re-run the gate." >&2
    echo "PPS verify gate: FAILED (acceptance not wired to an executed check)" >&2
    exit 1
  fi
  acceptance_structural_only="$(printf '%s' "$acceptance_structural_only" | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')"
  if [[ -n "$acceptance_structural_only" ]] &&
     [[ "$mode_value" =~ ^(software|hybrid)$ ]] &&
     ! printf '%s' "$stage_value" | grep -q 'bootstrap'; then
    echo "ERROR: non-bootstrap $mode_value package has acceptance items that only name structural gate names: $acceptance_structural_only." >&2
    echo "After bootstrap, every acceptance item must be backed by a manifest check or a real project artifact path." >&2
    echo "PPS verify gate: FAILED (acceptance items are structural-only floor)" >&2
    exit 1
  fi
  echo "acceptance wiring: every acceptance item is backed by an executed check"
else
  echo "acceptance wiring: no acceptance items declared (bootstrap or pre-1.2 package)"
fi
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
  # Wiring now means EXECUTED: the path must appear in a check manifest row
  # that the gate ran successfully on this platform. Text shape in the entry
  # is only a lint; it can never satisfy wiring on its own.
  redline_unwired=0
  while IFS= read -r redline_target; do
    [[ -n "$redline_target" ]] || continue
    run_evidence="$($python3_bin "$script_dir/pps_evidence.py" run-has-path "$root" "$redline_target" 2>/dev/null)"
    if [[ "$run_evidence" == "ok" ]]; then
      continue
    fi
    shape_lint=""
    if entry_invokes_path "$verify_entry" "$redline_target"; then
      shape_lint=" (the gate entry mentions it, but a mention is not an execution)"
    fi
    echo "ERROR: red line names '(verify: $redline_target)' but no manifest check ran it successfully on this platform${shape_lint}." >&2
    redline_unwired=1
  done <<< "$redline_targets"
  if (( redline_unwired == 1 )); then
    echo "Add a check row for the named path to .pps/verify-manifest.txt and re-run the gate." >&2
    echo "PPS verify gate: FAILED (red line not wired to an executed check)" >&2
    exit 1
  fi
  echo "red line wiring: all named checks are wired to executed manifest checks"
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
manifest_sha="absent"
[[ -f "$root/.pps/verify-manifest.txt" ]] && manifest_sha="$(sha256_of "$root/.pps/verify-manifest.txt")"
run_sha="absent"
[[ -f "$root/.pps/verify-run.json" ]] && run_sha="$(sha256_of "$root/.pps/verify-run.json")"
{
  printf 'package: %s\n' "$package_id"
  printf 'entry: %s\n' "$entry_rel"
  printf 'entry_sha256: %s\n' "$entry_sha"
  printf 'capsule_sha256: %s\n' "$capsule_sha"
  printf 'manifest_sha256: %s\n' "$manifest_sha"
  printf 'run_sha256: %s\n' "$run_sha"
  printf 'objective_sha256: %s\n' "$anchor_current_hash"
  printf 'platform: bash\n'
  printf 'result: pass\n'
  printf 'worktree: %s\n' "$worktree_id"
  printf 'verified_at: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$root/.pps/verify-stamp"
echo "verify stamp: $package_id"
echo "PPS verify gate: OK"

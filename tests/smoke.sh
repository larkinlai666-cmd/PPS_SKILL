#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
skill="$repo_root/skills/pps-skill"
temp_root="$(mktemp -d "${TMPDIR:-/tmp}/pps-skill-smoke.XXXXXX")"

cleanup() {
  case "$temp_root" in
    "${TMPDIR:-/tmp}"/pps-skill-smoke.*) rm -rf "$temp_root" ;;
    *) echo "Refusing unexpected cleanup target: $temp_root" >&2 ;;
  esac
}
trap cleanup EXIT

bash "$skill/scripts/validate_skill.sh" "$skill"
cp -R "$skill" "$temp_root/broken-skill"
rm "$temp_root/broken-skill/references/protocol.md"
if bash "$temp_root/broken-skill/scripts/validate_skill.sh" \
  "$temp_root/broken-skill" >"$temp_root/broken-skill.out" 2>&1; then
  echo "Skill health validator accepted a missing required file." >&2
  exit 1
fi
grep -q "Missing required skill file: references/protocol.md" \
  "$temp_root/broken-skill.out"

expect_invalid() {
  local project_root="$1"
  local expected="$2"
  local label="$3"
  local output_file="$temp_root/$(basename "$project_root").invalid.out"
  if bash "$project_root/scripts/validate_project.sh" \
    "$project_root" >"$output_file" 2>&1; then
    echo "$label was incorrectly accepted." >&2
    exit 1
  fi
  grep -q "$expected" "$output_file" || {
    echo "$label failed without the expected diagnostic: $expected" >&2
    cat "$output_file" >&2
    exit 1
  }
}

bash "$skill/scripts/init_project.sh" standard-case \
  --profile standard --parent "$temp_root" --no-git
bash "$skill/scripts/init_project.sh" evidence-case \
  --profile evidence --parent "$temp_root" --no-git

bash "$temp_root/standard-case/scripts/status_check.sh" \
  --root "$temp_root/standard-case"
bash "$temp_root/evidence-case/scripts/validate_project.sh" \
  "$temp_root/evidence-case"

[[ -f "$temp_root/evidence-case/SOURCE_INDEX.md" ]]
[[ -f "$temp_root/evidence-case/docs/CURRENT_REVIEW_EVIDENCE.md" ]]
[[ -d "$temp_root/standard-case/assets" ]]
[[ -d "$temp_root/standard-case/prototypes" ]]
[[ -f "$temp_root/standard-case/scripts/pre-commit" ]]
[[ -f "$temp_root/standard-case/scripts/pre-commit.ps1" ]]

cp -R "$temp_root/standard-case" "$temp_root/lifecycle-valid"
printf '\n### D-700 [superseded]\n\n- Summary: retained history.\n' \
  >>"$temp_root/lifecycle-valid/DECISIONS.md"
printf '\n### F-700 [frozen]\n\n- Summary: frozen history.\n' \
  >>"$temp_root/lifecycle-valid/DECISIONS.md"
bash "$temp_root/lifecycle-valid/scripts/validate_project.sh" \
  "$temp_root/lifecycle-valid" --quiet

bash "$skill/scripts/init_project.sh" git-case \
  --profile standard --parent "$temp_root" \
  --git-name "PPS Smoke" --git-email "pps-smoke@example.invalid" \
  --install-hook
git_case="$temp_root/git-case"
[[ "$(git -C "$git_case" branch --show-current)" == "main" ]]
[[ -x "$git_case/.git/hooks/pre-commit" ]]

remote_case="$temp_root/remote.git"
if ! git init --quiet --bare -b main "$remote_case" 2>/dev/null; then
  git init --quiet --bare "$remote_case"
fi
git -C "$git_case" remote add origin "$remote_case"
git -C "$git_case" push --quiet -u origin main
bash "$git_case/scripts/status_check.sh" --root "$git_case" --fetch \
  >"$temp_root/git-status.out"
grep -q '^Git-Remotes: origin$' "$temp_root/git-status.out"
grep -q '^Git-Upstream: origin/main$' "$temp_root/git-status.out"
grep -q '^Git-Ahead: 0$' "$temp_root/git-status.out"
grep -q '^Git-Behind: 0$' "$temp_root/git-status.out"

git -C "$git_case" remote add broken "$temp_root/does-not-exist.git"
if bash "$git_case/scripts/status_check.sh" --root "$git_case" --fetch \
  >"$temp_root/git-fetch-failed.out" 2>&1; then
  echo "Status check returned success after a requested fetch failed." >&2
  exit 1
fi
grep -q '^Git-Fetch: FAILED$' "$temp_root/git-fetch-failed.out"
git -C "$git_case" remote remove broken

git clone --quiet "$remote_case" "$temp_root/peer"
git -C "$temp_root/peer" config user.name "PPS Peer"
git -C "$temp_root/peer" config user.email "pps-peer@example.invalid"
printf 'remote checkpoint\n' >"$temp_root/peer/peer.txt"
git -C "$temp_root/peer" add peer.txt
git -C "$temp_root/peer" commit --quiet -m "test: remote checkpoint"
git -C "$temp_root/peer" push --quiet
bash "$git_case/scripts/status_check.sh" --root "$git_case" --fetch \
  >"$temp_root/git-behind.out"
grep -q '^Git-Behind: 1$' "$temp_root/git-behind.out"
git -C "$git_case" pull --quiet --ff-only

printf 'local checkpoint\n' >"$git_case/notes.txt"
git -C "$git_case" add notes.txt
git -C "$git_case" commit --quiet -m "test: local checkpoint"
bash "$git_case/scripts/status_check.sh" --root "$git_case" \
  >"$temp_root/git-ahead.out"
grep -q '^Git-Ahead: 1$' "$temp_root/git-ahead.out"

sed -i.bak '/^- Excluded:/d' "$git_case/CONTEXT.md"
git -C "$git_case" add CONTEXT.md
git -C "$git_case" restore --worktree -- CONTEXT.md
if git -C "$git_case" commit -m "test: invalid state" \
  >"$temp_root/hook.out" 2>&1; then
  echo "Installed pre-commit hook accepted invalid staged PPS state." >&2
  exit 1
fi
grep -q "PPS pre-commit: staged project validation failed" "$temp_root/hook.out"

mkdir -p "$temp_root/nonempty"
printf 'keep\n' >"$temp_root/nonempty/user.txt"
if bash "$skill/scripts/init_project.sh" nonempty \
  --parent "$temp_root" --no-git >"$temp_root/nonempty.out" 2>&1; then
  echo "Initializer accepted a non-empty target." >&2
  exit 1
fi
grep -q "Refusing to initialize a non-empty target" "$temp_root/nonempty.out"
[[ "$(cat "$temp_root/nonempty/user.txt")" == "keep" ]]

if bash "$skill/scripts/init_project.sh" 'invalid/name' \
  --parent "$temp_root" --no-git >"$temp_root/invalid-name.out" 2>&1; then
  echo "Initializer accepted an invalid project name." >&2
  exit 1
fi
grep -q "Project name may contain only" "$temp_root/invalid-name.out"
if bash "$skill/scripts/init_project.sh" '..' \
  --parent "$temp_root" --no-git >"$temp_root/dotdot-name.out" 2>&1; then
  echo "Initializer accepted '..' as a project name." >&2
  exit 1
fi
grep -q "cannot be '.' or '..'" "$temp_root/dotdot-name.out"

if bash "$skill/scripts/init_project.sh" 'CON' \
  --parent "$temp_root" --no-git >"$temp_root/reserved-name.out" 2>&1; then
  echo "Initializer accepted a non-portable reserved project name." >&2
  exit 1
fi
grep -q "Windows-reserved device name" "$temp_root/reserved-name.out"

if bash "$skill/scripts/init_project.sh" missing-arg \
  --parent >"$temp_root/missing-arg.out" 2>&1; then
  echo "Initializer accepted an option without its argument." >&2
  exit 1
fi
grep -q '^Usage:' "$temp_root/missing-arg.out"

if bash "$skill/scripts/init_project.sh" contradictory \
  --parent "$temp_root" --no-git --install-hook \
  >"$temp_root/contradictory.out" 2>&1; then
  echo "Initializer accepted contradictory Git options." >&2
  exit 1
fi
grep -q "cannot be used with --no-git" "$temp_root/contradictory.out"

if bash "$temp_root/standard-case/scripts/validate_project.sh" \
  "$temp_root/standard-case" extra >"$temp_root/validator-extra.out" 2>&1; then
  echo "Validator accepted an extra positional argument." >&2
  exit 1
fi
grep -q '^Usage:' "$temp_root/validator-extra.out"

cp -R "$temp_root/standard-case" "$temp_root/missing-coverage"
sed -i.bak '/^| M-002 |/d' "$temp_root/missing-coverage/CONTEXT.md"
if bash "$temp_root/missing-coverage/scripts/validate_project.sh" \
  "$temp_root/missing-coverage" >"$temp_root/missing.out" 2>&1; then
  echo "Missing coverage was incorrectly accepted." >&2
  exit 1
fi
grep -q "Manifest ID M-002 must have exactly one row" "$temp_root/missing.out"

cp -R "$temp_root/standard-case" "$temp_root/inactive-decision"
sed -i.bak 's/^- Decisions: none$/- Decisions: D-404/' \
  "$temp_root/inactive-decision/CONTEXT.md"
if bash "$temp_root/inactive-decision/scripts/validate_project.sh" \
  "$temp_root/inactive-decision" >"$temp_root/inactive.out" 2>&1; then
  echo "Inactive manifest decision was incorrectly accepted." >&2
  exit 1
fi
grep -q "Manifest ID D-404 must appear exactly once" "$temp_root/inactive.out"

cp -R "$temp_root/standard-case" "$temp_root/duplicate-active-block"
printf '\n<!-- PPS:ACTIVE:BEGIN -->\n<!-- PPS:ACTIVE:END -->\n' \
  >>"$temp_root/duplicate-active-block/DECISIONS.md"
expect_invalid "$temp_root/duplicate-active-block" \
  "must contain exactly one active authority block" \
  "Duplicate active block"

cp -R "$temp_root/standard-case" "$temp_root/orphan-active-record"
printf '\n### D-999 [active]\n\n- Summary: orphan.\n' \
  >>"$temp_root/orphan-active-record/DECISIONS.md"
expect_invalid "$temp_root/orphan-active-record" \
  "Active record D-999 must appear exactly once in the active block" \
  "Orphan active record"

cp -R "$temp_root/standard-case" "$temp_root/duplicate-global-id"
printf '\n### M-001 [superseded]\n\n- Summary: duplicate.\n' \
  >>"$temp_root/duplicate-global-id/DECISIONS.md"
expect_invalid "$temp_root/duplicate-global-id" \
  "Authority ID has more than one canonical record: M-001" \
  "Duplicate canonical authority ID"
grep -Eq 'DECISIONS.md lines [0-9]+,[0-9]+' \
  "$temp_root/duplicate-global-id.invalid.out"

cp -R "$temp_root/standard-case" "$temp_root/missing-excluded"
sed -i.bak '/^- Excluded:/d' "$temp_root/missing-excluded/CONTEXT.md"
expect_invalid "$temp_root/missing-excluded" \
  "Expected exactly one 'Excluded' field in 'Workset Manifest', found 0" \
  "Missing Excluded field"

cp -R "$temp_root/standard-case" "$temp_root/package-mismatch"
sed -i.bak 's/^- ID: PKG-001$/- ID: PKG-999/' \
  "$temp_root/package-mismatch/CONTEXT.md"
expect_invalid "$temp_root/package-mismatch" \
  "does not match PROJECT_STATE Package" \
  "Package mismatch"

cp -R "$temp_root/standard-case" "$temp_root/wrong-type-manifest"
sed -i.bak \
  's/^- Methods: M-001, M-002$/- Methods: M-001, M-002, D-999/' \
  "$temp_root/wrong-type-manifest/CONTEXT.md"
expect_invalid "$temp_root/wrong-type-manifest" \
  "comma-separated list of only M IDs" \
  "Wrong authority class in manifest"

cp -R "$temp_root/standard-case" "$temp_root/duplicate-manifest-id"
sed -i.bak \
  's/^- Methods: M-001, M-002$/- Methods: M-001, M-001, M-002/' \
  "$temp_root/duplicate-manifest-id/CONTEXT.md"
expect_invalid "$temp_root/duplicate-manifest-id" \
  "Methods contains duplicate IDs: M-001" \
  "Duplicate manifest ID"

cp -R "$temp_root/standard-case" "$temp_root/manifest-whitespace-merge"
sed -i.bak \
  's/^- Methods: M-001, M-002$/- Methods: M-001 M-002/' \
  "$temp_root/manifest-whitespace-merge/CONTEXT.md"
expect_invalid "$temp_root/manifest-whitespace-merge" \
  "comma-separated list of only M IDs" \
  "Manifest IDs merged by whitespace"

cp -R "$temp_root/standard-case" "$temp_root/duplicate-coverage"
printf '| M-001 | Duplicate | `docs/MAIN.md` | Conflicting |\n' \
  >>"$temp_root/duplicate-coverage/CONTEXT.md"
expect_invalid "$temp_root/duplicate-coverage" \
  "Manifest ID M-001 must have exactly one row" \
  "Duplicate coverage row"
grep -Eq 'found 2 \(lines [0-9]+,[0-9]+\)' \
  "$temp_root/duplicate-coverage.invalid.out"

cp -R "$temp_root/evidence-case" "$temp_root/evidence-package-mismatch"
sed -i.bak 's/^- ID: PKG-001$/- ID: PKG-999/' \
  "$temp_root/evidence-package-mismatch/docs/CURRENT_REVIEW_EVIDENCE.md"
expect_invalid "$temp_root/evidence-package-mismatch" \
  "Evidence package 'PKG-999' does not match PROJECT_STATE Package" \
  "Evidence package mismatch"

cp -R "$temp_root/evidence-case" "$temp_root/duplicate-source-row"
sed -i.bak 's/^- Sources: none$/- Sources: SRC-001/' \
  "$temp_root/duplicate-source-row/CONTEXT.md"
printf '| SRC-001 | source-a | v1 | F-001 | none | review |\n' \
  >>"$temp_root/duplicate-source-row/SOURCE_INDEX.md"
printf '| SRC-001 | source-b | v2 | F-001 | conflict | reject |\n' \
  >>"$temp_root/duplicate-source-row/SOURCE_INDEX.md"
expect_invalid "$temp_root/duplicate-source-row" \
  "Source ID SRC-001 must have exactly one row" \
  "Duplicate source row"
grep -Eq 'found 2 \(lines [0-9]+,[0-9]+\)' \
  "$temp_root/duplicate-source-row.invalid.out"

cp -R "$temp_root/standard-case" "$temp_root/misplaced-hot-field"
sed -i.bak '/^- Protocol: PPS\/1.0$/d' \
  "$temp_root/misplaced-hot-field/PROJECT_STATE.md"
printf '\n## Misplaced\n\n- Protocol: PPS/1.0\n' \
  >>"$temp_root/misplaced-hot-field/PROJECT_STATE.md"
expect_invalid "$temp_root/misplaced-hot-field" \
  "Expected exactly one 'Protocol' field in 'Hot State', found 0" \
  "Hot-state field outside canonical section"

cp -R "$temp_root/standard-case" "$temp_root/misplaced-workset-field"
sed -i.bak '/^- Facts: none$/d' \
  "$temp_root/misplaced-workset-field/CONTEXT.md"
printf '\n## Misplaced\n\n- Facts: none\n' \
  >>"$temp_root/misplaced-workset-field/CONTEXT.md"
expect_invalid "$temp_root/misplaced-workset-field" \
  "Expected exactly one 'Facts' field in 'Workset Manifest', found 0" \
  "Workset field outside canonical section"

cp -R "$temp_root/standard-case" "$temp_root/duplicate-hot-section"
printf '\n## Hot State\n\n- Protocol: PPS/1.0\n' \
  >>"$temp_root/duplicate-hot-section/PROJECT_STATE.md"
expect_invalid "$temp_root/duplicate-hot-section" \
  "Expected exactly one 'Hot State' section, found 2" \
  "Duplicate hot-state section"

cp -R "$temp_root/standard-case" "$temp_root/reversed-active-markers"
sed -i.bak 's/PPS:ACTIVE:BEGIN/PPS:ACTIVE:TEMP/' \
  "$temp_root/reversed-active-markers/DECISIONS.md"
sed -i.bak 's/PPS:ACTIVE:END/PPS:ACTIVE:BEGIN/' \
  "$temp_root/reversed-active-markers/DECISIONS.md"
sed -i.bak 's/PPS:ACTIVE:TEMP/PPS:ACTIVE:END/' \
  "$temp_root/reversed-active-markers/DECISIONS.md"
expect_invalid "$temp_root/reversed-active-markers" \
  "active authority markers are out of order" \
  "Reversed active markers"

cp -R "$temp_root/standard-case" "$temp_root/invalid-package-id"
sed -i.bak 's/^- Package: PKG-001$/- Package: package one/' \
  "$temp_root/invalid-package-id/PROJECT_STATE.md"
expect_invalid "$temp_root/invalid-package-id" \
  "Package must use a PKG-\* ID" \
  "Invalid package ID"

cp -R "$temp_root/standard-case" "$temp_root/invalid-updated-time"
sed -i.bak 's/^- Updated: .*Z$/- Updated: 2026-02-30T12:00:00Z/' \
  "$temp_root/invalid-updated-time/PROJECT_STATE.md"
expect_invalid "$temp_root/invalid-updated-time" \
  "Updated must be a UTC timestamp" \
  "Invalid Updated timestamp"

cp -R "$temp_root/standard-case" "$temp_root/frozen-in-active-block"
sed -i.bak '/PPS:ACTIVE:END/i\
- `D-777`
' "$temp_root/frozen-in-active-block/DECISIONS.md"
printf '\n### D-777 [frozen]\n\n- Summary: frozen item.\n' \
  >>"$temp_root/frozen-in-active-block/DECISIONS.md"
expect_invalid "$temp_root/frozen-in-active-block" \
  "Active ID D-777 must have exactly one \[active\] record, found 0" \
  "Frozen authority in active block"

printf '# Outside project\n' >"$temp_root/outside-main.md"
cp -R "$temp_root/standard-case" "$temp_root/symlink-escape"
ln -s "$temp_root/outside-main.md" "$temp_root/symlink-escape/outside-main.md"
sed -i.bak 's|^- Main: docs/MAIN.md$|- Main: outside-main.md|' \
  "$temp_root/symlink-escape/PROJECT_STATE.md"
expect_invalid "$temp_root/symlink-escape" \
  "Main must not traverse a symbolic link" \
  "Symbolic-link path escape"

legacy="$temp_root/legacy-case"
mkdir -p "$legacy/docs"
printf '# Legacy project\n' >"$legacy/README.md"
printf '# Agent handoff\n' >"$legacy/AGENTS.md"
printf '%s\n' '# Project state' '- Main: docs/PLAN.md' >"$legacy/PROJECT_STATE.md"
printf '# Decisions\n' >"$legacy/DECISIONS.md"
printf '# Plan\n' >"$legacy/docs/PLAN.md"
printf '# Ordinary roadmap\n' >"$legacy/ROADMAP.md"
legacy_before="$(
  {
    find "$legacy" -print
    find "$legacy" -type f -exec cksum {} \;
  } | LC_ALL=C sort
)"
legacy_report="$temp_root/legacy-report.md"
bash "$skill/scripts/audit_legacy_project.sh" \
  --root "$legacy" --output "$legacy_report"
legacy_after="$(
  {
    find "$legacy" -print
    find "$legacy" -type f -exec cksum {} \;
  } | LC_ALL=C sort
)"
[[ "$legacy_before" == "$legacy_after" ]]
grep -q 'Detected system: `plan-project-sync`' "$legacy_report"
grep -q 'Audit mode: read-only' "$legacy_report"

if bash "$skill/scripts/audit_legacy_project.sh" \
  --root "$legacy" --output "$legacy/MIGRATION_REPORT.md" \
  >"$temp_root/inside-report.out" 2>&1; then
  echo "Audit report was incorrectly written inside the target." >&2
  exit 1
fi
grep -q "Refusing to write the audit report inside the target project" \
  "$temp_root/inside-report.out"
[[ ! -e "$legacy/MIGRATION_REPORT.md" ]]

mixed="$temp_root/mixed-case"
mkdir -p "$mixed/legacy-state"
cp "$legacy/AGENTS.md" "$mixed/AGENTS.md"
cp "$legacy/PROJECT_STATE.md" "$mixed/PROJECT_STATE.md"
cp "$legacy/DECISIONS.md" "$mixed/DECISIONS.md"
printf '# Legacy state\n' >"$mixed/legacy-state/STATE.md"
bash "$skill/scripts/audit_legacy_project.sh" --root "$mixed" \
  >"$temp_root/mixed-report.md"
grep -q 'Detected system: `mixed`' "$temp_root/mixed-report.md"
grep -q "Do not write until one authority is selected" \
  "$temp_root/mixed-report.md"

pps_with_history="$temp_root/pps-with-history"
cp -R "$temp_root/standard-case" "$pps_with_history"
mkdir -p "$pps_with_history/legacy-state"
printf '# Archived state\n' >"$pps_with_history/legacy-state/STATE.md"
bash "$skill/scripts/audit_legacy_project.sh" --root "$pps_with_history" \
  >"$temp_root/pps-history-report.md"
grep -q 'Detected system: `pps`' "$temp_root/pps-history-report.md"

echo "PPS Bash smoke tests: OK"
